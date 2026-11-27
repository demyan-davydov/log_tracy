//! The host of the log table (ptable) in Sciter: its canvas and text measurer over the
//! graphics API of Sciter (sciter/graphics). The fonts and the ink come as a `TextLook` (ui/look): this layer
//! knows nothing of the log. The text layouts are kept in two generations (a layout of Sciter is what the memory of a log table
//! is). See docs/experiments/2026-11-19-painted-rows-d.md.
module ui.sciter_table.host;

import ptable.memory : Buffer, mallocAllocator;
import ptable.ports;
import ptable_text.measurer : FontMetrics, TextMeasurer;
import ptable_text.safetext : safeText;
import std.experimental.allocator : RCIAllocator;
import sciter.api : sciterApi;
import sciter.capi.api;
import sciter.graphics : GfxCanvas = Canvas, TextLayout, rgba;
import ui.look : FontSpec, TextLook;
import ui.sciter_table.generations : Generations;

import std.algorithm.comparison : max;
import std.math : ceil, round;

private struct TextKey
{
    uint font;
    uint rgba;
    int width; // of a paragraph, -1 for a line
    const(wchar)[] text;
}

/// The text layouts of a table: made on demand for a font, a color and a text, kept in two generations (ui/sciter_table/generations),
/// released when they go. The keys and the maps are in memory of the allocator given, the garbage collector is not asked for a lookup.
final class SciterTextCache
{
    private HELEMENT _he;
    private Generations!(TextKey, TextLayout) _layouts;
    private immutable(wchar)[][ulong] _styles; // by font, color, kind and width (`styleKey`): made once, the misses after it allocate nothing for it
    size_t made; /// layouts made so far
    private TextLook _look;
    private double[] _ascent, _advance;
    private double[] _lineHeights;
    private bool _read;
    private TextLayout function(HELEMENT, const(wchar)[], const(wchar)[]) nothrow _make = &TextLayout.create; // what makes a layout: Sciter's, a test's own
    private Buffer!wchar _clean; // the scratch of `safeText` (memory of the allocator, as the buffers of the table): a NUL (it made Sciter fault) or a CR within a line (words drawn over each other) is laid out cleaned

    this(HELEMENT he, TextLook look, RCIAllocator allocator = mallocAllocator())
    {
        _he = he;
        _look = look;
        _clean = Buffer!wchar(allocator);
        _ascent = new double[look.fonts.length];
        _advance = new double[look.fonts.length];
        _lineHeights = new double[look.fonts.length];
        _layouts = new Generations!(TextKey, TextLayout)(6000, delegate(ref TextLayout layout) nothrow { layout.release(); }, allocator);
    }

    /// What makes a layout of a text and a style: for a test (a fake, no Sciter), the cache makes them by Sciter's own
    void layoutMaker(TextLayout function(HELEMENT, const(wchar)[], const(wchar)[]) nothrow make)
    {
        _make = make;
    }

    /// The text this cache makes layouts of
    ref const(TextLook) look() const
    {
        return _look;
    }

    /// The layouts kept
    size_t count()
    {
        return _layouts.length;
    }

    /// How many layouts are kept at most (both generations: a layout is ~20 KB of memory, .ai/knowledge/sciter.md)
    void limit(size_t layouts)
    {
        _layouts.limit = layouts;
    }

    // The style of a layout, made once for its font, color, kind and width
    private immutable(wchar)[] styleOf(uint font, Color color, bool paragraph, bool measure, int width)
    {
        const key = styleKey(font, color, paragraph ? 2 : measure ? 1 : 0, width);
        if (auto found = key in _styles)
            return *found;
        auto style = makeStyle(font, color, paragraph, measure, width);
        _styles[key] = style;
        return style;
    }

    // `white-space: nowrap` drops the trailing spaces of a text from its width: a piece to measure is `pre`
    private immutable(wchar)[] makeStyle(uint font, Color color, bool paragraph, bool measure, int width)
    {
        import std.format : format;

        const spec = _look.fonts[font];
        const space = paragraph ? "pre-wrap; word-break: break-all"w : measure ? "pre"w : "nowrap"w;
        auto style = format!"white-space: %s; font-size: %gpt;%s font-family: %s; color: #%02x%02x%02x"w(space, spec.sizePt,
            spec.bold ? " font-weight: bold;"w : ""w, spec.family, color.r, color.g, color.b);
        if (paragraph)
            style ~= format!"; width: %dpx"w(width);
        return style;
    }

    /// The layout of a line of `text`; the same for the same arguments while it is kept
    TextLayout line(uint font, Color color, const(wchar)[] text)
    {
        return get(TextKey(font, pack(color), -1, text), color, false, 0);
    }

    /// The layout of a text wrapped in `width` (a width in the style wraps; `setBox` alone does not, 6.0.5.5)
    TextLayout paragraph(uint font, Color color, const(wchar)[] text, double width)
    {
        if (text.length && text[$ - 1] == '\r') // the CR of a line break whose LF was cut off, not one to be seen
            text = text[0 .. $ - 1];
        const w = cast(int) width;
        return get(TextKey(font, pack(color), w, text), color, true, w);
    }

    private static uint pack(Color c) pure nothrow @nogc @safe
    {
        return (cast(uint) c.r << 24) | (cast(uint) c.g << 16) | (cast(uint) c.b << 8) | c.a;
    }

    private TextLayout get(TextKey key, Color color, bool paragraph, int width)
    {
        if (auto found = _layouts.find(key))
            return *found;
        made++;
        const clean = safeText(key.text, _clean);
        if (clean is null && key.text.length)
            return TextLayout.init; // no memory for the cleaned copy: nothing drawn now (a layout of no text would be kept under this key), asked again
        auto layout = _make(_he, clean, styleOf(key.font, color, paragraph, false, width));
        _layouts.keep(key, layout);
        return layout;
    }

    /// The width of a piece of text, spaces at the end counted (not kept)
    double measure(uint font, const(wchar)[] text)
    {
        auto layout = _make(_he, safeText(text, _clean), styleOf(font, _look.ink, false, true, 0));
        const width = layout ? layout.metrics().maxWidth : 0;
        layout.release();
        return width;
    }

    private void read()
    {
        if (_read)
            return;
        _read = true;
        // The advance of a glyph of a monospace font is read off a run of them: Sciter rounds the width of a layout, and the rounding of one
        // glyph, times the length of a text, would move a text aligned to the right of its cell (a time: some pixels) off its edge
        enum run = "0000000000000000000000000000000000000000000000000000000000000000"w;
        foreach (font; 0 .. _look.fonts.length)
        {
            auto layout = _make(_he, run, styleOf(cast(uint) font, _look.ink, false, false, 0)); // a constant of zeros: clean
            const m = layout.metrics();
            _ascent[font] = round(m.ascent);
            _advance[font] = m.maxWidth / run.length;
            _lineHeights[font] = ceil(m.height);
            layout.release();
        }
    }

    double ascent(uint font)
    {
        read();
        return _ascent[font];
    }

    double advance(uint font)
    {
        read();
        return _advance[font];
    }

    /// The line height of a font
    double lineHeight(uint font)
    {
        read();
        return _lineHeights[font];
    }

    /// The line height of the rows: the one of the font of `TextLook.lineFont`
    double lineHeight()
    {
        return lineHeight(_look.lineFont);
    }

    void release()
    {
        _layouts.clear();
    }

    /// The text changed (the fonts, their sizes): what was made and read with the old fonts goes
    void setLook(TextLook look)
    {
        _look = look;
        _ascent = new double[look.fonts.length];
        _advance = new double[look.fonts.length];
        _lineHeights = new double[look.fonts.length];
        _read = false;
        _styles = null;
        release();
    }
}

/// The key of a style of `SciterTextCache`: the font, the color (its alpha is not in a style), the kind (0 a line, 1 a piece to measure,
/// 2 a paragraph) and the width of a paragraph, one number
ulong styleKey(uint font, Color color, uint kind, int width) pure nothrow @nogc @safe
{
    const rgb = (cast(ulong) color.r << 16) | (cast(ulong) color.g << 8) | color.b;
    return (cast(ulong) (font & 0xFF) << 56) | (cast(ulong) (kind & 3) << 54) | (rgb << 22) | (cast(ulong) width & 0x3F_FFFF);
}

@("styleKey: another font, color, kind or width is another key, the alpha of the color is not in it")
unittest
{
    const base = styleKey(1, Color(10, 20, 30, 255), 2, 640);
    assert(styleKey(1, Color(10, 20, 30, 128), 2, 640) == base);
    assert(styleKey(2, Color(10, 20, 30, 255), 2, 640) != base);
    assert(styleKey(1, Color(10, 20, 31, 255), 2, 640) != base);
    assert(styleKey(1, Color(10, 20, 30, 255), 0, 640) != base);
    assert(styleKey(1, Color(10, 20, 30, 255), 2, 641) != base);
    assert(styleKey(255, Color(255, 255, 255, 255), 3, 0x3F_FFFF) != styleKey(255, Color(255, 255, 255, 255), 3, 0x3F_FFFE));
}

// Printable ASCII: one unit, one glyph of the same width in a monospace font. Other text (a surrogate pair, a
// combining mark, a glyph of a fallback font) is measured as a layout.
private bool isPlain(const(wchar)[] text) pure nothrow @nogc @safe
{
    foreach (c; text)
        if (c < 0x20 || c > 0x7E)
            return false;
    return true;
}

private struct WidthKey
{
    uint font;
    const(wchar)[] text;
}

/// Measures text with the layouts of Sciter; what it measured is kept by font and text in two generations (ui/sciter_table/generations)
final class SciterMeasurer : TextMeasurer
{
    /// Widths kept, of both generations: a frame needs the runs it draws and at most `markEvery` before each place it looks for on a long
    /// line (ptable_text/runs keeps marks of them); the first walk of a long line goes through all of its runs once, the words repeated
    enum size_t maxWidths = 100_000;

    private SciterTextCache _cache;
    private Generations!(WidthKey, double) _widths;
    /// Wrap the Payload by the text engine of Sciter (it knows scripts our wrap does not), not by the glyphs
    bool sciterWrap;

    this(SciterTextCache cache)
    {
        _cache = cache;
        _widths = new Generations!(WidthKey, double)(maxWidths);
    }

    FontMetrics metrics(FontId font)
    {
        const line = _cache.lineHeight(font);
        return FontMetrics(_cache.ascent(font), line - _cache.ascent(font), line);
    }

    double width(FontId font, const(wchar)[] text)
    {
        if (text.length == 0)
            return 0;
        if (_cache.look.fonts[font].monospace && isPlain(text))
            return text.length * _cache.advance(font);
        const key = WidthKey(font, text);
        if (auto known = _widths.find(key))
            return *known;
        const result = _cache.measure(font, text);
        _widths.keep(key, result);
        return result;
    }

    int wrappedLines(FontId font, const(wchar)[] text, double width)
    {
        if (!sciterWrap)
            return -1;
        auto layout = _cache.paragraph(font, _cache.look.ink, text, width);
        return layout ? cast(int) max(1u, layout.metrics().lines) : -1; // none (Sciter refused, or no memory): by the glyphs
    }

    /// What was measured is dropped (the fonts changed)
    void forget()
    {
        _widths.clear();
    }
}

/// The canvas of a DRAW event of Sciter
final class SciterCanvas : Canvas
{
    private GfxCanvas _gfx;
    private float _ox = 0, _oy = 0;
    private SciterTextCache _cache;

    this(SciterTextCache cache)
    {
        _cache = cache;
    }

    /// Draws on `gfx` with (0, 0) of the table at (`ox`, `oy`) of it
    void begin(GfxCanvas gfx, float ox, float oy)
    {
        _gfx = gfx;
        _ox = ox;
        _oy = oy;
    }

    void fillRect(Rect area, Color color)
    {
        _gfx.fillRect(_ox + cast(float) area.x, _oy + cast(float) area.y, cast(float) area.w, cast(float) area.h,
            rgba(color.r, color.g, color.b, color.a));
    }

    void drawText(FontId font, const(wchar)[] text, double x, double baseline, Color color)
    {
        if (text.length == 0)
            return;
        auto layout = _cache.line(font, color, text);
        if (layout)
            _gfx.drawText(layout, _ox + cast(float) x, _oy + cast(float)(baseline - _cache.ascent(font)));
    }

    void drawParagraph(FontId font, const(wchar)[] text, double x, double top, double width, Color color)
    {
        auto layout = _cache.paragraph(font, color, text, width);
        if (layout)
            _gfx.drawText(layout, _ox + cast(float) x, _oy + cast(float) top);
    }

    void fillCircle(double cx, double cy, double radius, Color fill, Color line)
    {
        _gfx.circle(_ox + cast(float) cx, _oy + cast(float) cy, cast(float) radius, rgba(fill.r, fill.g, fill.b, fill.a),
            rgba(line.r, line.g, line.b, line.a));
    }

    void fillRoundRect(Rect area, double radius, Color color)
    {
        _gfx.fillRoundRect(_ox + cast(float) area.x, _oy + cast(float) area.y, cast(float) area.w, cast(float) area.h, cast(float) radius,
            rgba(color.r, color.g, color.b, color.a));
    }

    void pushClip(Rect area)
    {
        _gfx.pushClip(_ox + cast(float) area.x, _oy + cast(float) area.y, cast(float) area.w, cast(float) area.h);
    }

    void popClip()
    {
        _gfx.popClip();
    }
}

@("SciterTextCache: a layout is made of the text cleaned by safeText (measured and kept alike), the key stays the raw text")
unittest
{
    static const(wchar)[][] made;
    static TextLayout fake(HELEMENT, const(wchar)[] text, const(wchar)[]) nothrow
    {
        made ~= text.idup;
        return TextLayout.init;
    }

    made = null;
    auto cache = new SciterTextCache(null, TextLook([FontSpec("monospace"w, 10, false, true)], Color(0, 0, 0, 255), 0));
    cache.layoutMaker = &fake;
    cache.line(0, Color(0, 0, 0, 255), "a\0b\n"w);
    cache.line(0, Color(0, 0, 0, 255), "a\0b\n"w); // kept: not made again
    cache.paragraph(0, Color(0, 0, 0, 255), "x\vy"w, 100);
    cache.measure(0, "\u0085z"w);
    assert(made == ["a\u2400b\n"w, "x\u240By"w, "\uFFFDz"w]);
}

@("SciterTextCache: a paragraph is laid out without a CR at its very end, a CR within it is seen")
unittest
{
    static const(wchar)[][] made;
    static TextLayout fake(HELEMENT, const(wchar)[] text, const(wchar)[]) nothrow
    {
        made ~= text.idup;
        return TextLayout.init;
    }

    made = null;
    auto cache = new SciterTextCache(null, TextLook([FontSpec("monospace"w, 10, false, true)], Color(0, 0, 0, 255), 0));
    cache.layoutMaker = &fake;
    cache.paragraph(0, Color(0, 0, 0, 255), "a\rb\r\nc\r"w, 100);
    assert(made == ["a\u240Db\r\nc"w]);
}

@("SciterTextCache: no memory for the cleaned copy of a text: no layout is made or kept, the next ask makes it")
unittest
{
    import std.experimental.allocator : allocatorObject;
    import std.experimental.allocator.mallocator : Mallocator;

    static struct Failing // gives memory until told not to
    {
        bool fail;
        enum uint alignment = Mallocator.alignment;
        void[] allocate(size_t n) pure nothrow @nogc @trusted { return fail ? null : Mallocator.instance.allocate(n); }
        bool deallocate(void[] b) pure nothrow @nogc @trusted { return Mallocator.instance.deallocate(b); }
    }

    static size_t made;
    static TextLayout fake(HELEMENT, const(wchar)[], const(wchar)[]) nothrow
    {
        ++made;
        return TextLayout.init;
    }

    Failing failing;
    made = 0;
    auto cache = new SciterTextCache(null, TextLook([FontSpec("monospace"w, 10, false, true)], Color(0, 0, 0, 255), 0), allocatorObject(&failing));
    cache.layoutMaker = &fake;
    failing.fail = true;
    cache.line(0, Color(0, 0, 0, 255), "a\0b"w);
    assert(made == 0, "no text to make a layout of: none made");
    assert(cache.count == 0, "none kept");
    failing.fail = false;
    cache.line(0, Color(0, 0, 0, 255), "a\0b"w);
    assert(made == 1 && cache.count == 1, "asked again, made and kept");
}
