//! Where a table stands and how a host or a script moves it, on both axes: `Viewport` is what the table shows now, `ScrollPosition` where it is told
//! to stand. The rows are told by an item and the pixels of it scrolled away, never by an absolute pixel (the heights of the rows far off are not
//! known: they are read when they come near); the columns by pixels, or by a column and the pixels of it scrolled away. See docs/stories/painted-table.md.
module ptable.scrollplace;

import ptable.layout : Placement;
import ptable.ports : Rect;
import ptable.rowlayout : RowSlot, ViewState;
import ptable.viewport : ScrollMetrics;

/// The rows and the columns stand where this says; whatever is left out stays where it is
struct ScrollPosition
{
    enum size_t keepRows = size_t.max;

    size_t row = keepRows; /// the item that is first in the window
    double rowOffset = 0; /// the pixels of that item scrolled away above the window
    string column; /// the id of a scrolling column that is first in the window (a pinned, a hidden or an unknown one: the columns stay)
    double columnOffset = 0; /// the pixels of that column scrolled away at the left
    double x = double.nan; /// the columns scrolled sideways by this many pixels, when no column is named; NaN: they stay

    /// The rows only: the item `row` first, `offset` pixels of it scrolled away
    static ScrollPosition ofRow(size_t row, double offset = 0)
    {
        ScrollPosition p;
        p.row = row;
        p.rowOffset = offset;
        return p;
    }

    /// The columns only: scrolled sideways by `x` pixels
    static ScrollPosition ofX(double x)
    {
        ScrollPosition p;
        p.x = x;
        return p;
    }

    /// The columns only: the column `id` first, `offset` pixels of it scrolled away
    static ScrollPosition ofColumn(string id, double offset = 0)
    {
        ScrollPosition p;
        p.column = id;
        p.columnOffset = offset;
        return p;
    }

    /// Both axes: a row and pixels sideways
    static ScrollPosition of(size_t row, double rowOffset, double x)
    {
        auto p = ofRow(row, rowOffset);
        p.x = x;
        return p;
    }
}

/// What a table shows now: the first item and the part of it scrolled away, the rows (in items) and the columns (in pixels) as a bar shows them,
/// the room the rows lie in, the rows on the screen (the item, the top of it in the room, its height) and the columns (their id, where they stand in
/// the viewport and how wide they are). The slices are valid until the next layout. What a script reads to find how far to scroll
struct Viewport
{
    ViewState first;
    ScrollMetrics rows, columns;
    Rect area;
    const(RowSlot)[] slots;
    const(Placement)[] places;
}
