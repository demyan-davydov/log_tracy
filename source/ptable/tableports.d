//! What the host gives a table besides the model and the layout: the painter, the memory of the rows and the
//! format of a copy. The columns measure their texts themselves. One struct, so a constructor does not take them one by one.
module ptable.tableports;

import ptable.painter : Painter;
import ptable.selection : CopyFormat;

import std.experimental.allocator : RCIAllocator;

struct TablePorts
{
    Painter painter;
    /// Where the memory of the table's rows comes from; unset: the C heap. The table never uses the garbage collector for it
    RCIAllocator memory;
    /// How a copy joins the texts of cells and rows, and how long it may be; unset: a copy is empty (no limit)
    CopyFormat copyFormat;
}
