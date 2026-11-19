//! The cell under the mouse: a row and a column of the model, or none. The table keeps one and gives the painter two flags by it (the
//! row under the mouse, the cell under it); a frame compares two numbers, a row costs nothing. Pure. See docs/stories/painted-table.md.
module ptable.hovercell;

struct HoverCell
{
    private long _row = -1;
    private size_t _column;

    /// Where the mouse was last seen, in the table's coordinates (NaN: out of the table): the cell under it is asked again when the rows move
    double x = double.nan, y = double.nan;

    /// The row under the mouse, -1 if none
    long row() const pure nothrow @nogc @safe
    {
        return _row;
    }

    /// The column of the model under the mouse (meaningless with no row)
    size_t column() const pure nothrow @nogc @safe
    {
        return _column;
    }

    /// The mouse is over (`row`, `column`); true if that is another cell than before
    bool set(size_t row, size_t column)
    {
        if (_row == cast(long) row && _column == column)
            return false;
        _row = row;
        _column = column;
        return true;
    }

    /// The mouse is over no cell; true if it was over one
    bool clear()
    {
        if (_row < 0)
            return false;
        _row = -1;
        return true;
    }
}

@("HoverCell: another cell is a change, the same one is not, clearing tells whether there was one")
unittest
{
    HoverCell hover;
    assert(hover.row == -1 && !hover.clear());
    assert(hover.set(3, 1) && hover.row == 3 && hover.column == 1);
    assert(!hover.set(3, 1), "the same cell: no news");
    assert(hover.set(3, 2) && hover.set(4, 2), "another column, another row");
    assert(hover.clear() && hover.row == -1 && !hover.clear());
}
