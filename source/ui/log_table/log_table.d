//! The table of a log: the rows of a view of a document (its model; or the demo of the groups of rows), the table that
//! draws them in the look of the log table, and the scroll bar beside it, made and let go of together. It has the measurer and the clipboard it is given
//! and knows no Sciter: the behavior that shows it (ui/log_table_behavior) joins it to an element.
module ui.log_table.log_table;

import domain.document_id : DocumentId;
import domain.document_item : DocumentItem;
import ptable.columnar : ColumnarModel;
import ptable.columnhost : ColumnHost;
import ptable.regions : SideMargins;
import ptable.lookchange : LookChange;
import ptable.model : TableModel;
import ptable.ports : Clipboard;
import ptable_text.measurer : TextMeasurer;
import ptable.scrollbar : ScrollBar;
import ptable.scrolledtable : ScrolledTable;
import ptable.table : Table, TableEvents;
import ptable.selection : CopyFormat;
import ptable.tableports : TablePorts;
import ui.app_session : AppSession;
import ui.log_table.demo_model : demoTableModel;
import ui.log_table.document_model : DocumentRows, LogColumnLook, documentTableModel;
import ui.log_table.log_look : LogLook;
import ui.log_table.painter : LogPainter, LogScrollBarPainter;

/// What a log table shows: a view of a document and the column host the tables of the document share, or the demo of
/// the groups of rows (`demo`: ui/log_table/demo_model) with a host of its own
struct TableSource
{
    AppSession session;
    DocumentId docId;
    bool search;
    ColumnHost host;
    bool demo;
    bool singleLine; /// the rows are one line high (the setting of the application) from the start
}

/// What follows a change of the look, in the order that matters: when the metrics changed (the fonts, their sizes, the
/// spacing) the host drops what it measured first (`beforeMetrics`), only then the table reads its metrics again
/// (`restyle`); a change of the colors only repaints, there is nothing to drop
void applyLookChange(LookChange change, scope void delegate() beforeMetrics, scope void delegate(LookChange) restyle)
{
    if ((change & LookChange.metrics) != 0 && beforeMetrics !is null)
        beforeMetrics();
    restyle(change);
}

/// How a copy of the log table joins its texts, as the DOM table did: the cells of a row by tabs, the rows by new lines (a table to paste
/// into a sheet), a million characters at most
enum CopyFormat logCopyFormat = CopyFormat("\t"w, "\n"w, 1_000_000);

final class LogTable
{
    /// The look's metrics changed (the fonts, their sizes, the spacing): the host drops what it measured. Called before
    /// the table reads its metrics again, and only for a change of the metrics.
    void delegate() beforeMetrics;

    private void delegate() _disposeModel; // the model stops hearing its source
    private DocumentRows _rows; // the rows of the view (null for the demo): told what the model cannot know
    private LogPainter _painter;
    private Table _table;
    private ScrolledTable _scrolled; // the table with its scroll bar beside it
    private LogLook _look;
    private size_t _lookHandle;
    private bool _singleLine; // every row one line: the Payload is cut, not wrapped

    /// The model listens to the document and the table to the look from now on, until `dispose`
    this(TableSource source, LogLook look, TextMeasurer measurer, Clipboard clipboard)
    {
        TableModel model;
        bool delegate() anchorsFull;
        ColumnHost host = source.host;
        if (source.demo)
        {
            auto demo = demoTableModel(look, measurer);
            model = demo;
            _disposeModel = &demo.dispose;
            host = new ColumnHost; // its columns are not the document's
        }
        else
        {
            anchorsFull = () => source.session.doc(source.docId).anchorsFull; // the document says whether there is room
            auto document = documentTableModel(source.session, source.docId, source.search, _rows,
                () => LogColumnLook(look.spacing.payloadPadLeft, !_singleLine, look, anchorsFull, measurer, null, look.spacing.minWidths.dup));
            model = document;
            _disposeModel = &document.dispose;
        }
        _painter = new LogPainter(look);
        _painter.anchorsFull = anchorsFull;
        auto ports = TablePorts(_painter, clipboard);
        ports.copyFormat = logCopyFormat;
        host.setMargins(sidesOf(look)); // the same for the tables of a document: each gives the look's, the host keeps one
        _table = new Table(model, host, ports);
        _table.revealMargin = 24; // a row that comes into view has 24 dips of room from the edge it came from
        _table.followEnd(!source.demo); // the rows of a document grow (a file being written): the table at its end follows it, as a terminal does
        _scrolled = new ScrolledTable(_table, new ScrollBar(new LogScrollBarPainter(look)), new ScrollBar(new LogScrollBarPainter(look)));
        _scrolled.bar.width = _scrolled.across.width = 13; // the hover area at the edge, the wide thumb 9 (12, a dip wider: the user, 2026-11-20); a trial value
        _look = look;
        _lookHandle = look.subscribe((const LookChange change) {
            host.setMargins(sidesOf(look)); // nothing told when they are the same
            applyLookChange(change, beforeMetrics, (LookChange c) { _table.restyle(c); });
        });
    }

    // The margins left and right of the rows the look asks for
    private static SideMargins sidesOf(LogLook look)
    {
        return SideMargins(look.spacing.rowsMarginLeft, look.spacing.rowsMarginRight);
    }

    /// Every row one line (the Payload is cut where its cell ends) or as many as the Payload wraps to
    void singleLine(bool on)
    {
        if (on == _singleLine)
            return;
        _singleLine = on;
        _table.restyle(LookChange.metrics); // the columns are read again, the rows are wrapped again, the place is kept
    }

    /// An anchor was set or cleared on the message `message`: its row is read again; `moved`: the row came into the view or left it
    /// (the rows after it are other ones: nothing stays picked)
    void anchorApplied(size_t message, bool moved)
    {
        if (_rows is null)
            return;
        _rows.messageChanged(message, moved);
        if (moved)
            _table.forgetPicks();
        _table.updateHover(); // the sign under the mouse depends on whether there is room: it may have changed with this anchor
    }

    Table table() { return _table; }
    ScrolledTable scrolled() { return _scrolled; }

    /// What the table tells its host (the table's and the bar's)
    ref TableEvents events() { return _scrolled.events; }

    /// The table and the model let go of the document and the column host
    void dispose()
    {
        _look.unsubscribe(_lookHandle);
        _table.cancelPress(); // a drag that was on goes with the table
        _table.dispose();
        _disposeModel();
    }
}

@("applyLookChange: the host drops what it measured before the table reads its metrics, and only for a change of the fonts")
unittest
{
    string[] order;
    applyLookChange(LookChange.metrics, () { order ~= "drop"; }, (LookChange c) { order ~= "restyle"; });
    assert(order == ["drop", "restyle"]);
    order = null;
    applyLookChange(LookChange.colors, () { order ~= "drop"; }, (LookChange c) { order ~= "restyle"; });
    assert(order == ["restyle"], "colors: nothing to drop");
    order = null;
    applyLookChange(LookChange.metrics, null, (LookChange c) { order ~= "restyle"; });
    assert(order == ["restyle"], "no host hook is no failure");
}

@("LogTable: the demo shows rows grouped by a day and a shift, with a column host of its own: the document's is not touched")
unittest
{
    import ptable_text.testing : FakeMeasurer;
    import ui.log_table.log_look : defaultLogLook;

    auto shared_ = new ColumnHost;
    auto log = new LogTable(TableSource(null, DocumentId.init, false, shared_, true), defaultLogLook(), new FakeMeasurer, null);
    log.table.resize(400, 300);
    import ptable.painter : RecordingCanvas;
    log.table.paint(new RecordingCanvas);
    assert(log.table.stats.rowsOnScreen > 0 && log.table.copyText(false).length == 0, "the demo's rows, nothing selected");
    assert(shared_.layout.width("day") == 0 && shared_.layout.width("n") == 0 && shared_.width == 0,
        "the document's host has none of its widths and none of its room");
    log.table.scrollToEnd();
    log.table.paint(new RecordingCanvas);
    assert(!log.table.isFollowingEnd, "the demo does not follow an end: its rows do not grow");
    log.dispose();
}

@("LogTable: the margins left and right of the rows in the look are those of its column host, from the start and after a change of the look")
unittest
{
    import ptable_text.testing : FakeMeasurer;
    import ui.log_table.log_look : LogSpacing, defaultLogLook;

    auto look = defaultLogLook();
    LogSpacing spacing;
    spacing.rowsMarginLeft = 10;
    spacing.rowsMarginRight = 20;
    look.setSpacing(spacing);
    auto log = new LogTable(TableSource(null, DocumentId.init, false, new ColumnHost, true), look, new FakeMeasurer, null);
    log.table.resize(400, 300);
    assert(log.table.rowsArea.x == 10 && log.table.rowsArea.w == 370);
    spacing.rowsMarginLeft = 5;
    look.setSpacing(spacing);
    assert(log.table.rowsArea.x == 5 && log.table.rowsArea.w == 375);
    log.dispose();
}
