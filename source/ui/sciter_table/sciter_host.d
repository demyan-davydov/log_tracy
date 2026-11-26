//! Everything a log table needs from Sciter's element, text and graphics, as one unit: the element it is drawn in
//! (repaint, capture, a frame), the cache of text layouts, the measurer and the canvas that read it, and the clipboard.
//! The element is kept once and handed to those that need it; a change of the fonts is one call, which drops what was
//! measured with the old ones in the order that matters. It knows nothing of the log. Needs Sciter to run, so it is
//! checked by the build and by looking at the table.
module ui.sciter_table.sciter_host;

import ptable.ports : Canvas, Clipboard, Rect;
import ptable_text.measurer : TextMeasurer;
import sciter.api : sciterApi;
import sciter.capi.api;
import sciter.graphics : GfxCanvas = Canvas;
import ui.look : TextLook;
import ui.sciter_table.host : CopyTaker, SciterCanvas, SciterMeasurer, SciterTextCache, ScriptClipboard;

final class SciterHost
{
    private HELEMENT _he;
    private SciterTextCache _cache;
    private SciterMeasurer _measurer;
    private SciterCanvas _canvas;
    private ScriptClipboard _clipboard;

    /// `copied` takes the text of a copy to the clipboard
    this(HELEMENT he, TextLook look, CopyTaker copied)
    {
        _he = he;
        _cache = new SciterTextCache(he, look);
        _measurer = new SciterMeasurer(_cache);
        _canvas = new SciterCanvas(_cache);
        _clipboard = new ScriptClipboard(copied);
    }

    /// The fonts changed: what was made and measured with the old ones is dropped, the cache first
    void setLook(TextLook look)
    {
        _cache.setLook(look);
        _measurer.forget();
    }

    /// The layouts go back to the memory they came from
    void release()
    {
        _cache.release();
    }

    // ---- what the table is given ----

    TextMeasurer measurer() { return _measurer; }
    Clipboard clipboard() { return _clipboard; }

    /// The canvas of a draw event of Sciter: (0, 0) of the table at (`ox`, `oy`) of `gfx`
    Canvas canvas(GfxCanvas gfx, float ox, float oy)
    {
        _canvas.begin(gfx, ox, oy);
        return _canvas;
    }

    // ---- the element ----

    /// The element is to be drawn again
    void repaint()
    {
        RECT area;
        if (sciterApi().SciterGetElementLocation(_he, &area, ELEMENT_AREAS.ROOT_RELATIVE | ELEMENT_AREAS.BORDER_BOX) == SCDOM_OK)
            sciterApi().SciterRefreshElementArea(_he, area);
    }

    /// Only `area` of the element (the table's coordinates) is to be drawn again
    void repaintArea(Rect area)
    {
        RECT box;
        if (sciterApi().SciterGetElementLocation(_he, &box, ELEMENT_AREAS.ROOT_RELATIVE | ELEMENT_AREAS.BORDER_BOX) != SCDOM_OK)
            return;
        RECT part;
        part.left = box.left + cast(int) area.x;
        part.top = box.top + cast(int) area.y;
        part.right = box.left + cast(int)(area.x + area.w + 1);
        part.bottom = box.top + cast(int)(area.y + area.h + 1);
        sciterApi().SciterRefreshElementArea(_he, part);
    }

    /// The element takes the mouse even outside it (`on`) or lets it go
    void capture(bool on)
    {
        if (on)
            sciterApi().SciterSetCapture(_he);
        else
            sciterApi().SciterReleaseCapture(_he);
    }

    /// The element is drawn at once, not at the next frame
    void updateNow()
    {
        sciterApi().SciterUpdateElement(_he, true);
    }

    /// Sciter sends the element `eventCode` at its next animation frame
    void requestFrame(uint eventCode)
    {
        sciterApi().SciterRequestAnimationFrameEvent(_he, eventCode, 0);
    }

    // ---- for the checks of the script ----

    /// Wrap the Payload by the text engine of Sciter, not by the glyphs
    bool sciterWrap() const { return _measurer.sciterWrap; }
    void sciterWrap(bool on) { _measurer.sciterWrap = on; }

    /// The layouts the cache keeps (both generations)
    void textLimit(size_t layouts) { _cache.limit = layouts; }

    /// The layouts made so far and those kept
    size_t textsMade() const { return _cache.made; }
    size_t textsKept() { return _cache.count; }
}
