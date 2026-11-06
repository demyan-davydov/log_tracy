//! Looks for a substring in UTF-16 texts, in its case or in any case, by code
//! units: the text searched is not decoded.
module utils.text_search;

//! @brief A substring to look for, prepared once for many texts.
//! In any case, a pattern in the BMP is lowered code unit by code unit and
//! compared with the lowered code units of the text: exact, since a surrogate
//! is never a code unit of the pattern and no letter beyond the BMP is a
//! letter of the BMP in another case. A pattern with letters beyond the BMP
//! is compared by decoding, which is slower.
struct TextPattern
{
    private immutable(wchar)[] _pattern; // lowered if compared in any case in the BMP
    private Compare _compare;
    private wchar _firstUpper; // ByLowered: the upper case of the first unit, if lowered back to it

    private enum Compare : ubyte
    {
        Exact, // in its case
        ByLowered, // in any case, a pattern in the BMP
        ByDecoding, // in any case, a pattern with letters beyond the BMP
    }

    //! @param text - the substring, as the user wrote it
    this(const(wchar)[] text, bool ignoreCase) pure
    {
        import std.algorithm.searching : any;
        import std.utf : byCodeUnit;
        import std.uni : toUpper;

        if (!ignoreCase)
        {
            _pattern = text.idup;
            _compare = Compare.Exact;
        }
        else if (text.byCodeUnit.any!(c => c >= 0xD800 && c <= 0xDFFF)) // a pair: beyond the BMP
        {
            _pattern = text.idup;
            _compare = Compare.ByDecoding;
        }
        else
        {
            auto lower = new wchar[text.length];
            foreach (i, c; text)
                lower[i] = lowerOf(c);
            _pattern = cast(immutable) lower;
            _compare = Compare.ByLowered;
            if (lower.length)
            {
                // A quick yes only if lowered back to it (not for ı: its upper I is i)
                _firstUpper = cast(wchar) toUpper(cast(dchar) lower[0]);
                if (lowerOf(_firstUpper) != lower[0])
                    _firstUpper = lower[0];
            }
        }
    }

    //! @brief The first occurrence in `value` at or after `from`.
    //! @param end - set to the end of the occurrence: in any case a letter of
    //!   the text may take other code units than in the pattern
    //! @return its position, or -1 if there is none
    ptrdiff_t find(const(wchar)[] value, size_t from, out size_t end) const
    {
        if (from > value.length)
            return -1;
        final switch (_compare)
        {
        case Compare.Exact:
        case Compare.ByLowered:
            const at = _compare == Compare.Exact ? findExact(value, from) : findLowered(value, from);
            if (at >= 0)
                end = at + _pattern.length;
            return at;
        case Compare.ByDecoding:
            return findDecoding(value, from, end);
        }
    }

    // Most places differ at the first code unit, so it is checked alone first

    private ptrdiff_t findExact(const(wchar)[] value, size_t from) const pure nothrow @nogc
    {
        if (_pattern.length == 0)
            return from;
        if (value.length - from < _pattern.length)
            return -1;
        const first = _pattern[0];
        foreach (i; from .. value.length - _pattern.length + 1)
            if (value[i] == first && value[i + 1 .. i + _pattern.length] == _pattern[1 .. $])
                return i;
        return -1;
    }

    private ptrdiff_t findLowered(const(wchar)[] value, size_t from) const pure nothrow @nogc
    {
        if (_pattern.length == 0)
            return from;
        if (value.length - from < _pattern.length)
            return -1;
        const first = _pattern[0];
        outer: foreach (i; from .. value.length - _pattern.length + 1)
        {
            const c = value[i];
            // Beyond ASCII a letter may have more upper cases (K and the Kelvin sign)
            if (c != first && c != _firstUpper && (c < 0x80 || lowerOf(c) != first))
                continue;
            foreach (j; 1 .. _pattern.length)
                if (lowerOf(value[i + j]) != _pattern[j])
                    continue outer;
            return i;
        }
        return -1;
    }

    private ptrdiff_t findDecoding(const(wchar)[] value, size_t from, out size_t end) const
    {
        import std.typecons : Yes;
        import std.uni : toLower;
        import std.utf : decode, stride;

        for (size_t at = from; at <= value.length; at += at < value.length ? stride(value, at) : 1)
        {
            size_t v = at, p = 0;
            bool same = true;
            while (same && p < _pattern.length && v < value.length)
                same = toLower(decode!(Yes.useReplacementDchar)(value, v))
                    == toLower(decode!(Yes.useReplacementDchar)(_pattern, p));
            if (same && p == _pattern.length)
            {
                end = v;
                return at;
            }
        }
        return -1;
    }

    //! @return true for an empty substring: it is found anywhere
    bool isEmpty() const pure nothrow @nogc
    {
        return _pattern.length == 0;
    }

    //! @return true if the substring is in `value`
    bool foundIn(const(wchar)[] value) const
    {
        size_t end;
        return find(value, 0, end) >= 0;
    }
}

version (unittest)
{
    // [start, end) of every occurrence, as a highlight walks them
    private size_t[2][] occurrences(string pattern, bool ignoreCase, wstring value)
    {
        import std.utf : toUTF16;

        const p = TextPattern(pattern.toUTF16, ignoreCase);
        size_t[2][] all;
        size_t end;
        for (ptrdiff_t at = p.find(value, 0, end); at >= 0; at = p.find(value, end, end))
            all ~= [cast(size_t) at, end];
        return all;
    }
}

@("TextPattern: in its case, every occurrence after the previous one")
unittest
{
    assert(occurrences("ab", false, "xabyab"w) == [[1, 3], [4, 6]]);
    assert(occurrences("ab", false, "xAbyaB"w) == []);
    assert(occurrences("aa", false, "aaaa"w) == [[0, 2], [2, 4]], "occurrences don't overlap");
    assert(occurrences("abc", false, "ab"w) == [], "longer than the text");
    assert(TextPattern("x"w, false).foundIn("abx"w), "at the very end");
    assert(TextPattern(""w, false).foundIn("abc"w) && TextPattern(""w, true).foundIn(""w),
        "an empty pattern is in any text");

    size_t end;
    assert(TextPattern("ab"w, false).find("abab"w, 1, end) == 2 && end == 4, "from a position");
    assert(TextPattern("ab"w, false).find("abab"w, 4, end) == -1, "from the end");
    assert(TextPattern("ab"w, false).find("abab"w, 9, end) == -1, "from beyond the end");
}

@("TextPattern: in any case, ASCII and beyond")
unittest
{
    assert(occurrences("Error", true, "an ERROR, an error"w) == [[3, 8], [13, 18]]);
    assert(occurrences("ошибка", true, "Ошибка и ОШИБКА"w) == [[0, 6], [9, 15]]);
    assert(occurrences("straße", true, "STRASSE Straße"w) == [[8, 14]], "ß is one code unit, not SS");
    assert(occurrences("a1-", true, "A1-a1-"w) == [[0, 3], [3, 6]], "not letters compare as they are");
    assert(!TextPattern("[a]"w, true).foundIn("[b]"w));
}

@("TextPattern: in any case, the first letter is compared as the others")
unittest
{
    // the Kelvin sign is a K of another case: lowered to k
    assert(TextPattern("kelvin"w, true).foundIn("Kelvin"w));
    assert(TextPattern("Kelvin"w, true).foundIn("Kelvin"w));
    // the dotless ı is upper-cased to I, which is lowered to i, not to ı
    assert(!TextPattern("ıx"w, true).foundIn("Ix"w));
    assert(TextPattern("ix"w, true).foundIn("Ix"w));
    assert(TextPattern("x"w, true).foundIn("aX"w) && TextPattern("X"w, true).foundIn("ax"w));
}

@("TextPattern: beyond the BMP")
unittest
{
    // Deseret: 𐐀 (U+10400) is the upper case of 𐐨 (U+10428)
    assert(occurrences("𐐨x", true, "a𐐀X b𐐨x"w) == [[1, 4], [6, 9]]);
    assert(occurrences("😀", true, "a😀"w) == [[1, 3]]);
    assert(occurrences("😀", false, "a😀😀"w) == [[1, 3], [3, 5]]);
    assert(!TextPattern("😀"w, true).foundIn("a\U0001F601"w), "the pairs differ in the second unit");
}

//! @returns `c` in lower case: a code unit of the BMP, a surrogate as it is
private wchar lowerOf(wchar c) pure nothrow @nogc
{
    import std.uni : toLower;

    if (c < 0x80)
        return c >= 'A' && c <= 'Z' ? cast(wchar)(c + ('a' - 'A')) : c;
    return cast(wchar) toLower(cast(dchar) c);
}
