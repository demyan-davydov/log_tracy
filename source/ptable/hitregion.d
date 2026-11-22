//! Which part of the table a point is in, by the regions alone: the header, the footer, the rows, or the rest of the body (the
//! padding and the margins around the rows). Pure. See docs/stories/painted-table.md.
module ptable.hitregion;

import ptable.regions : Regions;

/// A part of the table
enum Area : ubyte
{
    header,
    footer,
    rows, /// where the rows lie (a row may still not be there: a margin of a group, below the last row)
    around, /// the body outside the rows: the margins at their sides
}

/// The part of the table the point (x, y) is in; a point above the header is in it, one below the table in the footer or around the rows
Area areaAt(ref const Regions r, double x, double y) pure nothrow @nogc @safe
{
    if (y < r.header.bottom)
        return Area.header;
    if (r.footer.h > 0 && y >= r.footer.y)
        return Area.footer;
    return r.rows.contains(x, y) ? Area.rows : Area.around;
}

@("areaAt: the header on top, the rows, what is around them, the footer")
unittest
{
    import ptable.painter : TableGeometry;
    import ptable.regions : SideMargins, regionsOf;

    TableGeometry g;
    g.footerHeight = 20;
    g.marginTop = 4;
    const r = regionsOf(400, 200, g, SideMargins(10, 0));
    assert(areaAt(r, 50, 5) == Area.header && areaAt(r, 50, -3) == Area.header);
    assert(areaAt(r, 50, 21 + 2) == Area.rows, "the margin above the rows is scrolled with them: where they lie");
    assert(areaAt(r, 5, 100) == Area.around, "the margin at the left");
    assert(areaAt(r, 50, 100) == Area.rows);
    assert(areaAt(r, 50, 190) == Area.footer);
}

@("areaAt: no footer, no margins: the rows reach the bottom, and below the table is around the rows")
unittest
{
    import ptable.painter : TableGeometry;
    import ptable.regions : regionsOf;

    TableGeometry g;
    const r = regionsOf(400, 121, g);
    assert(areaAt(r, 0, 120) == Area.rows && areaAt(r, 0, 500) == Area.around);
}
