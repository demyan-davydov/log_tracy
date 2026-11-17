//! The progress of the operations of a document from the positions of a pass of its index
//! (PassProgress): which of them run is the document's to know. A stage is as far as the
//! one it follows while that one has more to give. And ProgressThrottle: which progress is
//! worth an OperationProgress.
module domain.operation_progress;

import domain.document : Document;
import domain.index.progress : PassProgress;

alias Operation = Document.Operation;
alias ProgressValues = float[Operation.max + 1];

//! The operations of a document that run: their progress is told
struct Running
{
    bool loading;
    bool filtering;
    bool searching;
}

//! @return the progress of the operations that run, 0..1; NaN for one that doesn't
ProgressValues progressOf(in PassProgress p, Running running) pure nothrow @nogc @safe
{
    ProgressValues values; // NaN
    const float load = p.bytes ? cast(float) p.loadedBytes / p.bytes : 1.0f;
    if (running.loading)
        values[Operation.BuildOffsetIndex] = load;
    if (running.filtering)
        values[Operation.BuildFilterIndex] = p.loadBehind ? load
            : p.records ? cast(float) p.filtered / p.records : 1.0f;
    if (running.searching)
        values[Operation.BuildSearchIndex] = p.loadBehind ? load
            : p.filtered < p.records ? values[Operation.BuildFilterIndex]
            : p.rows ? cast(float) p.searched / p.rows : 1.0f;
    return values;
}

//! @return the load reached the end of the bytes it can split: it is over
bool loadOver(in PassProgress p) pure nothrow @nogc @safe
{
    return !p.loadBehind;
}

//! @return the filter covers every record found, once the load is over (`loading` false):
//! it is over, while a search may go on over its view
bool filterOver(in PassProgress p, bool loading) pure nothrow @nogc @safe
{
    return !loading && p.filtered >= p.records;
}

//! Minimal progress change worth an event
enum float progressStep = 0.01f;

//! Which progress is worth an OperationProgress: an operation moved by progressStep, reached
//! its end or went back. Started anew by each pass
struct ProgressThrottle
{
    private ProgressValues _published = -1;

    //! @return true if `values` are worth telling: they are taken as told then
    bool take(in ProgressValues values) pure nothrow @nogc @safe
    {
        bool worth = false;
        foreach (i, value; values)
        {
            if (value != value) // not running
                continue;
            if ((value >= 1.0f && _published[i] < 1.0f) || value - _published[i] >= progressStep
                || value < _published[i])
                worth = true;
        }
        if (!worth)
            return false;
        foreach (i, value; values)
            if (value == value)
                _published[i] = value;
        return true;
    }

    //! A pass starts: its first progress is told
    void reset() pure nothrow @nogc @safe
    {
        _published = -1;
    }
}

version (unittest)
{
    private bool isNan(float value) pure nothrow @nogc @safe => value != value;
}

@("progressOf: the operations that run only, as far as their positions")
unittest
{
    // Loaded, filtered, half searched
    const p = PassProgress(1000, 1000, false, 100, 100, 40, 20);
    auto values = progressOf(p, Running(false, false, true));
    assert(isNan(values[Operation.None]) && isNan(values[Operation.BuildOffsetIndex]));
    assert(isNan(values[Operation.BuildFilterIndex]));
    assert(values[Operation.BuildSearchIndex] == 0.5f);

    values = progressOf(PassProgress(1000, 1000, false, 100, 25, 10, 0), Running(false, true, false));
    assert(values[Operation.BuildFilterIndex] == 0.25f);
    assert(isNan(values[Operation.BuildSearchIndex]));
}

@("progressOf: a stage is as far as the one it follows, while that one has more to give")
unittest
{
    // Loading: the filter and the search are as far as the load
    auto values = progressOf(PassProgress(300, 1000, true, 30, 30, 10, 10), Running(true, true, true));
    assert(values[Operation.BuildOffsetIndex] == 0.3f);
    assert(values[Operation.BuildFilterIndex] == 0.3f);
    assert(values[Operation.BuildSearchIndex] == 0.3f);

    // Loaded, filtering: the search is as far as the filter
    values = progressOf(PassProgress(1000, 1000, false, 100, 60, 20, 20), Running(false, true, true));
    assert(values[Operation.BuildFilterIndex] == 0.6f);
    assert(values[Operation.BuildSearchIndex] == 0.6f);

    // A filter that isn't told (a source that grew after it was done): nor is the search
    values = progressOf(PassProgress(1000, 1000, false, 100, 60, 20, 20), Running(false, false, true));
    assert(isNan(values[Operation.BuildSearchIndex]));
}

@("progressOf: nothing to cover is complete")
unittest
{
    const values = progressOf(PassProgress(0, 0, false, 0, 0, 0, 0), Running(true, true, true));
    assert(values[Operation.BuildOffsetIndex] == 1.0f);
    assert(values[Operation.BuildFilterIndex] == 1.0f);
    assert(values[Operation.BuildSearchIndex] == 1.0f);
}

@("loadOver: the load at the end of the bytes it can split")
unittest
{
    assert(!loadOver(PassProgress(300, 1000, true)));
    assert(loadOver(PassProgress(1000, 1000, false)));
    assert(loadOver(PassProgress(990, 1000, false)), "the last bytes wait for the rest of their record");
}

@("filterOver: the filter over every record, once the load is over")
unittest
{
    assert(!filterOver(PassProgress(1000, 1000, false, 100, 100), true), "the load goes on");
    assert(filterOver(PassProgress(1000, 1000, false, 100, 100), false));
    assert(!filterOver(PassProgress(1000, 1000, false, 100, 99), false));
}

@("ProgressThrottle: a step, the end, a move back; anew after a reset")
unittest
{
    ProgressValues values; // NaN: nothing runs
    ProgressThrottle throttle;
    assert(!throttle.take(values), "nothing to tell");

    values[Operation.BuildOffsetIndex] = 0.0f;
    assert(throttle.take(values), "the first progress");
    values[Operation.BuildOffsetIndex] = 0.005f;
    assert(!throttle.take(values), "less than a step");
    values[Operation.BuildOffsetIndex] = 0.011f;
    assert(throttle.take(values));
    values[Operation.BuildOffsetIndex] = 0.995f;
    assert(throttle.take(values));
    values[Operation.BuildOffsetIndex] = 1.0f;
    assert(throttle.take(values), "the end");
    assert(!throttle.take(values));
    values[Operation.BuildOffsetIndex] = 0.5f;
    assert(throttle.take(values), "back");

    throttle.reset();
    assert(throttle.take(values), "a pass tells its first progress");
}
