//! The scroll of a drag that went past the rows: while the mouse button is down outside the rows, they keep
//! scrolling at a speed that grows with the distance, whether the mouse moves or not. It is driven by frames the host
//! gives (a timestamp each), not by a timer of its own: the first frame moves nothing, and a long pause (a hidden
//! window) counts as a short one. Pure; the table asks it. See docs/backlog.md (the time comes from the host).
module ptable.dragscroll;

import std.algorithm.comparison : min;
import std.math : isNaN;
import ptable.glide : longestFrameMs;


struct DragScroll
{
    private double _rate = 0; // pixels per second, down is positive; 0: not scrolling
    private double _x = 0, _y = 0; // where the mouse is
    private double _last; // the timestamp of the last frame; NaN before the first

    /// What one frame of the scroll moved
    struct Step
    {
        bool active; /// the scroll goes on: the host is to give the next frame
        double pixels = 0;
        double x = 0, y = 0; /// where the mouse is
    }

    /// The speed, in pixels per second, of the scroll for a mouse `beyond` pixels past the rows (negative above them, 0
    /// inside): a step the moment it is outside, growing with the distance up to a limit
    static double rateFor(double beyond)
    {
        if (beyond == 0)
            return 0;
        const distance = beyond < 0 ? -beyond : beyond;
        return (beyond < 0 ? -1.0 : 1.0) * min(2400.0, 120 + distance * 24);
    }

    /// The mouse is at (x, y) with the button down, `rate` pixels per second past the rows (0 inside them)
    void drag(double x, double y, double rate)
    {
        _x = x;
        _y = y;
        if (rate == 0)
            stop();
        else
            _rate = rate;
    }

    /// The drag ended or came back inside the rows
    void stop()
    {
        _rate = 0;
        _last = double.nan;
    }

    bool active() const
    {
        return _rate != 0;
    }

    /// A frame at `timestampMs`
    Step tick(double timestampMs)
    {
        if (_rate == 0)
            return Step.init;
        const dt = _last.isNaN ? 0.0 : min(longestFrameMs, timestampMs - _last);
        _last = timestampMs;
        return Step(true, _rate * dt / 1000, _x, _y);
    }
}

@("DragScroll: nothing moves before the first frame, then by the time between frames, at the speed given")
unittest
{
    DragScroll scroll;
    assert(!scroll.active && !scroll.tick(5).active, "not scrolling");
    scroll.drag(30, 400, 600); // 600 px a second
    assert(scroll.active);
    const first = scroll.tick(1000);
    assert(first.active && first.pixels == 0 && first.x == 30 && first.y == 400, "the first frame only starts the clock");
    assert(scroll.tick(1016).pixels == 600 * 16 / 1000.0);
    assert(scroll.tick(1032).pixels == 600 * 16 / 1000.0, "the mouse does not move: the scroll goes on");
}

@("DragScroll: a long pause counts for a short frame, stop and a drag back inside end it, up is negative")
unittest
{
    DragScroll scroll;
    scroll.drag(0, -50, -300);
    scroll.tick(0);
    assert(scroll.tick(10_000).pixels == -300 * longestFrameMs / 1000, "a hidden window is not a jump");
    scroll.drag(0, 100, 0); // back among the rows
    assert(!scroll.active && !scroll.tick(10_016).active);
    scroll.drag(0, 500, 200);
    assert(scroll.tick(20_000).pixels == 0, "a new drag starts its clock again");
    scroll.stop();
    assert(!scroll.active);
}

@("DragScroll: the speed grows with the distance past the rows, up and down, up to a limit")
unittest
{
    assert(DragScroll.rateFor(0) == 0);
    assert(DragScroll.rateFor(10) == 120 + 240 && DragScroll.rateFor(-10) == -(120 + 240));
    assert(DragScroll.rateFor(1000) == 2400 && DragScroll.rateFor(-1000) == -2400, "the limit");
    assert(DragScroll.rateFor(50) > DragScroll.rateFor(10));
}
