//! Where a key takes the selected row: the keys of a table and the pure rule that turns a key into the
//! item to select. Free of the table, so it is tested alone.
module ptable.navigation;

import std.algorithm.comparison : max, min;

/// The keys a table understands
enum Key : ubyte
{
    down,
    up,
    pageDown,
    pageUp,
    home,
    end,
    escape,
}

/// The item a movement key takes the selection to: from `at` (the selected item, or the first one on the
/// screen), among `count` items, `page` items a page. Virtual items (`isVirtual`) are passed. -1: nowhere
/// to go (no real item). `escape` is not a movement: -1 too.
long navigate(Key key, long at, long count, long page, scope bool delegate(long) isVirtual)
{
    if (count <= 0)
        return -1;
    long to, step = 1;
    final switch (key)
    {
    case Key.down: to = at + 1; break;
    case Key.up: to = at - 1; step = -1; break;
    case Key.pageDown: to = at + page; break;
    case Key.pageUp: to = at - page; step = -1; break;
    case Key.home: to = 0; break;
    case Key.end: to = count - 1; step = -1; break;
    case Key.escape: return -1;
    }
    long realFrom(long from, long dir)
    {
        while (from >= 0 && from < count && isVirtual(from))
            from += dir;
        return from < 0 || from >= count ? -1 : from;
    }

    const target = realFrom(max(0L, min(count - 1, to)), step);
    return target >= 0 ? target : realFrom(max(0L, min(count - 1, at)), -step); // nothing real that way: stay
}

version (unittest)
{
    private bool delegate(long) none() { return (long i) => false; }
}

@("navigate: a step, a page, the ends; the ends are clamped")
unittest
{
    assert(navigate(Key.down, 3, 10, 4, none) == 4);
    assert(navigate(Key.up, 3, 10, 4, none) == 2);
    assert(navigate(Key.pageDown, 3, 10, 4, none) == 7);
    assert(navigate(Key.pageUp, 3, 10, 4, none) == 0, "clamped");
    assert(navigate(Key.home, 5, 10, 4, none) == 0);
    assert(navigate(Key.end, 5, 10, 4, none) == 9);
    assert(navigate(Key.down, 9, 10, 4, none) == 9, "the last stays");
}

@("navigate: virtual items are passed, and if none is real that way the selection stays")
unittest
{
    bool odd(long i) { return i % 2 == 1; }
    assert(navigate(Key.down, 0, 10, 4, &odd) == 2);
    assert(navigate(Key.up, 4, 10, 4, &odd) == 2);
    assert(navigate(Key.end, 0, 10, 4, &odd) == 8, "the last real one");
    bool tail(long i) { return i >= 5; }
    assert(navigate(Key.down, 4, 10, 4, &tail) == 4, "only virtual ones below: stay");
}

@("navigate: no items, and escape, go nowhere")
unittest
{
    assert(navigate(Key.down, 0, 0, 4, none) == -1);
    assert(navigate(Key.escape, 2, 10, 4, none) == -1);
}
