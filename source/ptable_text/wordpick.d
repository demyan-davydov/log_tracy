//! Where a point or a click falls in a text: the caret nearest to a point, the character under it, the word a double click selects, the whole
//! text of a triple click. Pure: the widths come in as delegates.
module ptable_text.wordpick;

import ptable.selection : Part;
import std.algorithm.comparison : max, min;

/// The caret (a place between two units, 0 .. `length`) nearest to `dx` dips from the start of a text of `length` units: right
/// of the middle of a character is after it. `width(k)` is the width of the first k units (growing)
size_t caretAt(double dx, size_t length, scope double delegate(size_t) width)
{
    if (length == 0 || dx <= 0)
        return 0;
    size_t low = 0, high = length;
    while (low < high)
    {
        const middle = (low + high) / 2;
        if (dx < (width(middle) + width(middle + 1)) / 2)
            high = middle;
        else
            low = middle + 1;
    }
    return low;
}

/// The character (its first unit) under the point `dx` dips from the start of a text of `length`
/// units: the last one that starts at or before it. `width(k)` is the width of the first k units
/// (growing). Left of the text it is 0, right of it `length`.
size_t charAt(double dx, size_t length, scope double delegate(size_t) width)
{
    if (length == 0 || dx < 0)
        return 0;
    size_t low = 0, high = length;
    while (low < high)
    {
        const middle = (low + high) / 2;
        if (width(middle + 1) > dx)
            high = middle;
        else
            low = middle + 1;
    }
    return low;
}

private bool isWordChar(dchar c) pure nothrow @safe
{
    import std.uni : isAlpha, isNumber;

    return c == '_' || isAlpha(c) || isNumber(c);
}

// [start, end) of the character with the unit `i`: two units for one outside the BMP
private size_t[2] charSpan(const(wchar)[] text, size_t i) pure nothrow @nogc @safe
{
    const code = text[i];
    if (code >= 0xDC00 && code <= 0xDFFF && i > 0 && text[i - 1] >= 0xD800 && text[i - 1] <= 0xDBFF)
        return [i - 1, i + 1];
    if (code >= 0xD800 && code <= 0xDBFF && i + 1 < text.length && text[i + 1] >= 0xDC00 && text[i + 1] <= 0xDFFF)
        return [i, i + 2];
    return [i, i + 1];
}

private dchar charOf(const(wchar)[] text, size_t[2] span) pure nothrow @safe
{
    import std.utf : decode;

    size_t at = span[0];
    try
        return decode(text, at);
    catch (Exception)
        return 0xFFFD;
}

/// The word at `offset` a double click selects ([from, to)): the character alone if it is not part
/// of a word; none for an empty text
Part wordAt(const(wchar)[] text, long offset) pure nothrow @safe
{
    if (text.length == 0)
        return Part.init;
    const at = cast(size_t) max(0L, min(offset, cast(long) text.length - 1));
    const here = charSpan(text, at);
    if (!isWordChar(charOf(text, here)))
        return Part(true, here[0], here[1]);
    size_t from = here[0], to = here[1];
    while (from > 0)
    {
        const before = charSpan(text, from - 1);
        if (!isWordChar(charOf(text, before)))
            break;
        from = before[0];
    }
    while (to < text.length)
    {
        const after = charSpan(text, to);
        if (!isWordChar(charOf(text, after)))
            break;
        to = after[1];
    }
    return Part(true, from, to);
}

/// The whole text a triple click selects
Part wholeText(const(wchar)[] text) pure nothrow @nogc @safe
{
    return text.length ? Part(true, 0, text.length) : Part.init;
}


@("caretAt: the place between two characters nearest to the point, the ends of the text past them")
unittest
{
    double delegate(size_t) ten = delegate double(size_t k) => k * 10.0;
    assert(caretAt(4, 5, ten) == 0, "left half of the first character: before it");
    assert(caretAt(6, 5, ten) == 1, "right half: after it");
    assert(caretAt(34, 5, ten) == 3);
    assert(caretAt(36, 5, ten) == 4);
    assert(caretAt(500, 5, ten) == 5, "right of the text: its end");
    assert(caretAt(-5, 5, ten) == 0);
    assert(caretAt(5, 0, ten) == 0);
}

@("charAt: the last unit starting at or before the point")
unittest
{
    double delegate(size_t) ten = delegate double(size_t k) => k * 10.0;
    assert(charAt(0, 5, ten) == 0);
    assert(charAt(9, 5, ten) == 0);
    assert(charAt(10, 5, ten) == 1);
    assert(charAt(34, 5, ten) == 3);
    assert(charAt(500, 5, ten) == 5, "right of the text: past its end");
    assert(charAt(-5, 5, ten) == 0);
    assert(charAt(5, 0, ten) == 0);
}

@("wordAt: the word under the character, a lone character for a non-word, none for no text")
unittest
{
    assert(wordAt("foo bar_1 baz"w, 5) == Part(true, 4, 9));
    assert(wordAt("foo bar"w, 3) == Part(true, 3, 4), "a space alone");
    assert(wordAt("запрос ok"w, 2) == Part(true, 0, 6), "letters of any script");
    assert(wordAt("a😀b"w, 2) == Part(true, 1, 3), "a surrogate pair is not cut");
    assert(!wordAt(""w, 0).any);
    assert(wordAt("abc"w, 99) == Part(true, 0, 3), "past the end is the last character");
}

@("wholeText")
unittest
{
    assert(wholeText("abc"w) == Part(true, 0, 3));
    assert(!wholeText(""w).any);
}
