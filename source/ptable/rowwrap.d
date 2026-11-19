//! The flex cell of a row laid out by its column (`TableColumn.layout`): the lines it gives, whether the host's engine wraps
//! it itself (a paragraph); the height of the row, which is that of its tallest wanted cell (`TableColumn.measure`). See
//! docs/stories/painted-table.md.
module ptable.rowwrap;

version (unittest) import ptable.testing : withBoxes;
import ptable.column : CellInput;
import ptable.memory;
import ptable.model : CellData, ItemKind;
import ptable.rowentry : Entry;
import ptable.rowspec : RowSpec;

import std.algorithm.comparison : max;
import std.experimental.allocator : RCIAllocator;

final class RowWrap
{
    private RowSpec* _spec;

    this(RowSpec* spec)
    {
        _spec = spec;
    }

    /// Lays the flex cell of `e` out by its column (the lines in `arena`) and makes the row as high as its tallest wanted cell
    void wrap(ref Entry e, ref Arena arena)
    {
        auto spec = _spec;
        bool laidOut;
        // a flex column that is hidden (it has no width) is not wrapped
        if (e.data.kind == ItemKind.real_ && spec.flexDef != size_t.max && spec.flexDef < e.data.cells.length && spec.flexWidth > 0)
        {
            const cell = CellInput(0, cast(uint) spec.flexDef, &e.data.cells[spec.flexDef]);
            const done = spec.columns[spec.flexDef].layout(cell, spec.flexWidth, arena);
            e.height = done.height;
            laidOut = true;
        }
        e.height = max(laidOut ? e.height : 0, tallestCell(e.data.cells, laidOut ? spec.flexDef : size_t.max));
    }

    /// The height of a row with no data, as high as the wanted columns make an empty cell: a row not read yet is guessed so
    double emptyHeight()
    {
        return tallestCell(null, size_t.max);
    }

    // The tallest of the wanted cells `cells` (a column past them measures an empty cell) but the one `skip`; 1 if no column has a height
    private double tallestCell(const(CellData)[] cells, size_t skip)
    {
        double height = 0;
        foreach (i, column; _spec.columns)
        {
            if ((i < _spec.wanted.length && !_spec.wanted[i]) || i == skip)
                continue;
            const cell = CellInput(0, cast(uint) i, i < cells.length ? &cells[i] : null);
            height = max(height, column.measure(cell, 0, false).height);
        }
        return height > 0 ? height : 1; // a row still takes room
    }
}

@("RowWrap: a flex column that is an object lays its cell out itself and the row is as high as it says")
unittest
{
    import ptable.column : CellLayout, TableColumn;
    import ptable.layout : ColumnDef;
    import ptable.model : CellData, RowData;
    import ptable.painter : TableGeometry;
    import ptable.testing : BoxColumn;

    final class ThreeLines : TableColumn
    {
        this() { super(ColumnDef("t", "T", 24, true)); }

        override CellLayout layout(ref const CellInput cell, double width, ref Arena arena)
        {
            return CellLayout(3 * 14 + 2);
        }
    }

    TableColumn[] columns = [new BoxColumn(ColumnDef("n", "N")), new ThreeLines];
    RowSpec spec;
    spec.columns = columns;
    spec.flexDef = 1;
    spec.flexWidth = 46;
    TableGeometry geometry;
    spec.geometry = geometry;
    auto wrap = new RowWrap(&spec);
    auto arena = Arena(mallocAllocator());
    Entry e;
    e.data.kind = ItemKind.real_;
    e.data.cells = [CellData("1"w), CellData("abc"w)];
    wrap.wrap(e, arena);
    assert(e.height == 3 * 14 + 2, "what the column said");
    arena.release();
}

@("RowWrap: the flex cell is laid out by its column in the width it has; a column that is hidden has no width and is not laid out")
unittest
{
    import ptable.layout : ColumnDef;
    import ptable.model : CellData, RowData;
    import ptable.painter : TableGeometry;
    import ptable.testing : BoxColumn;

    auto columns = withBoxes([ColumnDef("n", "N"), ColumnDef("t", "T", 24, true)]);
    auto flex = cast(BoxColumn) columns[1];
    RowSpec spec;
    spec.columns = columns;
    spec.flexDef = 1;
    spec.flexWidth = 46;
    TableGeometry geometry;
    spec.geometry = geometry;
    auto wrap = new RowWrap(&spec);
    auto arena = Arena(mallocAllocator());
    Entry e;
    e.data.kind = ItemKind.real_;
    e.data.cells = [CellData("1"w), CellData("aaaabbbbcc"w)];
    wrap.wrap(e, arena);
    assert(flex.layouts == 1 && e.height == 14 + 2, "laid out once, as high as the box");
    spec.flexWidth = 0;
    Entry hidden;
    hidden.data.kind = ItemKind.real_;
    hidden.data.cells = e.data.cells;
    wrap.wrap(hidden, arena);
    assert(flex.layouts == 1, "no width: not laid out");
    arena.release();
}
