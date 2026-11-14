//! Measures how long the indexes of a log take to build: the offset index, then
//! a filter and a search with the given query over it, each a few rounds.
//!
//! ldc2 -O3 -release -enable-inlining -i -preview=in -preview=dip1000 -preview=dtorfields -Isource \
//!     scripts/utils/bench_index.d -of=/tmp/bench_index && /tmp/bench_index <log> [query] [text|regex] [ic|cs]
//! (the query is a text that ignores case by default)
//!
//! Options:
//!   --rounds=N     filters and searches of each kind (3); with many, the summary
//!                  shows whether the later ones are slower than the first
//!   --threads=N    worker threads of the task pool (by default the cores - 1)
//!   --generate=N   first writes to <log> N short lines, all of them "a" and a
//!                  number: decoding is cheap there, so the cost of collecting
//!                  the matches shows most
//!   --search-only  no filter rounds
//!   --regex=R      one more chip, a regular expression ignoring case; repeated for
//!                  more: a record matching none tries each chip in turn
//!
//! A sign that collecting the matches costs (docs/stories/parallel-indexing.md):
//! on --generate lines, a query every record matches ("a") is slower than one
//! nothing matches ("zzz"), gets slower round after round, or scales worse
//! with --threads.
//!
//! `node scripts/build.mjs bench` reads what this prints (scripts/utils/bench.mjs, parseMetrics):
//! a measure is a number with its unit (ms, ns/row, MB), named by its line up to the colon
//! and its part between commas, semicolons and brackets; an indented line belongs to the
//! unindented one above it. A number printed without its unit drops out of the comparison.
module bench_index;

import core.memory : GC;
import core.thread : Thread;
import core.time : msecs, MonoTime;
import std.algorithm : map, sort, sum;
import std.array : array;
import std.getopt : getopt;
import std.stdio : writefln;

import domain.anchors : Anchors;
import domain.document : Document, OperationFinished;
import domain.log_index : LogIndex;
import formats.registry : detectFormat;
import log_core.byte_source : FileSource;
import log_core.search_filter : SearchChip, SearchFilter;
import utils.event_bus.event_bus_async : EventBusAsync;

void main(string[] args)
{
    size_t rounds = 3, generate = 0;
    uint threads = 0;
    bool searchOnly = false;
    string[] moreRegexes;
    getopt(args, "rounds", &rounds, "threads", &threads, "generate", &generate,
        "search-only", &searchOnly, "regex", &moreRegexes);

    const path = args[1];
    const text = args.length > 2 ? args[2] : "error";
    const isRegex = args.length > 3 && args[3] == "regex";
    const ignoreCase = !(args.length > 4 && args[4] == "cs");

    if (threads > 0)
    {
        import std.parallelism : defaultPoolThreads;

        defaultPoolThreads = threads; // before the pool is first used
    }
    if (generate > 0)
        writeShortLines(path, generate);

    auto source = new FileSource(path);
    auto format = detectFormat(path, source.data);
    auto events = new EventBusAsync();
    // The file measures the working tree and the ref it is compared with
    // (build.mjs bench): an index built by passes (runPass), or by an
    // operation per index before that
    enum byPasses = __traits(hasMember, LogIndex, "runPass");
    size_t ended; // the passes or the operations that ended
    static if (byPasses)
    {
        import domain.log_index : PassFinished;

        events.subscribe((const PassFinished e) { ++ended; });
    }
    else
        events.subscribe((const OperationFinished e) { ++ended; });

    void waitEnd()
    {
        const before = ended;
        while (ended == before)
        {
            events.dispatch();
            Thread.sleep(1.msecs);
        }
    }

    auto start = MonoTime.currTime;
    auto index = LogIndex(source, format, events);
    waitEnd();

    void buildFilter(SearchFilter filter)
    {
        static if (byPasses)
        {
            index.setViewFilter(filter, Anchors.init);
            index.runPass();
        }
        else
            index.runBuildFilterIndex(filter, Anchors.init);
        waitEnd();
    }

    void buildSearch(SearchFilter filter)
    {
        static if (byPasses)
        {
            index.setSearchFilter(filter, Anchors.init);
            index.runPass();
        }
        else
            index.runBuildSearchIndex(filter, Anchors.init);
        waitEnd();
    }

    writefln("offsets: %s records in %.1f ms", index.messageCount, msSince(start));

    auto chips = [SearchChip(text, isRegex, ignoreCase)];
    foreach (more; moreRegexes)
        chips ~= SearchChip(more, true, true);
    auto filter = SearchFilter.fromChips(chips);
    double[] times;

    if (!searchOnly)
    {
        foreach (round; 0 .. rounds)
        {
            start = MonoTime.currTime;
            buildFilter(filter);
            times ~= msSince(start);
            writefln("filter: %s shown in %.1f ms", index.mainViewItemsCount, times[$ - 1]);
        }
        summarize("filter", times);
        buildFilter(null);
    }

    times = null;
    foreach (round; 0 .. rounds)
    {
        start = MonoTime.currTime;
        buildSearch(filter);
        times ~= msSince(start);
        writefln("search: %s found in %.1f ms", index.searchViewItemsCount, times[$ - 1]);
    }
    summarize("search", times);
}

//! Prints the spread of the times of the rounds, the later ones against the first
//! ones, and what the GC did so far
void summarize(string what, double[] times)
{
    if (times.length < 2)
        return;
    auto sorted = times.dup;
    sort(sorted);
    const third = (times.length + 2) / 3;
    const first = cast(double) times[0 .. third].sum / third;
    const last = cast(double) times[$ - third .. $].sum / third;
    const stats = GC.stats;
    writefln("%s summary: min %.1f ms, median %.1f ms, max %.1f ms; last third / first third: %.2f;"
        ~ " GC: %s collections, %s MB used",
        what, sorted[0], sorted[$ / 2], sorted[$ - 1], last / first,
        GC.profileStats.numCollections, stats.usedSize / (1024 * 1024));
}

//! Milliseconds since `start`, to a tenth: a step of 1 ms is a few percent of a search
double msSince(MonoTime start)
{
    return (MonoTime.currTime - start).total!"usecs" / 1000.0;
}

//! Writes `lines` lines "a <number>"
void writeShortLines(string path, size_t lines)
{
    import std.stdio : File;

    auto file = File(path, "w");
    foreach (i; 0 .. lines)
        file.writefln("a %s", i);
}
