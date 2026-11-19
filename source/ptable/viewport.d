//! The lowest level of the table: a window on a long list of rows of different heights. It knows only how
//! many items there are, the height of each (a function), the height of the window and where the window
//! stands (the first item and the part of it scrolled away); it says which items are on the screen and
//! where, and what a scroll bar needs (`ScrollMetrics`). It knows nothing of columns, cells, text or
//! colors, and nothing of a scroll bar's looks: any bar, the host's own or a painted one, is driven through
//! `metrics`, `scrollToRow` and `topOf`. Pure. See docs/stories/painted-table.md.
module ptable.viewport;

import ptable.rowlayout;

import std.algorithm.comparison : max, min;

/// What an outside scroll bar needs, in items (rows): the list is long and its rows differ in height, so a
/// bar by pixels would be wrong
struct ScrollMetrics
{
    size_t total; /// the items in the list
    size_t visible; /// how many items are on the screen (the last one may be cut)
    double position; /// the first item plus the part of it scrolled away, 0 .. total
}

/// A place of the window to keep when the heights of the rows change (a font, the width of the window): the
/// row, the point of it (a fraction of its height from its top) and where in the window that point is
struct ScrollAnchor
{
    bool valid;
    size_t row;
    double fraction = 0; /// of the height of the row, from its top: 0 the top edge, 0.5 the middle
    double at = 0; /// pixels from the top of the window to that point
}

/// Chooses the anchor among the rows on the screen: the host's policy (the first row by its top edge, the selected
/// row, the middle of the window). Called when the heights are about to change.
alias AnchorPolicy = ScrollAnchor delegate(const(RowSlot)[] slots);

/// The default policy: the top edge of the first row on the screen, where it is now
ScrollAnchor topAnchor(const(RowSlot)[] slots)
{
    if (slots.length == 0)
        return ScrollAnchor.init;
    return ScrollAnchor(true, slots[0].index, 0, slots[0].top);
}

/// A window on a list of items of different heights
final class RowViewport
{
    private HeightOf _heightOf;
    private size_t _count;
    private double _height = 0;
    private ViewState _state;
    private RowSlot[] _slots;
    private double _pending = 0;
    private ScrollAnchor _anchor;

    /// `heightOf(index)` is the height of an item (it may be costly: what it says is asked for the items
    /// near the window and, on a far scroll, never for the ones passed)
    this(HeightOf heightOf)
    {
        _heightOf = heightOf;
    }

    /// The items in the list
    void count(size_t items)
    {
        _count = items;
    }

    size_t count() const
    {
        return _count;
    }

    /// The height of the window
    void height(double value)
    {
        _height = value;
    }

    double height() const
    {
        return _height;
    }

    /// The items on the screen, as `layout` last put them
    const(RowSlot)[] slots() const
    {
        return _slots;
    }

    /// The first item on the screen and the part of it scrolled away
    ViewState state() const
    {
        return _state;
    }

    /// The slot of the item under `y` (from the top of the window): above the items it is the first, below them the last.
    /// There must be items on the screen.
    size_t slotAt(double y) const
    {
        if (y < _slots[0].top)
            return 0;
        foreach (i, ref r; _slots)
            if (y >= r.top && y < r.top + r.height)
                return i;
        return _slots.length - 1;
    }

    /// The mean height of the items on the screen (what a far scroll goes by)
    double meanHeight(double fallback) const
    {
        if (_slots.length == 0)
            return fallback;
        double sum = 0;
        foreach (r; _slots)
            sum += r.height;
        return sum / _slots.length;
    }

    /// Puts the items on the screen from the state, settling it
    void layout()
    {
        screenRows(_state, _slots, _height, _count, _heightOf);
    }

    /// Puts the items on the screen until what `changes` counts stops growing (an item seen changed the heights of the
    /// ones around it), at most `rounds` times
    void layoutSettled(scope size_t delegate() changes, size_t rounds = 4)
    {
        foreach (round; 0 .. rounds)
        {
            const before = changes();
            layout();
            if (before == changes())
                break;
        }
    }

    /// What was queued and not applied is dropped (the items are other ones)
    void dropPending()
    {
        _pending = 0;
    }

    /// The window moves by `pixels` (down is positive) at the next `applyPending`; what piled up stays
    /// within a screen
    void queueScroll(double pixels)
    {
        _pending = max(-_height, min(_height, _pending + pixels));
    }

    /// The heights are about to change: keeps the place the policy chooses (`topAnchor` if null) among the rows on the
    /// screen, to be put back by `restorePlace` once the new heights are known. A scroll before that wins.
    void keepPlace(AnchorPolicy policy = null)
    {
        const chosen = policy !is null ? policy(_slots) : topAnchor(_slots);
        if (chosen.valid)
            _anchor = chosen;
    }

    /// The place kept is of no use any more (the items are other ones): the window stays where it is
    void forgetPlace()
    {
        _anchor = ScrollAnchor.init;
    }

    /// Puts the window back where `keepPlace` saw it, by the heights now; false if nothing was kept
    bool restorePlace()
    {
        if (!_anchor.valid)
            return false;
        const kept = _anchor;
        _anchor = ScrollAnchor.init;
        if (kept.row >= _count)
            return false;
        double offset = kept.fraction * _heightOf(kept.row) - kept.at; // the part of the row scrolled away
        size_t first = kept.row;
        while (offset < 0 && first > 0) // the point is lower than the top of the window: rows above come first
            offset += _heightOf(--first);
        _state = ViewState(first, max(0.0, offset));
        return true;
    }

    /// Does the scroll that piled up; true if there was one
    bool applyPending(double fallbackHeight)
    {
        if (_pending == 0)
            return false;
        const move = _pending;
        _pending = 0;
        scrollBy(move, fallbackHeight);
        return true;
    }

    /// The window moves by `pixels` now
    void scrollBy(double pixels, double fallbackHeight)
    {
        _anchor = ScrollAnchor.init;
        _state = .scrollBy(_state, pixels, _height, _count, _heightOf, meanHeight(fallbackHeight));
    }

    /// The item `index` is the first one on the screen
    void scrollTo(size_t index)
    {
        _anchor = ScrollAnchor.init;
        _state = ViewState(index, 0);
    }

    /// How far (pixels, down is positive) the rows are to move to show the item `index` by the least scroll: 0 if it is shown,
    /// NaN if it is more than two screens off the window (the caller then jumps to it)
    double revealDistance(size_t index)
    {
        foreach (ref slot; _slots)
            if (slot.index == index)
            {
                if (slot.top < 0)
                    return slot.top;
                return slot.top + slot.height > _height ? slot.top + slot.height - _height : 0;
            }
        if (_slots.length == 0)
            return double.nan;
        const limit = 2 * _height;
        const last = _slots[$ - 1], first = _slots[0];
        if (index > last.index)
        {
            double distance = max(0.0, last.top + last.height - _height); // what the last item is below the window
            foreach (i; last.index + 1 .. index + 1)
            {
                distance += _heightOf(i);
                if (distance > limit)
                    return double.nan;
            }
            return distance;
        }
        if (index < first.index)
        {
            double distance = -first.top; // what the first item is above the window
            foreach (i; index .. first.index)
            {
                distance += _heightOf(i);
                if (distance > limit)
                    return double.nan;
            }
            return -distance;
        }
        return double.nan;
    }

    /// Shows the item `index` by the least scroll if it is among the items on the screen, or not more than two screens off them
    /// (it then stands at the edge it came from); false if it is farther (the caller then scrolls to it)
    bool reveal(size_t index, double fallbackHeight)
    {
        import std.math : isNaN;

        const distance = revealDistance(index);
        if (distance.isNaN)
            return false;
        if (distance != 0)
            scrollBy(distance, fallbackHeight);
        return true;
    }

    /// What a scroll bar shows
    ScrollMetrics metrics() const
    {
        const firstHeight = _slots.length ? _slots[0].height : 19;
        return ScrollMetrics(_count, max(1UL, _slots.length - 1), _state.first + _state.offset / max(1.0, firstHeight));
    }

    /// Whether the end of the list is in view: the last item is shown whole at the end of the window (none, or all of them in it: also)
    bool endInView() const
    {
        enum hair = 1e-6;
        if (_count == 0)
            return true;
        return _slots.length > 0 && _slots[$ - 1].index == _count - 1 && _slots[$ - 1].top + _slots[$ - 1].height <= _height + hair;
    }

    /// The window stands so that the bottom of the last item is the bottom of the window (a list shorter than the window at its top)
    void scrollToEnd()
    {
        if (_count == 0)
            return;
        const last = _count - 1;
        scrollToRow(last, _height - _heightOf(last));
    }

    /// The top of the item `row` from the top of the window (negative: above it), NaN if it is more than two screens off the window: the heights
    /// of the items far off are not known (the caller then jumps to it)
    double topOf(size_t row)
    {
        foreach (ref slot; _slots)
            if (slot.index == row)
                return slot.top;
        if (_slots.length == 0)
            return double.nan;
        const limit = 2 * _height;
        const first = _slots[0], last = _slots[$ - 1];
        double top = first.top;
        if (row < first.index)
        {
            foreach_reverse (i; row .. first.index)
            {
                top -= _heightOf(i);
                if (top < -limit)
                    return double.nan;
            }
            return top;
        }
        top = last.top + last.height;
        foreach (i; last.index + 1 .. row)
        {
            top += _heightOf(i);
            if (top > _height + limit)
                return double.nan;
        }
        return top;
    }

    /// The window stands so that the top of the item `row` is `dy` pixels from the top of the window: a `dy` below the top shows the items above
    /// it (a table that starts sooner stays at its start), one above it scrolls the item away
    void scrollToRow(size_t row, double dy)
    {
        _anchor = ScrollAnchor.init;
        const last = _count > 0 ? _count - 1 : 0;
        auto first = min(row, last);
        if (dy <= 0)
        {
            _state = ViewState(first, -dy);
            return;
        }
        double need = dy;
        while (need > 0 && first > 0)
        {
            const height = _heightOf(--first);
            if (height >= need)
            {
                _state = ViewState(first, height - need);
                return;
            }
            need -= height;
        }
        _state = ViewState(first, 0);
    }
}

version (unittest)
{
    private HeightOf rowsOf(double height)
    {
        return (size_t i) nothrow => height;
    }
}

@("RowViewport: the items on the screen from the first one, settled")
unittest
{
    auto view = new RowViewport(rowsOf(20));
    view.count = 100;
    view.height = 100;
    view.layout();
    assert(view.slots.length == 5 && view.slots[0] == RowSlot(0, 0, 20));
    view.scrollBy(45, 20);
    view.layout();
    assert(view.state == ViewState(2, 5) && view.slots[0].top == -5);
}

@("RowViewport: a wheel piles up, is cut to a screen and applied once")
unittest
{
    auto view = new RowViewport(rowsOf(20));
    view.count = 1000;
    view.height = 100;
    view.layout();
    view.queueScroll(60);
    view.queueScroll(60);
    assert(view.state.first == 0, "nothing moves before it is applied");
    assert(view.applyPending(20));
    view.layout();
    assert(view.state.first == 5, "120 px cut to a screen of 100: 5 rows");
    assert(!view.applyPending(20), "nothing is pending now");
    view.queueScroll(-100_000);
    view.applyPending(20);
    view.layout();
    assert(view.state.first == 0);
}

@("RowViewport: reveal scrolls the least way, and says no for an item off the screen")
unittest
{
    auto view = new RowViewport(rowsOf(20));
    view.count = 100;
    view.height = 100;
    view.scrollBy(30, 20);
    view.layout(); // the first item is cut: rows 1..6, the first starts at -10
    assert(view.reveal(1, 20));
    view.layout();
    assert(view.slots[0].index == 1 && view.slots[0].top == 0, "the cut first row is shown whole");
    assert(view.reveal(5, 20));
    view.layout();
    assert(view.slots[$ - 1].index == 5 && view.slots[$ - 1].top + 20 == 100, "the last row is shown whole");
    assert(!view.reveal(50, 20));
}

@("RowViewport: reveal of the item just past the window scrolls it to the bottom edge, one before it to the top edge, a far one is no")
unittest
{
    auto view = new RowViewport(rowsOf(20));
    view.count = 100;
    view.height = 100;
    view.scrollBy(30, 20);
    view.layout(); // rows 1..6, the first starts at -10, the last (6) ends at 110
    assert(view.reveal(7, 20));
    view.layout();
    assert(view.slots[$ - 1].index == 7 && view.slots[$ - 1].top + 20 == 100, "row 7 stands at the bottom");
    assert(view.reveal(0, 20));
    view.layout();
    assert(view.slots[0].index == 0 && view.slots[0].top == 0, "row 0 stands at the top");
    assert(view.reveal(11, 20));
    assert(!view.reveal(99, 20), "farther than two screens: the caller scrolls to it");
}

@("RowViewport: a scroll bar reads the metrics in items and sets the position by them")
unittest
{
    auto view = new RowViewport(rowsOf(20));
    view.count = 1000;
    view.height = 100;
    view.layout();
    auto m = view.metrics();
    assert(m.total == 1000 && m.visible == 4 && m.position == 0);
    view.scrollBy(30, 20);
    view.layout();
    m = view.metrics();
    assert(m.position == 1.5, "an item and a half");
    view.scrollToRow(500, -10);
    view.layout();
    assert(view.state == ViewState(500, 10));
}

@("RowViewport.scrollToRow: the top of the item at dy from the top of the window: above it scrolls the item away, below it shows the items before")
unittest
{
    auto view = new RowViewport(rowsOf(20));
    view.count = 1000;
    view.height = 100;
    view.layout();
    view.scrollToRow(500, 0);
    assert(view.state == ViewState(500, 0));
    view.scrollToRow(500, -5);
    assert(view.state == ViewState(500, 5), "5 px of it are above the window");
    view.scrollToRow(500, 30);
    assert(view.state == ViewState(498, 10), "30 below the top: the item before whole (20) and 10 of the one before it");
    view.scrollToRow(500, 20);
    assert(view.state == ViewState(499, 0), "exactly the item before");
    view.scrollToRow(1, 100);
    assert(view.state == ViewState(0, 0), "the list starts sooner: it stays at its start");
    view.scrollToRow(1_000_000, 0);
    assert(view.state == ViewState(999, 0), "past the end: the last item");
}

@("RowViewport.endInView: the last item is in the window whole; an empty list and one shorter than the window have their end in view")
unittest
{
    auto view = new RowViewport(rowsOf(20));
    view.height = 100;
    view.layout();
    assert(view.endInView(), "no items: nothing is out of view");
    view.count = 3;
    view.layout();
    assert(view.endInView(), "shorter than the window");
    view.count = 1000;
    view.layout();
    assert(!view.endInView(), "at the top of a long list");
    view.scrollToRow(995, 0);
    view.layout();
    assert(view.endInView() && view.slots[$ - 1].index == 999, "the last five items fill the window");
    view.scrollToRow(994, -5);
    view.layout();
    assert(!view.endInView(), "the last item is cut at the bottom");
}

@("RowViewport.scrollToEnd: the bottom of the last item is the bottom of the window; a short list stays at its top, a last item taller than the window shows its bottom")
unittest
{
    auto view = new RowViewport(rowsOf(20));
    view.count = 1000;
    view.height = 90; // four and a half items
    view.layout();
    view.scrollToEnd();
    view.layout();
    assert(view.state == ViewState(995, 10) && view.endInView(), "the last item ends at 90: the item before ends at 70, at 50, 30, 10");
    view.count = 3;
    view.scrollToEnd();
    view.layout();
    assert(view.state == ViewState(0, 0), "a short list is at its top");
    auto tall = new RowViewport((size_t i) nothrow => i == 9 ? 200.0 : 20.0);
    tall.count = 10;
    tall.height = 90;
    tall.layout();
    tall.scrollToEnd();
    tall.layout();
    assert(tall.state == ViewState(9, 110), "a last item taller than the window: its bottom is in view");
}

@("RowViewport.topOf: the top of an item in the window or near it, NaN when it is more than two screens away")
unittest
{
    auto view = new RowViewport(rowsOf(20));
    view.count = 1000;
    view.height = 100;
    view.scrollToRow(50, -5);
    view.layout();
    assert(view.topOf(50) == -5 && view.topOf(52) == 35, "in the window");
    assert(view.topOf(49) == -25 && view.topOf(45) == -105, "above it");
    assert(view.topOf(54) == 75 && view.topOf(56) == 115 && view.topOf(60) == 195, "below it: the first item past the window starts where the last ends");
    assert(view.topOf(0) != view.topOf(0) && view.topOf(900) != view.topOf(900), "far off: NaN");
}

@("RowViewport: an empty list has no items on the screen")
unittest
{
    auto view = new RowViewport(rowsOf(20));
    view.height = 100;
    view.layout();
    assert(view.slots.length == 0 && view.metrics().total == 0);
    view.scrollToRow(5, 0);
    assert(view.state.first == 0);
}

@("RowViewport: the place kept is put back by the new heights: the top edge, or the middle of a row where it was")
unittest
{
    double height = 20;
    auto view = new RowViewport((size_t i) nothrow => height);
    view.count = 100;
    view.height = 100;
    view.scrollBy(50, 20); // row 2, 10 px of it scrolled away
    view.layout();
    view.keepPlace();
    height = 40; // a bigger font
    assert(view.restorePlace());
    view.layout();
    assert(view.slots[0].index == 2 && view.slots[0].top == -10, "the first row stands where its top edge was");

    height = 20;
    view.layout();
    view.keepPlace((const(RowSlot)[] slots) => ScrollAnchor(true, slots[1].index, 0.5, slots[1].top + slots[1].height / 2));
    height = 40;
    assert(view.restorePlace());
    view.layout();
    foreach (slot; view.slots)
        if (slot.index == 3)
            assert(slot.top + slot.height / 2 == 20, "the middle of row 3 is where it was");
}

@("RowViewport: a scroll after the place was kept wins; nothing is kept for an empty window")
unittest
{
    double height = 20;
    auto view = new RowViewport((size_t i) nothrow => height);
    view.count = 100;
    view.height = 100;
    view.keepPlace(); // no slots yet
    assert(!view.restorePlace());
    view.layout();
    view.keepPlace();
    view.scrollTo(50);
    assert(!view.restorePlace(), "the user moved on");
    view.layout();
    assert(view.state.first == 50);
}

@("RowViewport: a place lower than the window's top takes rows from above")
unittest
{
    double height = 20;
    auto view = new RowViewport((size_t i) nothrow => height);
    view.count = 100;
    view.height = 100;
    view.scrollTo(10);
    view.layout();
    view.keepPlace((const(RowSlot)[] slots) => ScrollAnchor(true, 10, 0, 60)); // row 10 stands 60 px from the top
    assert(view.restorePlace());
    view.layout();
    assert(view.state.first == 7 && view.state.offset == 0 && view.slots[3].index == 10 && view.slots[3].top == 60);
}

@("RowViewport: the slot under a point, the first above the items and the last below them")
unittest
{
    auto view = new RowViewport(rowsOf(20));
    view.count = 100;
    view.height = 100;
    view.scrollBy(30, 20); // the first item is cut: starts at -10
    view.layout();
    assert(view.slotAt(-50) == 0 && view.slotAt(0) == 0 && view.slotAt(15) == 1);
    assert(view.slotAt(99) == view.slots.length - 1 && view.slotAt(500) == view.slots.length - 1);
}

@("RowViewport: layoutSettled lays out again while the count changes, and gives up after the rounds")
unittest
{
    auto view = new RowViewport(rowsOf(20));
    view.count = 100;
    view.height = 100;
    size_t counted;
    int layouts;
    // the heights change twice while the items are laid out: three rounds
    view.layoutSettled(() { ++layouts; return counted < 2 ? counted++ : counted; });
    assert(view.slots.length == 5);
    assert(layouts == 4, "two reads a round, two rounds: the count was still in the second");
    int endless;
    view.layoutSettled(() => cast(size_t) endless++, 3);
    assert(endless == 6, "three rounds, two reads each");
}

@("RowViewport: a place forgotten is not put back")
unittest
{
    auto view = new RowViewport(rowsOf(20));
    view.count = 100;
    view.height = 100;
    view.scrollTo(30);
    view.layout();
    view.keepPlace();
    view.forgetPlace();
    assert(!view.restorePlace());
}
