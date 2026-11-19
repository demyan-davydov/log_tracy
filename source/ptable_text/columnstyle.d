//! How the cells of a column look, as data: one type of style (`CellStyle`), every field of which may be unset, and the
//! style of a column (`ColumnStyle`) is three of them (its cells, its group heads, its title) with what is the column's
//! own. A text column holds it and draws and measures by it; the table never reads it (nothing here knows a log or a host). Colors
//! are ids the column resolves by its look. The rows (stripes, the selected one) are the painter's own, drawn apart from the styles
//! of the columns. See docs/stories/painted-table.md.
module ptable_text.columnstyle;

import ptable.ports : FontId;

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
