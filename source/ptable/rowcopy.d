//! The text of rows and of a selection for the clipboard. It reads the model apart from the row cache (a
//! copy may be long and must not push the rows on the screen out), the cells in the order they stand on the screen.
module ptable.rowcopy;

version (unittest) import ptable.testing : tabbed, tabbedUpTo;
import ptable.columnset : ColumnSet;
import ptable.layout : Placements;
import ptable.model;
import ptable.rowranges : RowRange;
import ptable.selection : CopyCell, CopyFormat, rangeText, TextRange;

/// How many rows a copy of rows took of how many it was asked for (the rows of the ranges the model has, less the virtual ones
/// passed before it stopped): fewer when the limit of the format stopped it
struct CopiedRows
{
    size_t copied;
    size_t asked;

    bool cut() const
    {
        return copied < asked;
    }
}

final class RowCopier
{
    private TableModel _model;
    private ColumnSet _columns;
    private RowData _spare;
    private CopyCell[] _cells;
    private CopyFormat _format;

    /// The texts are joined as `format` says
    this(TableModel model, ColumnSet columns, CopyFormat format)
    {
        _model = model;
        _columns = columns;
        _format = format;
    }

    /// The texts of the selectable cells of an item, in the order they stand, with where their bodies begin (after a
    /// head, `CellPartsExtractor`); null for a virtual or lost item. Valid until the next call.
    const(CopyCell)[] cellsOf(size_t item, const(bool)[] wanted, ref const Placements p)
    {
        if (!_model.item(item, _spare, wanted) || _spare.kind == ItemKind.virtual_)
            return null;
        _cells.length = 0;
        assumeSafeAppend(_cells);
        foreach (c; _columns.selectable(p))
        {
            const defIndex = c.defIndex;
            const text = defIndex < _spare.cells.length ? _spare.cells[defIndex].text : ""w;
            _cells ~= CopyCell(text, _columns.column(defIndex).cellParts.body(text).ptr - text.ptr, _columns.column(defIndex));
        }
        return _cells;
    }

    /// The full text of the cell of the column `column` of the model in the row `item`, a head too; "" for a virtual or lost item
    /// or a column the row has no cell of
    wstring cellText(size_t item, size_t column, const(bool)[] wanted)
    {
        if (!_model.item(item, _spare, wanted) || _spare.kind == ItemKind.virtual_ || column >= _spare.cells.length)
            return ""w;
        return _spare.cells[column].text.idup;
    }

    /// The text of a range of the selected text; a cell selected whole is its full text if `wholeCellsInFull`
    wstring ofRange(TextRange range, const(bool)[] wanted, ref const Placements p, bool wholeCellsInFull)
    {
        return rangeText(range, (size_t row) => cellsOf(row, wanted, p), _format, _model.itemCount(), wholeCellsInFull);
    }

    /// The rows of `ranges` (sorted), joined as the format says, in their order: the rows the model has and that are real ones. The text
    /// stops before the row that would make it longer than the limit of the format; a range of millions of rows is read only as far.
    wstring ofRows(const(RowRange)[] ranges, const(bool)[] wanted, ref const Placements p, bool wholeCellsInFull)
    {
        CopiedRows copied;
        return ofRows(ranges, wanted, p, wholeCellsInFull, copied);
    }

    /// The same, and how many rows it took of how many were asked (`copied`)
    wstring ofRows(const(RowRange)[] ranges, const(bool)[] wanted, ref const Placements p, bool wholeCellsInFull, out CopiedRows copied)
    {
        import std.array : appender;

        auto text = appender!wstring;
        const count = _model.itemCount();
        size_t asked, virtuals;
        foreach (range; ranges)
            if (range.first < count)
                asked += (range.last < count ? range.last : count - 1) - range.first + 1;
        scope (exit)
            copied.asked = asked - virtuals;
        foreach (range; ranges)
        {
            if (range.first >= count)
                break;
            const last = range.last < count ? range.last : count - 1;
            foreach (row; range.first .. last + 1)
            {
                const cells = cellsOf(row, wanted, p);
                if (cells is null)
                {
                    ++virtuals;
                    continue;
                }
                const line = lineOf(cells, wholeCellsInFull);
                const limit = _format.limit;
                const added = (text.data.length ? _format.rows.length : 0) + line.length;
                if (text.data.length + added > limit)
                {
                    if (text.data.length)
                        return text.data;
                    copied.copied = 1;
                    return line[0 .. limit]; // a single row over the limit is cut, not dropped
                }
                if (text.data.length)
                    text ~= _format.rows;
                text ~= line;
                ++copied.copied;
            }
        }
        return text.data;
    }

    /// The cells of an item, joined as the format says: their full texts if `wholeCellsInFull`, else as they are shown
    wstring ofRow(size_t item, const(bool)[] wanted, ref const Placements p, bool wholeCellsInFull)
    {
        return lineOf(cellsOf(item, wanted, p), wholeCellsInFull);
    }

    private wstring lineOf(const(CopyCell)[] cells, bool wholeCellsInFull)
    {
        wstring line;
        foreach (i, ref cell; cells)
            line ~= (i ? _format.cells : ""w) ~ cell.column.copyCell(cell.full, cell.bodyStart, wholeCellsInFull);
        return line;
    }
}

@("RowCopier: the rows of ranges, one per line, in their order, none past the end or virtual, and no more than the limit")
unittest
{
    import ptable.layout : ColumnLayout, placeColumns;

    auto model = new NumbersModel(10);
    auto columns = new ColumnSet(new ColumnLayout);
    columns.refresh(model.columns());
    const p = placeColumns(columns.columns, new ColumnLayout, 300);
    auto copier = new RowCopier(model, columns, tabbed);
    assert(copier.ofRows([RowRange(1, 2), RowRange(4, 4)], null, p, true) == "1\trow 1\n2\trow 2\n4\trow 4"w);
    assert(copier.ofRows([RowRange(8, 20)], null, p, true) == "8\trow 8\n9\trow 9"w, "the rows the model has");
    assert(copier.ofRows(null, null, p, true) == ""w);
    assert(new RowCopier(model, columns, tabbedUpTo(20)).ofRows([RowRange(0, 9)], null, p, true) == "0\trow 0\n1\trow 1"w,
        "stops before the row that would pass the limit");
}

@("RowCopier: how many rows went into the text of all asked: all of them, or fewer when the limit stopped it")
unittest
{
    import ptable.layout : ColumnLayout, placeColumns;

    auto model = new NumbersModel(10);
    auto columns = new ColumnSet(new ColumnLayout);
    columns.refresh(model.columns());
    const p = placeColumns(columns.columns, new ColumnLayout, 300);
    CopiedRows copied;
    new RowCopier(model, columns, tabbed).ofRows([RowRange(1, 2), RowRange(4, 4)], null, p, true, copied);
    assert(copied == CopiedRows(3, 3) && !copied.cut);
    new RowCopier(model, columns, tabbedUpTo(20)).ofRows([RowRange(0, 9)], null, p, true, copied);
    assert(copied == CopiedRows(2, 10) && copied.cut, "the limit stopped it after two");
    new RowCopier(model, columns, tabbed).ofRows([RowRange(8, 20)], null, p, true, copied);
    assert(copied == CopiedRows(2, 2), "the rows the model has are all that was asked");
}

@("RowCopier: the text of one cell by its row and column of the model, none for a row or a column that is not there")
unittest
{
    import ptable.layout : ColumnLayout, placeColumns;

    auto model = new NumbersModel(10);
    auto copier = new RowCopier(model, new ColumnSet(new ColumnLayout), tabbed);
    assert(copier.cellText(3, 0, null) == "3"w && copier.cellText(3, 1, null) == "row 3"w);
    assert(copier.cellText(3, 7, null) == ""w && copier.cellText(30, 0, null) == ""w);
}

@("RowCopier: a row is its selectable cells with tabs between, a range is its rows")
unittest
{
    import ptable.layout : ColumnLayout, placeColumns;
    import ptable.selection : Position, Selection, textRange;

    auto model = new NumbersModel(5);
    auto columns = new ColumnSet(new ColumnLayout);
    columns.refresh(model.columns());
    const p = placeColumns(columns.columns, new ColumnLayout, 300);
    auto copier = new RowCopier(model, columns, tabbed);
    assert(copier.ofRow(3, null, p, true) == "3\trow 3"w);
    assert(copier.cellsOf(99, null, p) is null, "no such item");
    const range = textRange(Selection(Position(1, 0, 0), Position(2, 1, 5)));
    assert(copier.ofRange(range, null, p, true) == "1\trow 1\n2\trow 2"w);
}

@("RowCopier: a cell with a head is its body, or its full text for a whole cell when asked")
unittest
{
    import ptable.layout : ColumnLayout, placeColumns;
    import ptable.selection : Position, Selection, textRange;
    import ptable.testing : DatedModel;

    auto model = new DatedModel(10, 3);
    auto columns = new ColumnSet(new ColumnLayout);
    columns.refresh(model.columns());
    const p = placeColumns(columns.columns, new ColumnLayout, 300);
    auto copier = new RowCopier(model, columns, tabbed);
    assert(copier.ofRow(4, null, p, false) == "t4\trow 4"w);
    assert(copier.ofRow(4, null, p, true) == "d1 t4\trow 4"w);
    const timeCell = textRange(Selection(Position(4, 0, 0), Position(4, 0, 2)));
    assert(copier.ofRange(timeCell, null, p, true) == "d1 t4"w && copier.ofRange(timeCell, null, p, false) == "t4"w);
}

@("RowCopier: a row is read once for the copy of rows, and a single row over the limit is cut, not dropped")
unittest
{
    import ptable.layout : ColumnLayout, placeColumns;
    import ptable.testing : DatedModel;

    auto model = new DatedModel(10, 3);
    auto columns = new ColumnSet(new ColumnLayout);
    columns.refresh(model.columns());
    const p = placeColumns(columns.columns, new ColumnLayout, 300);
    auto copier = new RowCopier(model, columns, tabbed);
    copier.ofRows([RowRange(2, 4)], null, p, true);
    assert(model.reads[2] == 1 && model.reads[3] == 1 && model.reads[4] == 1, "one read of the model for each");
    auto short_ = new RowCopier(model, columns, tabbedUpTo(4));
    assert(short_.ofRows([RowRange(2, 4)], null, p, true) == "d0 t"w, "a row longer than the limit is cut to it");
}
