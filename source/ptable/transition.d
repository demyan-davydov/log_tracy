//! A value going to its target in a given time, at an even pace: the widening of a scroll bar under the mouse. Driven by the
//! frames the host gives (a timestamp each), not by a timer: a new target starts at the next frame, from where the value
//! is then, so a change midway turns back without a jump. A long pause counts as a short one. Pure, no allocation.
module ptable.transition;

import ptable.glide : longestFrameMs;

import std.math : abs;

struct Transition
{
    private double _value = 0, _target = 0;
    private double _last = double.nan; // the time of the last frame; NaN: the next frame starts the way
    private double _durationMs;

    /// It takes `durationMs` to go the whole way, 0 to 1 (a shorter way takes as much less)
    this(double durationMs)
    {
        _durationMs = durationMs;
    }

    double value() const { return _value; }

    /// Whether the value is still on its way: the host is to give frames
    bool running() const { return _value != _target; }

    /// Go to `target` from where the value is; true if it has a way to go
    bool to(double target)
    {
        if (target != _target)
        {
            _target = target;
            _last = double.nan;
        }
        return running;
    }

    /// Stands at `target` at once
    void set(double target)
    {
        _value = _target = target;
    }

    /// A frame at `nowMs`: the value moves on; true while it is still on its way
    bool tick(double nowMs)
    {
        import std.algorithm.comparison : min;

        if (!running)
            return false;
        if (_last != _last || _durationMs <= 0) // the first frame of the way, or no time to take
        {
            _last = nowMs;
            if (_durationMs <= 0)
                _value = _target;
            return running;
        }
        const step = min(nowMs - _last, longestFrameMs) / _durationMs;
        _last = nowMs;
        const left = _target - _value;
        _value = abs(left) <= step ? _target : _value + (left > 0 ? step : -step);
        return running;
    }
}

@("Transition: goes to its target at an even pace from the next frame on, and stays")
unittest
{
    auto t = Transition(300);
    assert(!t.running && t.value == 0);
    assert(t.to(1) && t.running);
    assert(t.tick(1000) && t.value == 0, "the first frame starts the way");
    assert(t.tick(1075) && abs(t.value - 0.25) < 1e-9);
    assert(t.tick(1150) && abs(t.value - 0.5) < 1e-9);
    assert(t.tick(1225) && abs(t.value - 0.75) < 1e-9);
    assert(!t.tick(1310) && t.value == 1, "there, not past it");
    assert(!t.tick(1500) && t.value == 1, "no frames are needed once there");
}

@("Transition: a new target midway turns back from where the value is, the shorter way taking less time")
unittest
{
    auto t = Transition(300);
    t.to(1);
    t.tick(0);
    t.tick(75);
    t.tick(150);
    assert(abs(t.value - 0.5) < 1e-9);
    t.to(0);
    assert(t.tick(160) && abs(t.value - 0.5) < 1e-9, "the turn starts at the next frame, no jump");
    assert(t.tick(235) && abs(t.value - 0.25) < 1e-9);
    assert(!t.tick(310) && t.value == 0, "half the way in half the time");
}

@("Transition: a long pause counts as a short frame; set stands at once")
unittest
{
    auto t = Transition(300);
    t.to(1);
    t.tick(0);
    t.tick(5000); // a hidden window
    assert(abs(t.value - longestFrameMs / 300) < 1e-9, "not a jump to the end");
    t.set(0);
    assert(!t.running && t.value == 0);
}
