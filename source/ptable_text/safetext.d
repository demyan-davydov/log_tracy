//! The text that goes to a text engine as it is, and what is told apart in it: a control character (NUL, a vertical tab...) or a lone
//! surrogate in a layout made the engine of Sciter fault (a null pointer in its lazy layout), and a CR within a line or U+2028 breaks the
//! line in a measure (`white-space: pre`) but not in a drawing (words drawn over each other), so a host cleans the text it hands over,
//! 1:1 in UTF-16 units (a position of the cleaned text is a position of the original). The model and the payload keep the original text
//! (copy, search, export read it); only the edge of the engine is cleaned. Sciter-free: the rule is here, the host applies it.
module ptable_text.safetext;

import ptable.memory : Buffer, mallocAllocator;

/// What stands for what has no place in a text engine and has no picture of its own: a C1 control, U+2028, U+FFFE, U+FFFF, a lone surrogate
enum wchar replacement = '\uFFFD';

// The unit that stands for a control character the engine is not given: its control picture (U+2400 + the code: NUL is U+2400, DEL
// U+2421), so a reader sees what it was; a tab and a line feed are the table's own: `c` itself. For a unit that is no such character:
// `c` itself too
private wchar controlPicture(wchar c) pure nothrow @nogc @safe
{
    if (c < 0x20)
        return c == '\t' || c == '\n' ? c : cast(wchar)(0x2400 + c);
    return c == 0x7F ? cast(wchar) 0x2421 : c;
}

/// What stands for the unit `c` alone, `c` itself if it is fine: a control character its picture, a C1 control, U+2028, U+FFFE, U+FFFF the
/// `replacement`. A surrogate and the CR of a CRLF are told by their neighbours (`safeText`); here a surrogate is fine, a CR its picture
wchar unitFor(wchar c) pure nothrow @nogc @safe
{
    const picture = controlPicture(c);
    if (picture != c)
        return picture;
    return (c >= 0x80 && c < 0xA0) || c == 0x2028 || c == 0xFFFE || c == 0xFFFF ? replacement : c;
}

/// Whether a unit alone is not given to the engine (`unitFor` makes another of it)
bool isUnsafe(wchar c) pure nothrow @nogc @safe
{
    return unitFor(c) != c;
}

/// `text` as the engine is given it: `text` itself when nothing in it is unsafe (no copy), else a copy in `scratch` (memory of its
/// allocator, kept for the next call, valid until it) with each unsafe unit by `unitFor` and each lone surrogate by `replacement`; the CR
/// of a CRLF stays.
/// Empty if the scratch has no memory for the copy: no text, never the unsafe one
const(wchar)[] safeText(const(wchar)[] text, ref Buffer!wchar scratch) nothrow
{
    size_t first = text.length;
    for (size_t i = 0; i < text.length; ++i)
    {
        const c = text[i];
        if ((isUnsafe(c) && !crOfBreak(text, i)) || (c >= 0xD800 && c < 0xE000 && !pairAt(text, i)))
        {
            first = i;
            break;
        }
        if (c >= 0xD800 && c < 0xDC00)
            ++i; // the low unit of the pair
    }
    if (first == text.length)
        return text;
    scratch.clear();
    if (!scratch.reserve(text.length) || !scratch.put(text[0 .. first]))
        return null;
    for (size_t i = first; i < text.length; ++i)
    {
        const c = text[i];
        bool done;
        if (c >= 0xD800 && c < 0xDC00 && pairAt(text, i))
        {
            done = scratch.put(c) && scratch.put(text[i + 1]);
            ++i;
        }
        else
            done = scratch.put(c >= 0xD800 && c < 0xE000 ? replacement : crOfBreak(text, i) ? c : unitFor(c));
        if (!done)
            return null;
    }
    return scratch[];
}

// Whether the unit at `i` is the CR of a CRLF: the engine breaks the line there in a measure and in a drawing alike
private bool crOfBreak(const(wchar)[] text, size_t i) pure nothrow @nogc @safe
{
    return text[i] == '\r' && i + 1 < text.length && text[i + 1] == '\n';
}

// Whether the unit at `i` is the high unit of a pair whose low unit follows
private bool pairAt(const(wchar)[] text, size_t i) pure nothrow @nogc @safe
{
    const c = text[i];
    return c >= 0xD800 && c < 0xDC00 && i + 1 < text.length && text[i + 1] >= 0xDC00 && text[i + 1] < 0xE000;
}

/// A glyph as `safeText` makes it (a code point on its own: a surrogate is lone, one beyond the BMP is fine): the one rule of the width of a
/// glyph and of the text drawn
dchar safeGlyph(dchar glyph) pure nothrow @nogc @safe
{
    if (glyph >= 0x10000)
        return glyph;
    return glyph >= 0xD800 && glyph < 0xE000 ? replacement : unitFor(cast(wchar) glyph);
}

@("safeText: a text with nothing unsafe is returned as it is, not copied")
unittest
{
    auto scratch = Buffer!wchar(mallocAllocator());
    const text = "Hello, \tworld\r\n é中 \U0001F600"w;
    assert(safeText(text, scratch).ptr is text.ptr);
    assert(scratch.length == 0, "the scratch is not touched");
}

@("safeText: a NUL, a vertical tab, other controls and DEL become their control pictures, a C1 control the replacement character, one unit each")
unittest
{
    auto scratch = Buffer!wchar(mallocAllocator());
    assert(safeText("a\0b\vc\x01d\x7fe\u0085f"w, scratch) == "a\u2400b\u240bc\u2401d\u2421e\uFFFDf"w);
}

@("safeText: a tab, a line feed and the CR of a CRLF stay: the table knows them")
unittest
{
    auto scratch = Buffer!wchar(mallocAllocator());
    const text = "a\tb\nc\r\n"w;
    assert(safeText(text, scratch) == text);
}

@("safeText: a CR that ends no line becomes its control picture: the engine breaks a line by it in a measure, not in a drawing")
unittest
{
    auto scratch = Buffer!wchar(mallocAllocator());
    assert(safeText("a\rb \r c\r\r\n"w, scratch) == "a\u240Db \u240D c\u240D\r\n"w);
    assert(safeText("end\r"w, scratch) == "end\u240D"w, "a piece of a line: the end of a line is cut off before it comes here");
    assert(safeGlyph('\r') == 0x240D, "as wide as it is drawn");
}

@("safeText: the line separator U+2028 is replaced: the engine would break the line by it and the rest would not be seen")
unittest
{
    auto scratch = Buffer!wchar(mallocAllocator());
    assert(safeText("a\u2028b"w, scratch) == "a\uFFFDb"w);
    assert(safeGlyph(0x2028) == 0xFFFD);
}

@("safeText: a lone surrogate and U+FFFE, U+FFFF are replaced, a pair stays")
unittest
{
    auto scratch = Buffer!wchar(mallocAllocator());
    const high = cast(wchar) 0xD83D, low = cast(wchar) 0xDE00;
    assert(safeText([high, 'a', low, high, low, high], scratch) == "\uFFFDa\uFFFD\U0001F600\uFFFD"w);
    assert(safeText(['x', cast(wchar) 0xFFFE, cast(wchar) 0xFFFF], scratch) == "x\uFFFD\uFFFD"w);
}

@("safeText: the length is the same, so a place in the cleaned text is the place in the original")
unittest
{
    auto scratch = Buffer!wchar(mallocAllocator());
    const text = "\0\0\0ab\v"w;
    assert(safeText(text, scratch).length == text.length);
}

@("safeText: the scratch is reused for a longer text and a clean one after an unclean one is the text itself")
unittest
{
    auto scratch = Buffer!wchar(mallocAllocator());
    safeText("a\0"w, scratch);
    assert(safeText("a longer text with a \0 in it"w, scratch) == "a longer text with a \u2400 in it"w);
    const clean = "clean"w;
    assert(safeText(clean, scratch).ptr is clean.ptr);
}

@("safeGlyph: a glyph as safeText makes it: the same replacement for a unit, a lone surrogate and a code point beyond the BMP stays")
unittest
{
    assert(safeGlyph('a') == 'a' && safeGlyph('\t') == '\t' && safeGlyph(0x1F600) == 0x1F600);
    assert(safeGlyph('\0') == 0x2400 && safeGlyph('\v') == 0x240B && safeGlyph(0x7F) == 0x2421);
    assert(safeGlyph(0x85) == 0xFFFD && safeGlyph(0xFFFE) == 0xFFFD && safeGlyph(0xD83D) == 0xFFFD && safeGlyph(0xDE00) == 0xFFFD);
    auto scratch = Buffer!wchar(mallocAllocator());
    foreach (unit; cast(wchar[]) [0, 0x0B, 0x7F, 0x85, 0xFFFE, 0xD83D, 0xDE00, 'x'])
    {
        wchar[1] one = unit;
        assert(safeText(one[], scratch)[0] == safeGlyph(unit), "a glyph and a text are cleaned alike");
    }
}
