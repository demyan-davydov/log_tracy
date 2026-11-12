//! Scans a range of positions on a task pool in blocks and delivers what each
//! block found (parallelScan) or folded into (parallelFold) in the order of the
//! blocks, as a sequential scan would.
module utils.parallel_scan;

import std.parallelism : TaskPool, taskPool;

//! Tells a block whether the scan it belongs to has stopped: what the block
//! finds from then on is never delivered, so it may give up at once
struct ScanStop
{
    private const(shared(bool))* _stopped;

    @disable this(); // only parallelScan makes one

    private this(const(shared(bool))* stopped) pure nothrow @nogc
    {
        _stopped = stopped;
    }

    bool opCall() const nothrow @nogc
    {
        import core.atomic : atomicLoad;

        return atomicLoad(*_stopped);
    }
}

//! @brief Scans [0, length) in blocks of `blockLength` positions on `pool`.
//! `scan(lo, hi, found, stop)` runs concurrently for different blocks: it
//! writes what it finds in [lo, hi), at most a result per position, to the
//! start of `found` (room for `hi - lo` results), returns how many it wrote
//! and must only read shared state. The room is taken once for the whole
//! scan, so collecting a result costs a store, not an append. A long block
//! checks `stop()` now and then: true once `deliver` stopped the scan or a
//! block or `deliver` failed. `deliver(done, found)` runs on the calling thread, one block
//! at a time in the order of the blocks, as soon as the block and the ones
//! before it are scanned; `done` is the end of the block, and `found` is
//! valid during the call only: its memory is reused for a later block. It
//! returns false to stop the scan: no block after it is delivered then, and
//! the blocks no thread has started are dropped.
//! A few blocks per thread are in flight: a delivered block makes room for
//! the next one, so results held don't depend on `length`, and no thread
//! waits for another while there are blocks left.
//! @return false if `deliver` stopped the scan
bool parallelScan(T)(size_t length, size_t blockLength,
    scope size_t delegate(size_t lo, size_t hi, T[] found, ScanStop stop) scan,
    scope bool delegate(size_t done, const(T)[] found) deliver,
    TaskPool pool = null)
{
    import core.memory : GC;
    import std.array : uninitializedArray;

    assert(blockLength > 0);
    if (pool is null)
        pool = taskPool;

    const inFlight = inFlightOn(pool);
    // The room of a slot, reused by its blocks. Nothing reads what a block didn't
    // write: no need to clear it
    auto room = uninitializedArray!(T[])(inFlight * blockLength);
    // After the blocks: none uses the room once scanBlocks returns, and it may be megabytes
    scope (exit)
        GC.free(room.ptr);

    return scanBlocks!size_t(length, blockLength, inFlight,
        (size_t slot, size_t lo, size_t hi, ScanStop stop) {
            auto slotRoom = room[slot * blockLength .. slot * blockLength + (hi - lo)];
            const n = scan(lo, hi, slotRoom, stop);
            assert(n <= slotRoom.length, "more results than positions");
            return n;
        },
        (size_t done, size_t slot, ref size_t n) => deliver(done, room[slot * blockLength .. slot * blockLength + n]),
        pool);
}

//! @brief Folds [0, length) in blocks of `blockLength` positions on `pool`: each block
//! into an accumulator of its own, merged on the calling thread in the order of the
//! blocks, as a sequential fold would see them (the first and the last of something stay
//! so). `fold(lo, hi, stop)` runs concurrently for different blocks, must only read
//! shared state and returns what the block folded into; a long block checks `stop()` now
//! and then, as for parallelScan. `merge(done, folded)` runs on the calling thread, one
//! block at a time in their order, as soon as the block and the ones before it are
//! folded; `done` is the end of the block. It may take what `folded` holds (it is the
//! block's own). It returns false to stop the fold: no block after it is merged then.
//! The blocks in flight are as for parallelScan: what is held is an accumulator per block
//! in flight, whatever `length`.
//! @return false if `merge` stopped the fold
bool parallelFold(A)(size_t length, size_t blockLength,
    scope A delegate(size_t lo, size_t hi, ScanStop stop) fold,
    scope bool delegate(size_t done, ref A folded) merge,
    TaskPool pool = null)
{
    assert(blockLength > 0);
    if (pool is null)
        pool = taskPool;
    return scanBlocks!A(length, blockLength, inFlightOn(pool),
        (size_t slot, size_t lo, size_t hi, ScanStop stop) => fold(lo, hi, stop),
        (size_t done, size_t slot, ref A folded) => merge(done, folded),
        pool);
}

//! Blocks in flight for each thread
private enum blocksPerThread = 4;

//! The blocks in flight on `pool`: several per thread, so a slow block doesn't leave the
//! others idle; the calling thread works too
private size_t inFlightOn(TaskPool pool)
{
    return (pool.size + 1) * blocksPerThread;
}

//! @brief Scans [0, length) in blocks on `pool`, `inFlight` of them at most at a time,
//! each in a slot (< inFlight) a later block reuses once it is delivered. `scan(slot, lo,
//! hi, stop)` gives the result of a block, `deliver(done, slot, result)` takes it on the
//! calling thread in the order of the blocks: see parallelScan.
//! @return false if `deliver` stopped the scan
private bool scanBlocks(R)(size_t length, size_t blockLength, size_t inFlight,
    scope R delegate(size_t slot, size_t lo, size_t hi, ScanStop stop) scan,
    scope bool delegate(size_t done, size_t slot, ref R result) deliver,
    TaskPool pool)
{
    import core.atomic : atomicStore;
    import std.algorithm.comparison : min;
    import std.parallelism : task;

    const blockCount = (length + blockLength - 1) / blockLength;
    auto results = new R[inFlight]; // what the last block of each slot gave
    // What a block threw, rethrown on delivery. A task must not throw: an
    // Error of a task run by yieldForce on the waiting thread leaves the task
    // in progress for good (std.parallelism catches only Exception there)
    auto failure = new Throwable[inFlight];

    // Set once the scan stops or fails: a block no thread has started yet is
    // dropped, a block being scanned may give up (ScanStop)
    shared bool stopped = false;
    const stop = ScanStop(&stopped);

    void scanBlock(size_t block)
    {
        import core.atomic : atomicLoad;

        const slot = block % inFlight;
        failure[slot] = null;
        if (atomicLoad(stopped))
            return;
        results[slot] = R.init;
        const lo = block * blockLength, hi = min(lo + blockLength, length);
        try
            results[slot] = scan(slot, lo, hi, stop);
        catch (Throwable e)
            failure[slot] = e;
    }

    auto scanBlockDg = &scanBlock;
    alias BlockTask = typeof(task(scanBlockDg, size_t.init));
    auto tasks = new BlockTask[inFlight];
    size_t submitted = 0, delivered = 0;

    void submit()
    {
        auto t = task(scanBlockDg, submitted);
        tasks[submitted % inFlight] = t;
        pool.put(t);
        ++submitted;
    }

    // The tasks use this frame: they must be done before it is left, even by
    // a stop or a failure. Blocks no thread has started are dropped then.
    scope (exit)
    {
        // First, so the blocks being scanned give up (ScanStop) after a stop or
        // a failure; nothing is left to scan when the scan is complete
        atomicStore(stopped, true);
        foreach (block; delivered .. submitted)
            tasks[block % inFlight].yieldForce(); // doesn't throw: scanBlock catches
    }

    while (submitted < min(inFlight, blockCount))
        submit();

    while (delivered < blockCount)
    {
        const slot = delivered % inFlight;
        tasks[slot].yieldForce(); // runs it here if no worker took it
        if (failure[slot] !is null)
            throw failure[slot];
        const done = min((delivered + 1) * blockLength, length);
        const keepOn = deliver(done, slot, results[slot]);
        ++delivered;
        if (!keepOn)
            return false;
        if (submitted < blockCount)
            submit(); // into the slot just delivered
    }
    return true;
}

version (unittest)
{
    import std.algorithm : filter;
    import std.array : array;
    import std.range : iota;
}

@("parallelScan: delivers what the blocks found in their order")
unittest
{
    foreach (length; [0, 1, 99, 100, 101, 12_345])
    {
        size_t[] all;
        size_t lastDone = 0;
        const completed = parallelScan!size_t(length, 100,
            (size_t lo, size_t hi, size_t[] found, ScanStop stop) {
                size_t n = 0;
                foreach (i; lo .. hi)
                    if (i % 3 == 0)
                        found[n++] = i;
                return n;
            },
            (size_t done, const(size_t)[] found) {
                assert(done > lastDone, "blocks are delivered in order");
                assert(done == length || done % 100 == 0, "done is the end of a block");
                lastDone = done;
                all ~= found;
                return true;
            });
        assert(completed);
        assert(lastDone == length);
        assert(all == iota(length).filter!(i => i % 3 == 0).array);
    }
}

@("parallelScan: a block is given room for a result per position, and only what it wrote is delivered")
unittest
{
    size_t[] all;
    parallelScan!size_t(995, 10,
        (size_t lo, size_t hi, size_t[] found, ScanStop stop) {
            assert(found.length == hi - lo);
            found[] = size_t.max; // left over: not delivered
            found[0] = lo;
            return 1;
        },
        (size_t done, const(size_t)[] found) { all ~= found; return true; });
    assert(all == iota(0, 1000, 10).array);
}

@("parallelScan: deliver returning false stops the scan")
unittest
{
    import core.atomic : atomicOp, atomicLoad;

    shared size_t scanned = 0;
    size_t delivered = 0;
    const completed = parallelScan!size_t(1_000_000, 10,
        (size_t lo, size_t hi, size_t[] found, ScanStop stop) { atomicOp!"+="(scanned, 1); return 0; },
        (size_t done, const(size_t)[] found) { return ++delivered < 3; });
    assert(!completed);
    assert(delivered == 3, "nothing is delivered after a stop");
    assert(atomicLoad(scanned) < 100_000, "the blocks after the stop are not scanned");
}

@("parallelScan: an exception of a block reaches the caller")
unittest
{
    import std.exception : assertThrown;

    assertThrown!Exception(parallelScan!size_t(1000, 10,
        (size_t lo, size_t hi, size_t[] found, ScanStop stop) {
            if (lo == 500)
                throw new Exception("unreadable");
            return 0;
        },
        (size_t done, const(size_t)[] found) => true));
}

@("parallelScan: blocks run on several threads")
unittest
{
    import core.thread : Thread;
    import core.time : msecs;
    import core.sync.mutex : Mutex;

    auto pool = new TaskPool(4);
    scope (exit)
        pool.finish(true);

    auto mutex = new Mutex();
    bool[Thread] threads;
    parallelScan!size_t(16, 1,
        (size_t lo, size_t hi, size_t[] found, ScanStop stop) {
            synchronized (mutex)
                threads[Thread.getThis()] = true;
            Thread.sleep(5.msecs);
            return 0;
        },
        (size_t done, const(size_t)[] found) => true, pool);
    assert(threads.length > 1);
}

version (unittest)
{
    //! Waits until `done` is true; a deadline keeps a broken scan from hanging
    //! the tests
    //! @return false if it never was
    private bool waitUntil(scope bool delegate() done)
    {
        import core.thread : Thread;
        import core.time : msecs, MonoTime;

        const deadline = MonoTime.currTime + 10_000.msecs;
        while (!done() && MonoTime.currTime < deadline)
            Thread.sleep(1.msecs);
        return done();
    }
}

@("parallelScan: a block is delivered once the blocks before it are, not after its window")
unittest
{
    import core.atomic : atomicLoad, atomicStore;

    auto pool = new TaskPool(2);
    scope (exit)
        pool.finish(true);

    shared bool firstDelivered = false;
    bool waitedInVain = false;
    parallelScan!size_t(4, 1,
        (size_t lo, size_t hi, size_t[] found, ScanStop stop) {
            if (lo != 1)
                return 0;
            // The window of block 0 holds block 1 too: block 1 waits for block 0 to be delivered
            waitedInVain = !waitUntil(() => atomicLoad(firstDelivered));
            return 0;
        },
        (size_t done, const(size_t)[] found) {
            if (done == 1)
                atomicStore(firstDelivered, true);
            return true;
        }, pool);
    assert(!waitedInVain);
}

@("parallelScan: blocks waiting for a thread are dropped once the scan stops")
unittest
{
    import core.atomic : atomicLoad, atomicOp, atomicStore;

    auto pool = new TaskPool(2);
    scope (exit)
        pool.finish(true);

    shared size_t scanned = 0;
    shared bool missedStop = false, anotherStarted = false;
    const completed = parallelScan!size_t(1000, 1,
        (size_t lo, size_t hi, size_t[] found, ScanStop stop) {
            atomicOp!"+="(scanned, 1);
            if (lo == 0)
            {
                waitUntil(() => atomicLoad(anotherStarted)); // the stop finds a block being scanned
                return 0;
            }
            atomicStore(anotherStarted, true);
            // Holds its thread until the stop: no thread can take a block
            // after the one it started
            if (!waitUntil(() => stop()))
                atomicStore(missedStop, true);
            return 0;
        },
        (size_t done, const(size_t)[] found) => false, pool);
    assert(!completed);
    assert(atomicLoad(anotherStarted));
    assert(!atomicLoad(missedStop), "a block being scanned isn't told of the stop");
    // Block 0 and a block for each worker at most; 12 blocks were in flight
    assert(atomicLoad(scanned) <= 1 + pool.size);
}

@("parallelScan: a failure of deliver stops the blocks being scanned")
unittest
{
    import core.atomic : atomicLoad, atomicStore;
    import std.exception : assertThrown;

    auto pool = new TaskPool(3);
    scope (exit)
        pool.finish(true);

    shared bool missedStop = false, anotherStarted = false;
    assertThrown!Exception(parallelScan!size_t(1000, 1,
        (size_t lo, size_t hi, size_t[] found, ScanStop stop) {
            if (lo == 0)
            {
                waitUntil(() => atomicLoad(anotherStarted)); // the failure finds a block being scanned
                return 0;
            }
            atomicStore(anotherStarted, true);
            if (!waitUntil(() => stop()))
                atomicStore(missedStop, true);
            return 0;
        },
        (size_t done, const(size_t)[] found) {
            if (done > 0)
                throw new Exception("the index can't grow");
            return true;
        }, pool));
    assert(atomicLoad(anotherStarted));
    assert(!atomicLoad(missedStop), "a block goes on after deliver failed");
}

@("parallelScan: no block is left running when a block fails with an Error")
unittest
{
    import core.atomic : atomicLoad, atomicOp;
    import core.exception : AssertError;
    import core.thread : Thread;
    import core.time : msecs;

    auto pool = new TaskPool(3);
    scope (exit)
        pool.finish(true);

    shared int running = 0;
    bool failed = false;
    try
        parallelScan!size_t(100, 1,
            (size_t lo, size_t hi, size_t[] found, ScanStop stop) {
                if (lo == 0)
                {
                    Thread.sleep(5.msecs); // the others have started
                    throw new AssertError("broken");
                }
                atomicOp!"+="(running, 1);
                Thread.sleep(30.msecs);
                atomicOp!"-="(running, 1);
                return 0;
            },
            (size_t done, const(size_t)[] found) => true, pool);
    catch (AssertError)
        failed = true;
    assert(failed);
    assert(atomicLoad(running) == 0, "a block still uses the frame of the scan");
}

@("parallelFold: each block folds into its own accumulator, merged in the order of the blocks")
unittest
{
    static struct Span
    {
        size_t first = size_t.max, last, count; // of the multiples of 3
    }

    auto pool = new TaskPool(3);
    scope (exit)
        pool.finish(true);

    foreach (length; [0, 1, 99, 100, 101, 12_345])
    {
        Span all;
        size_t lastDone = 0;
        const completed = parallelFold!Span(length, 100,
            (size_t lo, size_t hi, ScanStop stop) {
                Span span;
                foreach (i; lo .. hi)
                    if (i % 3 == 0)
                    {
                        if (span.count++ == 0)
                            span.first = i;
                        span.last = i;
                    }
                return span;
            },
            (size_t done, ref Span folded) {
                assert(done > lastDone && (done == length || done % 100 == 0), "merged in order");
                lastDone = done;
                if (folded.count == 0)
                    return true;
                if (all.count == 0)
                    all.first = folded.first;
                all.last = folded.last;
                all.count += folded.count;
                return true;
            }, pool);
        assert(completed && lastDone == length);
        assert(all.count == (length + 2) / 3);
        if (length > 0)
            assert(all.first == 0 && all.last == (length - 1) / 3 * 3, "the first and the last stay so");
    }
}

@("parallelFold: merge returning false stops the fold")
unittest
{
    size_t merged = 0;
    const completed = parallelFold!size_t(1_000_000, 10,
        (size_t lo, size_t hi, ScanStop stop) => hi - lo,
        (size_t done, ref size_t folded) => ++merged < 3);
    assert(!completed && merged == 3);
}
