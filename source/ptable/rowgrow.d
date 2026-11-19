//! What the rows in the window need of the widths of the columns (a minimum, as in the table of the DOM): what each cell and each head
//! of a group measures (`TableColumn.measure`, `measureGroup`), a column that wraps not at all. The columns take that width as it is now
//! (`RowStore.measure`, settled by `ColumnHost.settle`): it grows and narrows with the rows in sight. `growths` counts the widths changed, so a layout made before
//! one is made again. See docs/stories/painted-table.md.
module ptable.rowgrow;

version (unittest) import ptable.testing : BoxColumn, withBoxes;
import ptable.model : ItemKind;
import ptable.rowentry : Entry;
import ptable.column : CellInput, GroupInput;
import ptable.rowspec : RowSpec, maxFitWidth;

import std.algorithm.comparison : max, min;

final class RowGrow
{
    private RowSpec* _spec;

    uint growths; /// counts the widths changed

    this(RowSpec* spec)
    {
        _spec = spec;
    }

    /// A width was changed by what the rows need
    void fitted()
    {
        growths++;
    }

    /// What the row `e` needs of each column, into `needs` (one per column, only raised): the width of its cell and its border, never
    /// more than `maxFitWidth` (a line of a megabyte would make a column nobody can scroll along), and of its head (a head stands in the
    /// cell of its column, as the column measures it, and is never cut); 0 where it needs nothing (a column that wraps, one not
    /// wanted, a virtual row)
    void needs(ref Entry e, double[] needs)
    {
        if (e.data.kind == ItemKind.virtual_)
            return;
        auto spec = _spec;
        foreach (i, column; spec.columns)
        {
            if (i >= needs.length || column.wraps() || i >= e.data.cells.length || (i < spec.wanted.length && !spec.wanted[i]))
                continue;
            const cell = CellInput(0, cast(uint) i, &e.data.cells[i]);
            needs[i] = max(needs[i], min(column.measure(cell, 0, true).maxWidth + 1, maxFitWidth));
            const slot = e.heads.length ? spec.groups.slotOf(i) : size_t.max;
            if (slot != size_t.max && e.heads[slot].length)
                needs[i] = max(needs[i], column.measureGroup(GroupInput(e.heads[slot])).maxWidth + 1);
        }
    }
}

@("RowGrow: needs gives what a row needs of each column, raised over rows; a virtual row and a column that wraps need nothing")
unittest
{
    import ptable.layout : ColumnDef;
    import ptable.model : CellData, ItemKind;
    import ptable.painter : TableGeometry;

    auto columns = withBoxes([ColumnDef("n", "N"), ColumnDef("t", "T", 24, true)]);
    RowSpec spec;
    spec.columns = columns;
    spec.flexDef = 1;
    TableGeometry geometry;
    spec.geometry = geometry;
    auto grow = new RowGrow(&spec);
    Entry a, b, separator;
    a.data.kind = b.data.kind = ItemKind.real_;
    a.data.cells = [CellData("12345"w), CellData("t"w)];
    b.data.cells = [CellData("12"w), CellData("t"w)];
    separator.data.kind = ItemKind.virtual_;
    separator.data.cells = [CellData("123456789"w), CellData("x"w)];
    auto needs = new double[2];
    needs[] = 0;
    grow.needs(a, needs);
    grow.needs(b, needs);
    grow.needs(separator, needs);
    assert(needs[0] == 5 * 10 + 6 + 1 && needs[1] == 0, "the widest row of the column; the flex one that wraps needs nothing ");
    (cast(BoxColumn) columns[1]).wrapping = false;
    grow.needs(a, needs);
    assert(needs[1] == 1 * 10 + 6 + 1, "the flex column that does not wrap needs its text");
}
