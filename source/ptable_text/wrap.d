//! Wrapping a text into lines by the advances of its glyphs, and the widths a text column asks of its measurer. Pure: no Sciter; the advance of
//! a glyph comes in as a delegate. The lines are the business of a text column (the table keeps none).
module ptable_text.wrap;

import ptable.ports : FontId;
import ptable_text.measurer : TextMeasurer;
import std.utf : decode;

/// A line of a wrapped text: [start, end) in UTF-16 units
struct LineSpan
{
    size_t start, end;
}

/// The lines of `text` in a width of `width` px; `advance(glyph)` is the width of a code
/// point. A line breaks after a space (the space may stick out of the width); a word longer
/// than a line breaks at the width; a hard "\n" breaks too, but one at the very end of the text ends its line and starts no empty one. A line has a glyph at least, so
/// a width smaller than a glyph still moves on. An empty text is one empty line.
/// `lines` is filled (its old content is dropped).
void wrapLines(ref LineSpan[] lines, const(wchar)[] text, double width, scope double delegate(dchar) nothrow advance)
{
    lines.length = 0;
    assumeSafeAppend(lines);
    size_t start = 0, position = 0, breakAt = size_t.max;
    double lineWidth = 0, breakWidth = 0;
    while (position < text.length)
    {
        const glyphStart = position;
        const glyph = decode(text, position); // moves `position` past the glyph
        if (glyph == '\n')
        {
            lines ~= LineSpan(start, glyphStart);
            start = position;
            lineWidth = 0;
            breakAt = size_t.max;
            continue;
        }
        const step = advance(glyph);
        if (glyph != ' ' && glyphStart > start && lineWidth + step > width)
        {
            if (breakAt != size_t.max && breakAt > start) // after the last space of the line
            {
                lines ~= LineSpan(start, breakAt);
                start = breakAt;
                lineWidth -= breakWidth;
            }
            else // no space: the word is cut
            {
                lines ~= LineSpan(start, glyphStart);
                start = glyphStart;
                lineWidth = 0;
            }
            breakAt = size_t.max;
            // what stayed over may still not leave room for the glyph (a very long word)
            if (glyphStart > start && lineWidth + step > width)
            {
                lines ~= LineSpan(start, glyphStart);
                start = glyphStart;
                lineWidth = 0;
            }
        }
        lineWidth += step;
        if (glyph == ' ')
        {
            breakAt = position;
            breakWidth = lineWidth;
        }
    }
    if (start < text.length || lines.length == 0 || text[$ - 1] != '\n') // a break at the very end starts no empty line
        lines ~= LineSpan(start, text.length);
}

/// The width of one glyph in `font` by `measurer` (a code point beyond the BMP is two units; a tab is a space); 6 if the measurer fails
double glyphWidth(TextMeasurer measurer, FontId font, dchar glyph) nothrow
{
    if (glyph == '\t')
        glyph = ' '; // a tab is drawn as a space (ptable_text/runs)
    wchar[2] units;
    size_t length = 0;
    if (glyph < 0x10000)
        units[length++] = cast(wchar) glyph;
    else
    {
        const v = glyph - 0x10000;
        units[length++] = cast(wchar)(0xD800 + (v >> 10));
        units[length++] = cast(wchar)(0xDC00 + (v & 0x3FF));
    }
    try
        return measurer.width(font, units[0 .. length]);
    catch (Exception)
        return 6;
}

/// How many characters of a line its width is measured by: the rest is estimated
enum size_t maxMeasuredChars = 2000;

/// The width of the first line of `text` (up to a hard break) by `width` (of a piece of text): a very long line is measured by its first
/// `maxMeasuredChars` characters and the rest is estimated by them (the host keeps what it measures)
double firstLineWidth(const(wchar)[] text, scope double delegate(const(wchar)[]) width)
{
    size_t end = 0;
    while (end < text.length && text[end] != '\n')
        ++end;
    const measured = end < maxMeasuredChars ? end : maxMeasuredChars;
    const part = width(text[0 .. measured]);
    return measured < end ? part * end / measured : part;
}

version (unittest)
{
    private auto tenPerGlyph = delegate double(dchar) nothrow => 10.0;

    private string[] cut(const(wchar)[] text, const LineSpan[] lines)
    {
        import std.conv : to;

        string[] result;
        foreach (l; lines)
            result ~= text[l.start .. l.end].to!string;
        return result;
    }

    private string[] wrapped(const(wchar)[] text, double width)
    {
        LineSpan[] lines;
        wrapLines(lines, text, width, tenPerGlyph);
        return cut(text, lines);
    }
}

@("wrapLines: a text that fits is one line, an empty one is one empty line")
unittest
{
    assert(wrapped("hello", 100) == ["hello"]);
    assert(wrapped("", 100) == [""]);
}

@("wrapLines: a line breaks after a space when the word does not fit")
unittest
{
    assert(wrapped("aaa bbb ccc", 70) == ["aaa bbb ", "ccc"]);
    assert(wrapped("aaa bbb ccc", 40) == ["aaa ", "bbb ", "ccc"]);
}

@("wrapLines: the space ending a line may stick out of the width")
unittest
{
    assert(wrapped("aaaa bb", 40) == ["aaaa ", "bb"]);
}

@("wrapLines: a word longer than the line breaks at the width")
unittest
{
    assert(wrapped("abcdefghij", 40) == ["abcd", "efgh", "ij"]);
    assert(wrapped("xabcdefghij", 40) == ["xabc", "defg", "hij"]);
    assert(wrapped("ab cdefghijkl", 50) == ["ab ", "cdefg", "hijkl"]);
}

@("wrapLines: a hard line break is kept")
unittest
{
    assert(wrapped("ab\ncd", 100) == ["ab", "cd"]);
    assert(wrapped("ab\n", 100) == ["ab"], "a line break at the very end ends the line, it starts no empty one (as in a browser)");
    assert(wrapped("ab\n\n", 100) == ["ab", ""], "only the last one: another is an empty line");
    assert(wrapped("\n", 100) == [""] && wrapped("a\n\nb", 100) == ["a", "", "b"], "in the middle every break is a line");
}

@("wrapLines: a width smaller than a glyph still takes a glyph a line")
unittest
{
    assert(wrapped("abc", 3) == ["a", "b", "c"]);
}

@("wrapLines: a surrogate pair is one glyph")
unittest
{
    LineSpan[] lines;
    const text = "a😀b"w; // 😀 is two units
    wrapLines(lines, text, 20, tenPerGlyph);
    assert(cut(text, lines) == ["a😀", "b"], "the pair is not cut");
}

@("firstLineWidth: the line up to a hard break, a very long one estimated by its first part")
unittest
{
    size_t longest;
    double width(const(wchar)[] text) { longest = text.length > longest ? text.length : longest; return text.length * 10.0; }
    assert(firstLineWidth("abc\ndefgh"w, &width) == 30);
    auto many = new wchar[maxMeasuredChars * 3];
    many[] = 'x';
    assert(firstLineWidth(many, &width) == maxMeasuredChars * 3 * 10.0 && longest == maxMeasuredChars, "measured by the part, the rest estimated");
}

@("glyphWidth: a tab is as wide as a space, as a line draws it (ptable_text/runs)")
unittest
{
    import ptable_text.measurer : FontMetrics;

    static final class Tabs : TextMeasurer
    {
        FontMetrics metrics(FontId font) { return FontMetrics(11, 3, 14); }
        double width(FontId font, const(wchar)[] text) { return text == "\t"w ? 80 : text.length * 10.0; }
        int wrappedLines(FontId font, const(wchar)[] text, double width) { return -1; }
    }

    assert(glyphWidth(new Tabs, 0, '\t') == 10);
}
