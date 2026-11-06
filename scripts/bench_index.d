//! Measures how long the indexes of a log take to build: the offset index, then
//! a filter and a search with the given query over it, each a few rounds.
//!
//! ldc2 -O3 -release -i -preview=in -preview=dip1000 -preview=dtorfields -Isource \
//!     scripts/bench_index.d -of=/tmp/bench_index && /tmp/bench_index <log> [query] [text|regex] [ic|cs]
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
//!
//! A sign that collecting the matches costs (docs/stories/parallel-indexing.md):
//! on --generate lines, a query every record matches ("a") is slower than one
//! nothing matches ("zzz"), gets slower round after round, or scales worse
//! with --threads.
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
    getopt(args, "rounds", &rounds, "threads", &threads, "generate", &generate,
        "search-only", &searchOnly);

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
    Document.Operation finished = Document.Operation.None;
    events.subscribe((const OperationFinished e) { finished = e.operation; });

    void waitFor(Document.Operation op)
    {
        while (finished != op)
        {
            events.dispatch();
            Thread.sleep(1.msecs);
        }
        finished = Document.Operation.None;
    }

    auto start = MonoTime.currTime;
    auto index = LogIndex(source, format, events);
    waitFor(Document.Operation.BuildOffsetIndex);
    writefln("offsets: %s records in %s ms", index.messageCount,
        (MonoTime.currTime - start).total!"msecs");

    auto filter = SearchFilter.fromChips([SearchChip(text, isRegex, ignoreCase)]);
    long[] times;

    if (!searchOnly)
    {
        foreach (round; 0 .. rounds)
        {
            start = MonoTime.currTime;
            index.runBuildFilterIndex(filter, Anchors.init);
            waitFor(Document.Operation.BuildFilterIndex);
            times ~= (MonoTime.currTime - start).total!"msecs";
            writefln("filter: %s shown in %s ms", index.mainViewItemsCount, times[$ - 1]);
        }
        summarize("filter", times);
        index.runBuildFilterIndex(null, Anchors.init);
        waitFor(Document.Operation.BuildFilterIndex);
    }

    times = null;
    foreach (round; 0 .. rounds)
    {
        start = MonoTime.currTime;
        index.runBuildSearchIndex(filter, Anchors.init);
        waitFor(Document.Operation.BuildSearchIndex);
        times ~= (MonoTime.currTime - start).total!"msecs";
        writefln("search: %s found in %s ms", index.searchViewItemsCount, times[$ - 1]);
    }
    summarize("search", times);
}

//! Prints the spread of the times of the rounds, the later ones against the first
//! ones, and what the GC did so far
void summarize(string what, long[] times)
{
    if (times.length < 2)
        return;
    auto sorted = times.dup;
    sort(sorted);
    const third = (times.length + 2) / 3;
    const first = cast(double) times[0 .. third].sum / third;
    const last = cast(double) times[$ - third .. $].sum / third;
    const stats = GC.stats;
    writefln("%s summary: min %s, median %s, max %s ms; last third / first third: %.2f;"
        ~ " GC: %s collections, %s MB used",
        what, sorted[0], sorted[$ / 2], sorted[$ - 1], last / first,
        GC.profileStats.numCollections, stats.usedSize / (1024 * 1024));
}

//! Writes `lines` lines "a <number>"
void writeShortLines(string path, size_t lines)
{
    import std.stdio : File;

    auto file = File(path, "w");
    foreach (i; 0 .. lines)
        file.writefln("a %s", i);
}
