//! The parts of a table's area: the header on top, the footer at the bottom, the body between them with
//! the margins around the rows (above and under them the table's own, left and right those of its column host). A scroll bar is not a part of it. Everything that needs a coordinate of the rows takes it from here, so a part added later
//! moves them in one place. Pure. See docs/stories/painted-table.md.
module ptable.regions;

import ptable.layout : Placement;
import ptable.painter : TableGeometry;
import ptable.ports : Rect;

/// The margins left and right of the rows: the columns, and their titles, stand between them. The column host's, the same for its tables
struct SideMargins
{
    double left = 0, right = 0;
}

/// Where the parts of a table of `width` x `height` are
struct Regions
{
    Rect header; /// the titles
    Rect footer; /// empty (no height) if there is none
    Rect body; /// between the header and the footer, all of the width
    Rect rows; /// where the rows lie: the body less the margins around them (a scroll bar is the host's, outside, along the body)
    Rect marginTop, marginBottom; /// the margins above and under the rows, all of the width (no height if there is none)
    Rect marginLeft, marginRight; /// the margins left and right of the rows, as high as the body (no width if there is none)
}

/// The regions for the size, the geometry and the margins left and right given; never negative in size: a margin takes no more than
/// the room there is, the one under (right of) the rows what the one above (left of) them left
Regions regionsOf(double width, double height, ref const TableGeometry g, SideMargins sides = SideMargins.init) pure nothrow @nogc @safe
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
    const above = max(0.0, min2(g.marginTop, bodyHeight));
    const below = max(0.0, min2(g.marginBottom, bodyHeight - above));
    r.marginTop = Rect(0, bodyTop, w, above);
    r.marginBottom = Rect(0, bodyTop + bodyHeight - below, w, below);
    const left = max(0.0, min2(sides.left, w));
    const right = max(0.0, min2(sides.right, w - left));
    r.marginLeft = Rect(0, bodyTop, left, bodyHeight);
    r.marginRight = Rect(w - right, bodyTop, right, bodyHeight);
    r.rows = Rect(left, bodyTop + above, w - left - right, bodyHeight - above - below);
    return r;
}

/// The cell of the column placed at `c` in `band` (a row under its margin, or the header): the place of the column (the lines between the
/// columns are apart, `placeColumns` puts them between), the band less the line under it (`rowBorder`; 0 for the header). A cell and the
/// lines are apart: a column draws its text in its cell only, the painter draws the lines in their own room (`columnLineOf`, `rowLineOf`).
Rect cellIn(ref const Placement c, Rect band, double rowBorder) pure nothrow @nogc @safe
{
    import std.algorithm.comparison : max;

    return Rect(c.x, band.y, c.width, max(0.0, band.h - rowBorder));
}

/// The line between the column placed at `c` and the next one on the screen, as high as its cell (no width: it has none)
Rect columnLineOf(ref const Placement c, Rect band, double rowBorder) pure nothrow @nogc @safe
{
    import std.algorithm.comparison : max;

    const h = max(0.0, band.h - rowBorder);
    if (c.lineBefore > 0)
        return Rect(c.x - c.lineBefore, band.y, c.lineBefore, h);
    return Rect(c.x + c.width, band.y, c.lineAfter, h);
}

/// The line under the row `row` (its area under its margin), across it
Rect rowLineOf(Rect row, double rowBorder) pure nothrow @nogc @safe
{
    import std.algorithm.comparison : max;

    const line = min2(max(0.0, rowBorder), max(0.0, row.h));
    return Rect(row.x, row.bottom - line, row.w, line);
}

@("cellIn, columnLineOf, rowLineOf: a cell, the line beside it and the line under its row share the room of the row, never overlap")
unittest
{
    import ptable.layout : Pin, Placement;

    const row = Rect(0, 21, 400, 16);
    const c = Placement("a", 60, 100, Pin.none, 0, 2);
    assert(cellIn(c, row, 3) == Rect(60, 21, 100, 13));
    assert(columnLineOf(c, row, 3) == Rect(160, 21, 2, 13), "right of the cell");
    assert(rowLineOf(row, 3) == Rect(0, 34, 400, 3));
    const pinned = Placement("r", 300, 50, Pin.right, 1, 0, 2);
    assert(columnLineOf(pinned, row, 0) == Rect(298, 21, 2, 16), "a right pinned column has its line left of it");
    const last = Placement("z", 0, 10);
    assert(columnLineOf(last, row, 0).w == 0, "the last column has none");
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
    assert(r.footer.h == 0 && r.marginTop.h == 0 && r.marginBottom.h == 0);
}

@("regionsOf: a footer and the margins above and under the rows take room from the rows, and the parts stay inside")
unittest
{
    TableGeometry g;
    g.footerHeight = 20;
    g.marginTop = 4;
    g.marginBottom = 10;
    const r = regionsOf(400, 200, g);
    assert(r.footer == Rect(0, 180, 400, 20));
    assert(r.body == Rect(0, 21, 400, 159));
    assert(r.marginTop == Rect(0, 21, 400, 4) && r.marginBottom == Rect(0, 170, 400, 10));
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
    const r = regionsOf(400, 121, g, SideMargins(10, 6));
    assert(r.rows == Rect(10, 21, 384, 100), "the rows stand between the margins");
    assert(r.marginLeft == Rect(0, 21, 10, 100) && r.marginRight == Rect(394, 21, 6, 100));
    assert(r.header == Rect(0, 0, 400, 21), "the header is as wide as the table");
    const wide = regionsOf(400, 121, g, SideMargins(500, 6));
    assert(wide.rows.w == 0 && wide.marginLeft.w == 400 && wide.marginRight.w == 0, "the margins stay inside");
}

@("regionsOf: the margins above and under the rows take no more than the body, the rows are left with no height and nothing is negative")
unittest
{
    TableGeometry g;
    g.marginTop = 500;
    g.marginBottom = 10;
    const tall = regionsOf(400, 121, g);
    assert(tall.marginTop == Rect(0, 21, 400, 100) && tall.marginBottom.h == 0 && tall.rows.h == 0 && tall.rows.y == 121);
    g.marginTop = 60;
    g.marginBottom = 60;
    const both = regionsOf(400, 121, g);
    assert(both.marginTop.h == 60 && both.marginBottom == Rect(0, 81, 400, 40) && both.rows.h == 0, "the bottom one takes what the top one left");
}
