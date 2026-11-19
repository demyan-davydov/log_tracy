//! The host of the log table (ptable) in Sciter: its canvas, text measurer and clipboard over the
//! graphics API of Sciter (sciter/graphics). The fonts and the ink come as a `TextLook` (ui/look): this layer
//! knows nothing of the log. The text layouts are kept in two generations (a layout of Sciter is what the memory of a log table
//! is). See docs/experiments/2026-11-19-painted-rows-d.md.
module ui.sciter_table.host;

import ptable.memory : Arena, HashMap, mallocAllocator;
import ptable.ports;
import ptable_text.measurer : FontMetrics, TextMeasurer;
import std.experimental.allocator : RCIAllocator;
import sciter.api : sciterApi;
import sciter.capi.api;
import sciter.graphics : GfxCanvas = Canvas, TextLayout, rgba;
import sciter.value : SciterValue;
import ui.look : FontSpec, TextLook;

import std.algorithm.comparison : max;
import std.math : ceil, round;

private struct TextKey
{
    uint font;
    uint rgba;
    int width; // of a paragraph, -1 for a line
    const(wchar)[] text;
}

// One generation of the layouts: the layouts, and the memory the texts of their keys are in
private struct Generation
{
    Arena arena;
    HashMap!(TextKey, TextLayout) layouts;

    this(RCIAllocator allocator)
    {
        arena = Arena(allocator);
        layouts = HashMap!(TextKey, TextLayout)(allocator);
    }

    void releaseLayouts()
    {
        foreach (ref const TextKey key, ref TextLayout layout; layouts)
            layout.release();
        layouts.clear();
        arena.reset();
    }
}

/// The text layouts of a table: made on demand for a font, a color and a text, kept in two generations. The keys
/// and the maps are in memory of the allocator given, the garbage collector is not asked for a lookup.
final class SciterTextCache
{
    private HELEMENT _he;
    private Generation[2] _generations;
    private size_t _current;
    private immutable(wchar)[][ulong] _styles; // by font, color and kind: made on a miss only
    size_t limit = 3000; /// layouts a generation keeps
    size_t made; /// layouts made so far
    private TextLook _look;
    private double[] _ascent, _advance;
    private double[] _lineHeights;
    private bool _read;

    this(HELEMENT he, TextLook look, RCIAllocator allocator = mallocAllocator())
    {
        _he = he;
        _look = look;
        _ascent = new double[look.fonts.length];
        _advance = new double[look.fonts.length];
        _lineHeights = new double[look.fonts.length];
        _generations[0] = Generation(allocator);
        _generations[1] = Generation(allocator);
    }

    void element(HELEMENT he)
    {
        _he = he;
    }

    /// The text this cache makes layouts of
    ref const(TextLook) look() const
    {
        return _look;
    }

    size_t count()
    {
        return _generations[0].layouts.length + _generations[1].layouts.length;
    }

    // `white-space: nowrap` drops the trailing spaces of a text from its width: a piece to measure is `pre`
    private immutable(wchar)[] styleOf(uint font, Color color, bool paragraph, bool measure, int width)
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
        const w = cast(int) width;
        return get(TextKey(font, pack(color), w, text), color, true, w);
    }

    private static uint pack(Color c) pure nothrow @nogc @safe
    {
        return (cast(uint) c.r << 24) | (cast(uint) c.g << 16) | (cast(uint) c.b << 8) | c.a;
    }

    private TextLayout get(TextKey key, Color color, bool paragraph, int width)
    {
        auto now = &_generations[_current];
        if (auto found = key in now.layouts)
            return *found;
        auto before = &_generations[1 - _current];
        if (auto old = key in before.layouts)
        {
            auto layout = *old;
            before.layouts.remove(key);
            key.text = now.arena.copy(key.text);
            now.layouts.set(key, layout);
            return layout;
        }
        if (now.layouts.length >= limit)
        {
            before.releaseLayouts(); // the older generation goes, the current becomes the older
            _current = 1 - _current;
            now = &_generations[_current];
        }
        made++;
        auto layout = TextLayout.create(_he, key.text, styleOf(key.font, color, paragraph, false, width));
        key.text = now.arena.copy(key.text);
        now.layouts.set(key, layout);
        return layout;
    }

    /// The width of a piece of text, spaces at the end counted (not kept)
    double measure(uint font, const(wchar)[] text)
    {
        auto layout = TextLayout.create(_he, text, styleOf(font, _look.ink, false, true, 0));
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
            auto layout = TextLayout.create(_he, run, styleOf(cast(uint) font, _look.ink, false, false, 0));
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
        foreach (ref g; _generations)
            g.releaseLayouts();
    }

    /// The text changed (the fonts, their sizes): what was made and read with the old fonts goes
    void setLook(TextLook look)
    {
        _look = look;
        _ascent = new double[look.fonts.length];
        _advance = new double[look.fonts.length];
        _lineHeights = new double[look.fonts.length];
        _read = false;
        release();
    }
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

/// Measures text with the layouts of Sciter
final class SciterMeasurer : TextMeasurer
{
    private SciterTextCache _cache;
    private double[wstring][] _widths;
    /// Wrap the Payload by the text engine of Sciter (it knows scripts our wrap does not), not by the glyphs
    bool sciterWrap;

    this(SciterTextCache cache)
    {
        _cache = cache;
        _widths = new double[wstring][cache.look.fonts.length];
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
        auto key = cast(wstring) text;
        if (auto found = key in _widths[font])
            return *found;
        if (_widths[font].length > 20_000)
            _widths[font] = null;
        const result = _cache.measure(font, text);
        _widths[font][text.idup] = result;
        return result;
    }

    int wrappedLines(FontId font, const(wchar)[] text, double width)
    {
        if (!sciterWrap)
            return -1;
        return cast(int) max(1u, _cache.paragraph(font, _cache.look.ink, text, width).metrics().lines);
    }

    /// What was measured is dropped (the fonts changed)
    void forget()
    {
        _widths = new double[wstring][_cache.look.fonts.length];
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

    void pushClip(Rect area)
    {
        _gfx.pushClip(_ox + cast(float) area.x, _oy + cast(float) area.y, cast(float) area.w, cast(float) area.h);
    }

    void popClip()
    {
        _gfx.popClip();
    }
}

/// Calls the global function `name` of the script of the window of `he` with a text; what it answers is dropped
void callScript(HELEMENT he, const(char)* name, const(wchar)[] text)
{
    HWINDOW hwnd;
    if (sciterApi().SciterGetElementHwnd(he, &hwnd, true) != SCDOM_OK)
        return;
    SciterValue arg;
    arg = text.idup;
    SciterValue result;
    sciterApi().SciterCall(hwnd, name, 1, arg.raw, result.raw);
}

/// The clipboard of Sciter belongs to the script: the text goes to its `logTableCopy`
final class ScriptClipboard : Clipboard
{
    private HELEMENT _he;

    this(HELEMENT he)
    {
        _he = he;
    }

    void element(HELEMENT he)
    {
        _he = he;
    }

    void writeText(const(wchar)[] text)
    {
        callScript(_he, "logTableCopy", text);
    }
}
