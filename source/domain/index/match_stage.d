//! MatchStage: how far a stage of a pass of LogIndex that collects the records a filter
//! matches has got (the filter of the main view, the search): its filter, the positions it
//! covers, whether it was stopped and whether its progress and end are still to be told.
//!
//! Not thread-safe: LogIndex writes it from the UI thread while no pass runs and from the
//! worker of a pass while it runs.
module domain.index.match_stage;

import log_core.log_filter : LogFilter;

struct MatchStage
{
    alias Filter = LogFilter!wchar;

    // With no filter the stage still runs: it lists the anchors (the search). Otherwise a
    // stage with no filter has nothing to do (the main view shows every record)
    private bool _listsWithoutFilter;

    Filter filter; // null: none
    size_t scanned; // the positions its index covers
    bool stopped; // cancelled or failed: its index is left as it is
    bool report; // asked for and not complete yet: its progress and end are told

    this(bool listsWithoutFilter) pure nothrow @nogc @safe
    {
        _listsWithoutFilter = listsWithoutFilter;
    }

    //! The stage is asked for with `filter`: from the start, told if `report`
    void restart(Filter filter, bool report = true) pure nothrow @nogc @safe
    {
        this.filter = filter;
        scanned = 0;
        stopped = false;
        this.report = report;
    }

    //! Cancelled or failed: its index is left as it is, nothing more is told
    void stop() pure nothrow @nogc @safe
    {
        stopped = true;
        report = false;
    }

    //! It has something to do over a range: not stopped, and with a filter unless it runs
    //! without one
    bool live() const pure nothrow @nogc @safe
    {
        return !stopped && (filter !is null || _listsWithoutFilter);
    }

    //! It doesn't cover the `positions` it is built over
    bool behind(size_t positions) const pure nothrow @nogc @safe
    {
        return live && scanned < positions;
    }

    //! It runs with a filter of its own: a stage before it takes a part at a time, so this
    //! one gets its rows as it goes
    bool wantsRows() const pure nothrow @nogc @safe
    {
        return live && filter !is null;
    }
}

@("MatchStage: a stage with no filter is live only if it lists without one")
unittest
{
    auto view = MatchStage(false), search = MatchStage(true);
    assert(!view.live && !view.behind(10));
    assert(search.live && search.behind(10));
    search.scanned = 10;
    assert(!search.behind(10));
}

@("MatchStage: a stopped stage is not live until it is asked for again")
unittest
{
    auto search = MatchStage(true);
    search.restart(null);
    search.scanned = 3;
    search.stop();
    assert(!search.live && !search.report && search.scanned == 3);
    search.restart(null, false);
    assert(search.live && search.scanned == 0 && !search.report);
}
