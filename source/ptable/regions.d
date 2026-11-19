//! The parts of a table's area: the header on top, the footer at the bottom, the body between them with
//! the room above and under the rows (the padding of the table). A scroll bar is not a part of it. Everything that needs a coordinate of the rows takes it from here, so a part added later
//! moves them in one place. Pure. See docs/stories/painted-table.md.
module ptable.regions;

import ptable.painter : TableGeometry;
import ptable.ports : Rect;

/// Where the parts of a table of `width` x `height` are
struct Regions
{
    Rect header; /// the titles
    Rect footer; /// empty (no height) if there is none
    Rect body; /// between the header and the footer, all of the width
    Rect rows; /// where the rows lie: the body less the padding above and under (a scroll bar is the host's, outside)
    Rect padAbove, padBelow; /// the padding of the body (no height if there is none)
    Rect marginLeft, marginRight; /// the margins left and right of the rows, as high as the body (no width if there is none)
}

/// The regions for the size and the geometry given; never negative in size
Regions regionsOf(double width, double height, ref const TableGeometry g) pure nothrow @nogc @safe
{
    import std.algorithm.comparison : max;

    Regions r;
    const w = max(0.0, width);
    r.header = Rect(0, 0, w, g.headerHeight);
    const footerHeight = max(0.0, g.footerHeight);
    r.footer = Rect(0, max(0.0, height - footerHeight), w, footerHeight);
    const bodyTop = g.headerHeight;
    const bodyHeight = max(0.0, height - g.headerHeight - footerHeight);
    r.body = Rect(0, bodyTop, w, bodyHeight);
    const above = max(0.0, min2(g.padTop, bodyHeight));
    const below = max(0.0, min2(g.padBottom, bodyHeight - above));
    r.padAbove = Rect(0, bodyTop, w, above);
    r.padBelow = Rect(0, bodyTop + bodyHeight - below, w, below);
    const left = max(0.0, min2(g.marginLeft, w));
    const right = max(0.0, min2(g.marginRight, w - left));
    r.marginLeft = Rect(0, bodyTop, left, bodyHeight);
    r.marginRight = Rect(w - right, bodyTop, right, bodyHeight);
    r.rows = Rect(left, bodyTop + above, w - left - right, bodyHeight - above - below);
    return r;
}

/// The cell of a column placed at `x`, `width` wide, in `band` (a row under its margin, or the header): the column less the line between the
/// columns right of it (`columnBorder`), the band less the line under it (`rowBorder`; 0 for the header). A cell and the lines are apart:
/// a column draws and hits its text in its cell only, the painter draws the lines in their own room (`columnLineIn`, `rowLineOf`).
Rect cellIn(double x, double width, Rect band, double columnBorder, double rowBorder) pure nothrow @nogc @safe
{
    import std.algorithm.comparison : max;

    return Rect(x, band.y, max(0.0, width - columnBorder), max(0.0, band.h - rowBorder));
}

/// The line right of the cell of `cellIn`, as high as the cell
Rect columnLineIn(double x, double width, Rect band, double columnBorder, double rowBorder) pure nothrow @nogc @safe
{
    import std.algorithm.comparison : max;

    const line = min2(max(0.0, columnBorder), max(0.0, width));
    return Rect(x + width - line, band.y, line, max(0.0, band.h - rowBorder));
}

/// The line under the row `row` (its area under its margin), across it
Rect rowLineOf(Rect row, double rowBorder) pure nothrow @nogc @safe
{
    import std.algorithm.comparison : max;

    const line = min2(max(0.0, rowBorder), max(0.0, row.h));
    return Rect(row.x, row.bottom - line, row.w, line);
}

@("cellIn, columnLineIn, rowLineOf: a cell and the lines right of it and under it share the room of the column and the row, never overlap")
unittest
{
    const row = Rect(0, 21, 400, 16);
    assert(cellIn(60, 100, row, 1, 2) == Rect(60, 21, 99, 14));
    assert(columnLineIn(60, 100, row, 1, 2) == Rect(159, 21, 1, 14));
    assert(rowLineOf(row, 2) == Rect(0, 35, 400, 2));
    assert(cellIn(60, 100, row, 0, 0) == Rect(60, 21, 100, 16) && columnLineIn(60, 100, row, 0, 0).w == 0, "no lines: the cell is all of it");
    assert(cellIn(60, 0.5, row, 1, 0).w == 0, "never negative");
}

private double min2(double a, double b) pure nothrow @nogc @safe
{
    return a < b ? a : b;
}

@("regionsOf: header on top, the rows in the body")
unittest
{
    TableGeometry g;
    const r = regionsOf(400, 121, g);
    assert(r.header == Rect(0, 0, 400, 21));
    assert(r.body == Rect(0, 21, 400, 100));
    assert(r.rows == Rect(0, 21, 400, 100));
    assert(r.footer.h == 0 && r.padAbove.h == 0 && r.padBelow.h == 0);
}

@("regionsOf: a footer and the padding take room from the rows, and the parts stay inside")
unittest
{
    TableGeometry g;
    g.footerHeight = 20;
    g.padTop = 4;
    g.padBottom = 10;
    const r = regionsOf(400, 200, g);
    assert(r.footer == Rect(0, 180, 400, 20));
    assert(r.body == Rect(0, 21, 400, 159));
    assert(r.padAbove == Rect(0, 21, 400, 4) && r.padBelow == Rect(0, 170, 400, 10));
    assert(r.rows == Rect(0, 25, 400, 145), "159 less 4 and 10");
}

@("regionsOf: a table too small for its parts has no rows and nothing negative")
unittest
{
    TableGeometry g;
    g.footerHeight = 50;
    const r = regionsOf(5, 30, g);
    assert(r.rows.h == 0 && r.body.h == 0 && r.rows.w >= 0);
}

@("regionsOf: the margins left and right narrow the rows and are regions of their own, never wider than the table")
unittest
{
    TableGeometry g;
    g.marginLeft = 10;
    g.marginRight = 6;
    const r = regionsOf(400, 121, g);
    assert(r.rows == Rect(10, 21, 384, 100), "the rows stand between the margins");
    assert(r.marginLeft == Rect(0, 21, 10, 100) && r.marginRight == Rect(394, 21, 6, 100));
    assert(r.header == Rect(0, 0, 400, 21), "the header is as wide as the table");
    g.marginLeft = 500;
    const wide = regionsOf(400, 121, g);
    assert(wide.rows.w == 0 && wide.marginLeft.w == 400 && wide.marginRight.w == 0, "the margins stay inside");
}
