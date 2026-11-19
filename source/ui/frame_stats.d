//! What the painted table measures of its own frames: the time each took (the last 512 in a ring), their median, the
//! 90th percentile and the longest, and the JSON the script reads them as (with what the table and the text cache
//! counted). Free of Sciter. docs/experiments/2026-11-19-painted-rows-d.md.
module ui.frame_stats;

import core.time : MonoTime;
import ptable.table : TableStats;

/// The times of the last frames
struct FrameStats
{
    private long[512] _us; // a ring
    private size_t _count; // the frames recorded since the last reset
    private long _last;

    /// A frame took `us` microseconds
    void record(long us)
    {
        _last = us;
        _us[_count++ % _us.length] = us;
    }

    /// Forgets the frames (the last one stays)
    void reset()
    {
        _count = 0;
    }

    size_t count() const
    {
        return _count;
    }

    long last() const
    {
        return _last;
    }

    /// The time at the quantile `q` (0.5 the median, 1.0 the longest) of the frames in the ring; 0 with none
    long at(double q) const
    {
        import std.algorithm.comparison : min;
        import std.algorithm.sorting : sort;

        const n = min(_count, _us.length);
        if (n == 0)
            return 0;
        auto sorted = _us[0 .. n].dup;
        sort(sorted);
        return sorted[min(n - 1, cast(size_t)(q * n))];
    }
}

/// The microseconds since `since`
long usSince(MonoTime since)
{
    return (MonoTime.currTime - since).total!"usecs";
}

/// What the script gets of the frames and the table: the times, what the table and the cache of the texts counted
wstring statsJson(ref const FrameStats frames, TableStats table, size_t textsMade, size_t textsCached, bool sciterWrap)
{
    import std.format : format;

    return format!`{"frames":%d,"medianUs":%d,"p90Us":%d,"maxUs":%d,"lastDrawUs":%d,"fetches":%d,"textsMade":%d,"textsCached":%d,"rowsCached":%d,"rows":%d,"first":%d,"wrap":"%s"}`w(
        frames.count, frames.at(0.5), frames.at(0.9), frames.at(1.0), frames.last, table.fetches, textsMade, textsCached,
        table.cachedRows, table.rowsOnScreen, table.first, sciterWrap ? "sciter"w : "advances"w);
}

@("FrameStats: the median, the 90th percentile and the longest of the frames, none for no frames")
unittest
{
    FrameStats stats;
    assert(stats.at(0.5) == 0 && stats.count == 0);
    foreach (us; [50, 10, 40, 20, 30, 60, 70, 80, 90, 100])
        stats.record(us);
    assert(stats.count == 10 && stats.last == 100);
    assert(stats.at(0.5) == 60 && stats.at(0.9) == 100 && stats.at(1.0) == 100, "q * n picks from the sorted ones");
    stats.reset();
    assert(stats.count == 0 && stats.at(0.5) == 0 && stats.last == 100, "the last one stays");
}

@("FrameStats: only the last 512 frames are in the ring")
unittest
{
    FrameStats stats;
    foreach (i; 0 .. 1000)
        stats.record(i < 488 ? 1_000_000 : 5); // the old slow frames are pushed out
    assert(stats.count == 1000 && stats.at(1.0) == 5);
}

@("statsJson: the numbers of the frames and of the table by their names, the wrap of the text")
unittest
{
    import std.json : parseJSON;
    import std.conv : to;

    FrameStats stats;
    stats.record(10);
    stats.record(30);
    const json = parseJSON(statsJson(stats, TableStats(7, 5, 2, 12, 100), 40, 90, true).to!string);
    assert(json["frames"].integer == 2 && json["maxUs"].integer == 30 && json["lastDrawUs"].integer == 30);
    assert(json["fetches"].integer == 7 && json["rows"].integer == 12 && json["first"].integer == 100);
    assert(json["textsMade"].integer == 40 && json["textsCached"].integer == 90 && json["wrap"].str == "sciter");
}
