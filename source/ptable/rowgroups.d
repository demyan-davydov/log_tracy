//! The groups of the rows of a table: which columns group them (those whose cells have heads, `CellPartsExtractor`)
//! and which heads of a row differ from those of the row above (`changes`: a row with any begins a group). The rows
//! need not be in the order of their heads: a head that comes back begins a group again. Pure; the row cache and the
//! frame painter ask it. See docs/backlog.md (the date of the time column over its rows).
module ptable.rowgroups;

version (unittest) import ptable.testing : withBoxes;
import ptable.column : TableColumn;
import ptable.layout : ColumnDef;

struct RowGroups
{
    private size_t[] _columns; // the columns whose cells have heads, in the order of the model's columns

    /// The most columns that group: a row's changes are bits of a `ulong`
    enum maxColumns = 64;

    /// The columns of the table: every one whose cells have heads groups the rows
    void configure(const(TableColumn)[] columns)
    {
        _columns.length = 0;
        foreach (i, column; columns)
            if (column.cellParts.hasHead && _columns.length < maxColumns)
                _columns ~= i;
    }

    /// The columns that group the rows (the indices of their definitions), in order: a row's heads stand in this order
    const(size_t)[] columns() const pure nothrow @nogc @safe
    {
        return _columns;
    }

    /// Where the column `defIndex` stands among a row's heads, `size_t.max` if it does not group
    size_t slotOf(size_t defIndex) const pure nothrow @nogc @safe
    {
        foreach (k, c; _columns)
            if (c == defIndex)
                return k;
        return size_t.max;
    }

    /// Whether the rows are grouped: a column has heads and the painter gives room to them
    bool grouping(double groupHeight) const pure nothrow @nogc @safe
    {
        return _columns.length > 0 && groupHeight > 0;
    }

    /// The heads of the row `index` (one a grouping column) that differ from those of the row above, `above` (shorter:
    /// the missing ones are empty), as bits: a row with any begins a group. Not the first row of all (its heads are over
    /// the header), nor a cell with no head
    static ulong changes(size_t index, const(const(wchar)[])[] heads, const(const(wchar)[])[] above) pure nothrow @nogc @safe
    {
        if (index == 0)
            return 0;
        ulong bits;
        foreach (k, head; heads)
            if (head.length && head != (k < above.length ? above[k] : null))
                bits |= 1UL << k;
        return bits;
    }
}

@("RowGroups: a column whose cells have heads groups the rows, and only with room for the heads")
unittest
{
    import ptable.cellparts : HeadedCellPartsExtractor, firstSpace;

    RowGroups groups;
    auto columns = withBoxes([ColumnDef("n", "N"), ColumnDef("time", "Time")]);
    columns[1].parts = new immutable HeadedCellPartsExtractor(&firstSpace);
    groups.configure(columns);
    assert(groups.columns == [1] && groups.grouping(20) && !groups.grouping(0));
    groups.configure(withBoxes([ColumnDef("n", "N")]));
    assert(groups.columns.length == 0 && !groups.grouping(20), "no column with heads");
}

@("RowGroups: every column whose cells have heads groups the rows, each has its place among the heads of a row")
unittest
{
    import ptable.cellparts : HeadedCellPartsExtractor, firstSpace;

    RowGroups groups;
    auto columns = withBoxes([ColumnDef("n", "N"), ColumnDef("day", "Day"), ColumnDef("t", "T"), ColumnDef("shift", "Shift")]);
    columns[1].parts = new immutable HeadedCellPartsExtractor(&firstSpace);
    columns[3].parts = columns[1].parts;
    groups.configure(columns);
    assert(groups.columns == [1, 3] && groups.slotOf(1) == 0 && groups.slotOf(3) == 1 && groups.slotOf(2) == size_t.max);
}

@("RowGroups: the heads that changed from the row above are bits; a missing head above counts as empty")
unittest
{
    const(wchar)[][2] heads = ["D1"w, "S4"w];
    const(wchar)[][2] same = ["D1"w, "S4"w];
    const(wchar)[][2] dayOnly = ["D0"w, "S4"w];
    const(wchar)[][2] both = ["D0"w, "S3"w];
    assert(RowGroups.changes(5, heads[], same[]) == 0);
    assert(RowGroups.changes(5, heads[], dayOnly[]) == 0b01);
    assert(RowGroups.changes(5, heads[], both[]) == 0b11);
    assert(RowGroups.changes(0, heads[], both[]) == 0, "the first row of all: its heads are over the header");
    assert(RowGroups.changes(5, heads[], null) == 0b11, "no heads above");
    const(wchar)[][2] noShift = ["D1"w, ""w];
    assert(RowGroups.changes(5, noShift[], dayOnly[]) == 0b01, "no head in a cell: no change there, only the day's");
}
