//! The rows of a view of a document for the log table (ptable): the view as a `RowSource` (`DocumentRows`,
//! which tells the changes of the document), the columns as the log table shows them (`documentColumns`:
//! ui/row_cells), the level, found and anchored marks as extra data, and the model both tables of a
//! document are made of (`documentTableModel`, a `ColumnarModel` of ptable). Free of Sciter.
//! docs/stories/painted-table.md.
module ui.log_table.document_model;

import domain.document_id : DocumentId;
import domain.document : DocumentView;
import domain.document_item : DocumentItem;
import log_core.log_format : ColumnInfo, ColumnKind;
import log_core.log_level : LogLevel;
import log_core.search_filter : MatchBuffer;
import ptable.columnar : Column, ColumnarModel, RowSource;
import ptable.column : TableColumn;
import ptable_text.columnstyle : ColumnStyle;
import ptable_text.measurer : TextMeasurer;
import ptable.layout : ColumnDef;
import ptable.listeners : Listeners;
import ptable.memory : Buffer, mallocAllocator;
import ptable.model;
import ui.app_session : AppSession;
import ui.log_table.text_column : TextColumn;
import ui.log_table.marks;
import ptable.cellparts : HeadedCellPartsExtractor, firstSpace;
import ptable_text.columnstyle : Halign;
import ui.log_table.log_columns : AnchorColumn, IndexColumn, LevelColumn;
import ui.log_table.log_look : LogFont, LogLook, defaultLogLook;
import ui.row_cells : putColumnText, putNumber;
import ui.log_table.view_events : ViewChangeTracker, ViewListener, ViewVersion;

import std.datetime.timezone : LocalTime, TimeZone;
import std.uni : toLower;

/// The parts of a cell of time: its date heads the rows of its day ("2026/11/18 12:34:56.000001", `putTime`); a time
/// since boot or none has no date
immutable HeadedCellPartsExtractor timeParts = new immutable HeadedCellPartsExtractor(&firstSpace);

/// What the look and the settings say of the columns of the log table: the room left of the Payload text (less than 0: the
/// geometry's) and whether the Payload wraps (not in the single-line view)
struct LogColumnLook
{
    double payloadPadLeft = -1;
    bool wrapPayload = true;
    LogLook look; /// the colors the columns that draw by themselves read; null: the default look
    bool delegate() anchorsFull; /// whether no room is left for another anchor: null, there is always room
    TextMeasurer measurer; /// what the columns measure their texts and fonts by; null: nothing (a test)
}

/// The columns of a table of the log: a column of the anchor marks, the Index, the columns of the
/// format but the Payload, which takes the rest and is the last; a column of time groups the rows by its date.
/// Pure, for the tests.
TableColumn[] logColumns(const(ColumnInfo)[] columns, LogColumnLook look = LogColumnLook.init)
{
    auto palette = look.look !is null ? look.look : defaultLogLook();
    auto anchorDef = ColumnDef("anchor", "⚓", 24);
    anchorDef.selectable = false;
    anchorDef.clickable = true; // a click sets or clears the anchor
    auto anchor = new AnchorColumn(anchorDef, palette, look.anchorsFull, look.measurer);
    anchor.style.cell.halign = Halign.center; // the mark stands in the middle of its cell
    auto index = new IndexColumn(ColumnDef("index", "Index"), palette, look.measurer);
    index.style.cell.halign = Halign.right;
    anchor.style.header.halign = index.style.header.halign = Halign.center;
    anchor.style.cell.font = index.style.cell.font = LogFont.aux;
    TableColumn[] made = [anchor, index];
    foreach (i, ref c; columns)
    {
        const def = i + 1 == columns.length ? ColumnDef(c.id, c.title, 200, true) : ColumnDef(c.id, c.title);
        TextColumn column = c.kind == ColumnKind.Level ? new LevelColumn(def, palette, look.measurer) : new TextColumn(def, palette, look.measurer);
        // the numbers and texts of the columns stand at their right side, a level in the middle, the Payload at its left;
        // the titles are in the middle but the Payload's (as in the old table)
        column.style.cell.halign = c.kind == ColumnKind.Level ? Halign.center : Halign.right;
        column.style.cell.font = c.kind == ColumnKind.Level ? LogFont.body : LogFont.aux;
        column.style.header.halign = Halign.center;
        if (def.flex)
        {
            column.style.cell.halign = column.style.header.halign = Halign.left;
            column.style.cell.font = LogFont.body;
            // the text of the last column and its title start a bit further from its border
            column.style.cell.padLeft = column.style.header.padLeft = look.payloadPadLeft;
            column.style.wrap = look.wrapPayload;
        }
        if (c.kind == ColumnKind.Time)
            column.parts = timeParts;
        made ~= column;
    }
    return made;
}


/// The columns of a table of the log as ptable's columns of a `DocumentItem`: the anchor marks (no text),
/// the Index, and a column of the format each. `indexExtra` is what the Index cell carries (the rule color).
Column!DocumentItem[] documentColumns(const(ColumnInfo)[] infos, immutable TimeZone zone, Extra delegate(ref const DocumentItem) indexExtra,
    LogColumnLook look = LogColumnLook.init, void delegate(ref const DocumentItem, ref Buffer!Fragment) payloadFragments = null)
{
    auto made = logColumns(infos, look);
    auto columns = new Column!DocumentItem[made.length];
    foreach (i, column; made)
        columns[i].column = column;
    columns[1].text = (ref const DocumentItem item, ref Buffer!wchar into) { putNumber(into, item.realIndex); };
    columns[1].extra = indexExtra;
    // what a column that draws more than text draws by is in the data of its own cell, not of the row: the anchor and the level
    columns[0].extra = (ref const DocumentItem item) => Extra(item.anchored ? anchoredMark : 0);
    foreach (i; 0 .. infos.length)
    {
        columns[2 + i].text = formatColumnText(infos, i, zone);
        if (infos[i].kind == ColumnKind.Level)
            columns[2 + i].extra = (ref const DocumentItem item) => Extra(cast(ulong) item.message.level);
    }
    columns[$ - 1].fragments = payloadFragments; // what the search found shows in the Payload, the last column
    return columns;
}

// The writer of the cell of the column `at` of the format. A function of its own: a closure made in a loop
// shares the variables of the loop's function (every column would write the last one's text)
private void delegate(ref const DocumentItem, ref Buffer!wchar) formatColumnText(const(ColumnInfo)[] infos, size_t at, immutable TimeZone zone)
{
    return (ref const DocumentItem item, ref Buffer!wchar into) {
        putColumnText(into, item.message, infos[at], zone);
    };
}

/// The extra data of a row of the log: its level and the marks the search and the anchors put on it
Extra rowExtraOf(ref const DocumentItem item)
{
    return Extra(cast(ulong) item.message.level | (item.found ? foundMark : 0) | (item.anchored ? anchoredMark : 0));
}

/// A view of a document as the rows of a table; tells the changes of the document by the rule of
/// ReadyView.dataVersion: rows appended under one version, everything for a new one
final class DocumentRows : RowSource!DocumentItem
{
    private AppSession _session;
    private DocumentId _docId;
    private bool _search;
    private ViewChangeTracker _tracker;
    private Listeners!ModelChange _listeners;
    private size_t _sessionHandle;
    private bool _hearing;

    this(AppSession session, DocumentId docId, bool search)
    {
        _session = session;
        _docId = docId;
        _search = search;
    }

    private DocumentView view()
    {
        auto doc = _session.doc(_docId);
        return _search ? doc.searchView : doc.mainView;
    }

    size_t count()
    {
        return view().itemsCount();
    }

    bool fetch(size_t index, ref DocumentItem row)
    {
        return view().fetchItem(index, row);
    }

    ulong idOf(ref const DocumentItem row)
    {
        return row.realIndex;
    }

    bool indexOf(ulong rowId, out size_t position)
    {
        return view().positionOf(cast(size_t) rowId, position);
    }

    // The session is listened to while somebody listens to the rows
    size_t subscribe(ModelListener listener)
    {
        if (!_hearing)
        {
            _hearing = true;
            _sessionHandle = _session.subscribeViews(_docId, ViewListener(&viewShown, &columnsChanged));
        }
        return _listeners.add(listener);
    }

    void unsubscribe(size_t handle)
    {
        _listeners.remove(handle);
        if (_hearing && _listeners.length == 0)
        {
            _hearing = false;
            _session.unsubscribeViews(_sessionHandle);
        }
    }

    private void viewShown(bool search, ViewVersion shown)
    {
        ModelChange change;
        if (search == _search && _tracker.next(shown, count(), change))
            tell(change);
    }

    private void columnsChanged()
    {
        tell(ModelChange(ModelChange.Kind.columns));
    }

    /// The row of the message `message` changed (an anchor was set or cleared on it). `moved`: it came into the view or left it, the rows
    /// after it are other ones. A row that is in the view is read again where it stands; one that left it is not found, so from the
    /// start of the view on
    void messageChanged(size_t message, bool moved)
    {
        size_t position;
        const found = view().positionOf(message, position);
        if (moved)
            tell(ModelChange(ModelChange.Kind.count, found ? position : 0, count()));
        else if (found)
            tell(ModelChange(ModelChange.Kind.rows, position, position + 1));
    }

    private void tell(const ModelChange change)
    {
        _listeners.tell(change);
    }
}

/// The columns of a document as the tables show them now (the settings may change them): the same array
/// until the columns of the format or their layout change
final class DocumentColumns
{
    private AppSession _session;
    private DocumentId _docId;
    private const(ColumnInfo)[] _infos;
    private Column!DocumentItem[] _columns;
    private immutable TimeZone _zone;
    private LogColumnLook delegate() _look; // the look and the settings of the columns: they may change
    private LogColumnLook _made; // what the columns were made with

    this(AppSession session, DocumentId docId, LogColumnLook delegate() look)
    {
        _session = session;
        _docId = docId;
        _zone = LocalTime();
        _look = look;
    }

    Column!DocumentItem[] get()
    {
        const now = _session.tableColumns(_session.doc(_docId));
        auto look = _look !is null ? _look() : LogColumnLook.init;
        if (_columns.length == 0 || now.ptr !is _infos.ptr || now.length != _infos.length || look != _made)
        {
            _infos = now;
            _made = look;
            _columns = documentColumns(now, _zone, (ref const DocumentItem item) {
                // the rule color a record matches shows in its Index cell only (.ai/rules/ux.md, 27)
                const rule = _session.ruleOf(_docId, item);
                return rule.isValid() ? Extra(ruleColorBits(_session.ruleColor(_docId, rule))) : Extra.init;
            }, look, (ref const DocumentItem item, ref Buffer!Fragment into) {
                // what the chips of the search found in the payload of a row the search found (a row it did not find costs a test)
                MatchBuffer found;
                foreach (match; _session.matchesOf(_docId, item, found[]))
                    into.put(Fragment(match.start, match.end, Extra(match.chip)));
            });
        }
        return _columns;
    }
}

/// The model of a view of a document (the main one, or the search results) for a log table
ColumnarModel!DocumentItem documentTableModel(AppSession session, DocumentId docId, bool search, LogColumnLook delegate() look = null)
{
    DocumentRows rows;
    return documentTableModel(session, docId, search, rows, look);
}

/// The same, and the rows of the view too: they are told what the model cannot know (an anchor changed some rows)
ColumnarModel!DocumentItem documentTableModel(AppSession session, DocumentId docId, bool search, out DocumentRows rows,
    LogColumnLook delegate() look = null)
{
    auto columns = new DocumentColumns(session, docId, look);
    rows = new DocumentRows(session, docId, search);
    return new ColumnarModel!DocumentItem(rows, &columns.get, (ref const DocumentItem item) => rowExtraOf(item));
}

version (unittest)
{
    // The style of a column of the log (every one is a text column)
    ref ColumnStyle styleOf(TableColumn column)
    {
        return (cast(TextColumn) column).style;
    }
}

@("logColumns: every column is an object: the anchor, the Index and the level draw by themselves, the others are text")
unittest
{
    const ColumnInfo[] infos = [
        ColumnInfo("time", "Time", ColumnKind.Time),
        ColumnInfo("level", "Level", ColumnKind.Level),
        ColumnInfo("payload", "Payload", ColumnKind.Payload),
    ];
    auto defs = logColumns(infos);
    assert(cast(AnchorColumn) defs[0] && cast(IndexColumn) defs[1] && cast(LevelColumn) defs[3]);
    assert(cast(TextColumn) defs[2] && cast(TextColumn) defs[4]);
}

@("logColumns: the anchor and the Index first, the last column of the format takes the rest")
unittest
{
    const ColumnInfo[] infos = [
        ColumnInfo("time", "Time", ColumnKind.Time),
        ColumnInfo("level", "Level", ColumnKind.Level),
        ColumnInfo("payload", "Payload", ColumnKind.Payload),
    ];
    auto defs = logColumns(infos);
    assert(defs.length == 5);
    assert(defs[0].def.id == "anchor" && styleOf(defs[0]).cell.halign == Halign.center && defs[0].def.clickable && !defs[1].def.clickable && !defs[0].def.selectable && defs[0].def.minWidth == 24);
    assert(defs[1].def.id == "index" && defs[1].def.selectable);
    assert(defs[2].def.id == "time" && !defs[2].def.flex);
    assert(defs[2].cellParts.hasHead && defs[2].cellParts.head("2026/11/18 12:34:56.000001"w) == "2026/11/18"
        && defs[2].cellParts.body("2026/11/18 12:34:56.000001"w) == "12:34:56.000001", "the date heads the rows of its day");
    assert(defs[2].cellParts.head("12.345678"w).length == 0, "a time since boot has no date");
    assert(!defs[1].cellParts.hasHead && !defs[3].cellParts.hasHead && !defs[4].cellParts.hasHead);
    assert(defs[4].def.id == "payload" && defs[4].def.flex && defs[4].def.minWidth == 200);
}

@("documentColumns: the anchor mark has no text, the Index and the columns of the format write their cell")
unittest
{
    import std.datetime.timezone : UTC;

    const ColumnInfo[] infos = [
        ColumnInfo("level", "Level", ColumnKind.Level),
        ColumnInfo("payload", "Payload", ColumnKind.Payload),
    ];
    auto columns = documentColumns(infos, UTC(), (ref const DocumentItem item) => Extra(item.realIndex));
    assert(columns.length == 4 && columns[0].text is null && columns[0].column.def.id == "anchor");
    assert(columns[1].column.def.id == "index" && columns[2].column.def.id == "level" && columns[3].column.def.id == "payload", "the order of logColumns");
    DocumentItem item;
    item.realIndex = 12;
    auto buffer = Buffer!wchar(mallocAllocator());
    wstring written(size_t i)
    {
        buffer.clear();
        columns[i].text(item, buffer);
        return buffer[].idup;
    }

    assert(written(1) == "12", "the Index; the texts of the format are those of putColumnText (ui/row_cells)");
    assert(columns[2].text !is null && columns[3].column.def.flex);
    assert(columns[2].text.ptr !is columns[3].text.ptr, "each column has a writer of its own, not the last one's");
    assert(columns[1].extra(item).bits == 12);
    item.anchored = true;
    assert(columns[0].extra(item).bits == anchoredMark, "the anchor's cell says whether the record has one");
    assert(columns[2].extra !is null && columns[2].extra(item).bits == item.message.level,
        "the level's cell says the level of the record, whatever its text");
    item.anchored = false;
    assert(columns[0].extra(item).bits == 0);
}

@("documentColumns: the Payload, the last column, gives the fragments it is told of; no other column does")
unittest
{
    import std.datetime.timezone : UTC;

    const ColumnInfo[] infos = [
        ColumnInfo("level", "Level", ColumnKind.Level),
        ColumnInfo("payload", "Payload", ColumnKind.Payload),
    ];
    auto columns = documentColumns(infos, UTC(), (ref const DocumentItem item) => Extra.init, LogColumnLook.init,
        (ref const DocumentItem item, ref Buffer!Fragment into) { into.put(Fragment(2, 5, Extra(3))); });
    DocumentItem item;
    auto into = Buffer!Fragment(mallocAllocator());
    assert(columns[0].fragments is null && columns[1].fragments is null && columns[2].fragments is null);
    columns[3].fragments(item, into);
    assert(into[] == [Fragment(2, 5, Extra(3))]);
    assert(documentColumns(infos, UTC(), (ref const DocumentItem item) => Extra.init)[3].fragments is null, "none told: none");
}

@("timeParts: the date that putTime writes heads the rows of its day, the rest is the body; a time of no date has no head")
unittest
{
    import log_core.log_message : TimeKind;
    import std.datetime.timezone : UTC;
    import ui.row_cells : putTime;

    auto buffer = Buffer!wchar(mallocAllocator());
    const(wchar)[] written(TimeKind kind)
    {
        buffer.clear();
        putTime(buffer, 1_795_017_016_873_000_123L, kind, UTC()); // 2026-11-18 15:50:16.873000 UTC
        return buffer[];
    }

    foreach (kind; [TimeKind.Absolute, TimeKind.Local])
        assert(timeParts.head(written(kind)) == "2026/11/18" && timeParts.body(written(kind)) == "15:50:16.873000");
    assert(timeParts.head(written(TimeKind.LocalNoYear)) == "11/18" && timeParts.body(written(TimeKind.LocalNoYear)) == "15:50:16.873000");
    foreach (kind; [TimeKind.SinceBoot, TimeKind.None])
        assert(timeParts.head(written(kind)).length == 0 && timeParts.body(written(kind)) == written(kind), "no date");
}

@("logColumns: the Payload text starts where the style says, the other columns leave it to the geometry")
unittest
{
    const ColumnInfo[] infos = [ColumnInfo("time", "Time", ColumnKind.Time), ColumnInfo("payload", "Payload", ColumnKind.Payload)];
    auto defs = logColumns(infos, LogColumnLook(5.33, false));
    assert(styleOf(defs[1]).cell.padLeft < 0 && styleOf(defs[2]).cell.padLeft < 0 && styleOf(defs[3]).cell.padLeft == 5.33 && styleOf(defs[3]).header.padLeft == 5.33 && defs[3].def.flex && !styleOf(defs[3]).wrap && styleOf(defs[2]).wrap);
}

@("logColumns: the numbers and the texts of the columns are set in the small font, the Payload and the levels in the body font")
unittest
{
    const ColumnInfo[] infos = [ColumnInfo("time", "Time", ColumnKind.Time), ColumnInfo("level", "Level", ColumnKind.Level),
        ColumnInfo("payload", "Payload", ColumnKind.Payload)];
    auto defs = logColumns(infos);
    assert(styleOf(defs[0]).cell.font == LogFont.aux && styleOf(defs[1]).cell.font == LogFont.aux && styleOf(defs[2]).cell.font == LogFont.aux);
    assert(styleOf(defs[3]).cell.font == LogFont.body && styleOf(defs[4]).cell.font == LogFont.body);
}
