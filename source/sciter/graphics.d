//! A thin layer over the graphics API of Sciter (capi/graphics.d) for a native behavior: the
//! canvas of a DRAW event (rectangles, clips, text layouts) and the text layouts themselves
//! (sciter-x-graphics.h: textCreateForElementAndStyle, textGetMetrics, textSetBox, gDrawText).
module sciter.graphics;

import sciter.api : graphicsApi;
import sciter.capi.graphics;
import sciter.capi.types;

/// The size of a laid out text, in dips
struct TextMetrics
{
    float minWidth = 0, maxWidth = 0, height = 0, ascent = 0, descent = 0;
    uint lines;
}

/// A text layout of Sciter: made for an element (its style is the base) and a style
/// declaration; owned, released by `release()` (no destructor: the cache decides when)
struct TextLayout
{
    HTEXT handle;

    bool opCast(T : bool)() const pure nothrow @nogc @safe
    {
        return handle !is null;
    }

    /// The layout of `text` styled as `style` ("font-size: 8pt; color: #333") over the style of
    /// element `he`; null (false) if Sciter refuses
    static TextLayout create(HELEMENT he, const(wchar)[] text, const(wchar)[] style) nothrow @nogc
    {
        TextLayout layout;
        const result = graphicsApi().textCreateForElementAndStyle(&layout.handle, text.ptr, cast(UINT) text.length, he,
            style.ptr, cast(UINT) style.length);
        if (result != GRAPHIN_RESULT.GRAPHIN_OK)
            layout.handle = null;
        return layout;
    }

    void release() nothrow @nogc
    {
        if (handle !is null)
            graphicsApi().textRelease(handle);
        handle = null;
    }

    TextMetrics metrics() nothrow @nogc
    {
        TextMetrics m;
        graphicsApi().textGetMetrics(handle, &m.minWidth, &m.maxWidth, &m.height, &m.ascent, &m.descent, &m.lines);
        return m;
    }

    /// Wraps the text in a box (a width of 0 or less: no wrapping)
    void setBox(float width, float height) nothrow @nogc
    {
        graphicsApi().textSetBox(handle, width, height);
    }
}

/// The canvas of a DRAW event
struct Canvas
{
    HGFX handle;

    /// A filled rectangle of the left top corner (x, y) and the size (w, h), with no outline
    void fillRect(float x, float y, float w, float h, SC_COLOR color) nothrow @nogc
    {
        auto api = graphicsApi();
        api.gLineWidth(handle, 0);
        api.gFillColor(handle, color);
        api.gRectangle(handle, x, y, x + w, y + h);
    }

    /// A filled rectangle as `fillRect` with its corners rounded by `radius`
    void fillRoundRect(float x, float y, float w, float h, float radius, SC_COLOR color) nothrow @nogc
    {
        auto api = graphicsApi();
        const SC_DIM[8] radii = radius;
        api.gLineWidth(handle, 0);
        api.gFillColor(handle, color);
        api.gRoundedRectangle(handle, x, y, x + w, y + h, radii.ptr);
    }

    /// Text drawn with its top left corner at (x, y)
    void drawText(TextLayout text, float x, float y) nothrow @nogc
    {
        graphicsApi().gDrawText(handle, text.handle, x, y, TEXT_POSITION.topLeft);
    }

    /// A circle of the center (cx, cy) and `radius`, filled and outlined 1 dip wide
    void circle(float cx, float cy, float radius, SC_COLOR fill, SC_COLOR line) nothrow @nogc
    {
        auto api = graphicsApi();
        api.gStateSave(handle); // the line and the fill colors of the circle must not stay for what is drawn after it
        api.gLineWidth(handle, 1);
        api.gLineColor(handle, line);
        api.gFillColor(handle, fill);
        api.gEllipse(handle, cx, cy, radius, radius);
        api.gStateRestore(handle);
    }

    void pushClip(float x, float y, float w, float h) nothrow @nogc
    {
        graphicsApi().gPushClipBox(handle, x, y, x + w, y + h, 1.0f);
    }

    void popClip() nothrow @nogc
    {
        graphicsApi().gPopClip(handle);
    }
}

/// The color of the given bytes (0..255), alpha 255 unless given
SC_COLOR rgba(uint r, uint g, uint b, uint a = 255) nothrow @nogc
{
    return graphicsApi().RGBA(r, g, b, a);
}
