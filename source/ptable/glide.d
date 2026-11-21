//! The rows moving by themselves over a distance, slower and slower, to land on it exactly: the coast after a pan and
//! the step of the mouse wheel are glides of their own shape. The way left falls as an exponent towards a point a tail
//! past the end, so a glide stops at the end at a gentle speed and in a short time. Driven by the frames the host gives
//! (a timestamp each), not by a timer; a long pause counts as a short one. Pure, no allocation. See docs/backlog.md
//! (the inertia of the scroll).
module ptable.glide;

/// The longest a frame of the host counts for, in milliseconds: a long pause (a hidden window) is not a jump
enum double longestFrameMs = 100;

/// How a glide slows down
struct GlideShape
{
    double timeMs; /// how long it takes to slow down by e
    double tailPx; /// how far past its end it aims
}

struct Glide
{
    private double _left = 0; // the pixels still to go; 0: not gliding
    private double _last = 0; // the time of the last frame
    private GlideShape _shape;

    /// What one frame of the glide moved
    struct Step
    {
        bool active; /// the glide goes on: the host is to give the next frame
        double pixels = 0;
    }

    /// The rows glide over `distance` pixels (down is positive) from `timestampMs` on, by `shape`; a distance that is
    /// not a finite number glides nowhere
    void start(double distance, double timestampMs, GlideShape shape)
    {
        import std.math : isFinite;

        _left = isFinite(distance) ? distance : 0; // a policy's NaN would glide for ever
        _last = timestampMs;
        _shape = shape;
    }

    /// `pixels` more to go at `timestampMs`, the way left kept within `limit` either way; a glide that was not on its
    /// way starts its clock now
    void add(double pixels, double timestampMs, double limit, GlideShape shape)
    {
        import std.algorithm.comparison : max, min;

        const left = active ? _left + pixels : pixels;
        start(max(-limit, min(limit, left)), active ? _last : timestampMs, shape);
    }

    void stop()
    {
        _left = 0;
    }

    bool active() const
    {
        return _left != 0;
    }

    /// The pixels still to go, down is positive
    double left() const
    {
        return _left;
    }

    /// A frame at `timestampMs`
    Step tick(double timestampMs)
    {
        import std.algorithm.comparison : max, min;
        import std.math : exp;

        if (_left == 0)
            return Step.init;
        const dt = max(0.0, min(longestFrameMs, timestampMs - _last));
        _last = timestampMs;
        const sign = _left < 0 ? -1.0 : 1.0;
        const left = sign * _left;
        const next = (left + _shape.tailPx) * exp(-dt / _shape.timeMs) - _shape.tailPx;
        if (next <= 0)
        {
            const rest = _left;
            _left = 0;
            return Step(false, rest);
        }
        _left = sign * next;
        return Step(true, sign * (left - next));
    }
}

version (unittest)
{
    private enum GlideShape shape = GlideShape(325, 10);

    // Glides to the end in frames of `frameMs` from `startMs`; the pixels moved and the frames taken
    private double glideAll(ref Glide glide, double startMs, double frameMs, out int frames)
    {
        double moved = 0;
        frames = 0;
        for (double t = startMs + frameMs; glide.active && frames < 10_000; t += frameMs, ++frames)
            moved += glide.tick(t).pixels;
        return moved;
    }
}

@("Glide: lands on its distance exactly, at 60 Hz and at 120 Hz, slower each frame")
unittest
{
    import std.math : abs, isClose;

    foreach (frameMs; [16.67, 8.33])
    {
        Glide glide;
        glide.start(300, 1000, shape);
        assert(glide.active);
        int frames;
        const moved = glideAll(glide, 1000, frameMs, frames);
        assert(isClose(moved, 300, 1e-9), "lands on the distance");
        assert(!glide.active && frames > 5 && frames < 5 * shape.timeMs / frameMs, "and ends in time");
    }

    Glide slows;
    slows.start(-200, 0, shape);
    const first = slows.tick(16).pixels, second = slows.tick(32).pixels;
    assert(first < 0 && second < 0 && abs(second) < abs(first), "up, slower and slower");
}

@("Glide: a long pause counts for a short frame, a stop ends it")
unittest
{
    Glide paused;
    paused.start(1000, 0, shape);
    const first = paused.tick(10_000).pixels;
    Glide steady;
    steady.start(1000, 0, shape);
    assert(first == steady.tick(longestFrameMs).pixels, "a hidden window is not a jump");

    Glide stopped;
    stopped.start(500, 0, shape);
    stopped.stop();
    assert(!stopped.active && stopped.tick(16).pixels == 0);
}

@("Glide: a glide of nothing, of no number or endless is not a glide")
unittest
{
    Glide glide;
    glide.start(0, 0, shape);
    assert(!glide.active);
    glide.start(double.nan, 0, shape);
    assert(!glide.active && !glide.tick(16).active, "a distance that is not a number");
    glide.start(double.infinity, 0, shape);
    assert(!glide.active, "nor an endless one");
}

@("Glide: what is added goes on the way left within the limit, a new glide starts its clock when added")
unittest
{
    import std.math : isClose;

    enum GlideShape quick = GlideShape(80, 1);
    Glide glide;
    glide.add(100, 5000, 400, quick);
    assert(glide.tick(5000).pixels == 0, "the clock starts at the add, not at an old frame");
    const moved = glide.tick(5016).pixels;
    glide.add(1000, 5020, 400, quick);
    double rest = 0;
    for (double t = 5032; glide.active; t += 16)
        rest += glide.tick(t).pixels;
    assert(isClose(moved + rest, moved + 400, 1e-9), "the way left is kept within the limit");
    glide.add(-50, 9000, 400, quick);
    glide.add(-500, 9000, 400, quick);
    double up = 0;
    for (double t = 9016; glide.active; t += 16)
        up += glide.tick(t).pixels;
    assert(isClose(up, -400), "up as well");
}
