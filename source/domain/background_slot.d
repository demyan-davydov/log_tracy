module domain.background_slot;

import core.thread : Thread;
import core.atomic : atomicLoad, atomicStore, MemoryOrder;
import core.sync.mutex : Mutex;

//! @brief Runs a given operation in a background thread.
//! At most one operation may run at a time; if a task is already running,
//! runTask() returns false and does nothing.
struct BackgroundSlot
{
    struct Ctx
    {
        private shared bool _cancelFlag = false;
        private shared float _progress = 0.0f;

        bool cancelled() const pure nothrow @nogc @property
        {
            return atomicLoad!(MemoryOrder.acq)(_cancelFlag);
        }

        float progress() const pure nothrow @nogc @property
        {
            return atomicLoad!(MemoryOrder.acq)(_progress);
        }

        void progress(float newProgress) pure nothrow @nogc @property
        {
            atomicStore!(MemoryOrder.rel)(_progress, newProgress);
        }

        private void setProgress(float v) pure nothrow @nogc
        {
            atomicStore!(MemoryOrder.rel)(_progress, v);
        }

        private void setCancelled(bool v) pure nothrow @nogc
        {
            atomicStore!(MemoryOrder.rel)(_cancelFlag, v);
        }
    }

    // Delegate takes Ctx* to avoid scope ref across thread boundary (dip1000)
    alias TaskDelegate = void delegate(Ctx* ctx);

    private bool _exitFlag = false;
    private Ctx _ctx;
    private Mutex _mutex;
    private Thread _thread;
    private shared bool _threadDone = true; // true = no active thread

    // Must be called under the mutex only
    private bool isRunning_() const nothrow @nogc
    {
        return _thread !is null && !atomicLoad!(MemoryOrder.acq)(_threadDone);
    }

    this(typeof(null))
    {
        _mutex = new Mutex();
    }

    @disable this(this);

    ~this()
    {
        Thread threadToJoin;
        synchronized (_mutex)
        {
            _exitFlag = true;
            _ctx.setCancelled(true);
            threadToJoin = _thread;
            _thread = null;
        }

        if (threadToJoin)
            threadToJoin.join();

        destroy(_mutex);
    }

    /// Run a task. Returns false if the slot is busy or shutdown is in progress.
    bool runTask(TaskDelegate dg)
    {
        synchronized (_mutex)
        {
            if (_exitFlag)
                return false;

            if (isRunning_())
                return false;

            // Previous thread finished — join and release it
            if (_thread !is null)
            {
                _thread.join();
                _thread = null;
            }

            _ctx.setCancelled(false);
            _ctx.setProgress(0.0f);
            atomicStore!(MemoryOrder.rel)(_threadDone, false);

            auto dgCopy = dg;
            auto ctxPtr = &_ctx;
            auto doneFlagPtr = &_threadDone;

            _thread = new Thread(() {
                dgCopy(ctxPtr);
                ctxPtr.setProgress(1.0f);
                atomicStore!(MemoryOrder.rel)(*doneFlagPtr, true);
            });
            _thread.isDaemon = false;
            _thread.start();
            return true;
        }
    }

    void cancel() nothrow
    {
        _ctx.setCancelled(true);
    }

    float progress() const pure nothrow @nogc @property
    {
        return _ctx.progress;
    }

    bool busy() @property
    {
        synchronized (_mutex)
            return isRunning_();
    }
}

// =============================================================================
// Unit tests
// =============================================================================

version (unittest)
{
    import core.time : msecs, Duration;

    private void sleepMs(int ms)
    {
        Thread.sleep(ms.msecs);
    }

    private void waitUntil(scope bool delegate() cond, Duration timeout = 3000.msecs)
    {
        import std.datetime.stopwatch : StopWatch;

        auto sw = StopWatch();
        sw.start();
        while (!cond() && sw.peek < timeout)
            sleepMs(5);
    }
}

/// Basic run: task executes and completes, runTask returns true
@("BackgroundSlot: basic run completes")
unittest
{
    auto slot = BackgroundSlot(null);
    shared bool ran = false;

    bool started = slot.runTask((BackgroundSlot.Ctx* ctx) {
        atomicStore!(MemoryOrder.rel)(ran, true);
    });

    assert(started, "runTask must return true on successful launch");
    waitUntil(() => !slot.busy);
    assert(atomicLoad!(MemoryOrder.acq)(ran), "task should have run");
}

/// progress: initial value 0.0, equals 1.0 after completion
@("BackgroundSlot: progress 0 -> 1 after completion")
unittest
{
    auto slot = BackgroundSlot(null);

    slot.runTask((BackgroundSlot.Ctx* ctx) {
        assert(ctx.progress == 0.0f, "initial progress must be 0");
        sleepMs(10);
    });

    waitUntil(() => !slot.busy);
    assert(slot.progress == 1.0f, "progress must be 1.0 after completion");
}

/// Worker thread can update progress via ctx.progress
@("BackgroundSlot: worker can report intermediate progress")
unittest
{
    auto slot = BackgroundSlot(null);

    slot.runTask((BackgroundSlot.Ctx* ctx) { ctx.progress = 0.5f; sleepMs(20); });

    waitUntil(() => slot.progress >= 0.5f);
    assert(slot.progress >= 0.5f, "intermediate progress must be readable");

    waitUntil(() => !slot.busy);
    assert(slot.progress == 1.0f);
}

/// busy: true while running, false after completion
@("BackgroundSlot: busy reflects running state")
unittest
{
    auto slot = BackgroundSlot(null);

    slot.runTask((BackgroundSlot.Ctx* ctx) { sleepMs(30); });

    assert(slot.busy, "slot must be busy=true immediately after launch");
    waitUntil(() => !slot.busy);
    assert(!slot.busy, "slot must be busy=false after completion");
}

/// A second runTask call while the slot is busy returns false without starting
@("BackgroundSlot: second runTask while busy returns false")
unittest
{
    auto slot = BackgroundSlot(null);
    shared int runCount = 0;

    slot.runTask((BackgroundSlot.Ctx* ctx) {
        atomicStore!(MemoryOrder.rel)(runCount, 1);
        sleepMs(30);
    });

    bool secondStarted = slot.runTask((BackgroundSlot.Ctx* ctx) {
        atomicStore!(MemoryOrder.rel)(runCount, 99); // must not execute
    });

    assert(!secondStarted, "second runTask must return false while slot is busy");

    waitUntil(() => !slot.busy);
    assert(atomicLoad!(MemoryOrder.acq)(runCount) == 1, "exactly one task must have run");
}

/// Slot is reusable after the first task completes
@("BackgroundSlot: slot reusable after task completes")
unittest
{
    auto slot = BackgroundSlot(null);
    shared int runCount = 0;

    slot.runTask((BackgroundSlot.Ctx* ctx) {
        atomicStore!(MemoryOrder.rel)(runCount, atomicLoad!(MemoryOrder.acq)(runCount) + 1);
    });
    waitUntil(() => !slot.busy);

    bool secondStarted = slot.runTask((BackgroundSlot.Ctx* ctx) {
        atomicStore!(MemoryOrder.rel)(runCount, atomicLoad!(MemoryOrder.acq)(runCount) + 1);
    });
    assert(secondStarted, "second task must start after first completes");
    waitUntil(() => !slot.busy);

    assert(atomicLoad!(MemoryOrder.acq)(runCount) == 2, "both tasks must have run");
}

/// cancel: ctx.cancelled becomes true so the task can abort early
@("BackgroundSlot: cancel sets ctx.cancelled")
unittest
{
    auto slot = BackgroundSlot(null);
    shared bool sawCancel = false;

    slot.runTask((BackgroundSlot.Ctx* ctx) {
        foreach (_; 0 .. 50)
        {
            if (ctx.cancelled)
            {
                atomicStore!(MemoryOrder.rel)(sawCancel, true);
                return;
            }
            sleepMs(5);
        }
    });

    sleepMs(10);
    slot.cancel();
    waitUntil(() => !slot.busy);

    assert(atomicLoad!(MemoryOrder.acq)(sawCancel), "task should have seen the cancel flag");
}

/// Destructor waits for the running task to finish — no use-after-free
@("BackgroundSlot: destructor waits for running task")
unittest
{
    shared bool finished = false;

    {
        auto slot = BackgroundSlot(null);
        slot.runTask((BackgroundSlot.Ctx* ctx) {
            sleepMs(30);
            atomicStore!(MemoryOrder.rel)(finished, true);
        });
        // destructor is called here and must wait for the task to finish
    }

    assert(atomicLoad!(MemoryOrder.acq)(finished),
        "destructor must have waited for the task to complete");
}

/// Destructor sets the cancel flag — the task reacts and exits early
@("BackgroundSlot: destructor signals cancel to running task")
unittest
{
    shared bool cancelSeen = false;

    {
        auto slot = BackgroundSlot(null);

        slot.runTask((BackgroundSlot.Ctx* ctx) {
            foreach (_; 0 .. 30)
            {
                if (ctx.cancelled)
                {
                    atomicStore!(MemoryOrder.rel)(cancelSeen, true);
                    return;
                }
                sleepMs(5);
            }
        });

        sleepMs(15);
        // slot exits scope here — destructor sets cancel and waits for the thread
    }

    assert(atomicLoad!(MemoryOrder.acq)(cancelSeen),
        "task must have received the cancel signal from the destructor");
}
