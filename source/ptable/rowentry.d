//! What the table knows of an item it has read: its data and how it lays out. Valid for the pass of the table it was read in
//! (`RowWindow`): nobody keeps one from a pass to the next. See docs/stories/painted-table.md.
module ptable.rowentry;

import ptable.model : RowData;

struct Entry
{
    bool valid; /// the model had the item
    RowData data; /// in the arena of the pass
    double height = 0;
    /// The heads of the row's cells in the columns that group the rows (a date, a shift), in the order of
    /// `RowGroups.columns`, in the arena; an empty one: none. The cells' own texts are their bodies (`CellPartsExtractor`)
    const(const(wchar)[])[] heads;
    /// Which of the heads differ from those of the row above, as bits: the row begins a group (`RowGroups.changes`)
    ulong changed;
    /// The room above the row, part of `height`: the row begins a group (its head differs from the row's above)
    double margin = 0;
}
