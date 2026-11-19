//! A set of rows kept as sorted ranges, the rows of a table that are selected: a range of millions of rows is one entry,
//! and asking whether a row is in the set is a binary search, so the table can ask it for every row it paints. A set
//! only: where a selection started and which row is current is the business of `RowPicks`, and no key is known here.
//! Pure. See docs/stories/painted-table.md.
module ptable.rowranges;

import std.algorithm.comparison : max, min;

/// The rows `first` to `last`, both in it
struct RowRange
{
    size_t first, last;
}

/// The rows picked: sorted ranges that neither overlap nor touch. Every change says whether it changed the set
struct RowRanges
{
    private RowRange[] _ranges;

    /// Whether the row `index` is in the set
    bool has(size_t index) const pure nothrow @nogc @safe
    {
        return rangeAt(index) != size_t.max;
    }

    /// The number of rows in the set
    ulong count() const pure nothrow @nogc @safe
    {
        ulong n;
        foreach (ref range; _ranges)
            n += range.last - range.first + 1;
        return n;
    }

    bool empty() const pure nothrow @nogc @safe
    {
        return _ranges.length == 0;
    }

    /// The ranges, sorted, valid until the next change
    const(RowRange)[] ranges() const pure nothrow @nogc @safe
    {
        return _ranges;
    }

    /// Only the row `index` is in the set
    bool only(size_t index)
    {
        return setRange(index, index);
    }

    /// Only the rows from `a` to `b` (either way round) are in the set
    bool setRange(size_t a, size_t b)
    {
        const range = RowRange(min(a, b), max(a, b));
        if (_ranges.length == 1 && _ranges[0] == range)
            return false;
        _ranges = [range];
        return true;
    }

    /// The rows from `a` to `b` (either way round) join the set, with the ranges they overlap or touch
    bool add(size_t a, size_t b)
    {
        auto first = min(a, b), last = max(a, b);
        size_t start = 0;
        while (start < _ranges.length && before(_ranges[start], first))
            ++start;
        size_t end = start;
        while (end < _ranges.length && !after(_ranges[end], last))
        {
            first = min(first, _ranges[end].first);
            last = max(last, _ranges[end].last);
            ++end;
        }
        if (end - start == 1 && _ranges[start] == RowRange(first, last) && has(min(a, b)) && has(max(a, b)))
            return false; // all of it was in already
        _ranges = _ranges[0 .. start] ~ RowRange(first, last) ~ _ranges[end .. $];
        return true;
    }

    /// The row `index` leaves the set, its range splits
    bool remove(size_t index)
    {
        const at = rangeAt(index);
        if (at == size_t.max)
            return false;
        const range = _ranges[at];
        RowRange[2] parts;
        size_t n;
        if (range.first < index)
            parts[n++] = RowRange(range.first, index - 1);
        if (index < range.last)
            parts[n++] = RowRange(index + 1, range.last);
        _ranges = _ranges[0 .. at] ~ parts[0 .. n] ~ _ranges[at + 1 .. $];
        return true;
    }

    /// The row `index` is in the set if it was not, and out of it if it was
    bool toggle(size_t index)
    {
        if (has(index))
            return remove(index);
        return add(index, index);
    }

    /// The set is exactly `ranges` (sorted, disjoint, not touching: what `ranges` of a set gives)
    void assign(const(RowRange)[] ranges)
    {
        _ranges = ranges.dup;
    }

    /// No row is in the set
    bool clear()
    {
        if (_ranges.length == 0)
            return false;
        _ranges = null;
        return true;
    }

    // The position in `_ranges` of the range with `index`, size_t.max if none
    private size_t rangeAt(size_t index) const pure nothrow @nogc @safe
    {
        size_t lo = 0, hi = _ranges.length;
        while (lo < hi)
        {
            const mid = (lo + hi) / 2;
            if (index < _ranges[mid].first)
                hi = mid;
            else if (index > _ranges[mid].last)
                lo = mid + 1;
            else
                return mid;
        }
        return size_t.max;
    }

    // `range` ends before the rows from `first` on and does not touch them
    private static bool before(const RowRange range, size_t first) pure nothrow @nogc @safe
    {
        return first > 0 && range.last < first - 1;
    }

    // `range` begins after the rows up to `last` and does not touch them
    private static bool after(const RowRange range, size_t last) pure nothrow @nogc @safe
    {
        return last < size_t.max && range.first > last + 1;
    }
}

@("RowRanges: nothing at first, one row, only replaces the set")
unittest
{
    RowRanges rows;
    assert(rows.empty && rows.count == 0 && !rows.has(0));
    assert(rows.only(5) && rows.ranges == [RowRange(5, 5)]);
    assert(!rows.only(5), "the same: no change");
    assert(rows.only(7) && rows.ranges == [RowRange(7, 7)] && rows.has(7) && !rows.has(5));
}

@("RowRanges: a range is either way round, joins what it overlaps or touches, and a huge one is one entry")
unittest
{
    RowRanges rows;
    assert(rows.setRange(14, 10) && rows.ranges == [RowRange(10, 14)]);
    assert(rows.add(2, 2) && rows.add(6, 6));
    assert(rows.ranges == [RowRange(2, 2), RowRange(6, 6), RowRange(10, 14)]);
    assert(rows.add(3, 3) && rows.ranges[0] == RowRange(2, 3), "an adjacent row joins");
    assert(rows.add(4, 9) && rows.ranges == [RowRange(2, 14)], "a range over the gaps joins all");
    assert(!rows.add(5, 7), "inside already: no change");
    assert(rows.setRange(0, 4_000_000_000) && rows.ranges.length == 1 && rows.count == 4_000_000_001 && rows.has(3_999_999_999));
}

@("RowRanges: removing a row from the middle splits its range, the ends shorten it, a row that is not in changes nothing")
unittest
{
    RowRanges rows;
    rows.setRange(0, 9);
    assert(rows.remove(4) && rows.ranges == [RowRange(0, 3), RowRange(5, 9)] && rows.count == 9);
    assert(!rows.has(4) && rows.has(5));
    assert(rows.remove(0) && rows.remove(9) && rows.ranges == [RowRange(1, 3), RowRange(5, 8)]);
    assert(!rows.remove(4));
    RowRanges one;
    one.only(3);
    assert(one.remove(3) && one.empty);
}

@("RowRanges: toggle adds or removes, clear empties; the first and the last row of all are fine")
unittest
{
    RowRanges rows;
    assert(rows.toggle(0) && rows.has(0));
    assert(rows.toggle(1) && rows.ranges == [RowRange(0, 1)], "the neighbor joins");
    assert(rows.toggle(0) && rows.ranges == [RowRange(1, 1)]);
    assert(rows.add(size_t.max - 1, size_t.max) && rows.has(size_t.max));
    assert(rows.clear() && rows.empty && !rows.clear());
}
