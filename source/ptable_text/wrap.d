//! Wrapping a text into lines by the widths its runs are drawn with (ptable_text/runs), and the widths a text column asks of its measurer.
//! Pure: no Sciter; the width of a piece of text and the advance of a glyph come in as delegates. The lines are the business of a text column (the table keeps none).
module ptable_text.wrap;

import ptable.ports : FontId;
import ptable_text.measurer : TextMeasurer;
import ptable_text.runs : PieceWidth, graphemeCut, lineWidth, runEnd, shownGlyph;

/// A line of a wrapped text: [start, end) in UTF-16 units
struct LineSpan
{
    size_t start, end;
}

/// The lines of `text` in a width of `width` px, as a line of it is drawn (ptable_text/runs): a word is as wide as `piece` says of its runs,
/// a gap of spaces or tabs too. A line breaks after a gap (the gap may stick out of the width). A word is measured by `piece` only when it
/// ends within the line by `advance`, the width of a code point, which must be no less than the glyph as drawn (`glyphWidth` reads it off a
/// run of it, rounded up). A word longer than a line is cut where the `advance`s of its part and a dip for the rounding of each run it is
/// drawn in fit, at the end of a grapheme; the part is not measured by `piece` (a new text on each line). A hard "\n" breaks too, but one
/// at the very end of the text ends its line and starts no empty one. A line has a grapheme at least, so a width smaller than one still
/// moves on. An empty text is one empty line. `lines` is filled (its old content is dropped).
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
            const step = advance(nextGlyph(text, next));
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
        // A word longer than the line: cut where its glyphs and a dip for each run its part is drawn in still fit (a glyph at least). The
        // part is not measured by the host: it is a new text on each line (a layout each), and drawn it is no wider than its glyphs (read off
        // runs of them, rounded up) and the rounding of each of its runs
        size_t first = i;
        nextGlyph(text, first);
        size_t cut = reach > first ? reach : first;
        double sum = estimate; // the glyphs of text[i .. reach], x is 0 at the start of a line
        while (cut > first && sum + runsIn(text[i .. cut]) > width)
        {
            size_t back = cut - (cut - 2 >= i && isLow(text[cut - 1]) && isHigh(text[cut - 2]) ? 2 : 1);
            size_t past = back;
            sum -= advance(nextGlyph(text, past));
            cut = back;
        }
        cut = graphemeCut(text, i, cut); // back to the end of a grapheme: only further in if the first one alone is wider than the line
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

// The code point at `at` of `text`, `at` moved past it: a surrogate pair is one, a lone surrogate is U+FFFD of one unit (std.utf's
// replacement takes the unit after it too)
private dchar nextGlyph(const(wchar)[] text, ref size_t at) pure nothrow @nogc @safe
{
    const c = text[at++];
    if (isHigh(c) && at < text.length && isLow(text[at]))
        return 0x10000 + ((c - 0xD800) << 10) + (text[at++] - 0xDC00);
    return isHigh(c) || isLow(c) ? 0xFFFD : c;
}

// How many runs a line of `part` is drawn in (ptable_text/runs)
private size_t runsIn(const(wchar)[] part) pure nothrow @safe
{
    size_t runs = 0;
    for (size_t at = 0; at < part.length; at = runEnd(part, at))
        ++runs;
    return runs;
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

@("wrapLines: a word longer than the line is cut where its glyphs and a dip for the rounding of each run of the part fit: drawn it fits")
unittest
{
    import ptable_text.runs : lineWidth;
    import std.math : ceil;

    double piece(const(wchar)[] t) { return ceil(count(t) * 3.25); }
    auto glyph = delegate double(dchar) nothrow => 3.25;
    LineSpan[] lines;
    const text = "abcdefghijklmnopqrstuvwxyz"w;
    wrapLines(lines, text, 33.5, &piece, glyph); // 10 glyphs are 32.5 and a dip for their run: 33.5
    assert(cut(text, lines) == ["abcdefghij", "klmnopqrst", "uvwxyz"]);
    wrapLines(lines, text, 33, &piece, glyph); // 10 are 33 drawn, but by the glyphs they may be 33.5: 9
    assert(cut(text, lines)[0] == "abcdefghi");
    foreach (width; [10.0, 20.5, 33, 50.2, 81])
    {
        wrapLines(lines, text, width, &piece, glyph);
        foreach (l; lines)
            assert(lineWidth(text[l.start .. l.end], &piece) <= width, "a part drawn past the width");
    }
}

@("wrapLines: a part cut off a word of many lines is placed by its glyphs, only the end of the word is measured (a dump of hex or base64)")
unittest
{
    size_t measured;
    double piece(const(wchar)[] t) { measured += t.length; return 10.0 * t.length; }
    auto text = new wchar[10_000];
    text[] = 'x';
    LineSpan[] lines;
    wrapLines(lines, text, 301, &piece, tenPerGlyph); // 30 glyphs a line and a dip for the rounding of their run: 334 lines
    assert(lines.length == 334);
    assert(measured <= 30, "a part cut off the word is measured by its glyphs, not by the host (a layout a line); only the last one, ending the word");
}

@("wrapLines: a cut that steps back steps over a surrogate pair whole")
unittest
{
    import std.math : ceil;

    double piece(const(wchar)[] t) { return ceil(count(t) * 3.25); }
    auto glyph = delegate double(dchar) nothrow => 3.25;
    wchar[] text;
    foreach (_; 0 .. 20)
        text ~= "😀"w;
    LineSpan[] lines;
    wrapLines(lines, text, 32.9, &piece, glyph); // 10 are 32.5 by the glyphs, 33.5 with the dip of their run: back by a pair, 9
    assert(lines[0] == LineSpan(0, 18) && lines[1].start == 18, "9 pairs, none cut");
}

@("wrapLines: a long word is cut between graphemes, not inside one: a letter keeps its mark, a flag is whole")
unittest
{
    wchar[] accents, flags;
    foreach (_; 0 .. 20)
    {
        accents ~= "é"w; // e and a combining acute
        flags ~= "🇩🇪"w; // two regional indicators, two units each
    }
    LineSpan[] lines;
    wrapLines(lines, accents, 31, tenPerGlyphPiece, tenPerGlyph); // 3 code points fit: the third is an e without its mark
    foreach (l; lines)
        assert(accents[l.start] == 'e' && (l.end - l.start) % 2 == 0, "a mark torn from its letter");
    wrapLines(lines, flags, 31, tenPerGlyphPiece, tenPerGlyph); // 3 code points: half a flag
    foreach (l; lines)
        assert(l.start % 4 == 0 && (l.end - l.start) % 4 == 0, "a flag cut in two");
    wrapLines(lines, flags, 15, tenPerGlyphPiece, tenPerGlyph); // not even a flag fits: a whole one a line
    assert(lines.length == 20 && lines[0] == LineSpan(0, 4));
}

@("wrapLines: a lone surrogate is a glyph, not an error")
unittest
{
    double piece(const(wchar)[] t) { return 10.0 * t.length; }
    const text = "abc"w ~ cast(wchar) 0xD800 ~ "defgh"w;
    LineSpan[] lines;
    wrapLines(lines, text, 41, &piece, tenPerGlyph); // 4 glyphs and a dip for their run
    assert(lines.length > 1 && lines[0].start == 0 && lines[$ - 1].end == text.length, "the whole text in lines");
    foreach (k, l; lines)
        assert((k == 0 || l.start == lines[k - 1].end) && 10.0 * (l.end - l.start) <= 41, "one after another, each in the width");
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

@("wrapLines: a word longer than the line breaks at the width, less a dip for the rounding of its run")
unittest
{
    assert(wrapped("abcdefghij", 41) == ["abcd", "efgh", "ij"]);
    assert(wrapped("abcdefghij", 40) == ["abc", "def", "ghij"], "4 glyphs are 40, their run may be drawn 41; the end of the word is measured as drawn");
    assert(wrapped("xabcdefghij", 41) == ["xabc", "defg", "hij"]);
    assert(wrapped("ab cdefghijkl", 51) == ["ab ", "cdefg", "hijkl"]);
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
    wrapLines(lines, text, 21, tenPerGlyphPiece, tenPerGlyph); // 2 glyphs and a dip for their run
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
