//! foldRecords: the records of a range of positions decoded in parallel blocks
//! (utils/parallel_scan) and folded, each block into an accumulator of its own, the
//! accumulators merged in the order of the blocks: a count by a value, the first and the
//! last record of a group, without decoding the range again on one thread. It reads the
//! records through Records only, from the threads of the pool, so the caller keeps them
//! open until it returns (a lease, or the holder's own scan).
module domain.index.record_fold;

import domain.index.match_scan : givesUp, scanBlockLength, stopCheckRecords;
import domain.index.record_store : Records;
import log_core.log_message : LogMessage;

import std.parallelism : TaskPool;

//! @brief Folds the records of the positions [from, to) in parallel blocks: each block
//! into an accumulator of its own (A.init), merged block by block in order. A block gives
//! up at its next check when `cancelled()` is true or the records are lost or closing
//! (Records.closing): the fold stops then, and no block is merged from then on (nor one
//! that read records of a lost file as zeros).
//! @param records - the records the positions are of: read from many threads at once
//! @param messageAt - the record of a position; called from many threads at once, so it
//!   may only read what doesn't change while the fold runs
//! @param fold - `fold(acc, record, msg)` adds the record `record`, decoded into `msg`, to
//!   the accumulator of its block; called from many threads at once, for the records of a
//!   block in order. A record that can't be decoded is skipped
//! @param cancelled - called from many threads at once; once true, it stays true
//! @param merge - `merge(done, acc)` on the calling thread: the accumulator of the
//!   positions before `done` not merged yet, the block's own; false stops the fold. It may
//!   throw: the fold stops and the exception comes out of foldRecords
//! @param pool - the threads the blocks run on; null: the shared task pool (see
//!   scanMatches)
//! @return false if the fold stopped before `to`: `merge` or a block gave up (the caller
//!   tells a cancel from a lost file by Records.lost)
bool foldRecords(A)(Records records, size_t from, size_t to, scope size_t delegate(size_t position) messageAt,
    scope void delegate(ref A acc, size_t record, ref const(LogMessage!wchar) msg) fold,
    scope bool delegate() cancelled, scope bool delegate(size_t done, ref A acc) merge, TaskPool pool = null)
{
    import utils.parallel_scan : parallelFold, ScanStop;

    assert(from <= to);
    return parallelFold!A(to - from, scanBlockLength,
        (size_t lo, size_t hi, ScanStop stop) {
            A acc;
            LogMessage!wchar msg; // a buffer per block: blocks run on several threads
            foreach (position; from + lo .. from + hi)
            {
                // A stop: this block is never merged (givesUp is checked again before)
                if ((position - from - lo) % stopCheckRecords == 0 && (givesUp(records, cancelled) || stop()))
                    break;
                const record = messageAt(position);
                if (records.decode(record, msg))
                    fold(acc, record, msg);
            }
            return acc;
        },
        (size_t done, ref A acc) => !givesUp(records, cancelled) && merge(from + done, acc), pool);
}

version (unittest)
{
    import domain.index.match_scan : storeOf;

    //! Of the lines that have "seven": how many, the first and the last
    private struct Sevens
    {
        size_t count, first, last;

        void add(size_t record)
        {
            if (count++ == 0)
                first = record;
            last = record;
        }

        void add(ref const Sevens other)
        {
            if (other.count == 0)
                return;
            if (count == 0)
                first = other.first;
            last = other.last;
            count += other.count;
        }
    }

    private bool hasSeven(ref const(LogMessage!wchar) msg)
    {
        import std.algorithm.searching : canFind;

        return msg.payloadText.canFind("seven"w);
    }
}

@("foldRecords: the records of a range folded over many blocks, merged in order")
unittest
{
    import std.algorithm : filter;
    import std.array : array;
    import std.range : iota;

    enum lines = 5 * scanBlockLength + 123;
    auto records = storeOf(lines).records;
    const from = 2, to = lines - 10;
    Sevens all;
    size_t lastDone = from;
    const completed = foldRecords!Sevens(records, from, to, (size_t p) => p,
        (ref Sevens acc, size_t record, ref const(LogMessage!wchar) msg) {
            if (hasSeven(msg))
                acc.add(record);
        },
        () => false,
        (size_t done, ref Sevens acc) {
            assert(done > lastDone && done <= to, "merged in order, up to the end of the range");
            lastDone = done;
            all.add(acc);
            return true;
        });
    const expected = iota(from, to).filter!(i => i % 7 == 0).array;
    assert(completed && lastDone == to);
    assert(all.count == expected.length && all.first == expected[0] && all.last == expected[$ - 1]);
}

@("foldRecords: a merge that returns false stops the fold")
unittest
{
    auto records = storeOf(3 * scanBlockLength).records;
    size_t merged;
    const completed = foldRecords!size_t(records, 0, records.length, (size_t p) => p,
        (ref size_t acc, size_t record, ref const(LogMessage!wchar) msg) { ++acc; },
        () => false, (size_t done, ref size_t acc) => ++merged < 2);
    assert(!completed && merged == 2);
}

@("foldRecords: a cancel stops the fold, the block cut short is not merged")
unittest
{
    import core.atomic : atomicLoad, atomicOp, atomicStore;

    enum blocks = 8;
    auto records = storeOf(blocks * scanBlockLength).records;
    shared bool cancel;
    shared size_t folded;
    size_t merged;
    const completed = foldRecords!size_t(records, 0, records.length, (size_t p) => p,
        (ref size_t acc, size_t record, ref const(LogMessage!wchar) msg) {
            ++acc;
            if (atomicOp!"+="(folded, 1) == 1)
                atomicStore(cancel, true); // cancelled by the first record folded
        },
        () => atomicLoad(cancel),
        (size_t done, ref size_t acc) { merged += acc; return true; });
    assert(!completed, "a fold cancelled is not complete");
    assert(merged % scanBlockLength == 0, "only whole blocks are merged");
    assert(atomicLoad(folded) < blocks * stopCheckRecords * 2, "a block went on after the cancel");
}

@("foldRecords: leased records whose holder is closing stop the fold")
unittest
{
    import core.atomic : atomicOp;

    auto store = storeOf(4 * scanBlockLength);
    auto lease = store.lease();
    shared size_t folded;
    const completed = foldRecords!size_t(lease.records, 0, lease.records.length, (size_t p) => p,
        (ref size_t acc, size_t record, ref const(LogMessage!wchar) msg) {
            if (atomicOp!"+="(folded, 1) == 1)
                store.markClosing(); // the document is closed meanwhile
        },
        () => false, (size_t done, ref size_t acc) => true);
    assert(!completed);
}

@("foldRecords: the blocks run on the pool given")
unittest
{
    import core.atomic : atomicLoad, atomicStore;

    auto pool = new TaskPool(2);
    scope (exit)
        pool.finish(true);
    auto records = storeOf(8 * scanBlockLength).records;
    shared bool onPool;
    foldRecords!size_t(records, 0, records.length, (size_t p) => p,
        (ref size_t acc, size_t record, ref const(LogMessage!wchar) msg) {
            if (pool.workerIndex > 0)
                atomicStore(onPool, true);
        },
        () => false, (size_t done, ref size_t acc) => true, pool);
    assert(atomicLoad(onPool), "no block ran on a thread of the pool");
}
