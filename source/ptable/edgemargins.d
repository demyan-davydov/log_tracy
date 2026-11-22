//! The room above the first item of a list and under the last one, scrolled with the items (`RowViewport.margins`): what each
//! adds to the height of an item, cut to the room the window leaves that item (in a low window the item stays in view, the margin
//! gives way), and the parts of them in the window. Pure. See docs/stories/painted-table.md.
module ptable.edgemargins;

import ptable.ports : Span;
import ptable.rowlayout : RowSlot;

import std.algorithm.comparison : max, min;

/// The margins asked for: above the first item and under the last one, none below 0
struct EdgeMargins
{
    double top = 0, bottom = 0;

    /// The room above the item `index` `height` high in a window `window` high: the top margin for the first item, no more than the
    /// window leaves it
    double above(size_t index, double height, double window) const pure nothrow @nogc @safe
    {
        return index == 0 ? fitted(top, height, window) : 0;
    }

    /// The room under the item `index` `height` high of a list of `count`: the bottom margin for the last item, no more than the
    /// window leaves it
    double below(size_t index, size_t count, double height, double window) const pure nothrow @nogc @safe
    {
        return count > 0 && index == count - 1 ? fitted(bottom, height, window) : 0;
    }

    /// The room above and under the item: what it adds to its height
    double around(size_t index, size_t count, double height, double window) const pure nothrow @nogc @safe
    {
        return above(index, height, window) + below(index, count, height, window);
    }

    private static double fitted(double margin, double height, double window) pure nothrow @nogc @safe
    {
        return max(0.0, min(margin, window - height));
    }
}

/// The parts of the margins in the window, from its top: empty if a margin is not in view
struct MarginsInView
{
    Span top, bottom;
}

/// The parts of the margins in a window `window` high, by the items on the screen with the margins (`padded`: the first and the last
/// item taller by them) and without (`own`), the same items in the same order, of a list of `count`
MarginsInView marginsInView(const(RowSlot)[] padded, const(RowSlot)[] own, size_t count, double window) pure nothrow @nogc @safe
{
    MarginsInView seen;
    if (own.length == 0)
        return seen;
    if (own[0].index == 0)
        seen.top = clipped(Span(padded[0].top, own[0].top), window);
    if (own[$ - 1].index == count - 1)
        seen.bottom = clipped(Span(own[$ - 1].top + own[$ - 1].height, padded[$ - 1].top + padded[$ - 1].height), window);
    return seen;
}

private Span clipped(Span span, double window) pure nothrow @nogc @safe
{
    const start = max(0.0, span.start), end = min(window, span.end);
    return end > start ? Span(start, end) : Span.init;
}

@("EdgeMargins: the top margin is the first item's, the bottom one the last item's, both of one item a list of one")
unittest
{
    const m = EdgeMargins(4, 24);
    assert(m.above(0, 20, 100) == 4 && m.above(1, 20, 100) == 0);
    assert(m.below(9, 10, 20, 100) == 24 && m.below(8, 10, 20, 100) == 0 && m.below(0, 0, 20, 100) == 0);
    assert(m.around(0, 1, 20, 100) == 28, "the only item has both");
}

@("EdgeMargins: in a low window a margin gives way to its item: no more than the window leaves it, never below 0")
unittest
{
    const m = EdgeMargins(4, 24);
    assert(m.below(9, 10, 60, 70) == 10, "70 less the item's 60");
    assert(m.below(9, 10, 90, 70) == 0, "an item taller than the window: no margin");
    assert(m.above(0, 68, 70) == 2);
}

@("marginsInView: the part of a margin in the window, none when its item is not on the screen")
unittest
{
    // the start: the first item 4 under the top, the margin 0 .. 4
    auto seen = marginsInView([RowSlot(0, 0, 24), RowSlot(1, 24, 20)], [RowSlot(0, 4, 20), RowSlot(1, 24, 20)], 100, 100);
    assert(seen.top == Span(0, 4) && seen.bottom.length == 0, "the last item is far");
    // the end: the last item ends at 76, its margin 76 .. 100
    seen = marginsInView([RowSlot(98, 36, 20), RowSlot(99, 56, 44)], [RowSlot(98, 36, 20), RowSlot(99, 56, 20)], 100, 100);
    assert(seen.bottom == Span(76, 100) && seen.top.length == 0);
    // scrolled into a margin: only the part in the window
    seen = marginsInView([RowSlot(0, -2, 24)], [RowSlot(0, 2, 20)], 1, 10);
    assert(seen.top == Span(0, 2) && seen.bottom == Span(0, 0), "the bottom margin of the only item is under the window");
}
