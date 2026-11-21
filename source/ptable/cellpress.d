//! A press of the mouse on a cell of a clickable column (`ColumnDef.clickable`): it picks no row and selects no text, and the
//! host gets a click if the button goes up over the same cell. Pure. See docs/stories/painted-table.md.
module ptable.cellpress;

struct CellPress
{
    private bool _on;
    private size_t _row, _column;

    /// The button went down on the cell
    void begin(size_t row, size_t column)
    {
        _on = true;
        _row = row;
        _column = column;
    }

    /// A press on a cell is on
    bool active() const pure nothrow @nogc @safe
    {
        return _on;
    }

    /// The row of the cell pressed, -1 if no press is on
    long row() const pure nothrow @nogc @safe
    {
        return _on ? cast(long) _row : -1;
    }

    /// The column of the model of the cell pressed (meaningless with no press)
    size_t column() const pure nothrow @nogc @safe
    {
        return _column;
    }

    /// The button went up over (`row`, `column`), `over` false: over no cell of a clickable column. True if it is a click (the same
    /// cell the press began on); the press is over either way. False too when no press was on
    bool end(bool over, size_t row, size_t column)
    {
        const click = _on && over && row == _row && column == _column;
        _on = false;
        return click;
    }

    /// The press is over with no click (the window lost the mouse)
    void cancel()
    {
        _on = false;
    }
}

@("CellPress: the button up over the cell it went down on is a click, elsewhere or over no cell it is not, and the press is over")
unittest
{
    CellPress press;
    assert(!press.active && !press.end(true, 1, 0), "no press, no click");
    assert(press.row == -1);
    press.begin(3, 2);
    assert(press.active && press.row == 3 && press.column == 2);
    assert(press.end(true, 3, 2) && !press.active && press.row == -1);
    press.begin(3, 0);
    assert(press.active && press.end(true, 3, 0) && !press.active);
    press.begin(3, 0);
    assert(!press.end(true, 4, 0), "another row");
    press.begin(3, 0);
    assert(!press.end(true, 3, 1), "another column");
    press.begin(3, 0);
    assert(!press.end(false, 3, 0), "outside the clickable cells");
    press.begin(2, 0);
    press.cancel();
    assert(!press.active && !press.end(true, 2, 0));
}
