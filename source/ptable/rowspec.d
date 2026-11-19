//! What the units that read, wrap and measure the rows of a table are told of the columns and the look: the definitions,
//! the flex column and its width, which columns the model fills, which ones group the rows, the geometry and the fonts.
//! Data the table's row cache owns and the units read through a pointer. Pure. See docs/stories/painted-table.md.
module ptable.rowspec;

import ptable.column : TableColumn;
import ptable.layout : ColumnDef;
import ptable.painter : TableGeometry;
import ptable.rowgroups : RowGroups;

/// The widest a column grows to by the text it shows (the flex column that does not wrap): the line of a megabyte
/// would make a column nobody can scroll along
enum double maxFitWidth = 100_000;


struct RowSpec
{
    TableColumn[] columns; /// in the order of the model
    size_t flexDef = size_t.max;
    bool[] wanted; /// the columns the model fills (the visible ones)
    RowGroups groups; /// which column groups the rows
    TableGeometry geometry;
    double flexWidth = -1;

}
