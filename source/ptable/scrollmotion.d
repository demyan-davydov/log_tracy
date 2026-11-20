//! The scrolls the table makes by itself on the host's frames: the scroll of a drag past the rows (`DragScroll`), the
//! coast after a pan of the trackpad (`Inertia` measures it), the step of the mouse wheel and the glide to a place the
//! table shows (`glideTo`: no rule of the input applies to it, a press lands or stops it), each a `Glide`. One `tick`
//! a frame gives what they moved and whether a frame is wanted again; a policy may change the distance of a coast
//! before it begins (a row start). Who moves the rows is a `Scroll` state, `next` the table of its changes: the newest
//! input takes over, except the wheel while the fingers move, and a wheel spinning since before the fingers (a wheel that
//! spins freely sends steps for seconds) does not break their coast. Pure; the table asks it. See
//! docs/experiments/2026-11-18-scroll-input-priority.md.
module ptable.scrollmotion;

import ptable.dragscroll : DragScroll;
import ptable.glide : Glide, GlideShape;
import ptable.inertia : glideTimeMs, Inertia;

/// Changes the distance a coast would go (the pixels, down is positive) into the one it goes: a row start, say
alias CoastPolicy = double delegate(double distance);

/// How a step of the wheel glides: short, aimed a pixel past its end
enum GlideShape wheelShape = GlideShape(80, 1);

/// How the coast slows down: aimed 10 px past its end, so it ends at a gentle speed, not after a long tail
enum GlideShape coastShape = GlideShape(glideTimeMs, 10);

/// How a glide to a place far off goes (a jump across the document): quicker than a step of the wheel, so the eye reads a rush
/// (a trial value, to be tuned by eye)
enum GlideShape farShape = GlideShape(50, 1);

/// How far a wheel along a coast may speed it up: the way left is kept within this many heights of the rows (or what
/// it was, if more), so a wheel that spins on does not make a coast of seconds and a frame's step stays under a screen
enum double boostScreens = 4;

/// How long after the last move of the fingers the wheel still waits (milliseconds): a release that does not coast
/// may come late or not at all
enum double fingersWaitMs = 150;

/// How long the wheel is quiet before its next step begins a new spin (milliseconds)
enum double wheelQuietMs = 300;

// The steps of the wheel that come one after another: when the spin they belong to began
private struct WheelSpin
{
    import std.math : isNaN;

    private double _began, _last; // NaN: no step yet

    /// A step at `timestampMs`: the time its spin began
    double step(double timestampMs)
    {
        if (_last.isNaN || timestampMs - _last > wheelQuietMs)
            _began = timestampMs;
        _last = timestampMs;
        return _began;
    }
}

/// Who moves the rows now
enum Scroll
{
    idle,
    wheel, /// a step of the wheel glides
    fingers, /// the fingers move the rows
    coast, /// the rows coast after the fingers left
}

/// What happened, for `next`
enum ScrollInput
{
    wheelStep, /// a step of the wheel, a new one or against the coast
    wheelAlong, /// a step of the wheel in the way of the coast
    wheelStale, /// a step of a wheel that began to spin before the fingers last touched: counted never, a quiet wheel begins a new spin
    pan, /// the fingers moved
    quiet, /// the fingers have not moved for `fingersWaitMs`
    fling, /// the fingers left fast
    rest, /// the fingers left still or slow
    stop, /// a press, a key, a jump, the scroll bar
    landed, /// the glide went all its way
}

/// What the glide does on an input
enum GlideAct
{
    none,
    addWheel, /// the step of the wheel is added to the way of the wheel's glide
    restartWheel, /// the coast stops, the step of the wheel glides
    boost, /// the step of the wheel is added to the way of the coast
    coast, /// the coast begins
    stop, /// the glide stops
}

/// Where an input takes the scroll and what the glide does
struct Move
{
    Scroll state;
    GlideAct act;
}

/// Where `input` takes the scroll from `state` and what the glide does: the newest input takes over and cancels a glide
/// of another, a step of the wheel in the way of a coast speeds it up, a wheel that was spinning before the fingers touched
/// is not counted at all (it does not break their coast, and a touch stops it), the wheel is not counted while the fingers move
Move next(Scroll state, ScrollInput input) pure nothrow @nogc @safe
{
    final switch (input)
    {
    case ScrollInput.wheelStep:
        return state == Scroll.fingers ? Move(state)
            : Move(Scroll.wheel, state == Scroll.coast ? GlideAct.restartWheel : GlideAct.addWheel);
    case ScrollInput.wheelAlong:
        return state == Scroll.fingers ? Move(state)
            : state == Scroll.coast ? Move(state, GlideAct.boost) : Move(Scroll.wheel, GlideAct.addWheel);
    case ScrollInput.wheelStale:
        return Move(state);
    case ScrollInput.pan:
        return Move(Scroll.fingers, GlideAct.stop);
    case ScrollInput.quiet:
    case ScrollInput.rest:
        return Move(state == Scroll.fingers ? Scroll.idle : state);
    case ScrollInput.fling:
        return state == Scroll.fingers ? Move(Scroll.coast, GlideAct.coast) : Move(state);
    case ScrollInput.stop:
        return Move(Scroll.idle, GlideAct.stop);
    case ScrollInput.landed:
        return Move(state == Scroll.fingers ? state : Scroll.idle);
    }
}

final class ScrollMotion
{
    private DragScroll _drag;
    private Inertia _coast; // the speed of the pan
    private Glide _glide; // the coast or the wheel's step
    private Scroll _state;
    private double _lastPan; // the time of the last move of the fingers; NaN: none yet
    private WheelSpin _spin;
    private bool _landsOnPress; // the glide is a glide to a place that a press lands (`glideTo`)

    /// What one frame moved
    struct Step
    {
        bool active; /// a scroll goes on: the host is to give the next frame
        double pixels = 0;
        bool dragging; /// the drag's scroll moved: the selection reaches under the mouse at (x, y)
        double x = 0, y = 0;
    }

    // ---- the drag past the rows ----

    /// The mouse is at (x, y) with the button down, `rate` pixels per second past the rows (0 inside them)
    void dragTo(double x, double y, double rate)
    {
        _drag.drag(x, y, rate);
    }

    /// The drag ended
    void dragStop()
    {
        _drag.stop();
    }

    // ---- the wheel ----

    /// A step of the wheel of `pixels` at `timestampMs`; `limit` is about the height of the rows: the way left of a step
    /// is kept within it, a step adds no more than it to a coast. True if the rows glide by it
    bool wheel(double pixels, double timestampMs, double limit)
    {
        import std.algorithm.comparison : max;
        import std.math : abs, isNaN;

        if (_state == Scroll.fingers && timestampMs - _lastPan >= fingersWaitMs)
            apply(next(_state, ScrollInput.quiet));
        const began = _spin.step(timestampMs);
        const input = !_lastPan.isNaN && began <= _lastPan ? ScrollInput.wheelStale
            : _state == Scroll.coast && (pixels < 0) == (_glide.left < 0) ? ScrollInput.wheelAlong : ScrollInput.wheelStep;
        const move = next(_state, input);
        _state = move.state;
        if (move.act != GlideAct.none)
            _landsOnPress = false; // the wheel's glide now
        final switch (move.act)
        {
        case GlideAct.none:
            return false;
        case GlideAct.restartWheel:
            _glide.stop();
            goto case GlideAct.addWheel;
        case GlideAct.addWheel:
            _glide.add(pixels, timestampMs, limit, wheelShape);
            break;
        case GlideAct.boost: // the coast goes faster and farther, never shorter
            _glide.add(pixels, timestampMs, max(abs(_glide.left), boostScreens * limit), coastShape);
            break;
        case GlideAct.coast:
        case GlideAct.stop:
            assert(false, "not an act of the wheel");
        }
        return _glide.active;
    }

    // ---- a glide to a place ----

    /// The rows glide `distance` pixels (down is positive) from `timestampMs` on, by `shape`: a scroll the table makes to show
    /// a place (a row revealed, a position asked for). No rule of the input applies: the scrolls before it stop, and the
    /// wheel's spins and the fingers are neither asked nor changed. A step of the wheel on its way takes it over. `landsOnPress`:
    /// a press lands it at once (a short glide: the second click of a double one finds the rows where they stay); else a press
    /// stops it where it is (a long one: what is pressed is what was seen). True if the rows glide
    bool glideTo(double distance, double timestampMs, GlideShape shape, bool landsOnPress)
    {
        stop();
        _glide.start(distance, timestampMs, shape);
        _state = _glide.active ? Scroll.wheel : Scroll.idle;
        _landsOnPress = _glide.active && landsOnPress;
        return _glide.active;
    }

    /// A press of the mouse: a glide to a place that lands on a press lands now and gives the pixels left of its way (the caller
    /// moves them at once); any other scroll stops where it is (0)
    double press()
    {
        const rest = _landsOnPress && _glide.active ? _glide.left : 0;
        stop();
        return rest;
    }

    // ---- the pan and its coast ----

    /// The fingers moved the rows by `pixels` at `timestampMs` (the table scrolls them itself)
    void pan(double pixels, double timestampMs)
    {
        apply(next(_state, ScrollInput.pan));
        _landsOnPress = false;
        _lastPan = timestampMs;
        _coast.feed(pixels, timestampMs);
    }

    /// The fingers left at `timestampMs`: the rows coast by the speed of the last moves, over the distance `policy`
    /// makes of it (null: as it is); true if they coast
    bool release(double timestampMs, scope CoastPolicy policy = null)
    {
        import std.math : isFinite;

        const fling = _state == Scroll.fingers ? _coast.fling(timestampMs) : 0; // a late release moves nothing
        _coast.forget();
        const distance = fling != 0 && policy !is null ? policy(fling) : fling;
        const move = next(_state, distance != 0 && isFinite(distance) ? ScrollInput.fling : ScrollInput.rest);
        _state = move.state;
        if (move.act == GlideAct.coast)
            _glide.start(distance, timestampMs, coastShape);
        return _state == Scroll.coast;
    }

    /// Any other input (a press, a key, a jump): the scrolls stop
    void stop()
    {
        _drag.stop();
        _coast.forget();
        _landsOnPress = false;
        apply(next(_state, ScrollInput.stop));
    }

    // Takes a move whose act needs no step of the wheel and no distance
    private void apply(Move move)
    {
        _state = move.state;
        if (move.act == GlideAct.stop)
            _glide.stop();
        else
            assert(move.act == GlideAct.none, "an act that needs more");
    }

    bool active() const
    {
        return _drag.active || _glide.active;
    }

    /// A frame at `timestampMs`
    Step tick(double timestampMs)
    {
        const drag = _drag.tick(timestampMs);
        const coast = _glide.tick(timestampMs);
        if (!_glide.active && (_state == Scroll.wheel || _state == Scroll.coast))
            apply(next(_state, ScrollInput.landed));
        return Step(drag.active || coast.active, drag.pixels + coast.pixels, drag.active, drag.x, drag.y);
    }
}

@("ScrollMotion: a drag past the rows moves on frames and tells where the mouse is; its stop ends it")
unittest
{
    auto motion = new ScrollMotion;
    assert(!motion.active && !motion.tick(0).active);
    motion.dragTo(10, 500, 1000);
    assert(motion.tick(0).active, "the first frame starts the clock");
    const step = motion.tick(16);
    assert(step.active && step.dragging && step.pixels == 16 && step.x == 10 && step.y == 500);
    motion.dragStop();
    assert(!motion.active && !motion.tick(32).dragging);
}

@("ScrollMotion: a pan released fast coasts, its last frame moves the rest and wants no more")
unittest
{
    auto motion = new ScrollMotion;
    foreach (i; 1 .. 11)
        motion.pan(16, i * 16.0); // 1000 px a second
    assert(motion.release(160));
    double moved = 0;
    double t = 160;
    ScrollMotion.Step step;
    do
    {
        t += 16;
        step = motion.tick(t);
        moved += step.pixels;
        assert(!step.dragging);
    }
    while (step.active && t < 10_000);
    assert(!motion.active && moved > 100, "coasted and stopped");
}

@("ScrollMotion: the policy changes the distance of the coast, the coast lands on it; nothing to coast asks no policy")
unittest
{
    import std.math : isClose;

    auto motion = new ScrollMotion;
    foreach (i; 1 .. 11)
        motion.pan(16, i * 16.0);
    double asked = 0;
    assert(motion.release(160, (double d) { asked = d; return 57.0; }));
    assert(asked > 0);
    double moved = 0;
    for (double t = 176; motion.active; t += 16)
        moved += motion.tick(t).pixels;
    assert(isClose(moved, 57), "lands where the policy said");

    auto still = new ScrollMotion;
    bool called;
    assert(!still.release(0, (double d) { called = true; return 10.0; }) && !called, "no speed: no coast, no policy");
}

@("ScrollMotion: stop ends the coast and the drag alike")
unittest
{
    auto motion = new ScrollMotion;
    foreach (i; 1 .. 11)
        motion.pan(-16, i * 16.0);
    motion.release(160);
    motion.dragTo(0, -40, -300);
    assert(motion.active);
    motion.stop();
    assert(!motion.active && !motion.tick(176).active);
}

@("ScrollMotion: the wheel glides to its pixels on frames, and what comes on its way is added, within the limit")
unittest
{
    import std.math : isClose;

    auto motion = new ScrollMotion;
    assert(motion.wheel(120, 1000, 500) && motion.active);
    double moved = 0, t = 1000;
    moved += motion.tick(t += 16).pixels;
    assert(moved > 0 && moved < 120, "a share at a frame, not all at once");
    motion.wheel(1000, t, 500);
    while (motion.active && t < 10_000)
        moved += motion.tick(t += 16).pixels;
    assert(t < 1600, "a short glide");
    assert(moved > 500 && moved <= 120 + 500 + 1e-9, "what was left and the new pixels, the way left within the limit");
}

@("ScrollMotion: the wheel is not counted while the fingers move the rows; once they are quiet or left slowly it is")
unittest
{
    auto motion = new ScrollMotion;
    foreach (i; 1 .. 11)
        motion.pan(16, i * 16.0);
    assert(!motion.wheel(-1100, 165, 500), "the fingers are on the trackpad");
    assert(motion.wheel(-30, 160 + fingersWaitMs, 500), "they have not moved for a while: the end of the pan never came");

    auto slow = new ScrollMotion;
    foreach (i; 1 .. 11)
        slow.pan(0.5, i * 16.0);
    assert(!slow.release(170));
    assert(slow.wheel(10, 175, 500), "left slowly: the wheel at once");

    auto pressed = new ScrollMotion;
    foreach (i; 1 .. 11)
        pressed.pan(16, i * 16.0);
    pressed.release(170);
    pressed.stop();
    assert(pressed.wheel(10, 180, 500), "a press or a key");
}

@("ScrollMotion: a wheel spinning since before the fingers does not break their coast; a new spin against it ends it")
unittest
{
    import std.math : isClose;

    auto motion = new ScrollMotion;
    for (double t = 0; t <= 100; t += 16)
        motion.wheel(-1100, t, 500); // a wheel spins freely ...
    foreach (i; 1 .. 11)
        motion.pan(16, 100 + i * 16.0); // ... the fingers take over ...
    motion.wheel(-1100, 200, 500); // ... while it still spins
    assert(motion.release(270));
    assert(!motion.wheel(-1100, 290, 500), "the old spin");
    assert(motion.tick(286).pixels > 0 && motion.tick(302).pixels > 0, "the coast goes on");

    assert(motion.wheel(-30, 700, 500), "the wheel stopped and spins again: a new input");
    double moved = 0;
    for (double t = 716; motion.active && t < 5000; t += 16)
        moved += motion.tick(t).pixels;
    assert(isClose(moved, -30), "the coast is over, the step of the wheel glides");
}

@("ScrollMotion: a touch without a move stops a wheel that spins freely, and the rest of that spin is not counted")
unittest
{
    auto motion = new ScrollMotion;
    for (double t = 0; t <= 100; t += 16)
        motion.wheel(-1100, t, 500); // the wheel spins freely and the rows glide ...
    assert(motion.active);
    motion.pan(0, 110); // ... a touch of the trackpad, the fingers do not move
    assert(!motion.active, "the glide stops at the touch");
    assert(!motion.release(120), "nothing to coast from");
    for (double t = 130; t < 1500; t += 16)
        assert(!motion.wheel(-900, t, 500), "the old spin goes on in the wheel, the rows stay");
    assert(motion.wheel(-30, 2000, 500), "the wheel was quiet: a new spin counts");
}

@("ScrollMotion: a step of the wheel in the way of a coast adds to it, no shorter than it was")
unittest
{
    import std.math : isClose;

    double coastAll(double step)
    {
        auto motion = new ScrollMotion;
        foreach (i; 1 .. 11)
            motion.pan(16, i * 16.0);
        motion.release(160);
        double moved = 0, t = 160;
        for (; t < 400; t += 16)
            moved += motion.tick(t).pixels;
        if (step != 0)
            assert(motion.wheel(step, t, 100), "the coast takes the step");
        for (; motion.active && t < 10_000; t += 16)
            moved += motion.tick(t).pixels;
        return moved;
    }

    const plain = coastAll(0);
    assert(isClose(coastAll(50), plain + 50), "the step is added to the way left");
    assert(coastAll(5000) >= plain, "a limit lower than the way left does not cut it");
}

@("ScrollMotion: a pan takes over from the wheel's glide")
unittest
{
    auto motion = new ScrollMotion;
    motion.wheel(300, 0, 500);
    motion.tick(16);
    motion.pan(5, 20);
    assert(!motion.active && motion.tick(32).pixels == 0);
}

@("next: every input in every state, where it goes and what the glide does")
unittest
{
    import std.traits : EnumMembers;

    alias S = Scroll;
    alias A = GlideAct;
    static Move m(S state, A act) { return Move(state, act); }
    // the states:                 idle                     wheel                       fingers                  coast
    immutable Move[4][ScrollInput.max + 1] table = [
        /* wheelStep  */ [m(S.wheel, A.addWheel),   m(S.wheel, A.addWheel),   m(S.fingers, A.none), m(S.wheel, A.restartWheel)],
        /* wheelAlong */ [m(S.wheel, A.addWheel),   m(S.wheel, A.addWheel),   m(S.fingers, A.none), m(S.coast, A.boost)],
        /* wheelStale */ [m(S.idle, A.none),        m(S.wheel, A.none),       m(S.fingers, A.none), m(S.coast, A.none)],
        /* pan        */ [m(S.fingers, A.stop),     m(S.fingers, A.stop),     m(S.fingers, A.stop), m(S.fingers, A.stop)],
        /* quiet      */ [m(S.idle, A.none),        m(S.wheel, A.none),       m(S.idle, A.none),    m(S.coast, A.none)],
        /* fling      */ [m(S.idle, A.none),        m(S.wheel, A.none),       m(S.coast, A.coast),  m(S.coast, A.none)],
        /* rest       */ [m(S.idle, A.none),        m(S.wheel, A.none),       m(S.idle, A.none),    m(S.coast, A.none)],
        /* stop       */ [m(S.idle, A.stop),        m(S.idle, A.stop),        m(S.idle, A.stop),    m(S.idle, A.stop)],
        /* landed     */ [m(S.idle, A.none),        m(S.idle, A.none),        m(S.fingers, A.none), m(S.idle, A.none)],
    ];
    foreach (input; EnumMembers!ScrollInput)
        foreach (state; EnumMembers!Scroll)
            assert(next(state, input) == table[input][state], "a cell of the table");
}

@("ScrollMotion: a wheel spinning on along a coast speeds it up to a few screens, no step of a frame over a screen")
unittest
{
    import std.math : abs;

    auto motion = new ScrollMotion;
    foreach (i; 1 .. 11)
        motion.pan(16, i * 16.0);
    motion.release(160);
    double t = 160, most = 0;
    for (; t < 3000; t += 16) // a wheel that spins freely, a step every frame
    {
        motion.wheel(1100, t, 500);
        most = most < abs(motion.tick(t).pixels) ? abs(motion.tick(t).pixels) : most;
    }
    assert(most <= 500, "a frame moves no more than a screen");
    double rest = 0;
    for (; motion.active && t < 20_000; t += 16)
        rest += motion.tick(t).pixels;
    assert(rest <= boostScreens * 500 + 1e-9, "what is left when the wheel stops is a few screens");
}

@("ScrollMotion: a glide to a place is no step of the wheel: a spin the fingers broke does not swallow it, it lands on its distance")
unittest
{
    import std.math : isClose;

    auto motion = new ScrollMotion;
    motion.wheel(-30, 0, 500); // a spin begins ...
    motion.pan(5, 100); // ... the fingers touch after it ...
    motion.stop(); // ... a key
    assert(motion.glideTo(200, 250, wheelShape, true), "within the quiet time of the spin, and still it glides");
    double moved = 0;
    for (double t = 266; motion.active && t < 5000; t += 16)
        moved += motion.tick(t).pixels;
    assert(isClose(moved, 200));
    assert(!motion.glideTo(0, 6000, wheelShape, true) && !motion.active, "a glide of nothing");
}

@("ScrollMotion: a press lands a glide to a place that lands on a press and gives what was left of it; any other scroll it only stops")
unittest
{
    import std.math : isClose;

    auto motion = new ScrollMotion;
    motion.glideTo(200, 0, wheelShape, true);
    const moved = motion.tick(16).pixels;
    assert(moved > 0 && moved < 200);
    assert(isClose(moved + motion.press(), 200) && !motion.active, "the rest of the way, to be moved now");

    auto stops = new ScrollMotion;
    stops.glideTo(200, 0, wheelShape, false);
    stops.tick(16);
    assert(stops.press() == 0 && !stops.active, "a glide that does not land on a press stops where it is");

    auto wheel = new ScrollMotion;
    wheel.wheel(120, 0, 500);
    wheel.tick(16);
    assert(wheel.press() == 0 && !wheel.active, "the wheel's glide stops where it is");

    auto taken = new ScrollMotion;
    taken.glideTo(200, 0, wheelShape, true);
    taken.wheel(50, 10, 500);
    assert(taken.press() == 0, "a step of the wheel took it over: no more a glide to a place");
}

@("ScrollMotion: a glide to a place goes by the shape it is given and lands on its distance")
unittest
{
    import std.math : isClose;

    foreach (shape; [wheelShape, farShape])
    {
        auto motion = new ScrollMotion;
        assert(motion.glideTo(-300, 0, shape, true));
        double moved = 0;
        for (double t = 16; motion.active && t < 5000; t += 16)
            moved += motion.tick(t).pixels;
        assert(isClose(moved, -300));
    }
}
