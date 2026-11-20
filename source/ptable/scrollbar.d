//! A scroll bar of the log table, an optional layer above it: the thumb's geometry, a press and a drag
//! of the mouse turned into a fraction, and the drawing through a painter of its own (`ScrollBar`), and
//! (`ScrolledTable`, in its own module, puts the table together with it). The table and the viewport know none of it: they give
//! `ScrollMetrics` and take `scrollToFraction`; a host may use this bar or connect its own (a native one)
//! to the same two. Pure. See docs/stories/painted-table.md.
module ptable.scrollbar;

import ptable.ports;
import ptable.rowpicks : Pick;
import ptable.transition : Transition;
import ptable.viewport : ScrollMetrics;

import std.algorithm.comparison : max, min;
import std.math : isNaN;

/// The thumb of a bar on a track
struct Thumb
{
    bool visible;
    double top = 0, size = 0;
}

/// The thumb of a bar on a track: where it stands and what a press or a drag of the mouse scrolls to. From a press to
/// the release the thumb keeps the size it had: the rows change under a drag (taller, more of them), the thumb stays under
/// the mouse
struct ScrollThumb
{
    double minSize = 24; /// the least size of the thumb
    private double _grab = 0, _size = 0;
    private bool _dragging;

    /// Whether a drag is on
    bool dragging() const pure nothrow @nogc @safe
    {
        return _dragging;
    }

    /// Where the thumb stands on a track `track` long for the metrics: not visible if there is nothing to scroll
    Thumb thumb(ScrollMetrics metrics, double track) const pure nothrow @nogc @safe
    {
        if (!(metrics.shown < 1) || !(track > 0))
            return Thumb.init;
        const size = _dragging ? _size : min(track, max(minSize, track * metrics.shown));
        return Thumb(true, (track - size) * max(0.0, min(1.0, metrics.fraction)), size);
    }

    /// A press at `y` of the track: a press on the thumb grabs it where it was pressed, a press beside it
    /// takes the middle of the thumb there. Returns the fraction to scroll to, NaN if there is nothing to scroll.
    double press(ScrollMetrics metrics, double track, double y) pure nothrow @nogc @safe
    {
        const bar = thumb(metrics, track);
        if (!bar.visible)
            return double.nan;
        _grab = y < bar.top || y > bar.top + bar.size ? bar.size / 2 : y - bar.top;
        _size = bar.size;
        _dragging = true;
        return drag(metrics, track, y);
    }

    /// The mouse is at `y` of the track while the thumb is dragged: the fraction to scroll to, NaN if not dragging
    double drag(ScrollMetrics metrics, double track, double y) const pure nothrow @nogc @safe
    {
        if (!_dragging || !(metrics.shown < 1))
            return double.nan;
        const room = track - _size;
        if (!(room > 0))
            return 0;
        return max(0.0, min(1.0, (y - _grab) / room));
    }

    void release() pure nothrow @nogc @safe
    {
        _dragging = false;
    }
}

/// How long a bar takes to widen under the mouse or to narrow back, in milliseconds (the user, 2026-11-20: about twice as fast as
/// the pool of rows' 300, tuned by eye)
enum double wideningMs = 170;

/// Which way a bar lies: along the rows (at the right edge) or along the columns (at the bottom)
enum Orientation : ubyte
{
    vertical,
    horizontal,
}

/// How a bar looks. The default is a plain one; a host draws its own by overriding `paint`. The bar lies over the edge of the
/// rows: what it does not draw shows them.
class ScrollBarPainter
{
    /// Draws the strip of the bar (`strip` is all of it, `track` the part the thumb runs along); `thumb` is
    /// the rectangle of the thumb, empty if there is nothing to scroll; `wide` how far it has widened under the mouse, 0 .. 1
    void paint(Canvas canvas, Rect strip, Rect track, Rect thumb, double wide, Orientation orientation = Orientation.vertical)
    {
        const color = Color(60, 60, 60, cast(ubyte)(115 + 64 * wide));
        if (thumb.w > 0 && thumb.h > 0)
            canvas.fillRect(orientation == Orientation.vertical ? Rect(thumb.x + 2, thumb.y, thumb.w - 4, thumb.h)
                : Rect(thumb.x, thumb.y + 2, thumb.w, thumb.h - 4), color);
    }

    /// Draws the badge that turns following the end on and off (`ScrolledTable` places it under the bar): `on` while the table follows its
    /// end, `wide` as in `paint`
    void paintBadge(Canvas canvas, Rect area, bool on, double wide)
    {
        canvas.fillRect(area, on ? Color(60, 60, 60, 204) : Color(60, 60, 60, cast(ubyte)(77 + 64 * wide)));
    }

    /// Draws a vertical bar pinned to the end of a table that follows it together with its badge `badge` under it, so that a painter may join
    /// them into one thumb; by default they are drawn apart, as `paint` and `paintBadge` (on) would
    void paintPinned(Canvas canvas, Rect strip, Rect track, Rect thumb, Rect badge, double wide)
    {
        paint(canvas, strip, track, thumb, wide, Orientation.vertical);
        paintBadge(canvas, badge, true, wide);
    }
}

/// A scroll bar: a strip at one edge of a table, which the host places and feeds with the mouse
final class ScrollBar
{
    /// What the bar tells: the position to scroll to, the mouse to capture, a paint again
    struct Events
    {
        void delegate(double fraction) scrollTo; /// 0 .. 1
        void delegate(bool on) capture;
        void delegate() invalidate;
        void delegate() needFrame; /// the bar is widening or narrowing: `tick` at the next frame
    }

    Events events;
    double width = 10; /// of the strip (its thickness: the width of a vertical bar, the height of a horizontal one)
    Orientation orientation; /// along the rows (default) or along the columns
    /// The table follows its end (the host says so): a press on the thumb holds it where it is until the mouse goes `snapOff` up from the press,
    /// so that a drag that only touches it does not turn the following off; pinned under a drag, the thumb is held from where the mouse is
    bool pinned() const
    {
        return _pinned;
    }

    void pinned(bool on)
    {
        _pinned = on;
        _heldAt = on && _thumb.dragging ? _lastAt : double.nan;
        widen(); // a pinned bar stays wide: its thumb and the badge under it are one
    }
    /// How far up from the press a pinned thumb is pulled before it comes off, in dips. A trial value, to be tuned by eye
    double snapOff = 24;

    private ScrollBarPainter _painter;
    private ScrollThumb _thumb;
    private ScrollMetrics _metrics;
    private bool _hover;
    private bool _enabled = true;
    private bool _pinned;
    private double _lastAt = 0; // where the mouse was on the track at the last press or move of a drag
    private double _heldAt = double.nan; // a pinned thumb was pressed here, on the track: it stays until the mouse goes `snapOff` up from it
    private Transition _wide = Transition(wideningMs); // 1: wide under the mouse or held, 0: thin

    this(ScrollBarPainter painter = new ScrollBarPainter)
    {
        _painter = painter;
    }

    /// The table scrolled or changed its count
    void update(ScrollMetrics metrics)
    {
        _metrics = metrics;
        if (!shown)
            forget();
    }

    /// A bar turned off is not there: not drawn, the mouse goes to the rows under it
    bool enabled() const { return _enabled; }

    void enabled(bool on)
    {
        _enabled = on;
        if (!shown)
            forget();
    }

    /// Whether the bar is there: turned on and something to scroll
    bool shown() const
    {
        return _enabled && _metrics.shown < 1;
    }

    // The bar is gone: a drag of its thumb is over, the mouse it had is let go of, and it comes back thin
    private void forget()
    {
        if (_thumb.dragging)
        {
            _thumb.release();
            if (events.capture !is null)
                events.capture(false);
        }
        _heldAt = double.nan;
        _hover = false;
        _wide.set(0);
    }

    bool dragging() const
    {
        return _thumb.dragging;
    }

    void hover(bool on)
    {
        on = on && shown; // a bar not there is under no mouse
        if (on == _hover)
            return;
        _hover = on;
        widen();
    }

    // Wide while the mouse is over it, its thumb is held or it is pinned: on the way there at the next frames
    private void widen()
    {
        if (_wide.to(_hover || _thumb.dragging || _pinned ? 1 : 0) && events.needFrame !is null)
            events.needFrame();
    }

    /// A frame at `nowMs` (the host's clock): the bar widens or narrows on; true while it is still on its way
    bool tick(double nowMs)
    {
        const before = _wide.value;
        const more = _wide.tick(nowMs);
        if (_wide.value != before)
            invalidate();
        return more;
    }

    private void invalidate()
    {
        if (events.invalidate !is null)
            events.invalidate();
    }

    private void scrollTo(double fraction)
    {
        if (!isNaN(fraction) && events.scrollTo !is null)
            events.scrollTo(fraction);
    }

    // Where `along` (y of a vertical bar, x of a horizontal one) is on the track, and how long the track is
    private double onTrack(double along, Rect track) const
    {
        return along - (orientation == Orientation.vertical ? track.y : track.x);
    }

    private double length(Rect track) const
    {
        return orientation == Orientation.vertical ? track.h : track.w;
    }

    /// A press of the main button at `along` (y of a vertical bar, x of a horizontal one), the track beginning where `track`
    /// does: true if it took it (the bar always does)
    bool mouseDown(double along, Rect track)
    {
        const at = onTrack(along, track), bar = _thumb.thumb(_metrics, length(track));
        const fraction = _thumb.press(_metrics, length(track), at);
        _lastAt = at;
        if (_pinned && bar.visible && at >= bar.top && at <= bar.top + bar.size)
            _heldAt = at; // the thumb is taken where it stands: no scroll yet
        else
            scrollTo(fraction);
        if (_thumb.dragging && events.capture !is null)
            events.capture(true);
        widen();
        return true;
    }

    /// The mouse moved while the thumb is dragged
    bool mouseMove(double along, Rect track)
    {
        if (!_thumb.dragging)
            return false;
        const at = onTrack(along, track);
        _lastAt = at;
        if (!isNaN(_heldAt))
        {
            if (_heldAt - at <= snapOff)
                return true; // held: not pulled far enough up
            _heldAt = double.nan; // it comes off and follows the mouse from here
        }
        scrollTo(_thumb.drag(_metrics, length(track), at));
        return true;
    }

    bool mouseUp()
    {
        if (!_thumb.dragging)
            return false;
        _thumb.release();
        _heldAt = double.nan;
        if (events.capture !is null)
            events.capture(false);
        widen();
        invalidate();
        return true;
    }

    /// Draws the bar in `strip`, its track being `track`, and the badge of following the end in `badge` (empty: none), on while the thumb is
    /// pinned (the painter may join them then)
    void paint(Canvas canvas, Rect strip, Rect track, Rect badge = Rect.init)
    {
        if (!shown)
            return;
        const thumb = _thumb.thumb(_metrics, length(track));
        Rect rect;
        if (thumb.visible)
            rect = orientation == Orientation.vertical ? Rect(strip.x, track.y + thumb.top, strip.w, thumb.size)
                : Rect(track.x + thumb.top, strip.y, thumb.size, strip.h);
        const hasBadge = badge.w > 0 && badge.h > 0;
        if (hasBadge && _pinned && orientation == Orientation.vertical)
            return _painter.paintPinned(canvas, strip, track, rect, badge, _wide.value);
        _painter.paint(canvas, strip, track, rect, _wide.value, orientation);
        if (hasBadge)
            _painter.paintBadge(canvas, badge, false, _wide.value);
    }
}

@("ScrollThumb: the thumb is as long as the part in view, at least the least, and stands by the fraction")
unittest
{
    ScrollThumb bar;
    const top = bar.thumb(ScrollMetrics(0, 0.01), 200);
    assert(top.visible && top.top == 0 && top.size == 24, "1% of 200 is 2: the least");
    assert(bar.thumb(ScrollMetrics(1, 0.01), 200).top == 200 - 24, "the end: at the bottom");
    assert(bar.thumb(ScrollMetrics(0.5, 0.25), 200) == Thumb(true, 75, 50));
    assert(bar.thumb(ScrollMetrics(0.5, 0.2501), 200).size - 50 < 0.1, "a part in view a little larger: a thumb a little longer, no step");
    assert(!bar.thumb(ScrollMetrics(0, 1), 200).visible, "all in view: no thumb");
}

@("ScrollThumb: a press on the thumb grabs it, a press beside takes its middle, a drag moves the fraction; the end of the track is 1")
unittest
{
    ScrollThumb bar;
    const metrics = ScrollMetrics(0, 0.01);
    const track = 200.0;
    assert(bar.press(metrics, track, 10) == 0 && bar.dragging);
    assert(bar.drag(metrics, track, 98) == 0.5, "88 of 176");
    assert(bar.drag(metrics, track, 500) == 1 && bar.drag(metrics, track, -50) == 0, "past the track: the ends");
    bar.release();
    assert(!bar.dragging && isNaN(bar.drag(metrics, track, 110)), "NaN after release");
    assert(bar.press(metrics, track, 100) == 0.5, "the thumb's middle at 100: its top at 88 of 176");
}

@("ScrollThumb: the thumb keeps its size from the press to the release while what is in view changes")
unittest
{
    ScrollThumb bar;
    const track = 200.0;
    bar.press(ScrollMetrics(0, 0.25), track, 10); // a thumb of 50: 150 to run
    assert(bar.drag(ScrollMetrics(0.2, 0.5), track, 85) == 0.5, "by the size at the press: 75 of 150");
    assert(bar.thumb(ScrollMetrics(0.5, 0.5), track) == Thumb(true, 75, 50), "drawn at the mouse, as long as at the press");
    bar.release();
    assert(bar.thumb(ScrollMetrics(0.5, 0.5), track).size == 100, "released: by what is in view");
}

@("ScrollThumb: nothing to scroll gives no fraction and starts no drag")
unittest
{
    ScrollThumb bar;
    assert(isNaN(bar.press(ScrollMetrics(0, 1), 200, 5)) && !bar.dragging);
    assert(isNaN(bar.drag(ScrollMetrics(0, 0.01), 200, 5)), "not dragging");
}

@("ScrollBar: the mouse over it widens it over the frames it asks of the host, away narrows it back; a held thumb stays wide")
unittest
{
    static class Wide : ScrollBarPainter
    {
        double wide = -1;
        override void paint(Canvas canvas, Rect strip, Rect track, Rect thumb, double wide, Orientation orientation = Orientation.vertical)
        {
            this.wide = wide;
        }
    }

    auto look = new Wide;
    auto bar = new ScrollBar(look);
    int frames, paints;
    bar.events.needFrame = () { ++frames; };
    bar.events.invalidate = () { ++paints; };
    bar.events.scrollTo = (double) {};
    bar.update(ScrollMetrics(0, 0.1));
    const strip = Rect(0, 0, 12, 200);
    bar.paint(null, strip, strip);
    assert(look.wide == 0, "thin at rest");
    bar.hover(true);
    assert(frames == 1, "the host is asked for frames");
    bar.tick(0);
    assert(bar.tick(150) && paints > 0, "on its way: painted again, more frames");
    bar.paint(null, strip, strip);
    assert(look.wide > 0 && look.wide < 1);
    bar.tick(250);
    assert(!bar.tick(350), "there in its time");
    bar.paint(null, strip, strip);
    assert(look.wide == 1, "wide");
    bar.mouseDown(5, strip); // the thumb is taken
    bar.hover(false); // the mouse left the strip while dragging
    assert(!bar.tick(500) && !bar.tick(600), "held: stays wide");
    bar.mouseUp();
    bar.tick(700);
    assert(bar.tick(800), "released away from it: narrows");
}

@("ScrollBar: a bar that goes (nothing to scroll, turned off) under the mouse forgets it: it comes back thin")
unittest
{
    static class Wide : ScrollBarPainter
    {
        double wide = -1;
        override void paint(Canvas canvas, Rect strip, Rect track, Rect thumb, double wide, Orientation orientation = Orientation.vertical)
        {
            this.wide = wide;
        }
    }

    auto look = new Wide;
    auto bar = new ScrollBar(look);
    int frames;
    bar.events.needFrame = () { ++frames; };
    const strip = Rect(0, 0, 12, 200);
    void widen(double from)
    {
        bar.hover(true);
        foreach (i; 0 .. 5)
            bar.tick(from + 100 * i);
    }

    bar.update(ScrollMetrics(0, 0.1));
    widen(0);
    bar.update(ScrollMetrics(0, 1)); // everything fits
    bar.update(ScrollMetrics(0, 0.1));
    bar.paint(null, strip, strip);
    assert(look.wide == 0, "back thin");
    frames = 0;
    bar.update(ScrollMetrics(0, 1));
    bar.hover(true);
    assert(frames == 0, "a bar not there asks for no frames");

    bar.update(ScrollMetrics(0, 0.1));
    widen(1000);
    bar.enabled = false;
    bar.enabled = true;
    bar.paint(null, strip, strip);
    assert(look.wide == 0, "turned off and on: thin");
}

@("ScrollBar: a pinned thumb stays under a drag until the mouse has gone `snapOff` up from the press, then follows it; down it stays")
unittest
{
    auto bar = new ScrollBar;
    double[] scrolled;
    bar.events.scrollTo = (double fraction) { scrolled ~= fraction; };
    bar.update(ScrollMetrics(1, 0.1)); // at the end: the thumb of 24 stands at 176 .. 200
    bar.pinned = true;
    const strip = Rect(0, 0, 12, 200);
    assert(bar.mouseDown(190, strip) && bar.dragging && scrolled.length == 0, "the press on the thumb holds it: no scroll");
    bar.mouseMove(250, strip);
    bar.mouseMove(190 - bar.snapOff + 1, strip);
    assert(scrolled.length == 0, "down, or up less than snapOff: it stays");
    bar.mouseMove(190 - bar.snapOff - 1, strip);
    assert(scrolled.length == 1 && scrolled[0] < 1, "past snapOff: it comes off, under the mouse");
    bar.mouseMove(150, strip);
    assert(scrolled.length == 2, "and follows the mouse from then");
    bar.mouseUp();
}

@("ScrollBar: a pinned bar pressed beside its thumb scrolls there as any bar does")
unittest
{
    auto bar = new ScrollBar;
    double[] scrolled;
    bar.events.scrollTo = (double fraction) { scrolled ~= fraction; };
    bar.update(ScrollMetrics(1, 0.1));
    bar.pinned = true;
    const strip = Rect(0, 0, 12, 200);
    bar.mouseDown(50, strip);
    assert(scrolled.length == 1 && scrolled[0] < 0.5);
}

@("ScrollBar: a bar pinned under a drag holds its thumb from where the mouse is then")
unittest
{
    auto bar = new ScrollBar;
    double[] scrolled;
    bar.events.scrollTo = (double fraction) { scrolled ~= fraction; };
    bar.update(ScrollMetrics(1, 0.1));
    const strip = Rect(0, 0, 12, 200);
    bar.mouseDown(190, strip);
    bar.mouseMove(230, strip); // below the track: the end
    const before = scrolled.length;
    bar.pinned = true; // the table began to follow its end under the drag
    bar.mouseMove(230 - bar.snapOff + 1, strip);
    assert(scrolled.length == before, "held from 230");
    bar.mouseMove(230 - bar.snapOff - 1, strip);
    assert(scrolled.length == before + 1, "pulled off");
    bar.mouseUp();
}

@("ScrollBar: a pinned bar stays wide away from the mouse and narrows once it is not pinned")
unittest
{
    static class Wide : ScrollBarPainter
    {
        double wide = -1;
        override void paint(Canvas canvas, Rect strip, Rect track, Rect thumb, double wide, Orientation orientation = Orientation.vertical)
        {
            this.wide = wide;
        }
    }

    auto look = new Wide;
    auto bar = new ScrollBar(look);
    bar.events.needFrame = () {};
    bar.update(ScrollMetrics(1, 0.1));
    const strip = Rect(0, 0, 12, 200);
    bar.pinned = true;
    foreach (now; [0.0, 100, 200, 300])
        bar.tick(now);
    bar.paint(null, strip, strip);
    assert(look.wide == 1, "pinned: wide without the mouse");
    bar.hover(true);
    bar.hover(false);
    foreach (now; [400.0, 500, 600, 700])
        bar.tick(now);
    bar.paint(null, strip, strip);
    assert(look.wide == 1, "the mouse came and went: still wide");
    bar.pinned = false;
    foreach (now; [800.0, 900, 1000, 1100])
        bar.tick(now);
    bar.paint(null, strip, strip);
    assert(look.wide == 0, "not pinned: thin");
}
