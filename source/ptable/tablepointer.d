//! The mouse of a table, all of it: where it was last seen, the dispatcher of what it did to the titles and the cells
//! (`ptable/pointerdispatch`), whether the press is held by a cell (a clickable column: it shows that it is pressed, the table picks
//! nothing), what the host is still to hear of it and what it wants to hear. The table hit-tests and decides (the thing under the
//! point, who owns a press, whether it became a drag) and feeds this; this says when the host is to take or let go of the mouse
//! (`Capture`) and keeps the messages until the table hands them over (`tell`). A reset of the rows resets it: a press is cancelled,
//! the mouse is over nothing until the table asks again where the point is. Pure. See docs/stories/painted-table.md.
module ptable.tablepointer;

import ptable.pointerdispatch;

/// What an input did to the host's hold of the mouse
enum Capture : ubyte
{
    same, /// nothing changed
    take, /// a press began: the host takes the mouse until the release
    letGo, /// the press is over: the host lets the mouse go
}

/// The kinds of things the host hears the mouse enter and leave (a handler of it listens to them)
struct OverKinds
{
    bool headers, cells;

    /// Both kinds
    static OverKinds all() pure nothrow @nogc @safe
    {
        return OverKinds(true, true);
    }

    /// Whether the enters and leaves of a thing of `kind` are heard
    bool has(TargetKind kind) const pure nothrow @nogc @safe
    {
        return kind == TargetKind.header ? headers : kind == TargetKind.cell && cells;
    }
}

// A point of the table, NaN out of it
private struct Point
{
    double x = double.nan, y = double.nan;
}

final class TablePointer
{
    private PointerDispatch _dispatch;
    private PointerMessage[] _told; // what the host is still to hear, reused
    private bool _cellHeld; // the press is on a cell that holds it
    private OverKinds _hostHears; // the things the host hears the enters and leaves of, besides the presses, releases, clicks and cancels
    private PointerTarget _hostOver; // what the host was told it is over: it hears no leave of a thing it never heard entered
    private Point _at; // where the mouse was last seen

    this()
    {
        _dispatch.listen(ListenerWants.init, &keep); // the host holds what it was over while a button is down
        _told.reserve(8); // a frame keeps a few messages at most: none of them allocates
    }

    /// The kinds of things the host hears the mouse enter and leave (someone of it listens to them): they come at every frame of a
    /// scroll under the mouse. What it was told it is over is kept while that kind is still heard, so it hears that left.
    void hostHearsOver(OverKinds kinds)
    {
        _hostHears = kinds;
        if (!kinds.has(_hostOver.kind))
            _hostOver = PointerTarget.init;
    }

    // ---- the point ----

    /// The mouse is at (x, y) of the table (NaN: out of it)
    void at(double x, double y)
    {
        _at = Point(x, y);
    }

    /// Where the mouse was last seen, NaN out of the table: the table asks again what is under it when the rows move
    double x() const pure nothrow @nogc @safe
    {
        return _at.x;
    }

    /// ditto
    double y() const pure nothrow @nogc @safe
    {
        return _at.y;
    }

    // ---- the input ----

    /// The thing under the point is `target` (the mouse moved, or the rows under it); true if it is another one than before
    bool moveTo(PointerTarget target)
    {
        const before = _dispatch.over;
        _dispatch.feed(PointerInput.move, target);
        return _dispatch.over != before;
    }

    /// The main button went down on `target`; `holds`: the cell takes the press itself
    Capture press(PointerTarget target, bool holds)
    {
        const was = _dispatch.pressed;
        _dispatch.feed(PointerInput.down, target);
        _cellHeld = holds && target.kind == TargetKind.cell;
        return was ? Capture.same : Capture.take;
    }

    /// The main button went up over `target`; `dragged`: the press became a drag (the table says), no click
    Capture release(PointerTarget target, bool dragged)
    {
        if (!_dispatch.pressed)
            return Capture.same; // a release of no press (another press, one cancelled): the table moves the mouse there itself
        _dispatch.feed(PointerInput.up, target, dragged);
        _cellHeld = false;
        return Capture.letGo;
    }

    /// The press is over with no release (the window lost the mouse or the focus); nothing with no press
    Capture cancel()
    {
        if (!_dispatch.pressed)
            return Capture.same;
        _dispatch.feed(PointerInput.cancel, PointerTarget.init);
        _cellHeld = false;
        return Capture.letGo;
    }

    /// The rows are other ones: a press is cancelled, the mouse is over nothing until the table asks again what is under the point
    /// (which is kept)
    Capture reset()
    {
        _dispatch.feed(PointerInput.move, PointerTarget.init); // first: the cancel then brings the host back to nothing, not to the old row
        return cancel();
    }

    // ---- what the painter reads ----

    /// The thing under the mouse
    PointerTarget over() const pure nothrow @nogc @safe
    {
        return _dispatch.over;
    }

    /// The row of the cell under the mouse, -1 if the mouse is over no cell: `RowState.hover`
    long overRow() const pure nothrow @nogc @safe
    {
        const o = _dispatch.over;
        return o.kind == TargetKind.cell ? cast(long) o.row : -1;
    }

    /// A press is on: the host holds the mouse
    bool pressed() const pure nothrow @nogc @safe
    {
        return _dispatch.pressed;
    }

    /// The press is held by a cell
    bool cellHeld() const pure nothrow @nogc @safe
    {
        return _cellHeld;
    }

    /// The row of the cell that holds the press, -1 if none does: `CellContext.pressed`
    long heldRow() const pure nothrow @nogc @safe
    {
        return _cellHeld ? cast(long) _dispatch.pressedTarget.row : -1;
    }

    /// The column of the model of that cell (meaningless with no row)
    size_t heldColumn() const pure nothrow @nogc @safe
    {
        return _dispatch.pressedTarget.column;
    }

    // ---- the host ----

    /// Hands `hear` what the host has not heard yet, in order, once (null: nobody hears, the messages are dropped)
    void tell(scope void delegate(in PointerMessage) hear)
    {
        for (size_t i = 0; hear !is null && i < _told.length; i++) // a message the host makes this keep is told here too
            hear(_told[i]);
        if (_told.length == 0)
            return;
        _told.length = 0;
        _told.assumeSafeAppend(); // the buffer is reused: no garbage for each message
    }

    private void keep(in PointerMessage m)
    {
        if (m.action == PointerAction.enter || m.action == PointerAction.leave)
        {
            if (!_hostHears.has(m.target.kind) || (m.action == PointerAction.leave && m.target != _hostOver))
                return;
            _hostOver = m.action == PointerAction.enter ? m.target : PointerTarget.init;
            if (m.action == PointerAction.leave && _told.length > 0 && _told[$ - 1].action == PointerAction.enter
                && _told[$ - 1].target == m.target)
            {
                _told.length = _told.length - 1; // entered and left before the host heard: it hears neither
                _told.assumeSafeAppend();
                return;
            }
        }
        _told ~= m;
    }
}

version (unittest)
{
    private alias cell = PointerTarget.cell;
    private alias title = PointerTarget.header;

    // What the host is told, as "action kind row" words
    private string[] told(TablePointer p)
    {
        import std.conv : to;

        string[] w;
        p.tell((in PointerMessage m) { w ~= m.action.to!string ~ " " ~ m.target.kind.to!string ~ m.target.row.to!string; });
        return w;
    }
}

@("TablePointer: a press takes the mouse and its release or cancel lets it go; a release or a cancel of no press changes nothing")
unittest
{
    auto p = new TablePointer;
    assert(p.release(cell(1, 0), false) == Capture.same && p.cancel() == Capture.same);
    assert(p.press(title(2), false) == Capture.take && p.pressed);
    assert(p.release(title(2), false) == Capture.letGo && !p.pressed);
    assert(p.press(cell(1, 0), false) == Capture.take && p.cancel() == Capture.letGo);
}

@("TablePointer: a cell that holds the press is the pressed one until the release or a cancel; a press it does not hold shows none")
unittest
{
    auto p = new TablePointer;
    p.press(cell(3, 2), true);
    assert(p.cellHeld && p.heldRow == 3 && p.heldColumn == 2);
    p.release(cell(3, 2), false);
    assert(!p.cellHeld && p.heldRow == -1);
    p.press(cell(3, 2), false);
    assert(!p.cellHeld && p.heldRow == -1, "the table took the press");
    p.cancel();
    p.press(cell(1, 0), true);
    p.cancel();
    assert(p.heldRow == -1);
}

@("TablePointer: the host always hears the presses, releases, clicks and cancels, the enters and leaves only while it wants them")
unittest
{
    auto p = new TablePointer;
    p.moveTo(cell(1, 0));
    p.press(cell(1, 0), true);
    p.release(cell(1, 0), false);
    assert(told(p) == ["down cell1", "up cell1", "click cell1"], "no enter and leave unasked");
    p.hostHearsOver(OverKinds.all);
    p.moveTo(cell(2, 0));
    p.press(cell(2, 0), false);
    p.release(cell(2, 0), false);
    assert(told(p) == ["enter cell2", "down cell2", "leave cell2", "up cell2", "click cell2", "enter cell2"]);
    assert(told(p).length == 0, "told once");
}

@("TablePointer: a reset of the rows cancels a press with no click, lets the mouse go and keeps the point, the mouse over nothing")
unittest
{
    auto p = new TablePointer;
    p.hostHearsOver(OverKinds.all);
    p.at(10, 40);
    p.moveTo(cell(5, 0));
    p.press(cell(5, 0), true);
    told(p);
    assert(p.reset() == Capture.letGo);
    assert(!p.pressed && p.heldRow == -1 && p.overRow == -1 && p.x == 10 && p.y == 40);
    assert(told(p) == ["cancel cell5"], "the old row is not entered again: it may be another message now");
    assert(p.release(cell(5, 0), false) == Capture.same && told(p).length == 0, "the release of that press clicks nothing");
    p.moveTo(cell(5, 0));
    assert(told(p) == ["enter cell5"], "the table asks again: what is under the mouse now");
    assert(p.reset() == Capture.same && told(p) == ["leave cell5"], "no press: the mouse leaves what it was over");
}

@("TablePointer: an enter not yet told and the leave of the same thing cancel out, so the host hears where the mouse ended up")
unittest
{
    auto p = new TablePointer;
    p.hostHearsOver(OverKinds.all);
    p.moveTo(cell(1, 0));
    p.moveTo(cell(2, 0));
    p.moveTo(cell(3, 0));
    assert(told(p) == ["enter cell3"], "the rows passed between two tellings are not told");
    p.moveTo(cell(4, 0));
    assert(told(p) == ["leave cell3", "enter cell4"], "a thing told entered is told left");
    p.press(cell(4, 0), false);
    p.release(cell(4, 0), false);
    p.moveTo(cell(5, 0));
    assert(told(p) == ["down cell4", "leave cell4", "up cell4", "click cell4", "enter cell5"],
        "the enter after the release and the leave after it cancel out too: the host is never told it is over two things");
}

@("TablePointer.moveTo: true when the thing under the mouse is another one")
unittest
{
    auto p = new TablePointer;
    assert(p.moveTo(cell(1, 0)) && !p.moveTo(cell(1, 0)) && p.moveTo(title(0)) && p.overRow == -1);
}

@("TablePointer: the host hears the enters and leaves of the kinds it asked for only")
unittest
{
    auto p = new TablePointer;
    p.hostHearsOver(OverKinds(true, false));
    p.moveTo(cell(1, 0));
    p.moveTo(title(2));
    told(p);
    p.moveTo(cell(1, 0));
    assert(told(p) == ["leave header0"], "the cells are not heard");
}

@("TablePointer: asking for one more kind keeps what the host was told it is over, so it hears that left")
unittest
{
    auto p = new TablePointer;
    p.hostHearsOver(OverKinds(true, false));
    p.moveTo(title(2));
    assert(told(p) == ["enter header0"]);
    p.hostHearsOver(OverKinds.all);
    p.moveTo(cell(1, 0));
    assert(told(p) == ["leave header0", "enter cell1"]);
}

@("TablePointer: a kind no longer heard is forgotten: the host hears no leave of it")
unittest
{
    auto p = new TablePointer;
    p.hostHearsOver(OverKinds.all);
    p.moveTo(title(2));
    told(p);
    p.hostHearsOver(OverKinds(false, true));
    p.moveTo(cell(1, 0));
    assert(told(p) == ["enter cell1"]);
}
