//! The widths of texts a measurer has measured, by font: a text measured once is not laid out again while it is kept. A font that keeps
//! too many texts starts empty. Not bounded by the bytes of the texts: the backgrounds of the matches of a search measure the start of a
//! line up to each match, keys of up to a hundred kilobytes, again on every frame, and a bound by bytes emptied the cache within a frame
//! (every frame laid them out anew: measured 2026-11-20, docs/backlog.md). Free of Sciter: `SciterMeasurer` (ui/sciter_table/host)
//! measures what is not here.
module ui.sciter_table.width_cache;

final class WidthCache
{
    enum size_t maxTexts = 100_000; /// texts a font keeps: the words of the lines on the screen and of the long lines before what is seen (ptable_text/runs)

    private double[wstring][] _widths;

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

    /// Keeps the width of `text` in `font` (a copy of the text); a font that keeps `maxTexts` lets go of all it kept first
    void keep(size_t font, const(wchar)[] text, double width)
    {
        if (_widths[font].length >= maxTexts)
            _widths[font] = null;
        _widths[font][text.idup] = width;
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
}

@("WidthCache: long texts measured frame after frame stay kept: the start of lines up to the matches of a search")
unittest
{
    import std.array : replicate;

    auto cache = new WidthCache(1);
    const line = "w"w.replicate(60_000);
    foreach (frame; 0 .. 3)
        foreach (i; 0 .. 100) // 100 prefixes of up to 120 KB each: 12 MB of keys a frame
        {
            double width;
            if (!cache.find(0, line[0 .. $ - i], width))
            {
                assert(frame == 0, "a frame after the first measures nothing again");
                cache.keep(0, line[0 .. $ - i], i);
            }
        }
}

@("WidthCache: the texts of a font are bounded by their number")
unittest
{
    import std.conv : to;

    auto cache = new WidthCache(1);
    foreach (i; 0 .. WidthCache.maxTexts + 5)
        cache.keep(0, i.to!wstring, i);
    assert(cache.count(0) <= WidthCache.maxTexts && cache.count(0) > 0);
    cache.forget(1);
    assert(cache.count(0) == 0, "forgotten");
}
