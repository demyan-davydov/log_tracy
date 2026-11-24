//! The one place the mouse of a table goes through: the table feeds it what the mouse did (a move, a press, a release, a cancel) and the
//! thing of the table under the point (a title, a cell, nothing: the table's hit test), and it tells each listener what it is to hear.
//! A press always holds the mouse until the release or a cancel (`pressed`: the host captures it then), whatever the listeners are.
//! Each listener says once what it wants while the button is down (`ListenerWants`): to keep the thing it was over (the default: a leave
//! at the press, nothing until the release, then the thing under the mouse again) or to follow the things the mouse passes (`track`).
//! One listener's wants change nothing of what the others hear. When a listener hears is its own business (one that tells the script
//! keeps what it heard until the frame is painted). The rows moving under a still mouse are a move to the thing now under it. Knows no
//! geometry, and whether a press became a drag is the table's to say. See docs/stories/painted-table.md.
module ptable.pointerdispatch;

/// What a thing of the table under the mouse is
enum TargetKind : ubyte
{
    none, /// nothing the listeners hear of: below the rows, a margin, the footer, out of the table
    header, /// a column's title: a column, no row
    cell, /// a cell of a row: a row and a column
}

/// A thing of the table the mouse can be over or press: its kind, its column of the model, the row of a cell
struct PointerTarget
{
    TargetKind kind;
    size_t row; /// of a cell, 0 else
    size_t column; /// of a title or a cell, 0 else

    /// The title of the column `column` of the model
    static PointerTarget header(size_t column) pure nothrow @nogc @safe
    {
        return PointerTarget(TargetKind.header, 0, column);
    }

    /// The cell of the row `row` in the column `column` of the model
    static PointerTarget cell(size_t row, size_t column) pure nothrow @nogc @safe
    {
        return PointerTarget(TargetKind.cell, row, column);
    }
}

/// What the mouse did, as the table feeds it
enum PointerInput : ubyte
{
    move, /// the mouse moved (with the button down or not), or the rows moved under it
    down, /// the main button went down
    up, /// the main button went up
    cancel, /// the press is over with no release (the window lost the mouse or the focus); nothing with no press
}

/// What a listener hears
enum PointerAction : ubyte
{
    enter, /// the mouse came over the thing
    leave, /// the mouse left the thing, or a press began and the listener holds (it hears the thing again after the release)
    down, /// the button went down on the thing (a press on nothing is told nothing of: no down, up or cancel)
    up, /// the button went up over the thing
    click, /// the button went down and up on the thing, with no drag
    cancel, /// the press is over with no release; the thing is the one it began on
}

/// What a listener hears: what happened, to what
struct PointerMessage
{
    PointerAction action;
    PointerTarget target;
}

/// What a listener wants while the button is down
struct ListenerWants
{
    bool track; /// the enters and leaves of the things the mouse passes go on (else: a leave at the press, the thing again after the release)
}

/// The listeners of a table's mouse and what each was told
struct PointerDispatch
{
    private static struct Listener
    {
        ListenerWants wants;
        void delegate(in PointerMessage) hear;
        PointerTarget told; // the thing it was last told the mouse is over
    }

    private Listener[] _listeners;
    private PointerTarget _over, _pressed;
    private bool _pressOn;

    /// Adds a listener; it hears from the next input on
    void listen(ListenerWants wants, void delegate(in PointerMessage) hear)
    {
        _listeners ~= Listener(wants, hear);
    }

    /// A press is on: the host holds the mouse (captures it) until it is not
    bool pressed() const pure nothrow @nogc @safe
    {
        return _pressOn;
    }

    /// The thing the press began on (none with no press)
    PointerTarget pressedTarget() const pure nothrow @nogc @safe
    {
        return _pressed;
    }

    /// The thing under the mouse, as last fed
    PointerTarget over() const pure nothrow @nogc @safe
    {
        return _over;
    }

    /// The mouse did `input` over `target` (a cancel: wherever it is). `dragged` (an `up` only): the press became a drag, the table says,
    /// so the release is no click
    void feed(PointerInput input, PointerTarget target, bool dragged = false)
    {
        if (target.kind == TargetKind.none)
            target = PointerTarget.init;
        if (!_pressOn && input == PointerInput.cancel)
            return; // the focus was lost with no button down: the mouse is where it was
        if (!_pressOn && input == PointerInput.up)
            input = PointerInput.move; // a release of no press (another button, a press that was not the table's): a move
        final switch (input)
        {
        case PointerInput.move:
            _over = target;
            foreach (ref l; _listeners)
                if (!_pressOn || l.wants.track)
                    sync(l, target);
            break;
        case PointerInput.down:
            _over = _pressed = target;
            _pressOn = true;
            foreach (ref l; _listeners)
            {
                sync(l, target); // a press where no move told it
                if (target.kind != TargetKind.none) // a press on nothing holds the mouse, and is nobody's news
                    l.hear(PointerMessage(PointerAction.down, target));
                if (!l.wants.track)
                    sync(l, PointerTarget.init); // it holds: nothing until the release
            }
            break;
        case PointerInput.up:
            const click = !dragged && target.kind != TargetKind.none && target == _pressed;
            const ofSomething = _pressed.kind != TargetKind.none; // the press was on a thing: its listeners hear how it ended
            _over = target;
            endPress();
            foreach (ref l; _listeners)
            {
                if (l.wants.track)
                    sync(l, target);
                if (ofSomething)
                    l.hear(PointerMessage(PointerAction.up, target));
                if (click)
                    l.hear(PointerMessage(PointerAction.click, target));
                if (!l.wants.track)
                    sync(l, target);
            }
            break;
        case PointerInput.cancel:
            const began = _pressed;
            endPress();
            foreach (ref l; _listeners)
            {
                if (began.kind != TargetKind.none)
                    l.hear(PointerMessage(PointerAction.cancel, began));
                if (!l.wants.track)
                    sync(l, _over);
            }
            break;
        }
    }

    private void endPress()
    {
        _pressOn = false;
        _pressed = PointerTarget.init;
    }

    // Tells `l` the mouse is over `target` if it was told another thing: a leave of that one, an enter of this one
    private static void sync(ref Listener l, PointerTarget target)
    {
        if (l.told == target)
            return;
        if (l.told.kind != TargetKind.none)
            l.hear(PointerMessage(PointerAction.leave, l.told));
        if (target.kind != TargetKind.none)
            l.hear(PointerMessage(PointerAction.enter, target));
        l.told = target;
    }
}

version (unittest)
{
    private struct Heard
    {
        PointerMessage[] messages;

        void hear(in PointerMessage m)
        {
            messages ~= m;
        }

        // What was heard, as "action kind row column" words: short to compare
        string[] words()
        {
            import std.conv : to;

            string[] w;
            foreach (m; messages)
                w ~= m.action.to!string ~ " " ~ (m.target.kind == TargetKind.none ? "none"
                    : m.target.kind == TargetKind.header ? "h" ~ m.target.column.to!string
                    : "c" ~ m.target.row.to!string ~ ":" ~ m.target.column.to!string);
            messages = null;
            return w;
        }
    }

    private alias cell = PointerTarget.cell;
    private alias title = PointerTarget.header;
    private enum none = PointerTarget.init;
}

@("PointerDispatch: with no press a listener hears a leave and an enter only when the mouse comes to another thing")
unittest
{
    PointerDispatch d;
    Heard a;
    d.listen(ListenerWants.init, &a.hear);
    d.feed(PointerInput.move, title(0));
    d.feed(PointerInput.move, title(0));
    d.feed(PointerInput.move, title(1));
    d.feed(PointerInput.move, cell(0, 1));
    d.feed(PointerInput.move, none);
    assert(a.words == ["enter h0", "leave h0", "enter h1", "leave h1", "enter c0:1", "leave c0:1"]);
    assert(!d.pressed);
}

@("PointerDispatch: a press holds the mouse until the release, a click is the release on the thing of the press with no drag")
unittest
{
    PointerDispatch d;
    Heard a;
    d.listen(ListenerWants.init, &a.hear);
    d.feed(PointerInput.move, cell(2, 0));
    a.words;
    d.feed(PointerInput.down, cell(2, 0));
    assert(d.pressed && d.pressedTarget == cell(2, 0));
    d.feed(PointerInput.up, cell(2, 0));
    assert(!d.pressed);
    assert(a.words == ["down c2:0", "leave c2:0", "up c2:0", "click c2:0", "enter c2:0"]);
    d.feed(PointerInput.down, cell(2, 0));
    d.feed(PointerInput.up, cell(2, 0), true);
    assert(!a.words.canFindWord("click"), "a drag back to it is no click");
    d.feed(PointerInput.down, cell(2, 0));
    d.feed(PointerInput.move, cell(3, 0));
    d.feed(PointerInput.up, cell(3, 0));
    assert(a.words == ["down c2:0", "leave c2:0", "up c3:0", "enter c3:0"], "released over another thing: no click, the thing under the mouse at last");
    d.feed(PointerInput.down, none);
    assert(d.pressed, "a press on nothing holds the mouse too");
    d.feed(PointerInput.up, none);
    assert(!d.pressed && !a.words.canFindWord("click"), "and clicks nothing");
}

@("PointerDispatch: a listener that holds hears nothing between the press and the release, one that tracks hears the things passed")
unittest
{
    PointerDispatch d;
    Heard holds, tracks;
    d.listen(ListenerWants(false), &holds.hear);
    d.listen(ListenerWants(true), &tracks.hear);
    d.feed(PointerInput.move, title(1));
    holds.words;
    tracks.words;
    d.feed(PointerInput.down, title(1));
    d.feed(PointerInput.move, title(2));
    d.feed(PointerInput.move, cell(0, 2));
    d.feed(PointerInput.up, cell(0, 2));
    assert(holds.words == ["down h1", "leave h1", "up c0:2", "enter c0:2"]);
    assert(tracks.words == ["down h1", "leave h1", "enter h2", "leave h2", "enter c0:2", "up c0:2"], "it was told where the mouse is all along");
}

@("PointerDispatch: a cancel ends the press with no click, and the listeners that held hear the thing under the mouse again")
unittest
{
    PointerDispatch d;
    Heard a;
    d.listen(ListenerWants.init, &a.hear);
    d.feed(PointerInput.move, cell(4, 1));
    d.feed(PointerInput.down, cell(4, 1));
    d.feed(PointerInput.move, cell(5, 1));
    a.words;
    d.feed(PointerInput.cancel, none);
    assert(!d.pressed);
    assert(a.words == ["cancel c4:1", "enter c5:1"], "the cancel names the thing of the press; then where the mouse was last fed");
}

@("PointerDispatch: a press on nothing holds the mouse but tells the listeners nothing of the press, the release or the cancel")
unittest
{
    PointerDispatch d;
    Heard a;
    d.listen(ListenerWants.init, &a.hear);
    d.feed(PointerInput.down, none);
    d.feed(PointerInput.up, none);
    d.feed(PointerInput.down, none);
    assert(d.pressed);
    d.feed(PointerInput.cancel, none);
    assert(a.words.length == 0);
    d.feed(PointerInput.down, none);
    d.feed(PointerInput.up, cell(1, 0));
    assert(a.words == ["enter c1:0"], "released over a cell: no up of it, the mouse is over it");
}

@("PointerDispatch: a cancel with no press changes nothing (the window lost the focus with no button down)")
unittest
{
    PointerDispatch d;
    Heard a;
    d.listen(ListenerWants.init, &a.hear);
    d.feed(PointerInput.move, cell(1, 0));
    a.words;
    d.feed(PointerInput.cancel, none);
    assert(a.words.length == 0 && d.over == cell(1, 0), "the mouse is where it was");
}

@("PointerDispatch: what one listener wants changes nothing of what another hears")
unittest
{
    PointerDispatch alone, together;
    Heard a, b, c;
    alone.listen(ListenerWants.init, &a.hear);
    together.listen(ListenerWants.init, &b.hear);
    together.listen(ListenerWants(true), &c.hear);
    foreach (ref d; [&alone, &together])
    {
        d.feed(PointerInput.move, title(0));
        d.feed(PointerInput.down, title(0));
        d.feed(PointerInput.move, cell(1, 0));
        d.feed(PointerInput.move, cell(2, 0));
        d.feed(PointerInput.up, cell(2, 0));
    }
    assert(a.words == b.words);
}

version (unittest) private bool canFindWord(string[] words, string action)
{
    import std.algorithm.searching : canFind, startsWith;

    return words.canFind!(w => w.startsWith(action ~ " "));
}
