//! The log table in Sciter: the thin adapter of the table of the package ptable. It is a native
//! behavior (`behavior: log-table` puts it on an element) that turns the events of Sciter into the calls
//! of `Table` and gives it a canvas, a text measurer and a clipboard (ui/sciter_table/sciter_host), the rows of a view
//! of a document (ui/log_table/document_model; or the demo of grouped rows, ui/log_table/demo_model, for
//! `logTableCall("demo")`) and the look of the log table (ui/log_table/painter, ui/log_table/log_look).
//! docs/stories/painted-table.md, docs/experiments/2026-11-19-painted-rows-d.md.
//!
//! Left: anchors by a click, the matches of the search, the rule colors, the search view's own columns, the inertia
//! of a scroll, the growth of a log being read, selection in right-to-left text. The scroll of a drag past the rows
//! goes on the frames Sciter gives (`Table.tick`).
module ui.log_table_behavior;

import ptable.model : Extra;
import ptable.navigation : Key;
import ptable.ports : Rect;
import ptable.scrollplace : CellPosition;
import ui.view_json : viewJson;
import ptable.tablehit : CopyTarget, PointerKind;
import sciter.api : sciterApi;
import sciter.capi.api;
import sciter.event_handler : SciterEventHandler;
import sciter.graphics : GfxCanvas = Canvas;
import sciter.value;
import ui.frame_stats : FrameStats, statsJson, usSince;
import ui.log_table.log_table : LogTable, TableSource;
import ui.log_table.marks : marksOf;
import ui.log_table.log_look : LogLook;
import ui.sciter_table.frame_request : FrameRequest;
import ui.sciter_table.input : wheelIsAcross, cursorOf, isCopy, isOurEvent, isSelectAll, keyPickMode, pickMode, startsPickPress, tableKey, wheelPixels;
import ui.sciter_table.host : ScriptTeller;
import ui.sciter_table.sciter_host : SciterHost;
import ui.table_script : dispatch, ScriptArgs, ScriptResult, TableControl;

import core.time : MonoTime;
import std.utf : toUTF16;

/// The name of the behavior in CSS: `behavior: log-table`
enum logTableBehavior = "log-table";

/// How much the rows move by the fingers' move on the trackpad: Sciter hands over the system's deltas as they are, and the
/// rows followed them a little sluggishly (the user, 2026-11-18: about 20% more); the coast's speed follows the same pans
enum double panScale = 1.2;
enum double wheelScale = 1.0;

/// What the window hears of a table: it can be talked to from the attach on and no longer after the detach
struct TableHooks
{
    size_t id; /// the number the script talks to the table by (`LogTableTarget.set`)
    void delegate(TableControl) attached;
    void delegate(TableControl) detached;
    ScriptTeller tell; /// what the table has to tell the script, queued by the window: never called from inside an event
}

/// A call of the script to `control`, handed over by the main window: Sciter doesn't deliver `element.xcall` to a
/// handler attached by a behavior of CSS (6.0.5.5). `argv` are the arguments after the method. False for a method it
/// does not know.
bool runScript(TableControl control, const(char)[] method, const(SCITER_VALUE)* argv, uint argc, SCITER_VALUE* result)
{
    auto numbers = new double[argc];
    foreach (i; 0 .. argc)
    {
        auto view = SciterValueConstView(&argv[i]);
        int asInt;
        double asDouble;
        numbers[i] = view.tryGet(asInt) ? asInt : view.tryGet(asDouble) ? asDouble : double.nan;
    }
    ScriptResult answer;
    if (!dispatch(control, method, ScriptArgs(numbers), answer))
        return false;
    auto resultView = SciterValueView(result);
    final switch (answer.kind)
    {
    case ScriptResult.Kind.nothing: break;
    case ScriptResult.Kind.number: resultView = cast(int) answer.value; break;
    case ScriptResult.Kind.text: resultView = answer.text; break;
    }
    return true;
}

/// A native behavior drawing the rows of a view of a document
final class LogTableBehavior : SciterEventHandler
{
    private SciterHost _host; // the element and everything of Sciter the table needs
    private TableSource _source; // what the table shows, until it is attached and made
    private LogLook _look;
    private TableHooks _hooks; // the window is told when the table can be talked to
    private LogTable _log; // the table of the log: made when the element is attached
    private bool _mainDown; // the last press was of the main button (a double click of another one selects nothing)

    private Control _control; // what the script may ask of the table
    private FrameStats _frames; // the times of the frames drawn
    private FrameRequest _frameRequest; // one frame event on its way at a time

    this(TableSource source, LogLook look, TableHooks hooks, HELEMENT he)
    {
        _host = new SciterHost(he, look.text, hooks.tell);
        _look = look;
        _source = source;
        _hooks = hooks;
        _control = new Control; // once: the window holds it through the hooks
    }

    // The model and the table listen to the document and the look: made once the element has them, so a behavior
    // that never got attached keeps nobody listening
    private void build()
    {
        _host.setLook(_look.text); // the fonts may have changed since the behavior was made
        _log = new LogTable(_source, _look, _host.measurer, _host.clipboard);
        _log.singleLine(_source.singleLine);
        _log.beforeMetrics = () { _host.setLook(_look.text); };
        _log.events.invalidate = &_host.repaint;
        _log.events.invalidateArea = &_host.repaintArea;
        _log.events.capture = &_host.capture;
        _log.events.needFrame = &requestFrame;
        _log.events.cellClicked = &cellClicked;
        _log.events.rowSelected = &rowChosen;
        _log.events.copyCut = &copyCut;
    }

    // A copy of rows was cut by the limit of the copy: the script tells the user how many rows went to the clipboard
    private void copyCut(size_t copied, size_t total)
    {
        import std.json : JSONValue;

        JSONValue cut = ["table": JSONValue(_hooks.id), "copied": JSONValue(copied), "total": JSONValue(total)];
        _hooks.tell("logTableCopyCut", cut.toString.toUTF16);
    }

    // A click on a cell of a clickable column (the table picks nothing): the script knows what it is for
    private void cellClicked(size_t item, size_t column)
    {
        import std.json : JSONValue;

        auto table = _log.table;
        ulong id;
        if (!table.isClickable(column) || !table.rowId(item, id))
            return; // a click on text is no business of the script, and a row that is gone since the press is nobody's click
        JSONValue click = ["table": JSONValue(_hooks.id), "item": JSONValue(item), "id": JSONValue(id), "column": JSONValue(table.columnId(column)),
            "anchored": JSONValue(marksOf(Extra(table.rowExtra(item))).anchored)];
        Rect area;
        if (table.cellRect(item, column, area)) // where the cell is in the table, for what the script shows by it (a notice)
            click["rect"] = [area.x, area.y, area.w, area.h];
        _hooks.tell("logTableCellClicked", click.toString.toUTF16);
    }

    // A row was selected by the user (the script follows it in the other table): which table, the item, the message, and whether it may move on
    private void rowChosen(size_t item, ulong id, bool delayed)
    {
        import std.json : JSONValue;

        JSONValue chosen = ["table": JSONValue(_hooks.id), "row": JSONValue(item), "id": JSONValue(id), "delayed": JSONValue(delayed)];
        _hooks.tell("logTableRowChosen", chosen.toString.toUTF16);
    }

    override protected bool handleSubscription(HELEMENT he, UINT* event_groups)
    {
        *event_groups = EVENT_GROUPS.HANDLE_DRAW | EVENT_GROUPS.HANDLE_MOUSE | EVENT_GROUPS.HANDLE_KEY
            | EVENT_GROUPS.HANDLE_FOCUS | EVENT_GROUPS.HANDLE_SCRIPTING_METHOD_CALL | EVENT_GROUPS.HANDLE_INITIALIZATION
            | EVENT_GROUPS.HANDLE_BEHAVIOR_EVENT;
        return true;
    }

    override protected void handleAttached(HELEMENT he)
    {
        _host.attach(he);
        if (_log is null)
            build();
        _log.table.tableHasFocus = elementHasFocus(he); // the element may have it already when the table is made
        if (_hooks.attached !is null)
            _hooks.attached(_control);
    }

    // Whether the element is the one in focus now (`:focus`)
    private static bool elementHasFocus(HELEMENT he)
    {
        import sciter.capi.dom : ELEMENT_STATE_BITS, SCDOM_OK;

        UINT bits;
        return sciterApi().SciterGetElementState(he, &bits) == SCDOM_OK && (bits & ELEMENT_STATE_BITS.STATE_FOCUS) != 0;
    }

    override protected void handleDetached(HELEMENT he)
    {
        if (_log !is null)
        {
            if (_hooks.detached !is null)
                _hooks.detached(_control);
            _log.dispose();
        }
        _host.release();
        _log = null; // nothing of the behavior works after it is detached
        SciterEventHandler.unhold(this);
    }

    // ---- the frames the table asks for (a drag past the rows, a step of the wheel, a coast scroll on them) ----

    // The code of the event Sciter sends this element at its next animation frame
    private enum uint frameEvent = BEHAVIOR_EVENTS.FIRST_APPLICATION_EVENT_CODE + 1;

    // The time of a frame or of a move of the fingers in milliseconds, one clock for both; the table only needs the
    // differences
    private static double nowMs()
    {
        return MonoTime.currTime.ticks * 1000.0 / MonoTime.ticksPerSecond;
    }

    // The table asks again and again while it scrolls by itself: one frame is on its way at a time
    private void requestFrame()
    {
        const asked = _frameRequest.ask(MonoTime.currTime);
        if (asked)
            _host.requestFrame(frameEvent);
    }

    override protected bool handleEvent(HELEMENT he, BEHAVIOR_EVENT_PARAMS* params)
    {
        // our own element handles the bubbling one (the phase flags are not part of the code)
        if ((params.cmd & PHASE_MASK.SINKING) != 0 || (params.cmd & ~cast(uint) PHASE_MASK.HANDLED) != frameEvent || _log is null)
            return false;
        // Sciter sends the next frame while the handler says it handled this one: asking again here would start one more
        // chain of frames each frame, and the window hangs
        const more = _log.scrolled.tick(nowMs()); // the table's own scrolls and its bars' widening
        if (more)
            _frameRequest.goesOn(MonoTime.currTime);
        else
            _frameRequest.arrived();
        return more;
    }

    override protected bool handleEvent(HELEMENT he, FOCUS_PARAMS* params)
    {
        if (_log is null)
            return false;
        // the table has the focus as long as its element has: the painter is told (the element is focusable by its tabindex, set where it is made)
        if (params.cmd == FOCUS_EVENTS.FOCUS_GOT)
            _log.table.tableHasFocus = true;
        // the focus went elsewhere with a button down: the press is over (no mouse up will come)
        else if (params.cmd == FOCUS_EVENTS.FOCUS_LOST)
        {
            _log.table.tableHasFocus = false;
            _log.scrolled.cancelPress();
        }
        return false;
    }

    // ---- painting ----

    override protected bool handleEvent(HELEMENT he, DRAW_PARAMS* params)
    {
        if (_log is null || params.cmd != DRAW_EVENTS.DRAW_CONTENT)
            return false; // not built yet: the table is made when the element is attached
        const started = MonoTime.currTime;
        _log.scrolled.resize(params.area.right - params.area.left, params.area.bottom - params.area.top);
        _log.scrolled.paint(_host.canvas(GfxCanvas(params.gfx), params.area.left, params.area.top));
        _frames.record(usSince(started));
        return true;
    }

    // ---- input ----

    override protected bool handleEvent(HELEMENT he, MOUSE_PARAMS* params)
    {
        if (_log is null)
            return false;
        const cmd = params.cmd & 0xFF;
        // our own element handles the bubbling ones, not the ones already handled: a click on an item of a menu over the table comes
        // here too, handled by the menu, and must not be a press of the table (it let go of the text before the item copied it)
        const x = params.pos.x, y = params.pos.y;
        const onBar = _log.scrolled.onBar(x, y);
        // the cursor is told at every event of the mouse that has a place, of whatever phase: an event left unanswered (a move, a press, a
        // release over a clickable cell) shows the arrow for a moment
        const hand = cmd != MOUSE_EVENTS.MOUSE_WHEEL && cmd != MOUSE_EVENTS.MOUSE_LEAVE && !onBar
            && _log.table.pointerAt(x, y) == PointerKind.hand;
        if (cmd != MOUSE_EVENTS.MOUSE_WHEEL && cmd != MOUSE_EVENTS.MOUSE_LEAVE && !onBar)
            params.cursor_type = cursorOf(hand ? PointerKind.hand : PointerKind.arrow);
        if (!isOurEvent(params.cmd))
            return false;
        switch (cmd)
        {
        case MOUSE_EVENTS.MOUSE_WHEEL:
            if (wheelIsAcross(params.alt_state))
                _log.table.scrollXBy(wheelPixels(params.button_state, wheelScale)); // Shift: the columns, by the pixels at once
            else
                _log.table.wheel(wheelPixels(params.button_state, wheelScale), nowMs());
            return true;
        case MOUSE_EVENTS.MOUSE_DOWN:
            _mainDown = startsPickPress(params.button_state, params.alt_state);
            return _mainDown && _log.scrolled.mouseDown(x, y, pickMode(params.alt_state));
        case MOUSE_EVENTS.MOUSE_MOVE:
            _log.scrolled.mouseOver(x, y);
            return _log.scrolled.mouseMove(x, y) || hand; // a handled move keeps its cursor
        case MOUSE_EVENTS.MOUSE_UP:
            return _log.scrolled.mouseUp(x, y, nowMs()); // a click on a row cut at an edge brings it in by a glide
        case MOUSE_EVENTS.MOUSE_ENTER:
            return hand;
        case MOUSE_EVENTS.MOUSE_LEAVE:
            _log.scrolled.mouseOver(double.nan, double.nan);
            return false;
        case MOUSE_EVENTS.MOUSE_DCLICK:
            return !onBar && _mainDown && _log.table.selectAt(x, y, true);
        case MOUSE_EVENTS.MOUSE_TCLICK:
            return !onBar && _mainDown && _log.table.selectAt(x, y, false);
        default:
            return false;
        }
    }

    override protected bool handleEvent(HELEMENT he, KEY_PARAMS* params)
    {
        if (_log is null || params.cmd != KEY_EVENTS.KEY_DOWN)
            return false;
        if (isCopy(params.alt_state, params.key_code))
        {
            _log.table.copy(); // a cell selected whole, a row: with its date
            return true;
        }
        if (isSelectAll(params.alt_state, params.key_code))
        {
            _log.table.selectAll();
            return true;
        }
        Key key;
        return tableKey(params.key_code, key) && _log.table.key(key, keyPickMode(params.alt_state), nowMs());
    }

    // ---- the script's calls (Window.xcall("logTableCall", ...)) ----

    // What the script may ask of the table, done with the table and the cache of this behavior
    private final class Control : TableControl
    {
        long jump(size_t row, bool now)
        {
            const started = MonoTime.currTime;
            _log.table.scrollTo(row);
            if (now)
                _host.updateNow();
            return usSince(started);
        }

        wstring view()
        {
            auto table = _log.table;
            return viewJson(table.size, table.partlyVisibleRows, table.firstVisible, table.lastVisible).toUTF16;
        }

        void pickRow(size_t row) { _log.table.pickRow(row); }

        void reveal(size_t row, bool smooth) { _log.table.reveal(row, smooth ? nowMs() : double.nan); }

        wstring currentRow()
        {
            import std.json : JSONValue;

            long row;
            ulong id;
            auto table = _log.table;
            if (!table.currentRow(row) || !table.rowId(cast(size_t) row, id))
                return "null"w;
            return JSONValue(["row": JSONValue(row), "id": JSONValue(id)]).toString.toUTF16;
        }

        wstring rowHeight(size_t index) { import std.conv : to; return _log.table.rowHeight(index).to!wstring; }

        void scrollTo(size_t row, size_t column, double dy, double dx, bool smooth)
        {
            _log.table.scrollToPosition(CellPosition(row, column, dy, dx), smooth ? nowMs() : double.nan);
        }

        long scrollBy(double pixels, bool now)
        {
            const started = MonoTime.currTime;
            _log.table.scrollBy(pixels);
            if (now)
                _host.updateNow();
            return usSince(started);
        }

        void pan(double pixels, double across)
        {
            // a move of the fingers is along the axis it goes farther on: a trackpad's small sideways jitter during a scroll down
            // does not drift the columns, and the other way round
            import std.math : abs;

            if (abs(across) > abs(pixels))
                _log.table.scrollXBy(across * panScale);
            else
                _log.table.pan(pixels * panScale, nowMs());
        }
        void panEnd() { _log.table.panEnd(nowMs()); }

        long render()
        {
            const started = MonoTime.currTime;
            _host.updateNow();
            return usSince(started);
        }

        void refresh() { _log.table.repaint(); } // the next frame reads the rows again

        void setWrap(bool bySciter)
        {
            _host.sciterWrap = bySciter;
            _log.table.restyle();
        }

        void setLimits(size_t texts)
        {
            _host.textLimit(texts);
        }

        void singleLine(bool on)
        {
            _source.singleLine = on;
            if (_log !is null)
            {
                _log.singleLine(on);
                _host.repaint();
            }
        }

        void showDemo(bool on)
        {
            if (_source.demo == on)
                return;
            _source.demo = on;
            if (_log is null)
                return; // made so once attached
            _log.dispose(); // the table is made again of the other model
            build();
            _host.repaint();
        }
        void resetStats() { _frames.reset(); }
        void select(double x1, double y1, double x2, double y2) { _log.table.selectBetween(x1, y1, x2, y2); }
        void selectWord(double x, double y, bool word) { _log.table.selectAt(x, y, word); }
        wstring copyText(bool wholeCellsInFull) { return _log.table.copyText(wholeCellsInFull); }
        void copy(CopyTarget target, size_t row, size_t column) { _log.table.copy(target, row, column); }
        wstring hitTest(double x, double y) { return _log.table.hitTest(x, y).toJson.toUTF16; }

        void contextPick(size_t row) { _log.table.contextPick(row); }
        void anchorApplied(size_t message, bool moved) { _log.anchorApplied(message, moved); }
        void updateRow(size_t item) { _log.table.updateRow(item); }
        void updateCell(size_t item, size_t column) { _log.table.updateCell(item, column); }
        wstring stats() { return statsJson(_frames, _log.table.stats, _host.textsMade, _host.textsKept, _host.sciterWrap); }
    }
}
