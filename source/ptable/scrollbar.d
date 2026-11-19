//! A scroll bar of the log table, an optional layer above it: the thumb's geometry, a press and a drag
//! of the mouse turned into a position, and the drawing through a painter of its own (`ScrollBar`), and
//! (`ScrolledTable`, in its own module, puts the table together with it). The table and the viewport know none of it: they give
//! `ScrollMetrics` and take `scrollToPosition`; a host may use this bar or connect its own (a native one)
//! to the same two. Pure. See docs/stories/painted-table.md.
module ptable.scrollbar;

import ptable.ports;
import ptable.rowpicks : Pick;
import ptable.rowlayout : Thumb, rowAtThumb, thumbOf;
import ptable.viewport : ScrollMetrics;

import std.algorithm.comparison : max, min;
import std.math : isNaN;

/// The thumb of a bar on a track: where it stands and what a press or a drag of the mouse scrolls to
struct ScrollThumb
{
    double minSize = 24; /// the least size of the thumb
    private double _grab = 0;
    private bool _dragging;

    /// Whether a drag is on
    bool dragging() const pure nothrow @nogc @safe
    {
        return _dragging;
    }

    /// Where the thumb stands on a track `track` long for the metrics: not visible if all the items are on the screen
    Thumb thumb(ScrollMetrics metrics, double track) const pure nothrow @nogc @safe
    {
        const first = cast(size_t) metrics.position;
        return thumbOf(first, metrics.position - first, 1, metrics.total, track, metrics.visible, minSize);
    }

    /// A press at `y` of the track: a press on the thumb grabs it where it was pressed, a press beside it
    /// takes the middle of the thumb there. Returns the position (an item and a fraction) to scroll to, NaN
    /// if there is nothing to scroll.
    double press(ScrollMetrics metrics, double track, double y) pure nothrow @nogc @safe
    {
        const bar = thumb(metrics, track);
        if (!bar.visible)
            return double.nan;
        _grab = y < bar.top || y > bar.top + bar.size ? bar.size / 2 : y - bar.top;
        _dragging = true;
        return drag(metrics, track, y);
    }

    /// The mouse is at `y` of the track while the thumb is dragged: the position to scroll to, NaN if not dragging
    double drag(ScrollMetrics metrics, double track, double y) const pure nothrow @nogc @safe
    {
        const bar = thumb(metrics, track);
        if (!_dragging || !bar.visible)
            return double.nan;
        const top = max(0.0, min(track - bar.size, y - _grab));
        return rowAtThumb(top, track, bar.size, metrics.total, metrics.visible);
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
        void delegate(double position) scrollTo;
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

    private void scrollTo(double position)
    {
        if (!isNaN(position) && events.scrollTo !is null)
            events.scrollTo(position);
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

@("ScrollThumb: the thumb is as long as the part on the screen, at least the least, and stands by the position")
unittest
{
    ScrollThumb bar;
    const top = bar.thumb(ScrollMetrics(1000, 10, 0), 200);
    assert(top.visible && top.top == 0 && top.size == 24, "10 of 1000 of 200 is 2: the least");
    const end = bar.thumb(ScrollMetrics(1000, 10, 990), 200);
    assert(end.top == 200 - 24, "the last screen: at the bottom");
    assert(!bar.thumb(ScrollMetrics(5, 10, 0), 200).visible, "all on the screen: no thumb");
}

@("ScrollThumb: a press on the thumb grabs it, a press beside takes its middle, a drag moves the position")
unittest
{
    ScrollThumb bar;
    const metrics = ScrollMetrics(1000, 10, 0);
    const track = 200.0;
    assert(bar.press(metrics, track, 10) == 0 && bar.dragging);
    const pos = bar.drag(metrics, track, 110);
    assert(pos > 540 && pos < 580, "about 57% of 990");
    bar.release();
    assert(!bar.dragging && isNaN(bar.drag(metrics, track, 110)), "NaN after release");
    const jump = bar.press(metrics, track, 100);
    assert(jump > 480 && jump < 510, "the thumb's top at 88 of 176: about 50%");
}

@("ScrollThumb: nothing to scroll gives no position and starts no drag")
unittest
{
    ScrollThumb bar;
    assert(isNaN(bar.press(ScrollMetrics(3, 10, 0), 200, 5)) && !bar.dragging);
    assert(isNaN(bar.drag(ScrollMetrics(1000, 10, 0), 200, 5)), "not dragging");
}
