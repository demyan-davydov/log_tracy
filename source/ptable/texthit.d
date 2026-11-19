//! Where the text of the table is under a point, and which rectangles a selected text takes, by the cells of a row: the cell under
//! the point, the part of each cell a selection takes. How a content lies in its cell is its column's business (`TableColumn.hitTest`,
//! `rects`). Pure.
module ptable.texthit;

version (unittest) import ptable.testing : plainText;
import ptable.column : CellInput, TableColumn;
import ptable.ports : Rect;
import ptable.selection;

version (unittest)
{
    import ptable.layout : ColumnDef;
    import ptable.model : CellData;
}

/// The text of a cell as the hit tests see it: what its column is given of it, where it stands, and the column, which answers
struct CellText
{
    CellInput input;
    Rect area;
    Rect view; /// the part of `area` seen (`seenOf`)
    TableColumn column;

    /// The text of the cell, none if the model gave none
    const(wchar)[] text() const pure nothrow @nogc @safe
    {
        return input.data !is null ? input.data.text : null;
    }
}

// The selectable cells of one row, left to right, are anything that has: `length` (their count), `right(col)` (the
// right edge of the cell `col`) and `cell(col)` (its `CellText`). A struct or a class: the table asks about them on every
// frame with a selection and must not allocate for it.

/// The text position under (`x`, `y`, in the table's coordinates) in the row `row`: the cell under `x` (left of the cells the first, right
/// of them the last) and where its column says the point is in its text. False with no cells.
bool textPositionAt(Cells)(auto ref Cells cells, size_t row, double x, double y, out Position at)
{
    const count = cells.length;
    if (count == 0)
        return false;
    size_t col = count - 1;
    foreach (i; 0 .. count)
        if (x < cells.right(i))
        {
            col = i;
            break;
        }
    auto info = cells.cell(col);
    at = Position(row, col, info.column.hitTest(info.input, info.area, info.view, x, y));
    return true;
}

/// The rectangles the selection `range` takes in the row `row`, as the columns of its cells place them: `emit` is called for each
void selectionRects(Cells)(auto ref Cells cells, TextRange range, size_t row, scope void delegate(Rect) emit)
{
    if (row < range.start.row || row > range.end.row)
        return;
    foreach (col; 0 .. cells.length)
    {
        auto info = cells.cell(col);
        const part = cellPart(range, row, col, info.text.length);
        if (!part.any)
            continue;
        info.column.rects(info.input, info.area, info.view, part.from, part.to, emit);
    }
}

@("textPositionAt, selectionRects: the column of a cell answers where a point is and which rectangles a part takes")
unittest
{
    final class Fixed : TableColumn
    {
        this() { super(ColumnDef("f", "F")); }

        override size_t hitTest(ref const CellInput cell, Rect area, Rect view, double x, double y) { return 42; }

        override void rects(ref const CellInput cell, Rect area, Rect view, size_t from, size_t to, scope void delegate(Rect) emit)
        {
            emit(Rect(from, to, area.y, 1));
        }
    }

    static final class Own
    {
        TableColumn column;
        static immutable CellData data = CellData("abcdef"w);
        size_t length() { return 1; }
        double right(size_t col) { return 100; }
        CellText cell(size_t col) { return CellText(CellInput(0, 0, &data), Rect(0, 20, 100, 16), Rect(0, 20, 100, 16), column); }
    }

    auto cells = new Own;
    cells.column = new Fixed;
    Position at;
    assert(textPositionAt(cells, 3, 15, 0, at) && at == Position(3, 0, 42));
    Rect[] seen;
    selectionRects(cells, TextRange(Position(3, 0, 1), Position(3, 0, 2)), 3, (Rect r) { seen ~= r; });
    assert(seen == [Rect(1, 2, 20, 1)], "the part [1, 2) as the column gets it");
}

@("textPositionAt: an empty cell is its start, no cells no position")
unittest
{
    final class Empty
    {
        size_t length() { return 1; }
        double right(size_t col) { return 50; }
        CellText cell(size_t col) { return CellText(CellInput.init, Rect(0, 0, 50, 16), Rect(0, 0, 50, 16), plainText); }
    }

    final class None
    {
        size_t length() { return 0; }
        double right(size_t col) { return 0; }
        CellText cell(size_t col) { return CellText(CellInput.init, Rect.init, Rect.init, plainText); }
    }

    Position at;
    assert(textPositionAt(new Empty, 3, 10, 0, at) && at == Position(3, 0, 0));
    assert(!textPositionAt(new None, 3, 10, 0, at));
}

