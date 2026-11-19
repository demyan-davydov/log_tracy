//! The widths the columns grow to by the texts the rows show (a minimum, as in the table of the DOM): what each cell and each head
//! of a group measures (`TableColumn.measure`, `measureGroup`), a column that wraps not at all. `growths` counts the widths
//! grown, so a layout made before one is made again. See docs/stories/painted-table.md.
module ptable.rowgrow;

version (unittest) import ptable.testing : BoxColumn, withBoxes;
import ptable.layout : ColumnLayout;
import ptable.model : ItemKind;
import ptable.rowentry : Entry;
import ptable.column : CellInput, GroupInput;
import ptable.rowspec : RowSpec, maxFitWidth;

import std.algorithm.comparison : min;

final class RowGrow
{
    private ColumnLayout _layout;
    private RowSpec* _spec;

    uint growths; /// counts the widths grown

    this(ColumnLayout layout, RowSpec* spec)
    {
        _layout = layout;
        _spec = spec;
    }

    /// The columns grow to the texts of the row `e`: to the width each cell measures and its border, never more than `maxFitWidth` (a line of
    /// a megabyte would make a column nobody can scroll along); a column that wraps does not grow
    void grow(ref Entry e)
    {
        if (e.data.kind == ItemKind.virtual_)
            return;
        auto spec = _spec;
        foreach (i, column; spec.columns)
        {
            if (column.wraps() || i >= e.data.cells.length || (i < spec.wanted.length && !spec.wanted[i]))
                continue;
            const def = &column.def;
            const cell = CellInput(0, cast(uint) i, &e.data.cells[i]);
            if (_layout.grow(def.id, min(column.measure(cell, 0, true).maxWidth + 1, maxFitWidth)))
                growths++;
            // a head stands in the cell of its column, as the column measures it, and the border: it is never cut
            const slot = e.heads.length ? spec.groups.slotOf(i) : size_t.max;
            if (slot != size_t.max && e.heads[slot].length && _layout.grow(def.id, column.measureGroup(GroupInput(e.heads[slot])).maxWidth + 1))
                growths++;
        }
    }
}

@("RowGrow: the columns grow to the texts of a row, once; a virtual row grows nothing; the flex column that does not wrap grows too")
unittest
{
    import ptable.layout : ColumnDef, ColumnLayout;
    import ptable.model : CellData, ItemKind;
    import ptable.painter : TableGeometry;
    auto columns = withBoxes([ColumnDef("n", "N"), ColumnDef("t", "T", 24, true)]);
    auto layout = new ColumnLayout;
    RowSpec spec;
    spec.columns = columns;
    spec.flexDef = 1;
    TableGeometry geometry;
    spec.geometry = geometry;
    auto grow = new RowGrow(layout, &spec);
    Entry e;
    e.data.kind = ItemKind.real_;
    e.data.cells = [CellData("12345"w), CellData("text"w)];
    grow.grow(e);
    assert(layout.width("n") == 5 * 10 + 6 + 1 && grow.growths == 1, "the column grew to its text; the flex one that wraps does not");
    grow.grow(e);
    assert(grow.growths == 1, "the same text: nothing grows again");
    Entry separator;
    separator.data.kind = ItemKind.virtual_;
    separator.data.cells = [CellData("123456789"w), CellData("x"w)];
    grow.grow(separator);
    assert(grow.growths == 1 && layout.width("n") == 57, "a virtual row grows nothing");
    (cast(BoxColumn) columns[1]).wrapping = false;
    grow.grow(e);
    assert(layout.width("t") == 4 * 10 + 6 + 1 && grow.growths == 2, "the flex column that does not wrap grows to its text");
}
