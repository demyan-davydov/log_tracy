//! One frame on its way at a time: the table asks for a frame again and again while it scrolls by itself (a drag past
//! the rows, a step of the wheel, a coast), the host passes on
//! the first and holds the others until the frame comes. A request that has been on its way too long is taken for lost
//! (a hidden window, a refused call) and the next ask goes through, so the scroll does not die with one frame. Sciter
//! goes on sending frames for as long as the handler says it handled them: the next is never asked for from the
//! handler (each ask there adds another chain of frames, the window hangs: seen 2026-11-18).
module ui.sciter_table.frame_request;

import core.time : Duration, MonoTime, msecs;

/// How long a request is waited for
enum Duration frameWait = 250.msecs;

struct FrameRequest
{
    private MonoTime _asked; // MonoTime.init: none on its way

    /// The table asks at `now`: true if the host is to ask Sciter for a frame
    bool ask(MonoTime now)
    {
        if (_asked != MonoTime.init && now - _asked < frameWait)
            return false;
        _asked = now;
        return true;
    }

    /// The frame came at `now` and the table wants the next: the handler says it handled the frame, and Sciter goes on
    /// sending them (asking again from the handler would add a frame to the frame being sent, without end), so the next
    /// one is on its way
    void goesOn(MonoTime now)
    {
        _asked = now;
    }

    /// The frame came and the table wants no more (the handler says so to Sciter)
    void arrived()
    {
        _asked = MonoTime.init;
    }
}

@("FrameRequest: one request at a time, the next goes through when the frame came or the wait is over")
unittest
{
    FrameRequest request;
    const start = MonoTime.currTime;
    assert(request.ask(start), "the first goes through");
    assert(!request.ask(start + 100.msecs), "one is on its way");
    assert(request.ask(start + 300.msecs), "it was lost: asked again");
    request.arrived();
    assert(request.ask(start + 310.msecs), "the frame came: the next one is free");
    assert(!request.ask(start + 320.msecs));
}

@("FrameRequest: a frame that goes on is on its way, an ask waits for it as for a request, the last frame frees the next")
unittest
{
    FrameRequest request;
    const start = MonoTime.currTime;
    assert(request.ask(start));
    request.goesOn(start + 16.msecs);
    assert(!request.ask(start + 20.msecs), "the next frame comes by itself: a mouse move asks nothing more");
    request.goesOn(start + 32.msecs);
    assert(!request.ask(start + 270.msecs), "the wait counts from the last frame");
    assert(request.ask(start + 300.msecs), "frames that stopped coming are asked for again");
    request.arrived();
    assert(request.ask(start + 310.msecs), "the last frame came: the next ask goes through");
}
