//! Scans a range of positions on a task pool in blocks and delivers what each
//! block found in the order of the blocks, as a sequential scan would.
module utils.parallel_scan;

import std.parallelism : TaskPool, taskPool;

//! @brief Scans [0, length) in blocks of `blockLength` positions on `pool`.
//! `scan(lo, hi, found)` runs concurrently for different blocks: it writes
//! what it finds in [lo, hi), at most a result per position, to the start of
//! `found` (room for `hi - lo` results), returns how many it wrote and must
//! only read shared state. The room is taken once for the whole scan, so
//! collecting a result costs a store, not an append. `deliver(done, found)` runs on the calling thread, one block
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
    scope size_t delegate(size_t lo, size_t hi, T[] found) scan,
    scope bool delegate(size_t done, const(T)[] found) deliver,
    TaskPool pool = null)
{
    import std.algorithm.comparison : min;
    import std.parallelism : task;

    assert(blockLength > 0);
    if (pool is null)
        pool = taskPool;

    const blockCount = (length + blockLength - 1) / blockLength;
    // Several blocks per thread, so a slow block doesn't leave the others idle
    const inFlight = (pool.size + 1) * blocksPerThread; // the calling thread works too
    // The room of a slot, reused by its blocks; what its last block wrote
    auto room = new T[inFlight * blockLength];
    auto foundCount = new size_t[inFlight];
    // What a block threw, rethrown on delivery. A task must not throw: an
    // Error of a task run by yieldForce on the waiting thread leaves the task
    // in progress for good (std.parallelism catches only Exception there)
    auto failure = new Throwable[inFlight];

    // Set once the scan stops or fails: a block no thread has started yet is dropped
    shared bool stopped = false;

    void scanBlock(size_t block)
    {
        import core.atomic : atomicLoad;

        const slot = block % inFlight;
        failure[slot] = null;
        if (atomicLoad(stopped))
            return;
        foundCount[slot] = 0;
        const lo = block * blockLength, hi = min(lo + blockLength, length);
        auto slotRoom = room[slot * blockLength .. slot * blockLength + (hi - lo)];
        try
        {
            const n = scan(lo, hi, slotRoom);
            assert(n <= slotRoom.length, "more results than positions");
            foundCount[slot] = n;
        }
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
        import core.atomic : atomicStore;

        atomicStore(stopped, true); // nothing is left to scan when the scan is complete
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
        const keepOn = deliver(done, room[slot * blockLength .. slot * blockLength + foundCount[slot]]);
        ++delivered;
        if (!keepOn)
            return false;
        if (submitted < blockCount)
            submit(); // into the slot just delivered
    }
    return true;
}

//! Blocks in flight for each thread
private enum blocksPerThread = 4;

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
            (size_t lo, size_t hi, size_t[] found) {
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
        (size_t lo, size_t hi, size_t[] found) {
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
        (size_t lo, size_t hi, size_t[] found) { atomicOp!"+="(scanned, 1); return 0; },
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
        (size_t lo, size_t hi, size_t[] found) {
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
        (size_t lo, size_t hi, size_t[] found) {
            synchronized (mutex)
                threads[Thread.getThis()] = true;
            Thread.sleep(5.msecs);
            return 0;
        },
        (size_t done, const(size_t)[] found) => true, pool);
    assert(threads.length > 1);
}

@("parallelScan: a block is delivered once the blocks before it are, not after its window")
unittest
{
    import core.atomic : atomicLoad, atomicStore;
    import core.thread : Thread;
    import core.time : msecs, MonoTime;

    auto pool = new TaskPool(2);
    scope (exit)
        pool.finish(true);

    shared bool firstDelivered = false;
    bool waitedInVain = false;
    parallelScan!size_t(4, 1,
        (size_t lo, size_t hi, size_t[] found) {
            if (lo != 1)
                return 0;
            // The window of block 0 holds block 1 too: block 1 waits for block 0 to be delivered
            const deadline = MonoTime.currTime + 2000.msecs;
            while (!atomicLoad(firstDelivered) && MonoTime.currTime < deadline)
                Thread.sleep(1.msecs);
            waitedInVain = !atomicLoad(firstDelivered);
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
    import core.atomic : atomicLoad, atomicOp;
    import core.thread : Thread;
    import core.time : msecs;

    auto pool = new TaskPool(2);
    scope (exit)
        pool.finish(true);

    shared size_t scanned = 0;
    const completed = parallelScan!size_t(1000, 1,
        (size_t lo, size_t hi, size_t[] found) {
            atomicOp!"+="(scanned, 1);
            Thread.sleep(2.msecs);
            return 0;
        },
        (size_t done, const(size_t)[] found) => false, pool);
    assert(!completed);
    // 3 threads, 12 blocks in flight: the ones started go on, the others are dropped
    assert(atomicLoad(scanned) <= 6);
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
            (size_t lo, size_t hi, size_t[] found) {
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
