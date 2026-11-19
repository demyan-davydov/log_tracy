//! How far the rows coast after the fingers left the trackpad: the moves of a pan are fed with the time of the host's
//! clock, and the speed of the last ones gives the distance of the coast (`fling`), which a `Glide` then goes. Pure, no allocation. See docs/backlog.md (the inertia of the scroll).
module ptable.inertia;

/// How long the coast takes to slow down by e (milliseconds): the speed drops to 0.95 of itself every 1/60 s
enum double glideTimeMs = 325;

/// The moves older than this before the release say nothing of the speed (milliseconds)
enum double speedWindowMs = 100;

/// A release slower than this (pixels a second) does not coast
enum double leastFlingSpeed = 60;


struct Inertia
{
    private enum samples = 8; // the last moves kept
    private double[samples] _pixels = 0, _times = 0; // a ring of the moves fed and their times
    private size_t _fed; // how many moves were fed since they were forgotten (the ring keeps the last ones)
    /// The fingers moved the rows by `pixels` (down is positive) at `timestampMs`
    void feed(double pixels, double timestampMs)
    {
        _pixels[_fed % samples] = pixels;
        _times[_fed % samples] = timestampMs;
        ++_fed;
    }

    /// How far the rows would go on by themselves after a release at `timestampMs`, by the speed of the last moves; 0:
    /// no coast (too slow, the fingers stood still before they left)
    double fling(double timestampMs) const
    {
        import std.algorithm.comparison : min;

        // the moves within the window, newest first: the oldest of them only starts the clock
        const kept = min(_fed, samples);
        double moved = 0, oldest = double.nan, newest = double.nan;
        foreach (back; 0 .. kept)
        {
            const i = (_fed - 1 - back) % samples;
            if (_times[i] < timestampMs - speedWindowMs)
                break;
            if (back == 0)
                newest = _times[i];
            else
                moved += _pixels[(i + 1) % samples];
            oldest = _times[i];
        }
        if (!(newest > oldest))
            return 0;
        const speed = moved / (newest - oldest) * 1000; // pixels a second
        return (speed < 0 ? -speed : speed) < leastFlingSpeed ? 0 : speed * glideTimeMs / 1000;
    }

    /// The moves fed are of no use any more (the coast began, another input came)
    void forget()
    {
        _fed = 0;
    }
}

version (unittest)
{
    // Feeds a steady pan of `speed` px/s in frames of `frameMs` from 0 to `untilMs`
    private void pan(ref Inertia inertia, double speed, double frameMs, double untilMs)
    {
        for (double t = frameMs; t <= untilMs + 1e-9; t += frameMs)
            inertia.feed(speed * frameMs / 1000, t);
    }
}

@("Inertia: the speed of the last moves gives the distance of the coast, down and up")
unittest
{
    import std.math : isClose;

    Inertia down;
    pan(down, 1000, 16, 320);
    assert(isClose(down.fling(320), 1000 * glideTimeMs / 1000, 1e-6), "speed times the glide time");

    Inertia up;
    pan(up, -500, 8, 200);
    assert(isClose(up.fling(200), -500 * glideTimeMs / 1000, 1e-6));
}

@("Inertia: moves older than the window are not counted, a release after the fingers stood still does not coast")
unittest
{
    import std.math : isClose;

    Inertia inertia;
    pan(inertia, 5000, 16, 160); // a fast start ...
    for (double t = 176; t <= 480; t += 16) // ... then slow
        inertia.feed(400 * 16 / 1000.0, t);
    assert(isClose(inertia.fling(480), 400 * glideTimeMs / 1000, 1e-6), "only the last moves count");
    assert(inertia.fling(480 + speedWindowMs + 1) == 0, "the fingers stood still");
}

@("Inertia: a slow release, a single move or nothing fed do not coast")
unittest
{
    Inertia slow;
    pan(slow, leastFlingSpeed / 2, 16, 160);
    assert(slow.fling(160) == 0);

    Inertia one;
    one.feed(50, 10);
    assert(one.fling(10) == 0, "no speed from one move");

    Inertia none;
    assert(none.fling(1000) == 0);
}

@("Inertia: forgotten moves give no coast")
unittest
{
    Inertia inertia;
    pan(inertia, 1000, 16, 160);
    inertia.forget();
    assert(inertia.fling(160) == 0);
}
