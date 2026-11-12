//! scanMatches: the records of a range of positions that are anchored or that a filter
//! matches, scanned in parallel blocks (utils/parallel_scan) and delivered in the order of
//! the positions. It reads the records through Records only: what its caller was given,
//! read from the threads of the pool, so the caller keeps the store open until it returns.
module domain.index.match_scan;

import domain.anchors : Anchors;
import domain.index.record_store : Records;
import log_core.log_filter : LogFilter;
import log_core.log_message : LogMessage;

import std.parallelism : TaskPool;

//! Positions a thread scans at a time: what a block finds is at most 64 KB, and a few
//! blocks per thread are held (utils/parallel_scan)
enum size_t scanBlockLength = 16 * 1024;

//! Positions a block scans between its checks of a stop (a cancel, a lost file)
enum size_t stopCheckRecords = 256;

//! @brief Scans the positions [from, to) in parallel blocks for the records that are in
//! `anchors` or that `filter` matches, and delivers them block by block in order, as soon
//! as a block and the ones before it are scanned. A block gives up at its next check when
//! `cancelled()` is true, the records are lost or closing (Records.closing): what it found then
//! is not delivered.
//! @param records - the records the positions are of: read from many threads at once
//! @param messageAt - the record of a position; called from many threads at once, so it
//!   may only read what doesn't change while the scan runs
//! @param filter - called from many threads at once (LogFilter)
//! @param cancelled - called from many threads at once
//! @param deliver - `deliver(done, found)` on the calling thread: the records `found` in
//!   the positions before `done`, valid during the call only; false stops the scan. It may
//!   throw: the scan stops and the exception comes out of scanMatches
//! @param pool - the threads the blocks run on; null: the shared task pool. A reader that
//!   shouldn't slow the window down scans on a pool of its own
//! @return false if `deliver` stopped the scan
bool scanMatches(T)(Records records, size_t from, size_t to, scope size_t delegate(size_t position) messageAt,
    const(LogFilter!wchar) filter, ref const(Anchors) anchors, scope bool delegate() cancelled,
    scope bool delegate(size_t done, const(T)[] found) deliver, TaskPool pool = null)
{
    import utils.parallel_scan : parallelScan, ScanStop;

    assert(from <= to);
    return parallelScan!T(to - from, scanBlockLength,
        (size_t lo, size_t hi, T[] found, ScanStop stop) {
            LogMessage!wchar msg; // a buffer per block: blocks run on several threads
            size_t n = 0;
            foreach (position; from + lo .. from + hi)
            {
                // A stop: the delivery of this block stops the scan, or fails it, or it
                // is never delivered
                if ((position - from - lo) % stopCheckRecords == 0 && (cancelled() || records.lost || records.closing || stop()))
                    break;
                const record = messageAt(position);
                if (!records.decode(record, msg))
                    continue;
                if (anchors.has(record) || filter.matches(msg))
                    found[n++] = cast(T) record;
            }
            return n;
        },
        (size_t done, const(T)[] found) => deliver(from + done, found), pool);
}

version (unittest)
{
    import domain.index.record_store : RecordStore;
    import log_core.byte_source : ByteSource;

    private final class Lines : ByteSource
    {
        private const(ubyte)[] _data;

        this(string text)
        {
            _data = cast(const(ubyte)[]) text;
        }

        override const(ubyte)[] data() const pure nothrow @nogc => _data;
        override bool complete() const nothrow @nogc => true;
        override bool lost() const nothrow @nogc => false;
        override void close() nothrow @nogc {}
    }

    //! A store of `lines` lines "line <i>", " seven" after those divisible by 7
    package RecordStore storeOf(size_t lines)
    {
        import formats.plain_text : PlainTextFormat;
        import std.array : appender;
        import std.format : formattedWrite;

        auto text = appender!string;
        foreach (i; 0 .. lines)
            text.formattedWrite("line %s%s\n", i, i % 7 == 0 ? " seven" : "");
        auto store = new RecordStore(new Lines(text[]), new PlainTextFormat());
        for (;;)
        {
            const bunch = store.findRecords(store.data, true);
            if (bunch.found.count == 0 && bunch.found.next == store.scannedBytes)
                break; // no more: a bunch of none may have skipped bytes that are no record
            assert(store.append(bunch));
        }
        return store;
    }
}

@("scanMatches: the anchored and the matching records of a range, in order, over many blocks")
unittest
{
    import log_core.search_filter : SearchChip, SearchFilter;
    import std.algorithm : filter;
    import std.array : array;
    import std.range : iota;

    enum lines = 5 * scanBlockLength + 123;
    auto records = storeOf(lines).records;
    Anchors anchors;
    anchors.set(3, true);
    const from = 2, to = lines - 10;

    uint[] all;
    size_t lastDone = from;
    const completed = scanMatches!uint(records, from, to, (size_t p) => p,
        SearchFilter.fromChips([SearchChip("seven")]), anchors, () => false,
        (size_t done, const(uint)[] found) {
            assert(done > lastDone && done <= to, "delivered in order, up to the end of the range");
            lastDone = done;
            all ~= found;
            return true;
        });
    assert(completed && lastDone == to);
    assert(all == iota(from, to).filter!(i => i % 7 == 0 || i == 3).array);
}

@("scanMatches: a delivery that returns false stops the scan")
unittest
{
    import log_core.search_filter : SearchChip, SearchFilter;

    auto records = storeOf(3 * scanBlockLength).records;
    Anchors anchors;
    size_t delivered;
    const completed = scanMatches!uint(records, 0, records.length, (size_t p) => p,
        SearchFilter.fromChips([SearchChip("line")]), anchors, () => false,
        (size_t done, const(uint)[] found) => ++delivered < 2);
    assert(!completed && delivered == 2);
}

@("scanMatches: a cancel stops the blocks being scanned at their next check, not at their end")
unittest
{
    import core.atomic : atomicLoad, atomicOp, atomicStore;
    import log_core.search_filter : SearchChip, SearchFilter;

    enum blocks = 8;
    auto records = storeOf(blocks * scanBlockLength).records;
    Anchors anchors;
    shared bool cancel;
    shared size_t scanned;
    scanMatches!uint(records, 0, records.length, (size_t p) {
            if (atomicOp!"+="(scanned, 1) == 1)
                atomicStore(cancel, true); // cancelled by the first position scanned
            return p;
        },
        SearchFilter.fromChips([SearchChip("line")]), anchors, () => atomicLoad(cancel),
        (size_t done, const(uint)[] found) => true);
    // A block goes on to its next check at most: without the checks every block would scan
    // its whole length
    assert(atomicLoad(scanned) < blocks * stopCheckRecords * 2, "a block went on after the cancel");
}

@("scanMatches: the blocks of records that are lost give up at their next check")
unittest
{
    import core.atomic : atomicLoad, atomicStore;
    import formats.plain_text : PlainTextFormat;
    import log_core.search_filter : SearchChip, SearchFilter;

    static final class Losable : ByteSource
    {
        private const(ubyte)[] _data;
        shared bool isLost;

        this(string text) { _data = cast(const(ubyte)[]) text; }

        override const(ubyte)[] data() const pure nothrow @nogc => _data;
        override bool complete() const nothrow @nogc => true;
        override bool lost() const nothrow @nogc => atomicLoad(isLost);
        override void close() nothrow @nogc {}
    }

    import std.array : replicate;

    auto source = new Losable("line\n".replicate(4 * scanBlockLength));
    auto store = new RecordStore(source, new PlainTextFormat());
    for (;;)
    {
        const bunch = store.findRecords(store.data, true);
        if (bunch.found.count == 0 && bunch.found.next == store.scannedBytes)
            break;
        assert(store.append(bunch));
    }
    Anchors anchors;
    shared size_t scanned;
    uint[] found;
    scanMatches!uint(store.records, 0, store.length, (size_t p) {
            import core.atomic : atomicOp;

            if (atomicOp!"+="(scanned, 1) == 1)
                atomicStore(source.isLost, true);
            return p;
        },
        SearchFilter.fromChips([SearchChip("line")]), anchors, () => false,
        (size_t done, const(uint)[] blockFound) { found ~= blockFound; return true; });
    // A block stops at its next check: a few checks' worth of positions per block at most
    assert(atomicLoad(scanned) < 4 * stopCheckRecords * 2, "a block of lost records went on");
    assert(found.length < 4 * stopCheckRecords * 2);
}

@("scanMatches: the blocks of leased records whose holder is closing give up at their next check")
unittest
{
    import core.atomic : atomicLoad, atomicOp;
    import log_core.search_filter : SearchChip, SearchFilter;

    auto store = storeOf(4 * scanBlockLength);
    auto lease = store.lease();
    Anchors anchors;
    shared size_t scanned;
    scanMatches!uint(lease.records, 0, lease.records.length, (size_t p) {
            if (atomicOp!"+="(scanned, 1) == 1)
                store.markClosing(); // the document is closed meanwhile
            return p;
        },
        SearchFilter.fromChips([SearchChip("line")]), anchors, () => false,
        (size_t done, const(uint)[] found) => true);
    assert(atomicLoad(scanned) < 4 * stopCheckRecords * 2, "a block of records closing went on");
}

@("scanMatches: the blocks run on the pool given")
unittest
{
    import core.atomic : atomicLoad, atomicStore;
    import log_core.search_filter : SearchChip, SearchFilter;

    auto pool = new TaskPool(2);
    scope (exit)
        pool.finish(true);
    auto records = storeOf(8 * scanBlockLength).records;
    Anchors anchors;
    shared bool onPool;
    scanMatches!uint(records, 0, records.length, (size_t p) {
            if (pool.workerIndex > 0)
                atomicStore(onPool, true);
            return p;
        },
        SearchFilter.fromChips([SearchChip("line")]), anchors, () => false,
        (size_t done, const(uint)[] found) => true, pool);
    assert(atomicLoad(onPool), "no block ran on a thread of the pool");
}
