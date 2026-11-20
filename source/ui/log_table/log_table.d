//! The table of a log: the rows of a view of a document (its model), the table that
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
import ui.log_table.document_model : DocumentRows, LogColumnLook, documentTableModel;
import ui.log_table.log_look : LogLook;
import ui.log_table.painter : LogPainter, LogScrollBarPainter;

/// What a log table shows: a view of a document and the column host the tables of the document share
struct TableSource
{
    AppSession session;
    DocumentId docId;
    bool search;
    ColumnHost host;
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

/// How a copy of the log table joins its texts: the cells of a row by tabs, the rows by new lines (a table to paste
/// into a sheet), a million characters at most
enum CopyFormat logCopyFormat = CopyFormat("\t"w, "\n"w, 1_000_000);

final class LogTable
{
    /// The look's metrics changed (the fonts, their sizes, the spacing): the host drops what it measured. Called before
    /// the table reads its metrics again, and only for a change of the metrics.
    void delegate() beforeMetrics;

    private void delegate() _disposeModel; // the model stops hearing its source
    private DocumentRows _rows; // the rows of the view: told what the model cannot know
    private LogPainter _painter;
    private Table _table;
    private ScrolledTable _scrolled; // the table with its scroll bar beside it
    private LogLook _look;
    private size_t _lookHandle;
    private bool _singleLine; // every row one line: the Payload is cut, not wrapped
    private bool _columnLookStale = true; // the look or the single line changed: what the columns are made with is made again

    /// The model listens to the document and the table to the look from now on, until `dispose`
    this(TableSource source, LogLook look, TextMeasurer measurer, Clipboard clipboard)
    {
        ColumnHost host = source.host;
        bool delegate() anchorsFull = () => source.session.doc(source.docId).anchorsFull; // the document says whether there is room
        // The model asks for it at every row it reads: it is made again only after a change of the look or of the single line, and
        // holds the look's own least widths (a change of the look replaces them, it never changes them in place)
        LogColumnLook columnLook;
        auto model = documentTableModel(source.session, source.docId, source.search, _rows, () {
            if (_columnLookStale)
            {
                // the columns only read the widths: the look's own, not a copy
                columnLook = LogColumnLook(look.spacing.payloadPadLeft, !_singleLine, look, anchorsFull, measurer, null,
                    cast(double[string]) look.spacing.minWidths);
                _columnLookStale = false;
            }
            return columnLook;
        });
        _disposeModel = &model.dispose;
        _painter = new LogPainter(look);
        auto ports = TablePorts(_painter, clipboard);
        ports.copyFormat = logCopyFormat;
        host.setMargins(sidesOf(look)); // the same for the tables of a document: each gives the look's, the host keeps one
        _table = new Table(model, host, ports);
        _table.revealMargin = 24; // a row that comes into view has 24 dips of room from the edge it came from
        _table.followEnd(true); // the rows of a document grow (a file being written): the table at its end follows it, as a terminal does
        _scrolled = new ScrolledTable(_table, new ScrollBar(new LogScrollBarPainter(look)), new ScrollBar(new LogScrollBarPainter(look)));
        _scrolled.bar.width = _scrolled.across.width = 13; // the hover area at the edge, the wide thumb 9 (12, a dip wider: the user, 2026-11-20); a trial value
        _look = look;
        _lookHandle = look.subscribe((const LookChange change) {
            host.setMargins(sidesOf(look)); // nothing told when they are the same
            _columnLookStale = true;
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
        _columnLookStale = true;
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

version (unittest)
{
    // A text log of `lines` lines in the temporary folder, opened in a session of its own and loaded whole
    private struct TestLog
    {
        AppSession session;
        DocumentId id;
        string path;

        void close()
        {
            import std.file : remove;

            session.closeAll();
            remove(path);
        }
    }

    private TestLog openTestLog(string name, size_t lines)
    {
        import core.thread : Thread;
        import core.time : msecs;
        import std.array : replicate;
        import std.file : tempDir, write;
        import std.path : buildPath;
        import domain.document : Document;
        import domain.document_store : DocumentStore;
        import domain.log_document : LogDocument;
        import log_core.log_format : FormatChoice;
        import ui.app_settings : AppSettings;

        TestLog log;
        log.path = buildPath(tempDir(), name);
        write(log.path, "a line of the log with some words in it\n".replicate(lines));
        log.session = new AppSession(AppSettings.init, new DocumentStore(),
            (string path, FormatChoice choice) => cast(Document) new LogDocument(path, choice), (in AppSettings s) {});
        log.id = log.session.openFile(log.path).docId;
        foreach (attempt; 0 .. 500)
        {
            log.session.dispatchEvents();
            log.session.takeScriptCalls();
            if (log.session.doc(log.id).mainView.itemsCount == lines)
                break;
            Thread.sleep(10.msecs);
        }
        assert(log.session.doc(log.id).mainView.itemsCount == lines, "the log is loaded");
        return log;
    }
}

@("DocumentRows: the rows of the main view look another way when the search view is shown anew (what the search found marks them)")
unittest
{
    import core.thread : Thread;
    import core.time : msecs;
    import ptable.model : ModelChange;
    import ui.log_table.document_model : DocumentRows;

    auto opened = openTestLog("log_tracy_log_table_found.log", 50);
    scope (exit) opened.close();
    auto main = new DocumentRows(opened.session, opened.id, false);
    auto search = new DocumentRows(opened.session, opened.id, true);
    ModelChange[] heardMain, heardSearch;
    main.subscribe((const ModelChange c) { heardMain ~= c; });
    search.subscribe((const ModelChange c) { heardSearch ~= c; });
    assert(opened.session.startChipSearch(opened.id, `[{"text": "words", "isRegex": false, "matchCase": false}]`) == "");
    foreach (attempt; 0 .. 500)
    {
        opened.session.dispatchEvents();
        opened.session.takeScriptCalls();
        if (opened.session.doc(opened.id).searchView.itemsCount == 50)
            break;
        Thread.sleep(10.msecs);
    }
    import std.algorithm.searching : canFind;

    assert(heardMain.canFind!(c => c.kind == ModelChange.Kind.looks), "the main rows show what was found");
    assert(!heardSearch.canFind!(c => c.kind == ModelChange.Kind.looks), "the search rows are told their own view as rows");
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
    auto opened = openTestLog("log_tracy_log_table_margins.log", 50);
    scope (exit) opened.close();
    auto log = new LogTable(TableSource(opened.session, opened.id, false, new ColumnHost), look, new FakeMeasurer, null);
    log.table.resize(400, 300);
    assert(log.table.rowsArea.x == 10 && log.table.rowsArea.w == 370);
    spacing.rowsMarginLeft = 5;
    look.setSpacing(spacing);
    assert(log.table.rowsArea.x == 5 && log.table.rowsArea.w == 375);
    log.dispose();
}

@("LogTable: the rows of a document scrolled frame after frame take no memory of the garbage collector")
unittest
{
    import core.memory : GC;
    import core.thread : Thread;
    import core.time : msecs;
    import std.array : replicate;
    import std.file : remove, tempDir, write;
    import std.path : buildPath;
    import domain.document : Document;
    import domain.document_store : DocumentStore;
    import domain.log_document : LogDocument;
    import log_core.log_format : FormatChoice;
    import ptable.ports : Canvas, Color, FontId, Rect;
    import ptable_text.testing : FakeMeasurer;
    import ui.app_settings : AppSettings;
    import ui.log_table.log_look : defaultLogLook;

    static final class Null : Canvas
    {
        void fillRect(Rect area, Color color) {}
        void drawText(FontId font, const(wchar)[] text, double x, double baseline, Color color) {}
        void drawParagraph(FontId font, const(wchar)[] text, double x, double top, double width, Color color) {}
        void fillRoundRect(Rect area, double radius, Color color) {}
        void fillCircle(double cx, double cy, double radius, Color fill, Color line) {}
        void pushClip(Rect area) {}
        void popClip() {}
    }

    auto opened = openTestLog("log_tracy_log_table_frames.log", 2000);
    scope (exit) opened.close();
    auto log = new LogTable(TableSource(opened.session, opened.id, false, new ColumnHost), defaultLogLook(), new FakeMeasurer, null);
    scope (exit) log.dispose();
    static void noFrame() {}
    import std.functional : toDelegate;
    log.table.events.needFrame = toDelegate(&noFrame);
    log.table.resize(400, 300);
    auto canvas = new Null;
    double t = 0;
    void scrollAround(int frames)
    {
        foreach (i; 0 .. frames)
        {
            log.table.queueScroll(i % 2 ? 37 : -25);
            log.table.paint(canvas);
        }
        foreach (i; 0 .. frames)
        {
            log.table.wheel(i % 3 ? 300 : -200, t += 16);
            log.table.tick(t);
            log.table.paint(canvas);
        }
    }

    scrollAround(30); // warms up: the columns, the arenas, the maps, the scratch arrays
    const before = GC.stats().allocatedInCurrentThread;
    scrollAround(100);
    assert(GC.stats().allocatedInCurrentThread == before, "a frame allocated from the garbage collector");
}
