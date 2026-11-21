//! What the table remembers of the mouse and of the text selected: a press waits to become a click or a
//! text drag, and the selection is a range of text or nothing. State and rules only, free of the table.
module ptable.pointer;

import ptable.selection : isDrag, Position, Selection;

/// The text selection: none, or a `Selection` of two text positions
struct SelectionState
{
    bool has;
    Selection selection;

    /// Sets it (`has` false: none). Returns whether it changed.
    bool set(bool has, Selection selection = Selection.init)
    {
        if (has == this.has && (!has || (selection.anchor == this.selection.anchor && selection.focus == this.selection.focus)))
            return false;
        this.has = has;
        this.selection = selection;
        return true;
    }
}

/// How a press of the main button ended
struct Release
{
    bool wasPressed; /// there was a press
    bool click; /// it was a click: not dragged, and on a text position
    Position position; /// of the click
    size_t column; /// the column of the model it was in
}

/// A press waits: dragged away it selects text, let go where it was it is a click on the row
struct PressTracker
{
    private bool _pressed, _hasPosition, _dragging;
    private double _x = 0, _y = 0;
    private Position _position;
    private size_t _column;

    /// A press at (x, y) on the text position `position` (`hasPosition` false: on no text) in `column`
    void begin(double x, double y, bool hasPosition, Position position, size_t column)
    {
        _pressed = true;
        _dragging = false;
        _x = x;
        _y = y;
        _hasPosition = hasPosition;
        _position = position;
        _column = column;
    }

    bool pressed() const { return _pressed; }
    bool hasPosition() const { return _hasPosition; }
    Position position() const { return _position; }

    /// The mouse moved to (x, y): true once the press is a drag (and stays so until it ends)
    bool dragged(double x, double y)
    {
        if (_pressed && !_dragging && isDrag(_x, _y, x, y))
            _dragging = true;
        return _dragging;
    }

    /// The button went up
    Release end()
    {
        const r = Release(_pressed, _pressed && !_dragging && _hasPosition, _position, _column);
        _pressed = false;
        _dragging = false;
        return r;
    }
}

@("SelectionState: it tells whether the selection changed")
unittest
{
    SelectionState s;
    const a = Selection(Position(1, 0, 2), Position(1, 0, 5));
    assert(!s.set(false), "none stays none");
    assert(s.set(true, a) && s.has);
    assert(!s.set(true, a), "the same one");
    assert(s.set(true, Selection(Position(1, 0, 2), Position(2, 0, 1))));
    assert(s.set(false) && !s.has);
}

@("PressTracker: a press let go where it was is a click, one that moved is a drag and no click")
unittest
{
    PressTracker p;
    assert(!p.end().wasPressed, "no press");
    p.begin(10, 10, true, Position(3, 1, 4), 2);
    assert(!p.dragged(11, 10), "a tremble");
    const click = p.end();
    assert(click.wasPressed && click.click && click.position.row == 3 && click.column == 2);
    p.begin(10, 10, true, Position(3, 1, 4), 2);
    assert(p.dragged(60, 10) && p.dragged(10, 10), "once a drag, a drag");
    const dragged = p.end();
    assert(dragged.wasPressed && !dragged.click);
    assert(!p.pressed);
}

@("PressTracker: a press on no text is no click")
unittest
{
    PressTracker p;
    p.begin(1, 1, false, Position.init, 0);
    assert(!p.end().click);
}
