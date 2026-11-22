//! Wrapping a text into lines by the widths its runs are drawn with (ptable_text/runs), and the widths a text column asks of its measurer.
//! Pure: no Sciter; the width of a piece of text and the advance of a glyph come in as delegates. The lines are the business of a text column (the table keeps none).
module ptable_text.wrap;

import ptable.ports : FontId;
import ptable_text.measurer : TextMeasurer;
import ptable_text.runs : PieceWidth, lineWidth, shownGlyph;
import std.typecons : Yes;
import std.utf : decode;

/// A line of a wrapped text: [start, end) in UTF-16 units
struct LineSpan
{
    size_t start, end;
}

/// The lines of `text` in a width of `width` px, as a line of it is drawn (ptable_text/runs): a word is as wide as `piece` says of its runs,
/// a gap of spaces or tabs too. A line breaks after a gap (the gap may stick out of the width); a word longer than a line is cut where its
/// part, as drawn, still fits (found by `advance`, the width of a code point, and checked by `piece`); a hard "\n" breaks too, but one at
/// the very end of the text ends its line and starts no empty one. A line has a glyph at least, so a width smaller than a glyph still moves
/// on. An empty text is one empty line. `lines` is filled (its old content is dropped).
void wrapLines(ref LineSpan[] lines, const(wchar)[] text, double width, scope PieceWidth piece, scope double delegate(dchar) nothrow advance)
{
    lines.length = 0;
    assumeSafeAppend(lines);
    size_t start = 0;
    while (true)
    {
        size_t end = start;
        while (end < text.length && text[end] != '\n')
            ++end;
        wrapLine(lines, text, start, end, width, piece, advance);
        if (end >= text.length || end + 1 == text.length) // a break at the very end starts no empty line
            return;
        start = end + 1;
    }
}

// The lines of `text[start .. end]`, a line with no hard break, appended to `lines`
private void wrapLine(ref LineSpan[] lines, const(wchar)[] text, size_t start, size_t end, double width, scope PieceWidth piece,
    scope double delegate(dchar) nothrow advance)
{
    size_t i = start;
    double x = 0;
    while (i < end)
    {
        if (isGap(text[i]))
        {
            size_t j = i;
            while (j < end && isGap(text[j]))
                ++j;
            x += lineWidth(text[i .. j], piece); // by its runs, as drawn
            i = j;
            continue;
        }
        // The word by the advances of its glyphs, only as far as the line goes: a word of many lines is walked neither to its end nor whole
        // on each of them. Drawn it is no narrower (its runs are rounded up), so only a word that ends within the line by them is measured
        size_t reach = i;
        double estimate = 0;
        while (reach < end && !isGap(text[reach]))
        {
            size_t next = reach;
            const step = advance(decode!(Yes.useReplacementDchar)(text, next));
            if (x + estimate + step > width)
                break;
            estimate += step;
            reach = next;
        }
        if (wordEnds(text, reach, end))
        {
            const w = lineWidth(text[i .. reach], piece);
            if (x + w <= width)
            {
                x += w;
                i = reach;
                continue;
            }
        }
        if (i > start) // the word goes to the next line
        {
            lines ~= LineSpan(start, i);
            start = i;
            x = 0;
            continue;
        }
        // a word longer than the line: cut where the glyphs reach the width (a glyph at least), then back while its part as drawn does not fit
        size_t first = i;
        decode!(Yes.useReplacementDchar)(text, first);
        size_t cut = reach > first ? reach : first;
        while (cut > first && lineWidth(text[i .. cut], piece) > width)
            cut -= cut - 2 >= i && isLow(text[cut - 1]) && isHigh(text[cut - 2]) ? 2 : 1;
        if (wordEnds(text, cut, end)) // a glyph wider than the line: it stays on its line with what follows it
        {
            x = lineWidth(text[i .. cut], piece);
            i = cut;
            continue;
        }
        lines ~= LineSpan(start, cut);
        start = i = cut;
        x = 0;
    }
    lines ~= LineSpan(start, end);
}

// Whether a word ends at `at` of a line that ends at `end`
private bool wordEnds(const(wchar)[] text, size_t at, size_t end) pure nothrow @nogc @safe
{
    return at == end || isGap(text[at]);
}

private bool isGap(wchar c) pure nothrow @nogc @safe
{
    return c == ' ' || c == '\t';
}

private bool isHigh(wchar c) pure nothrow @nogc @safe
{
    return c >= 0xD800 && c < 0xDC00;
}

private bool isLow(wchar c) pure nothrow @nogc @safe
{
    return c >= 0xDC00 && c < 0xE000;
}

/// How many copies of a glyph its width is read off: a host may round the width of a text up to a whole dip (Sciter does), and the rounding
/// of one glyph, summed over a line, would wrap it early
enum size_t glyphRun = 32;

/// The width of one glyph in `font` by `measurer`, read off a run of `glyphRun` of it (a code point beyond the BMP is two units; a tab is a
/// space); 6 if the measurer fails
double glyphWidth(TextMeasurer measurer, FontId font, dchar glyph) nothrow
{
    glyph = shownGlyph(glyph); // a tab as a space
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
    wchar[2 * glyphRun] run;
    foreach (i; 0 .. glyphRun)
        run[i * length .. (i + 1) * length] = units[0 .. length];
    try
        return measurer.width(font, run[0 .. glyphRun * length]) / glyphRun;
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
    import std.utf : count;

    private auto tenPerGlyph = delegate double(dchar) nothrow => 10.0;
    private auto tenPerGlyphPiece = delegate double(const(wchar)[] piece) => 10.0 * count(piece); // a pair is one glyph

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
        wrapLines(lines, text, width, tenPerGlyphPiece, tenPerGlyph);
        return cut(text, lines);
    }
}

@("wrapLines: a line is as wide as it is drawn, by the widths of its runs: a host rounding each run up to a whole dip wraps no line past the width")
unittest
{
    import ptable_text.runs : lineWidth;
    import std.math : ceil;

    // as Sciter: a glyph is 3.25, the layout of a piece is rounded up; the advance of a glyph is read off a run of it (`glyphWidth`)
    double piece(const(wchar)[] t) { return ceil(count(t) * 3.25); }
    auto glyph = delegate double(dchar) nothrow => 3.25;
    const text = "ab cd ef gh ij kl mn op qr st uv wx yz ab cd ef gh ij kl mn op qr st uv wx yz"w;
    LineSpan[] lines;
    wrapLines(lines, text, 100, &piece, glyph);
    assert(lines.length > 1);
    foreach (l; lines)
    {
        auto drawn = text[l.start .. l.end];
        while (drawn.length && drawn[$ - 1] == ' ')
            drawn = drawn[0 .. $ - 1]; // the space ending a line may stick out
        assert(lineWidth(drawn, &piece) <= 100, "a line drawn past the width of the cell");
    }
    // a word is 7 drawn (6.5 by the glyphs), a space 4 (3.25): 9 words and their spaces fit as drawn, 10 by the glyphs
    assert(cut(text, lines[0 .. 1]) == ["ab cd ef gh ij kl mn op qr "], "as many runs as fit as drawn");
}

@("wrapLines: a word longer than the line is cut where its piece, as drawn, still fits")
unittest
{
    import std.math : ceil;

    double piece(const(wchar)[] t) { return ceil(count(t) * 3.25); }
    auto glyph = delegate double(dchar) nothrow => 3.25;
    LineSpan[] lines;
    const text = "abcdefghijklmnopqrstuvwxyz"w;
    wrapLines(lines, text, 33, &piece, glyph); // 10 glyphs are 32.5 by the glyphs and 33 drawn; 11 are 35.75
    assert(cut(text, lines) == ["abcdefghij", "klmnopqrst", "uvwxyz"]);
    wrapLines(lines, text, 32.9, &piece, glyph); // 10 glyphs fit by the glyphs, not as drawn (33): 9 (30 drawn)
    assert(cut(text, lines)[0] == "abcdefghi");
}

@("wrapLines: a word of many lines is measured by its lines, not again whole after each cut (a dump of hex or base64)")
unittest
{
    size_t measured;
    double piece(const(wchar)[] t) { measured += t.length; return 10.0 * t.length; }
    auto text = new wchar[10_000];
    text[] = 'x';
    LineSpan[] lines;
    wrapLines(lines, text, 300, &piece, tenPerGlyph); // 30 glyphs a line, 334 lines
    assert(lines.length == 334);
    assert(measured <= 4 * text.length, "the rest of the word measured after each cut");
}

@("wrapLines: a cut that steps back as drawn steps over a surrogate pair whole")
unittest
{
    import std.math : ceil;

    double piece(const(wchar)[] t) { return ceil(count(t) * 3.25); }
    auto glyph = delegate double(dchar) nothrow => 3.25;
    wchar[] text;
    foreach (_; 0 .. 20)
        text ~= "😀"w;
    LineSpan[] lines;
    wrapLines(lines, text, 32.9, &piece, glyph); // 10 fit by the glyphs (32.5), not as drawn (33): 9
    assert(lines[0] == LineSpan(0, 18) && lines[1].start == 18, "9 pairs, none cut");
}

@("wrapLines: a lone surrogate is a glyph, not an error")
unittest
{
    double piece(const(wchar)[] t) { return 10.0 * t.length; }
    const text = "abc"w ~ cast(wchar) 0xD800 ~ "defgh"w;
    LineSpan[] lines;
    wrapLines(lines, text, 40, &piece, tenPerGlyph);
    assert(lines == [LineSpan(0, 4), LineSpan(4, 8), LineSpan(8, 9)], "the surrogate is a glyph of 10 of its own");
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
    wrapLines(lines, text, 20, tenPerGlyphPiece, tenPerGlyph);
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

@("glyphWidth: read off a run of the glyph, a measurer rounding a text up to a whole dip does not round the glyph")
unittest
{
    import ptable_text.measurer : FontMetrics;
    import std.math : ceil, isClose;
    import std.utf : count;

    static final class RoundsUp : TextMeasurer // as Sciter's layouts: the width of a text rounded up
    {
        FontMetrics metrics(FontId font) { return FontMetrics(11, 3, 14); }
        double width(FontId font, const(wchar)[] text) { return ceil(count(text) * 3.3); } // by glyphs, a pair is one
        int wrappedLines(FontId font, const(wchar)[] text, double width) { return -1; }
    }

    assert(isClose(glyphWidth(new RoundsUp, 0, 'i'), 3.3, 0, 0.1), "not 4: a narrow glyph would wrap a line a quarter too early");
    assert(isClose(glyphWidth(new RoundsUp, 0, 0x1F600), 3.3, 0, 0.1), "a glyph beyond the BMP too");
}

@("wrapLines: a line breaks after a tab as after a space, and the tab may stick out of the width")
unittest
{
    assert(wrapped("aaa\tbbb\tccc", 70) == ["aaa\tbbb\t", "ccc"]);
    assert(wrapped("aaaa\tbb", 40) == ["aaaa\t", "bb"]);
}
