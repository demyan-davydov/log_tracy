//! Measures what scrolling a log costs: loading it, then fetching every row of
//! the main view (as the table does) without a search and with each given
//! search, and the rows of the search view; the memory of the process after
//! each step. Results on a reference log: docs/performance.md.
//!
//! ldc2 -O3 -release -enable-inlining -i -preview=in -preview=dip1000 -preview=dtorfields -Isource \
//!     scripts/bench_rows.d -of=/tmp/bench_rows && /tmp/bench_rows <log> [word...]
//! (each word is a search of one text chip that ignores case)
//!
//! Builds against older checkouts too: without DocumentItem.found (before the
//! main view marked the rows the search found) the "rows + fragments" line of
//! the main view is left out. Memory is read on macOS only.
//!
//! `node scripts/build.mjs bench` reads what this prints (scripts/bench.mjs, parseMetrics):
//! a measure is a number with its unit (ms, ns/row, MB), named by its line up to the colon
//! and its part between commas, semicolons and brackets; an indented line belongs to the
//! unindented one above it. A number printed without its unit drops out of the comparison.
module bench_rows;

import core.thread : Thread;
import core.time : msecs, MonoTime;
import std.stdio;
import std.conv : to;
import std.algorithm : min;

import domain.document;
import domain.document_item;
import domain.log_document;
import log_core.log_message : LogMessage;
import log_core.search_filter : MatchRange, maxMatchRanges, SearchChip, SearchFilter;

enum rounds = 5;

// Memory of the process (macOS TASK_VM_INFO): footprint is what Activity
// Monitor shows (no clean pages of the mapped file), resident counts them too
version (OSX)
{
    extern (C) uint mach_task_self();
    extern (C) int task_info(uint task, int flavor, int* info, uint* count);
}

void memory(string phase)
{
    version (OSX)
    {
        // task_vm_info as 64-bit words: [2] resident_size, [18] phys_footprint,
        // [21] ledger_phys_footprint_peak; 22 is TASK_VM_INFO
        ulong[64] info;
        uint count = info.sizeof / 4;
        if (task_info(mach_task_self(), 22, cast(int*) info.ptr, &count) != 0)
        {
            writeln("task_info failed");
            return;
        }
        enum mb = 1024.0 * 1024.0;
        writefln("  memory %-24s footprint %7.1f MB (peak %7.1f MB), resident %7.1f MB",
            phase ~ ":", info[18] / mb, info[21] / mb, info[2] / mb);
    }
}

double ms(MonoTime t0) { return (MonoTime.currTime - t0).total!"usecs" / 1000.0; }

void waitFinished(LogDocument doc, ref int finished, int target)
{
    const deadline = MonoTime.currTime + 600_000.msecs;
    while (finished < target && MonoTime.currTime < deadline)
    {
        doc.dispatchEvents();
        Thread.sleep(1.msecs);
    }
    assert(finished >= target, "timeout");
}

// The number of fragments of the chips in a payload: written to a buffer, or
// (before matchRanges took one) a new array
size_t fragmentsOf(SearchFilter search, ref const(LogMessage!wchar) msg)
{
    MatchRange[maxMatchRanges] buffer;
    static if (__traits(compiles, search.matchRanges(msg, buffer[])))
        return search.matchRanges(msg, buffer[]).length;
    else
        return search.matchRanges(msg).length;
}

enum hasFound = __traits(hasMember, DocumentItem, "found");

// Best of `rounds`: ns per row for the rows [0, count) of a view. withMatches:
// also what the app computes for a row it sends (the fragments of the chips
// for a found row; master computes them in the search view only)
double fetchRows(DocumentView view, size_t count, SearchFilter search, bool withMatches, out size_t found)
{
    DocumentItem item;
    double best = double.max;
    size_t fragments;
    foreach (r; 0 .. rounds)
    {
        found = 0;
        fragments = 0;
        const t0 = MonoTime.currTime;
        foreach (i; 0 .. count)
        {
            if (!view.fetchItem(i, item))
                assert(false, "no row " ~ i.to!string);
            static if (hasFound)
            {
                found += item.found;
                if (withMatches && item.found && search !is null)
                    fragments += fragmentsOf(search, item.message());
            }
            else
            {
                if (withMatches && search !is null)
                    fragments += fragmentsOf(search, item.message());
            }
        }
        const ns = (MonoTime.currTime - t0).total!"nsecs";
        best = min(best, cast(double) ns / count);
    }
    return best;
}

void main(string[] args)
{
    const path = args[1];
    int finished;

    memory("at start");
    auto t0 = MonoTime.currTime;
    auto doc = new LogDocument(path);
    doc.events.subscribe((const OperationFinished e) { ++finished; });
    waitFinished(doc, finished, 1);
    const rows = doc.mainView.itemsCount;
    writefln("records: %s, loaded in %.1f ms", rows, ms(t0));

    memory("after loading");
    size_t found;
    writefln("main view, no search:          %6.1f ns/row", fetchRows(doc.mainView, rows, null, false, found));

    foreach (word; args[2 .. $])
    {
        auto search = SearchFilter.fromChips([SearchChip(word)]);
        t0 = MonoTime.currTime;
        doc.applySearchFilter(search);
        waitFinished(doc, finished, finished + 1);
        const results = doc.searchView.itemsCount;
        const searchMs = ms(t0);
        writefln("search \"%s\": %s results (%.1f%%), found in %.1f ms", word, results,
            100.0 * results / rows, searchMs);
        memory("after the search"); // under its search: bench of build.mjs names a number by it
        writefln("  main view, rows only:        %6.1f ns/row", fetchRows(doc.mainView, rows, search, false, found));
        static if (hasFound)
            writefln("  main view, rows + fragments: %6.1f ns/row (found %s)",
                fetchRows(doc.mainView, rows, search, true, found), found);
        writefln("  search view + fragments:     %6.1f ns/row",
            fetchRows(doc.searchView, results, search, true, found));
        memory("after the rows");
    }
}
