//! What a table needs of its surroundings, as interfaces: a canvas to draw on, the
//! clipboard. The tests give it fakes, the application a Sciter implementation
//! (`sciter/graphics`). See docs/stories/painted-table.md.
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

    /// Draws only inside `area` until `popClip`
    void pushClip(Rect area);
    void popClip();
}

interface Clipboard
{
    void writeText(const(wchar)[] text);
}
