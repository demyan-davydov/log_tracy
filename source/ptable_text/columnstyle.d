//! How the cells of a column look, as data: one type of style (`CellStyle`), every field of which may be unset, and the
//! style of a column (`ColumnStyle`) is three of them (its cells, its group heads, its title) with what is the column's
//! own. A text column holds it and draws and measures by it; the table never reads it (nothing here knows a log or a host). Colors
//! are ids the column resolves by its look. The rows (stripes, the selected one) are the painter's own, drawn apart from the styles
//! of the columns. See docs/stories/painted-table.md.
module ptable_text.columnstyle;

import ptable.ports : FontId, Span;

/// A color the painter knows by this number (the theme's palette slot); `noColor` is no choice: the painter's own
alias ColorId = uint;

/// No color chosen
enum ColorId noColor = 0;

/// No font chosen: the table's (the body font for a cell, the header font for a title and a group head)
enum FontId noFont = FontId.max;

/// Where the text of a cell stands in a row that is taller than the text
enum Valign : ubyte
{
    inherit, /// not chosen: the middle
    top,
    middle,
    bottom,
}

/// Where a text stands between the sides of its cell
enum Halign : ubyte
{
    inherit, /// not chosen: the left
    left,
    center,
    right,
}

/// How a cell, a group head or a title looks. Every field may be left unset: the table's own is used then (the body or the
/// header font, the painter's colors, the middle, the left, the geometry's paddings)
struct CellStyle
{
    FontId font = noFont;
    ColorId ink = noColor; /// of the text
    ColorId back = noColor; /// of the background of the cell
    /// Where the text of the cell stands between its sides (the wrapped text of the flex column starts at the left) and in a
    /// row taller than it
    Halign halign = Halign.inherit;
    Valign valign = Valign.inherit;
    /// The text of a cell cut by the edge of the rows stays aligned in the part of the cell that is seen (`alignedXInView`,
    /// `alignedTopInView`), across and down each on its own; off: it stands where it stands in the whole cell. Only the cells read them
    bool keepInViewX, keepInViewY;
    /// The room left and right of the text; less than 0: the column's own (3 for a text column)
    double padLeft = -1, padRight = -1;
    /// The room above and under the text; less than 0: the column's own (a line of a cell has 1 above and under it)
    double padTop = -1, padBottom = -1;

    /// The room above the text, `fallback` if the style leaves it to the column
    double top(double fallback) const pure nothrow @nogc @safe
    {
        return padTop >= 0 ? padTop : fallback;
    }

    /// The room under the text, `fallback` if the style leaves it to the column
    double bottom(double fallback) const pure nothrow @nogc @safe
    {
        return padBottom >= 0 ? padBottom : fallback;
    }

    /// The room left of the text, `fallback` if the style leaves it to the geometry
    double left(double fallback) const pure nothrow @nogc @safe
    {
        return padLeft >= 0 ? padLeft : fallback;
    }

    /// The room right of the text, `fallback` if the style leaves it to the geometry
    double right(double fallback) const pure nothrow @nogc @safe
    {
        return padRight >= 0 ? padRight : fallback;
    }

    /// The width left for the text of a cell of `width`
    double inner(double width, double fallback) const pure nothrow @nogc @safe
    {
        return width - left(fallback) - right(fallback);
    }
}

/// The style of a column: how its cells, its group heads (the plates over the rows of a group) and its title look, and what
/// is the column's own and no layer of rows may change
struct ColumnStyle
{
    CellStyle cell, group, header;
    /// The least height of a row it is in; 0: none (the least width is the layout's, `ColumnDef.minWidth`)
    double minHeight = 0;
    /// The text breaks into lines in the width of the column. Only the flex column wraps (the other cells are one line):
    /// for another column it is ignored
    bool wrap = true;
}

/// Where the text of the width `textWidth` starts in a cell of `width` from `x` (whole pixels), by `halign` and the paddings
double alignedX(Halign halign, double x, double width, double textWidth, double padLeft, double padRight) pure nothrow @nogc @safe
{
    import std.math : round;

    final switch (halign)
    {
    case Halign.inherit:
    case Halign.left:
        return x + padLeft;
    case Halign.center:
        return round(x + (width - textWidth) / 2);
    case Halign.right:
        return round(x + width - padRight - textWidth);
    }
}

/// How far down from the top of the room `inner` a text of the height `content` starts; never above it, whole pixels
double alignOffset(Valign valign, double inner, double content) pure nothrow @nogc @safe
{
    import std.math : round;

    const room = inner - content;
    if (room <= 0)
        return 0;
    final switch (valign)
    {
    case Valign.top:
        return 0;
    case Valign.inherit:
    case Valign.middle:
        return round(room / 2);
    case Valign.bottom:
        return room;
    }
}

/// Where the text of `alignedX` starts when it is kept in the part `view` of the cell that is seen: aligned the same way in that part, never
/// out of the room the alignment has in the whole cell (between its paddings, the whole cell for the middle) nor further than where it stands
/// in the whole cell. A cell seen whole has its text where `alignedX` puts it; a text no narrower than the room between the paddings does
/// not move
double alignedXInView(Halign halign, double x, double width, double textWidth, double padLeft, double padRight, Span view) pure nothrow @nogc @safe
{
    const whole = alignedX(halign, x, width, textWidth, padLeft, padRight);
    const seen = Span(x, x + width).meet(view);
    if (seen.length <= 0)
        return whole;
    const inSeen = alignedX(halign, seen.start, seen.length, textWidth, padLeft, padRight);
    return keptIn(whole, inSeen, Span(x + padLeft, x + width - padRight), textWidth);
}

/// Where the top of a content `content` high starts in a cell from `y`, `height` high, with the room `above` and `under` it, kept in the part
/// `view` of the cell that is seen: as `alignOffset` puts it in that part, never out of the room between the paddings nor further than where
/// it stands in the whole cell. A cell seen whole has its content where `alignOffset` puts it; a content no lower than that room does not move
double alignedTopInView(Valign valign, double y, double height, double content, double above, double under, Span view) pure nothrow @nogc @safe
{
    const whole = y + above + alignOffset(valign, height - above - under, content);
    const seen = Span(y, y + height).meet(view);
    if (seen.length <= 0)
        return whole;
    const inSeen = seen.start + above + alignOffset(valign, seen.length - above - under, content);
    return keptIn(whole, inSeen, Span(y + above, y + height - under), content);
}

// `wanted` (where a content `size` long would stand in the part seen) moved into the room `room`, which is widened to hold `whole` (where it
// stands in the whole cell: the middle of a cell is not between its paddings when they differ); `whole` if the content does not fit the room
private double keptIn(double whole, double wanted, Span room, double size) pure nothrow @nogc @safe
{
    import std.algorithm.comparison : clamp, max, min;

    if (size >= room.length)
        return whole;
    return clamp(wanted, min(whole, room.start), max(whole, room.end - size));
}

@("alignedXInView: a cell seen whole keeps the place of alignedX, a cut one aligns in the part seen, between its paddings")
unittest
{
    // a cell from 100, 60 wide, a text 20 wide, 3 left and right of it
    enum all = Span(0, 1000);
    foreach (h; [Halign.left, Halign.center, Halign.right, Halign.inherit])
        assert(alignedXInView(h, 100, 60, 20, 3, 3, all) == alignedX(h, 100, 60, 20, 3, 3), "seen whole: where it is");
    // cut on the left: 130..160 is seen
    assert(alignedXInView(Halign.center, 100, 60, 20, 3, 3, Span(130, 1000)) == 135);
    assert(alignedXInView(Halign.left, 100, 60, 20, 3, 3, Span(130, 1000)) == 133, "at the left of the part seen, after the padding");
    assert(alignedXInView(Halign.right, 100, 60, 20, 3, 3, Span(130, 1000)) == 137, "the right side is seen: no move");
    // cut on the right: 100..130 is seen
    assert(alignedXInView(Halign.center, 100, 60, 20, 3, 3, Span(0, 130)) == 105);
    assert(alignedXInView(Halign.left, 100, 60, 20, 3, 3, Span(0, 130)) == 103);
    assert(alignedXInView(Halign.right, 100, 60, 20, 3, 3, Span(0, 130)) == 107);
    // a strip narrower than the text: it stops at the padding of the far side
    foreach (h; [Halign.left, Halign.center, Halign.right])
        assert(alignedXInView(h, 100, 60, 20, 3, 3, Span(150, 1000)) == 137);
    assert(alignedXInView(Halign.left, 100, 60, 20, 3, 3, Span(0, 110)) == 103, "a strip on the left: at its own padding");
    // a text as wide as the room between the paddings, a cell not seen at all
    assert(alignedXInView(Halign.center, 100, 60, 54, 3, 3, Span(130, 1000)) == alignedX(Halign.center, 100, 60, 54, 3, 3));
    assert(alignedXInView(Halign.center, 100, 60, 20, 3, 3, Span(200, 300)) == 120, "not seen: where it is");
}

@("alignedTopInView: a cell seen whole keeps the place of alignOffset, a cut one aligns in the part seen, between its paddings")
unittest
{
    // a cell from 100, 60 high, a content 14 high, 1 above and under it: the room is 101..159
    enum all = Span(0, 1000);
    foreach (v; [Valign.top, Valign.middle, Valign.bottom, Valign.inherit])
        assert(alignedTopInView(v, 100, 60, 14, 1, 1, all) == 101 + alignOffset(v, 58, 14), "seen whole: where it is");
    // cut above: 130..160 is seen
    assert(alignedTopInView(Valign.middle, 100, 60, 14, 1, 1, Span(130, 1000)) == 138);
    assert(alignedTopInView(Valign.top, 100, 60, 14, 1, 1, Span(130, 1000)) == 131, "at the top of the part seen, under the padding");
    assert(alignedTopInView(Valign.bottom, 100, 60, 14, 1, 1, Span(130, 1000)) == 145, "the bottom is seen: no move");
    // cut under: 100..130 is seen
    assert(alignedTopInView(Valign.middle, 100, 60, 14, 1, 1, Span(0, 130)) == 108);
    assert(alignedTopInView(Valign.top, 100, 60, 14, 1, 1, Span(0, 130)) == 101);
    assert(alignedTopInView(Valign.bottom, 100, 60, 14, 1, 1, Span(0, 130)) == 115);
    // a strip lower than the content: it stops at the padding of the far side
    foreach (v; [Valign.top, Valign.middle, Valign.bottom])
        assert(alignedTopInView(v, 100, 60, 14, 1, 1, Span(150, 1000)) == 145);
    // a content as high as the room, a cell not seen at all
    assert(alignedTopInView(Valign.middle, 100, 60, 58, 1, 1, Span(130, 1000)) == 101);
    assert(alignedTopInView(Valign.middle, 100, 60, 14, 1, 1, Span(200, 300)) == 123, "not seen: where it is");
}

@("alignOffset: top, middle and bottom in a room taller than the text, none when it does not fit")
unittest
{
    assert(alignOffset(Valign.top, 44, 14) == 0);
    assert(alignOffset(Valign.middle, 44, 14) == 15);
    assert(alignOffset(Valign.bottom, 44, 14) == 30);
    assert(alignOffset(Valign.inherit, 44, 14) == 15, "not chosen: the middle");
    assert(alignOffset(Valign.middle, 14, 14) == 0 && alignOffset(Valign.bottom, 14, 14) == 0);
    assert(alignOffset(Valign.middle, 10, 14) == 0, "a text taller than the room stays at the top");
    assert(alignOffset(Valign.middle, 45, 14) == 16, "half a pixel goes to whole ones");
}

@("CellStyle: a padding it leaves unset is the geometry's, an alignment unset is the left")
unittest
{
    CellStyle style;
    assert(style.left(3) == 3 && style.right(3) == 3 && style.halign == Halign.inherit && style.valign == Valign.inherit);
    style.padLeft = 5;
    style.padRight = 0;
    assert(style.left(3) == 5 && style.right(3) == 0, "0 is a padding, not an unset one");
    assert(style.inner(100, 3) == 95);
    assert(style.top(1) == 1 && style.bottom(1) == 1, "the room above and under is the column's unless the style sets it");
    style.padTop = 4;
    assert(style.top(1) == 4);
    assert(ColumnStyle.init.wrap && ColumnStyle.init.minHeight == 0 && ColumnStyle.init.cell == CellStyle.init);
}

@("alignedX: left by the padding, right by the padding, the middle of the whole cell, unset is the left")
unittest
{
    assert(alignedX(Halign.left, 100, 60, 20, 3, 3) == 103);
    assert(alignedX(Halign.inherit, 100, 60, 20, 3, 3) == 103);
    assert(alignedX(Halign.right, 100, 60, 20, 3, 3) == 137);
    assert(alignedX(Halign.center, 100, 60, 21, 3, 3) == 120, "(60 - 21) / 2 = 19.5 rounds to 20");
}
