//! Where a scroll bar's thumb stands for the rows and where the rows stand for the thumb: the fraction (0 .. 1) a bar
//! shows, both ways. The point at the fraction p of the list is shown at the point p of the window: at 0 the top of the
//! first row is at the top of the window, at 1 the bottom of the last row is at its bottom, the ends exact by
//! construction and nothing measured but the rows on the screen. That moves the rows forward all the way when no row is
//! lower than `minHeight` and the list has at least a window of such rows; a shorter list (fewer rows than a window of
//! the least ones, wrapped taller than it) and any list of a few rows (`exactRows`) are measured whole and scrolled by
//! pixels. Pure. See
//! docs/stories/painted-table.md.
module ptable.scrollscale;

import ptable.rowlayout : HeightOf, RowSlot, ViewState;

import std.algorithm.comparison : max, min;

/// How many rows a list may have to be scrolled by pixels whatever its rows, measured whole: the thumb keeps its size and a
/// tall row takes its height of the track (a few tall rows in a small window made it change all the way). 0: only a list
/// shorter than a window of its least rows is. A trial value, to be measured
enum size_t exactRows = 500;

/// Whether the list is scrolled by pixels, every row measured: it has few rows (`exactRows`), or fewer than a window `view`
/// high of the least ones (`minHeight`; not known, 0: by the count alone), which the anchor would move back
bool exactPixels(size_t count, double minHeight, double view) pure nothrow @nogc @safe
{
    return count <= exactRows || (minHeight > 0 && count * minHeight < view);
}

/// Where a row stands: the top of the row `row` is `dy` from the top of the window
struct RowPlace
{
    size_t row;
    double dy = 0;
}

/// The rows of `count` in a window `view` high at the fraction `p` of the bar: the point p·count of the list (a row and
/// the fraction of its height) at p·view of the window
RowPlace anchorPlace(double p, size_t count, double view, scope HeightOf heightOf)
{
    if (count == 0)
        return RowPlace.init;
    p = clamp01(p);
    const r = p * count;
    size_t row = count - 1;
    double part = 1;
    if (r < count) // p·count of a p a hair under 1 may round up to count: the end
    {
        row = cast(size_t) r;
        part = r - row;
    }
    return RowPlace(row, p * view - part * heightOf(row));
}

/// The fraction of the bar for the rows on the screen (`slots`, laid out from the top of the window `view` high) of a
/// list of `count`: the p whose point of the list, p·count, is at the point p·view of the window. 0 with nothing on the
/// screen
double anchorFraction(const(RowSlot)[] slots, size_t count, double view) pure nothrow @nogc @safe
{
    enum hair = 1e-9;
    if (count == 0 || slots.length == 0 || !(view > 0))
        return 0;
    // in a slot (i, t, h) the row under y is i + (y - t) / h: equal to p·count at y = p·view where p = (i·h - t) / (count·h - view)
    foreach (ref s; slots)
    {
        const across = count * s.height - view;
        double p;
        if (across > 0)
            p = (s.index * s.height - s.top) / across;
        else if (across == 0)
            p = s.top / view; // the rows stand still while p crosses this slot: its start
        else
            continue; // lower than the least: the anchor moves back here, no fraction of it is to be trusted
        const y = p * view;
        if (p >= -hair && p <= 1 + hair && y >= s.top - hair * view && y <= s.top + s.height + hair * view)
            return clamp01(p);
    }
    // not met (rows lower than the least): the rows above the window of all of them
    const first = slots[0];
    return clamp01((first.index - first.top / max(1.0, first.height)) / count);
}

/// The rows of a list measured whole (`exactPixels`) at the fraction `p`: the first row and the part of it scrolled away
ViewState pixelState(double p, size_t count, double view, scope HeightOf heightOf)
{
    if (count == 0)
        return ViewState.init;
    double total = 0;
    foreach (i; 0 .. count)
        total += heightOf(i);
    double target = clamp01(p) * max(0.0, total - view);
    size_t first;
    while (first < count - 1)
    {
        const height = heightOf(first);
        if (target < height)
            break;
        target -= height;
        ++first;
    }
    return ViewState(first, target);
}

/// The pixels of a list measured whole (`exactPixels`): all of them, and those scrolled away above the window
struct PixelSpan
{
    double total = 0, above = 0;
}

/// The pixels of a list of `count` standing at `state`, in one pass over its rows
PixelSpan pixelSpan(ViewState state, size_t count, scope HeightOf heightOf)
{
    auto span = PixelSpan(0, state.offset);
    foreach (i; 0 .. count)
    {
        const height = heightOf(i);
        span.total += height;
        if (i < state.first)
            span.above += height;
    }
    return span;
}

/// The fraction of the bar for a list measured whole in a window `view` high: the pixels scrolled away of all it can be
double pixelFraction(PixelSpan span, double view) pure nothrow @nogc @safe
{
    const room = span.total - view;
    return room > 0 ? clamp01(span.above / room) : 0;
}

/// How much of a list of `count` the rows on the screen are, in rows (a row cut by an edge counts by the part in the window)
double rowsShown(const(RowSlot)[] slots, size_t count, double view) pure nothrow @nogc @safe
{
    if (count == 0)
        return 1;
    double rows = 0;
    foreach (ref s; slots)
        if (s.height > 0)
            rows += max(0.0, min(s.top + s.height, view) - max(s.top, 0.0)) / s.height;
    return min(1.0, rows / count);
}

private double clamp01(double p) pure nothrow @nogc @safe
{
    return p > 0 ? (p < 1 ? p : 1) : 0;
}

version (unittest)
{
    import ptable.rowlayout : screenRows;

    // The rows of `heights`, their tops from the top of a window `view` high at the place `at`, laid out
    private RowSlot[] laidOut(RowPlace at, size_t count, double view, scope HeightOf heightOf)
    {
        auto state = ViewState(at.row, -at.dy);
        // the rows above the place: as `RowViewport.scrollToRow` does
        while (state.offset < 0 && state.first > 0)
            state.offset += heightOf(--state.first);
        RowSlot[] slots;
        screenRows(state, slots, view, count, heightOf);
        return slots;
    }

    // The pixels of the list above the top of the window
    private double scrolled(const(RowSlot)[] slots, scope HeightOf heightOf)
    {
        double above = -slots[0].top;
        foreach (i; 0 .. slots[0].index)
            above += heightOf(i);
        return above;
    }

    private HeightOf mixed(ulong seed, double least, double most)
    {
        return (size_t i) nothrow {
            ulong x = (i + 1) * 6364136223846793005UL + seed * 1442695040888963407UL;
            x ^= x >> 29;
            x *= 0xbf58476d1ce4e5b9UL;
            x ^= x >> 32;
            return least + (x % 1000) / 1000.0 * (most - least);
        };
    }
}

@("exactPixels: few rows (up to exactRows), or fewer than a window of the least ones")
unittest
{
    assert(exactPixels(exactRows, 16, 600), "few rows: measured whole, whatever the window");
    assert(exactPixels(exactRows, 0, 600), "few rows, the least height not known");
    assert(!exactPixels(exactRows + 1, 16, 600), "more, and a window of the least ones");
    assert(!exactPixels(exactRows + 1, 0, 600), "more, the least height not known");
    assert(exactPixels(exactRows + 1, 16, 16 * (exactRows + 2)), "fewer than a window of the least ones");
}

@("anchorPlace: 0 is the top of the first row at the top, 1 the bottom of the last row at the bottom")
unittest
{
    HeightOf h = (size_t i) nothrow => i == 99 ? 50.0 : 20.0;
    assert(anchorPlace(0, 100, 90, h) == RowPlace(0, 0));
    assert(anchorPlace(1, 100, 90, h) == RowPlace(99, 90 - 50), "the last row ends at the bottom");
    assert(anchorPlace(1 - 1e-17, 100, 90, h) == RowPlace(99, 90 - 50), "a hair under 1 is the end");
    assert(anchorPlace(2, 100, 90, h) == RowPlace(99, 40) && anchorPlace(-1, 100, 90, h) == RowPlace(0, 0), "past the ends: the ends");
    assert(anchorPlace(0.5, 0, 90, h) == RowPlace.init, "no rows");
}

@("anchorPlace: the point p·count of the list stands at p·view")
unittest
{
    HeightOf h = (size_t i) nothrow => 20.0;
    const at = anchorPlace(0.5, 100, 90, h); // the point 50.0: the top of row 50, at 45
    assert(at == RowPlace(50, 45));
    const quarter = anchorPlace(0.255, 100, 100, h); // 25.5: the middle of row 25 at 25.5
    assert(quarter.row == 25 && quarter.dy == 25.5 - 10);
}

@("anchorPlace: the rows go on without a gap where p·count crosses a row")
unittest
{
    auto h = mixed(7, 16, 120);
    enum count = 50, view = 300.0;
    foreach (k; 1 .. count)
    {
        const p = cast(double) k / count;
        // the top of the row k from each side (k / count · count may round to a hair under k: the row before, ending there)
        double topOfK(RowPlace at)
        {
            return at.row == k ? at.dy : at.dy + h(at.row);
        }

        const below = anchorPlace(p - 1e-12, count, view, h), at = anchorPlace(p, count, view, h);
        assert(below.row == k - 1 && (at.row == k || at.row == k - 1));
        const gap = topOfK(below) - topOfK(at);
        assert(gap < 1e-6 && gap > -1e-6, "the row before ends where the row k begins");
    }
}

@("anchorPlace: the rows move forward all the way when no row is lower than the least and the list has a window of them")
unittest
{
    foreach (seed; 0 .. 20)
    {
        auto h = mixed(seed, 16, seed % 2 ? 400 : 80); // some rows taller than the window
        enum count = 40, view = 300.0; // 40 · 16 = 640 >= 300
        double last = -1;
        foreach (step; 0 .. 1001)
        {
            const p = step / 1000.0;
            const s = scrolled(laidOut(anchorPlace(p, count, view, h), count, view, h), h);
            assert(s >= last - 1e-6, "never back");
            last = s;
        }
    }
}

@("anchorPlace: equal rows scroll in proportion: p of all the list can scroll")
unittest
{
    HeightOf h = (size_t i) nothrow => 20.0;
    foreach (step; 0 .. 11)
    {
        const p = step / 10.0;
        const s = scrolled(laidOut(anchorPlace(p, 100, 90, h), 100, 90, h), h);
        const want = p * (100 * 20 - 90);
        assert(s - want < 1e-9 && s - want > -1e-9);
    }
}

@("anchorFraction: the fraction of the rows laid out by anchorPlace is the one they were laid out by")
unittest
{
    foreach (seed; 0 .. 20)
    {
        auto h = mixed(seed, 16, seed % 2 ? 400 : 80);
        enum count = 40, view = 300.0;
        foreach (step; 0 .. 101)
        {
            const p = step / 100.0;
            const back = anchorFraction(laidOut(anchorPlace(p, count, view, h), count, view, h), count, view);
            assert(back - p < 1e-9 && back - p > -1e-9, "p -> rows -> p");
        }
    }
}

@("anchorFraction: the top of the list is 0, the bottom of the last row at the bottom is 1")
unittest
{
    HeightOf h = (size_t i) nothrow => i == 99 ? 500.0 : 20.0; // the last row is taller than the window
    RowSlot[] top = laidOut(RowPlace(0, 0), 100, 90, h);
    assert(anchorFraction(top, 100, 90) == 0);
    RowSlot[] end = laidOut(RowPlace(99, 90 - 500), 100, 90, h);
    assert(anchorFraction(end, 100, 90) == 1);
    assert(anchorFraction(null, 100, 90) == 0 && anchorFraction(top, 0, 90) == 0, "nothing on the screen");
}

@("anchorFraction: a row whose rows stand still (count · height = view) does not divide by zero")
unittest
{
    HeightOf h = (size_t i) nothrow => i == 2 ? 10.0 : 20.0;
    const p = anchorFraction(laidOut(RowPlace(2, 0), 10, 100, h), 10, 100); // row 2: 10 · 10 = 100
    assert(p >= 0 && p <= 1 && p == p);
}

@("pixelState: the pixels of p of what the list can scroll; pixelFraction back")
unittest
{
    HeightOf h = (size_t i) nothrow => i == 3 ? 400.0 : 20.0; // 10 rows: 580 px in 300
    assert(pixelState(0, 10, 300, h) == ViewState(0, 0));
    assert(pixelState(1, 10, 300, h) == ViewState(3, 220), "280 scrolled: three rows and 220 of the tall one");
    assert(pixelState(0.5, 10, 300, h) == ViewState(3, 80));
    foreach (step; 0 .. 101)
    {
        const p = step / 100.0;
        const back = pixelFraction(pixelSpan(pixelState(p, 10, 300, h), 10, h), 300);
        assert(back - p < 1e-9 && back - p > -1e-9, "p -> rows -> p");
    }
    assert(pixelFraction(pixelSpan(ViewState(0, 0), 3, h), 300) == 0, "shorter than the window: nothing to scroll");
    assert(pixelSpan(ViewState(4, 5), 10, h) == PixelSpan(580, 465), "all the pixels and those above: 3 · 20 + 400 + 5");
}

@("rowsShown: the rows on the screen, a cut one by its part, of all of them")
unittest
{
    const slots = [RowSlot(4, -10, 20), RowSlot(5, 10, 40), RowSlot(6, 50, 100)];
    assert(rowsShown(slots, 100, 100) == (0.5 + 1 + 0.5) / 100);
    assert(rowsShown(null, 0, 100) == 1, "no rows: all shown");
    assert(rowsShown(slots, 2, 100) == 1, "not more than all");
}

@("anchorFraction: rows lower than the least (the anchor would move them back) give the fraction of the rows above the window, not 0")
unittest
{
    RowSlot[] slots;
    foreach (i; 0 .. 1000)
        slots ~= RowSlot(300 + i, i, 1); // rows of 1 px in a window of 1000: 600 · 1 < 1000
    const p = anchorFraction(slots, 600, 1000);
    assert(p > 0.45 && p < 0.55, "row 300 of 600 at the top: about the middle");
}
