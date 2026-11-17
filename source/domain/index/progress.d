//! PassProgress: the positions a pass of LogIndex has got to, by its own facts (bytes split,
//! records filtered, rows searched), and ProgressReporter, which publishes them throttled.
//! Which operations they are the progress of is the document's to say
//! (domain/operation_progress).
module domain.index.progress;

import utils.event_bus.event_bus_interface : SignalProducer;

//! Minimal move of a position, a part of its total, worth an event
enum double positionStep = 0.01;

//! How far a pass of LogIndex has got. Published from the worker thread; only the latest
//! matters, and events of one type override each other at the end of the queue
struct PassProgress
{
    enum isOverridable = true;

    ulong loadedBytes; // of `bytes`, split into records
    ulong bytes; // the bytes the pass splits: a source that grows meanwhile is taken by the next one
    bool loadBehind; // bytes are left to split, and no record waits at them for more
    size_t records; // in the offset index
    size_t filtered; // of `records`, those the filter of the main view covers: all of them without one
    size_t rows; // of the main view
    size_t searched; // of `rows`, those the search covers: all of them when it isn't built
}

//! Publishes the positions of a pass, a part of them: the first ones, those where a position
//! moved by positionStep of its total, reached it or went back, and those it is told to
struct ProgressReporter
{
    private SignalProducer _events;
    private PassProgress _published;
    private bool _any; // something was published

    this(SignalProducer events)
    {
        _events = events;
    }

    //! @param force - published whatever it moved: the document decides the end of a stage by it
    void report(in PassProgress progress, bool force = false)
    {
        if (!force && _any && !worthTelling(_published, progress))
            return;
        _published = progress;
        _any = true;
        _events.publish(progress);
    }
}

//! A position moved enough since `told` to be told again
bool worthTelling(in PassProgress told, in PassProgress now) pure nothrow @nogc @safe
{
    return now.loadBehind != told.loadBehind
        || moved(told.loadedBytes, told.bytes, now.loadedBytes, now.bytes)
        || moved(told.filtered, told.records, now.filtered, now.records)
        || moved(told.searched, told.rows, now.searched, now.rows);
}

//! A position at its total that stays there as the total grows (a stage that isn't built,
//! or that keeps up with the one before it) tells nothing: the stage before it tells it.
//! Else one would be told for every bunch of records the load finds
private bool moved(ulong told, ulong toldTotal, ulong now, ulong total) pure nothrow @nogc @safe
{
    if (now == told || told == toldTotal && now == total)
        return false;
    return now < told || now == total || now - told >= total * positionStep;
}

@("worthTelling: a position that moved by a step of its total")
unittest
{
    auto told = PassProgress(100, 1000, true, 10, 0, 0, 0);
    auto now = told;
    now.loadedBytes = 109;
    assert(!worthTelling(told, now), "less than a step");
    now.loadedBytes = 110;
    assert(worthTelling(told, now));

    now = told;
    now.records = 1000; // the total of the filter
    now.filtered = 9;
    assert(!worthTelling(told, now));
    now.filtered = 10;
    assert(worthTelling(told, now));

    now = told;
    now.rows = 100;
    now.searched = 1;
    assert(worthTelling(told, now));
}

@("worthTelling: a position that reached its total or went back, the load that caught up")
unittest
{
    auto told = PassProgress(995, 1000, true, 99, 99, 99, 98);
    auto now = told;
    now.loadedBytes = 1000;
    assert(worthTelling(told, now), "at its end");

    now = told;
    now.searched = 99;
    assert(worthTelling(told, now), "the search covers the rows");

    now = told;
    now.filtered = 50;
    assert(worthTelling(told, now), "went back");

    now = told;
    now.loadBehind = false;
    assert(worthTelling(told, now), "the load is at the end of the bytes it can split");

    assert(!worthTelling(told, told));
}

@("worthTelling: positions that stay at their totals as they grow are not told")
unittest
{
    // A load with no filter and no search: they cover every record and row found
    auto told = PassProgress(100, 1_000_000, true, 32, 32, 32, 32);
    auto now = PassProgress(101, 1_000_000, true, 64, 64, 64, 64);
    assert(!worthTelling(told, now), "a bunch of the load: the bytes tell it");
}

@("ProgressReporter: publishes the first positions, those worth telling and those it is told to")
unittest
{
    import utils.event_bus.event_bus_async : EventBusAsync;

    auto events = new EventBusAsync();
    PassProgress[] published;
    events.subscribe((const PassProgress e) { published ~= e; });
    auto reporter = ProgressReporter(events);
    auto progress = PassProgress(0, 1000, true);
    reporter.report(progress);
    events.dispatch();
    assert(published.length == 1, "the first ones");

    progress.loadedBytes = 5;
    reporter.report(progress);
    events.dispatch();
    assert(published.length == 1, "not worth telling");
    reporter.report(progress, true);
    events.dispatch();
    assert(published.length == 2 && published[1].loadedBytes == 5, "forced");
}
