//! What a table needs of its surroundings, as an interface: a canvas to draw on. The tests
//! give it fakes, the application a Sciter implementation (`sciter/graphics`). See
//! docs/stories/painted-table.md.
module ptable.ports;

/// A rectangle in dips: the left top corner and the size
struct Rect
{
    double x = 0, y = 0, w = 0, h = 0;

    double right() const pure nothrow @nogc @safe { return x + w; }
    double bottom() const pure nothrow @nogc @safe { return y + h; }

    bool contains(double px, double py) const pure nothrow @nogc @safe
    {
        return px >= x && px < x + w && py >= y && py < y + h;
    }

    /// Its sides across and down as stretches of an axis
    Span across() const pure nothrow @nogc @safe { return Span(x, x + w); }

    /// ditto
    Span down() const pure nothrow @nogc @safe { return Span(y, y + h); }
}

/// A stretch of one axis from `start` to `end` (a side of a cell, the part of the screen the rows are seen in)
struct Span
{
    double start = 0, end = 0;

    /// How long it is; 0 if it is empty
    double length() const pure nothrow @nogc @safe
    {
        return end > start ? end - start : 0;
    }

    /// The part it shares with `other`; empty (no length) if they do not meet
    Span meet(Span other) const pure nothrow @nogc @safe
    {
        import std.algorithm.comparison : max, min;

        return Span(max(start, other.start), min(end, other.end));
    }
}

@("Span: its length, never below 0, and the part two of them share; a rectangle's sides as spans")
unittest
{
    assert(Span(10, 30).length == 20 && Span(30, 10).length == 0);
    assert(Span(10, 30).meet(Span(20, 50)) == Span(20, 30));
    assert(Span(10, 30).meet(Span(0, 100)) == Span(10, 30));
    assert(Span(10, 30).meet(Span(40, 50)).length == 0, "apart: nothing shared");
    assert(Rect(10, 20, 30, 40).across == Span(10, 40) && Rect(10, 20, 30, 40).down == Span(20, 60));
}

/// A width and a height in dips
struct Size
{
    double w = 0, h = 0;
}

/// A color: red, green, blue, alpha (0..255)
struct Color
{
    ubyte r, g, b, a = 255;
}

/// A font a column names (a role such as "aux", "body", "header", and what the painter made of it);
/// the canvas and the measurer of the text columns know what it is
alias FontId = uint;

/// Where a table draws; the coordinates are the table's own (0, 0 is its left top corner)
interface Canvas
{
    void fillRect(Rect area, Color color);

    /// Text with its baseline at `y` from `x`
    void drawText(FontId font, const(wchar)[] text, double x, double baseline, Color color);

    /// A text wrapped in `width` by the host, its first line's top at `top`: for what `wrappedLines` answered
    void drawParagraph(FontId font, const(wchar)[] text, double x, double top, double width, Color color);

    /// A circle of the center (`cx`, `cy`) and `radius`, filled and outlined by a line 1 dip wide
    void fillCircle(double cx, double cy, double radius, Color fill, Color line);

    /// A filled rectangle with its corners rounded by `radius`, with no outline
    void fillRoundRect(Rect area, double radius, Color color);

    /// Draws only inside `area` until `popClip`
    void pushClip(Rect area);
    void popClip();
}
