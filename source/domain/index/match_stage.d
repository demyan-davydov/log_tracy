//! MatchStage: how far a stage of a pass of LogIndex that collects the records a filter
//! matches has got (the filter of the main view, the search): its filter, the positions it
//! covers and whether it was stopped.
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

    this(bool listsWithoutFilter) pure nothrow @nogc @safe
    {
        _listsWithoutFilter = listsWithoutFilter;
    }

    //! The stage is asked for with `filter`: from the start
    void restart(Filter filter) pure nothrow @nogc @safe
    {
        this.filter = filter;
        scanned = 0;
        stopped = false;
    }

    //! Cancelled or failed: its index is left as it is
    void stop() pure nothrow @nogc @safe
    {
        stopped = true;
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

    //! Its index holds what it found at `position`, and no pass adds to it there: not
    //! stopped (a stopped stage's index is left as it is), and the position scanned
    bool covers(size_t position) const pure nothrow @nogc @safe
    {
        return !stopped && position < scanned;
    }

    //! A row was added (`added`) or taken out at `position` of what it is built over, in
    //! place: the positions it covers follow the rows after it
    void moved(size_t position, bool added) pure nothrow @nogc @safe
    {
        if (covers(position))
            scanned = added ? scanned + 1 : scanned - 1;
    }

    //! @brief `position` is the one it scans next: it is taken now, a row the caller
    //! lists itself (an anchor, listed whatever the stage finds)
    //! @return true if taken
    bool takeNext(size_t position) pure nothrow @nogc @safe
    {
        if (stopped || position != scanned)
            return false;
        ++scanned;
        return true;
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
    assert(!search.live && search.scanned == 3);
    search.restart(null);
    assert(search.live && search.scanned == 0);
}

@("MatchStage: covers the positions it scanned, unless stopped")
unittest
{
    auto stage = MatchStage(true);
    stage.scanned = 3;
    assert(stage.covers(0) && stage.covers(2) && !stage.covers(3));
    stage.stop();
    assert(!stage.covers(0), "its index is left as it is");
}

@("MatchStage: a row added or taken out where it scanned moves what it covers")
unittest
{
    auto stage = MatchStage(true);
    stage.scanned = 3;
    stage.moved(1, true);
    assert(stage.scanned == 4, "the rows after it moved down");
    stage.moved(4, true);
    assert(stage.scanned == 4, "after what it scanned: a pass gets there");
    stage.moved(0, false);
    assert(stage.scanned == 3);
    stage.moved(3, false);
    assert(stage.scanned == 3, "not scanned");
}

@("MatchStage: takes the position it scans next only")
unittest
{
    auto stage = MatchStage(true);
    stage.scanned = 3;
    assert(!stage.takeNext(2) && !stage.takeNext(4));
    assert(stage.takeNext(3) && stage.scanned == 4);
    stage.stop();
    assert(!stage.takeNext(4), "a stopped stage takes nothing");
}
