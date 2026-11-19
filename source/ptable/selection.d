//! The text selected across the cells and rows of a painted log table (prototype of
//! docs/experiments/2026-11-19-painted-rows-d.md): the D port of resources/text-selection.js. Pure,
//! no Sciter.
//!
//! A selection is an anchor (where the drag began) and a focus (where the mouse is now). A
//! position is the row of the view, the cell of the row (as the cells stand on the screen) and a
//! place between two characters of the text of that cell (`Position.at`, a caret); the text between
//! the two ends is selected, `[start, end)`.
module ptable.selection;

version (unittest) import ptable.testing : plainText, tabbed, tabbedUpTo;
import ptable.column : TableColumn;

import std.algorithm.comparison : max, min;

public import ptable.column : Position;

/// Where a drag began and where it is
struct Selection
{
    Position anchor, focus;
}

/// The selection in the order of the text
struct TextRange
{
    Position start, end;
}

TextRange textRange(const Selection selection) pure nothrow @nogc @safe
{
    return selection.anchor <= selection.focus ? TextRange(selection.anchor, selection.focus)
        : TextRange(selection.focus, selection.anchor);
}

private bool cellInRange(const TextRange range, size_t row, size_t col) pure nothrow @nogc @safe
{
    const cell = Position(row, col, 0);
    return cell >= Position(range.start.row, range.start.col, 0) && cell <= Position(range.end.row, range.end.col, 0);
}

/// The selected part of the cell `col` of the row `row` whose text has `length` units: [from, to)
struct Part
{
    bool any;
    size_t from, to;
}

Part cellPart(const TextRange range, size_t row, size_t col, size_t length) pure nothrow @nogc @safe
{
    if (length == 0 || !cellInRange(range, row, col))
        return Part.init;
    const from = row == range.start.row && col == range.start.col ? min(range.start.at, length) : 0;
    const to = row == range.end.row && col == range.end.col ? min(range.end.at, length) : length;
    return to > from ? Part(true, from, to) : Part.init;
}

/// How a copy joins its texts: what stands between two cells of a row and between two rows, and the most characters it takes
/// (whole rows of it; a single row over it is cut). The host's: the table knows no tab or new line
struct CopyFormat
{
    wstring cells;
    wstring rows;
    size_t limit;
}

/// A cell's text for a copy: all of it, and where its body (what the cell shows) begins after its head
struct CopyCell
{
    wstring full;
    size_t bodyStart;
    const(TableColumn) column; /// the column the cell is of, if it is an object: it cuts the text for the clipboard (the bridge)

    wstring body() const pure nothrow @nogc @safe { return full[bodyStart .. $]; }
}

/// The selected text for the clipboard: the cells of a row and the rows joined as `format` says, at most its `limit` characters of
/// whole rows. `cellTextsOf(row)` gives the texts of a row's cells, null
/// if the row can't be read (it is left out); `rowCount` is the rows of the view. The offsets of `range` are in the
/// bodies of the cells; a cell whose body is selected whole gives its full text (its head too) if `wholeCellsInFull`.
wstring rangeText(const TextRange range, scope const(CopyCell)[] delegate(size_t) cellTextsOf, in CopyFormat format,
    size_t rowCount, bool wholeCellsInFull)
{
    import std.array : appender;

    auto result = appender!wstring;
    if (rowCount == 0)
        return "";
    const last = min(range.end.row, rowCount - 1);
    bool first = true;
    foreach (row; range.start.row .. last + 1)
    {
        const cells = cellTextsOf(row);
        if (cells is null)
            continue;
        wstring line;
        bool firstCell = true;
        foreach (col, ref cell; cells)
        {
            if (!cellInRange(range, row, col))
                continue;
            const body = cell.body;
            const part = cellPart(range, row, col, body.length);
            if (!firstCell)
                line ~= format.cells;
            firstCell = false;
            if (part.any)
                line ~= cell.column.copyPart(cell.full, cell.bodyStart, part.from, part.to, wholeCellsInFull);
        }
        if (result[].length + (first ? 0 : format.rows.length) + line.length > format.limit)
            break;
        if (!first)
            result ~= format.rows;
        first = false;
        result ~= line;
    }
    return result[];
}

/// How far in dips the mouse moves from a press before it is a drag selecting text
enum double dragThreshold = 3;

bool isDrag(double pressX, double pressY, double x, double y) pure nothrow @nogc @safe
{
    import std.math : hypot;

    return hypot(x - pressX, y - pressY) >= dragThreshold;
}

@("textRange: in the order of the text whichever end was first")
unittest
{
    const a = Position(2, 3, 4), b = Position(2, 5, 0);
    assert(textRange(Selection(a, b)) == TextRange(a, b));
    assert(textRange(Selection(b, a)) == TextRange(a, b));
}

@("cellPart: the text between the two carets, the cells between are whole, others are out")
unittest
{
    const range = TextRange(Position(1, 2, 3), Position(3, 1, 2));
    assert(cellPart(range, 1, 2, 10) == Part(true, 3, 10), "the first cell from its caret");
    assert(cellPart(range, 1, 5, 10) == Part(true, 0, 10), "a later cell of the first row");
    assert(cellPart(range, 2, 0, 4) == Part(true, 0, 4), "a row between");
    assert(cellPart(range, 3, 1, 10) == Part(true, 0, 2), "the end cell up to its caret");
    assert(!cellPart(range, 3, 2, 10).any, "after the end");
    assert(!cellPart(range, 1, 1, 10).any, "before the start");
    assert(!cellPart(range, 2, 0, 0).any, "an empty cell");
}

@("cellPart: the ends of a cell are its limits; two carets at one place select nothing")
unittest
{
    const range = TextRange(Position(0, 1, Position.begin), Position(0, 1, Position.end));
    assert(cellPart(range, 0, 1, 5) == Part(true, 0, 5));
    assert(!cellPart(TextRange(Position(0, 1, 2), Position(0, 1, 2)), 0, 1, 5).any);
}

version (unittest)
{
    // The cells of rows of plain texts
    private const(CopyCell)[][] plainCells(const wstring[][] rows)
    {
        const(CopyCell)[][] cells;
        foreach (row; rows)
        {
            const(CopyCell)[] line;
            foreach (text; row)
                line ~= CopyCell(text, 0, plainText);
            cells ~= line;
        }
        return cells;
    }
}

@("rangeText: cells by tabs, rows by new lines, an empty cell keeps its tab")
unittest
{
    const rows = plainCells([["0"w, "aaa", "bbb"], ["1"w, "", "ddd"], ["2"w, "eee", "fff"]]);
    const range = TextRange(Position(0, 1, 1), Position(2, 1, 2));
    const text = rangeText(range, (size_t r) => rows[r], tabbed, rows.length, true);
    assert(text == "aa\tbbb\n1\t\tddd\n2\tee"w, "whole rows between the ends, the cells of the end row up to its end");
}

@("rangeText: the limit stops at whole rows, an unreadable row is left out, the end may outlast the view")
unittest
{
    const rows = plainCells([["aaaa"w], ["bbbb"w], ["cccc"w]]);
    const range = TextRange(Position(0, 0, 0), Position(10, 0, Position.end));
    assert(rangeText(range, (size_t r) => rows[r], tabbed, 3, false) == "aaaa\nbbbb\ncccc");
    assert(rangeText(range, (size_t r) => rows[r], tabbedUpTo(8), 3, false) == "aaaa", "only whole rows within the limit");
    assert(rangeText(range, (size_t r) => r == 1 ? null : rows[r], tabbed, 3, false) == "aaaa\ncccc");
}

@("isDrag")
unittest
{
    assert(!isDrag(10, 10, 11, 11));
    assert(isDrag(10, 10, 13, 10));
}

@("rangeText: offsets are in the body of a cell; a whole body gives the full text when asked, a part of it never")
unittest
{
    const cells = [CopyCell("2026/11/18 12:34:56"w, 11, plainText), CopyCell("row"w, 0, plainText)];
    const(CopyCell)[] of(size_t row) { return cells; }

    const whole = textRange(Selection(Position(0, 0, 0), Position(0, 0, 8)));
    assert(rangeText(whole, &of, tabbed, 1, false) == "12:34:56", "as shown");
    assert(rangeText(whole, &of, tabbed, 1, true) == "2026/11/18 12:34:56", "in full");
    const part = textRange(Selection(Position(0, 0, 3), Position(0, 0, 5)));
    assert(rangeText(part, &of, tabbed, 1, true) == "34", "a part is as shown");
    const both = textRange(Selection(Position(0, 0, 0), Position(0, 1, 3)));
    assert(rangeText(both, &of, tabbed, 1, true) == "2026/11/18 12:34:56\trow");
}

@("rangeText: a cell whose column is an object has its text cut by the column")
unittest
{
    import ptable.layout : ColumnDef;

    final class Brackets : TableColumn
    {
        this() { super(ColumnDef("b", "B")); }

        override wstring copyPart(wstring full, size_t bodyStart, size_t from, size_t to, bool inFull) const
        {
            return "["w ~ full[bodyStart + from .. bodyStart + to] ~ "]"w;
        }
    }

    auto column = new Brackets;
    const cells = [CopyCell("abcdef"w, 0, plainText), CopyCell("xyz"w, 0, column)];
    const range = TextRange(Position(0, 0, 1), Position(0, 1, 2));
    assert(rangeText(range, (size_t row) => cells, tabbed, 1, false) == "bcdef\t[xy]"w, "the cell of the column is its own, the other is cut by the table");
}

