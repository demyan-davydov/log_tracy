//! The widths of texts a measurer has measured, by font: a text measured once is not laid out again while it is kept. The texts are the
//! keys, so what the cache holds is bounded by their bytes as well as by their number: the start of a line up to a match far into it, or
//! the steps of a caret through a long line, would make keys of a hundred kilobytes each. A font over either bound starts empty. Free of
//! Sciter: `SciterMeasurer` (ui/sciter_table/host) measures what is not here.
module ui.sciter_table.width_cache;

final class WidthCache
{
    enum size_t maxTexts = 20_000; /// texts a font keeps
    enum size_t maxBytes = 2 * 1024 * 1024; /// bytes of the texts a font keeps

    private double[wstring][] _widths;
    private size_t[] _bytes;

    /// `fonts`: how many fonts there are
    this(size_t fonts)
    {
        forget(fonts);
    }

    /// The width of `text` in `font` as it was measured; false if it is not kept
    bool find(size_t font, const(wchar)[] text, out double width)
    {
        if (auto found = cast(wstring) text in _widths[font])
        {
            width = *found;
            return true;
        }
        return false;
    }

    /// Keeps the width of `text` in `font` (a copy of the text); a font over a bound lets go of all it kept first
    void keep(size_t font, const(wchar)[] text, double width)
    {
        const bytes = text.length * wchar.sizeof;
        if (_widths[font].length >= maxTexts || _bytes[font] + bytes > maxBytes)
        {
            _widths[font] = null;
            _bytes[font] = 0;
        }
        _widths[font][text.idup] = width;
        _bytes[font] += bytes;
    }

    /// The bytes of the texts `font` keeps
    size_t bytes(size_t font) const
    {
        return _bytes[font];
    }

    /// How many texts `font` keeps
    size_t count(size_t font) const
    {
        return _widths[font].length;
    }

    /// Lets go of all of it: `fonts` fonts from now on (the fonts changed)
    void forget(size_t fonts)
    {
        _widths = new double[wstring][fonts];
        _bytes = new size_t[fonts];
    }
}

@("WidthCache: a width kept is found by its font and text, another font knows nothing of it")
unittest
{
    auto cache = new WidthCache(2);
    cache.keep(0, "abc"w, 21);
    double width;
    assert(cache.find(0, "abc"w, width) && width == 21);
    assert(!cache.find(1, "abc"w, width), "another font");
    assert(!cache.find(0, "abd"w, width), "another text");
    assert(cache.bytes(0) == 6 && cache.bytes(1) == 0);
}

@("WidthCache: the long texts of a font are bounded by their bytes: past the bound the font starts empty, the other fonts keep theirs")
unittest
{
    import std.array : replicate;

    auto cache = new WidthCache(2);
    cache.keep(1, "x"w, 7);
    const long_ = "w"w.replicate(60_000); // the start of a line up to a match at its 60 000th unit
    size_t kept;
    foreach (i; 0 .. 40)
    {
        cache.keep(0, long_[0 .. $ - i], i);
        assert(cache.bytes(0) <= WidthCache.maxBytes, "never over the bound");
        kept = cache.count(0);
    }
    assert(kept < 40, "the font let go of what it kept when the next text would pass the bound");
    double width;
    assert(cache.find(0, long_[0 .. $ - 39], width) && width == 39, "the last one kept");
    assert(cache.find(1, "x"w, width) && width == 7, "another font is not touched");
}

@("WidthCache: the texts of a font are bounded by their number too")
unittest
{
    import std.conv : to;

    auto cache = new WidthCache(1);
    foreach (i; 0 .. WidthCache.maxTexts + 5)
        cache.keep(0, i.to!wstring, i);
    assert(cache.count(0) <= WidthCache.maxTexts && cache.count(0) > 0);
    cache.forget(1);
    assert(cache.count(0) == 0 && cache.bytes(0) == 0, "forgotten");
}
