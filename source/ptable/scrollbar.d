//! A scroll bar of the log table, an optional layer above it: the thumb's geometry, a press and a drag
//! of the mouse turned into a fraction, and the drawing through a painter of its own (`ScrollBar`), and
//! (`ScrolledTable`, in its own module, puts the table together with it). The table and the viewport know none of it: they give
//! `ScrollMetrics` and take `scrollToFraction`; a host may use this bar or connect its own (a native one)
//! to the same two. Pure. See docs/stories/painted-table.md.
module ptable.scrollbar;

import ptable.ports;
import ptable.rowpicks : Pick;
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

/// Which way a bar lies: along the rows (at the right edge) or along the columns (at the bottom)
enum Orientation : ubyte
{
    vertical,
    horizontal,
}

/// How a bar looks. The default is a plain one; a host draws its own by overriding `paint`.
class ScrollBarPainter
{
    /// Draws the strip of the bar (`strip` is all of it, `track` the part the thumb runs along); `thumb` is
    /// the rectangle of the thumb, empty if there is nothing to scroll
    void paint(Canvas canvas, Rect strip, Rect track, Rect thumb, bool hover, bool dragging, Orientation orientation = Orientation.vertical)
    {
        canvas.fillRect(strip, Color(0xf0, 0xf0, 0xf0));
        const color = hover || dragging ? Color(60, 60, 60, 179) : Color(60, 60, 60, 115);
        if (thumb.w > 0 && thumb.h > 0)
            canvas.fillRect(orientation == Orientation.vertical ? Rect(thumb.x + 2, thumb.y, thumb.w - 4, thumb.h)
                : Rect(thumb.x, thumb.y + 2, thumb.w, thumb.h - 4), color);
    }

    /// The corner where the two bars meet
    void paintCorner(Canvas canvas, Rect corner)
    {
        canvas.fillRect(corner, Color(0xf0, 0xf0, 0xf0));
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
    }

    Events events;
    double width = 10; /// of the strip (its thickness: the width of a vertical bar, the height of a horizontal one)
    Orientation orientation; /// along the rows (default) or along the columns

    private ScrollBarPainter _painter;
    private ScrollThumb _thumb;
    private ScrollMetrics _metrics;
    private bool _hover;

    this(ScrollBarPainter painter = new ScrollBarPainter)
    {
        _painter = painter;
    }

    /// The table scrolled or changed its count
    void update(ScrollMetrics metrics)
    {
        _metrics = metrics;
    }

    bool dragging() const
    {
        return _thumb.dragging;
    }

    void hover(bool on)
    {
        if (on == _hover)
            return;
        _hover = on;
        invalidate();
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
        scrollTo(_thumb.press(_metrics, length(track), onTrack(along, track)));
        if (_thumb.dragging && events.capture !is null)
            events.capture(true);
        return true;
    }

    /// The mouse moved while the thumb is dragged
    bool mouseMove(double along, Rect track)
    {
        if (!_thumb.dragging)
            return false;
        scrollTo(_thumb.drag(_metrics, length(track), onTrack(along, track)));
        return true;
    }

    bool mouseUp()
    {
        if (!_thumb.dragging)
            return false;
        _thumb.release();
        if (events.capture !is null)
            events.capture(false);
        invalidate();
        return true;
    }

    /// Draws the bar in `strip`, its track being `track`
    void paint(Canvas canvas, Rect strip, Rect track)
    {
        const thumb = _thumb.thumb(_metrics, length(track));
        Rect rect;
        if (thumb.visible)
            rect = orientation == Orientation.vertical ? Rect(strip.x, track.y + thumb.top, strip.w, thumb.size)
                : Rect(track.x + thumb.top, strip.y, thumb.size, strip.h);
        _painter.paint(canvas, strip, track, rect, _hover, _thumb.dragging, orientation);
    }

    /// The corner where this bar and the other meet
    void paintCorner(Canvas canvas, Rect corner)
    {
        _painter.paintCorner(canvas, corner);
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
