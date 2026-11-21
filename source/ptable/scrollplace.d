//! Where a cell stands in the viewport of a table: the position the table reports of its first and last visible cell and is told to scroll to. The
//! rows are told by an item and where its top is, never by an absolute pixel (the heights of the rows far off are not known: they are read when
//! they come near). See docs/stories/painted-table.md.
module ptable.scrollplace;

/// A cell and where its left top corner is, from the left top corner of the place the rows lie in (below the header, right of the columns pinned at
/// the left): a negative `dy` or `dx` is a cell that is partly gone beyond the edge. The columns are numbered as the model has them
struct CellPosition
{
    size_t row;
    size_t column;
    double dy = 0;
    double dx = 0;
}
