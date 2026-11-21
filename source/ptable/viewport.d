//! The lowest level of the table: a window on a long list of rows of different heights. It knows only how
//! many items there are, the height of each (a function), the height of the window and where the window
//! stands (the first item and the part of it scrolled away); it says which items are on the screen and
//! where, and what a scroll bar needs (`ScrollMetrics`, by `ptable.scrollscale`). It knows nothing of columns, cells,
//! text or colors, and nothing of a scroll bar's looks: any bar, the host's own or a painted one, is driven through
//! `metrics` and `scrollToFraction`. Pure. See docs/stories/painted-table.md.
module ptable.viewport;

import ptable.rowlayout;
import ptable.scrollscale : anchorFraction, anchorPlace, exactPixels, exactRows, pixelFraction, pixelSpan, pixelState, rowsShown;

import std.algorithm.comparison : max, min;

/// What an outside scroll bar needs, in no unit: where the thumb stands and how much of the track it takes. The owner of
/// the scroll (the viewport for the rows, the table for the columns) turns its place into these and a fraction back
/// into a place; a bar knows neither rows nor pixels.
struct ScrollMetrics
{
    double fraction = 0; /// where the thumb stands: 0 at the start, 1 at the end
    double shown = 1; /// how much of all is in view, 0 .. 1: the length of the thumb of the track; 1, nothing to scroll
}

/// How an item is to be shown (`RowViewport.revealPlan`)
struct RevealPlan
{
    bool needed; /// it is not shown yet
    double dy = 0; /// where its top is to stand, from the top of the window
    double top = double.nan; /// where its top stands now; NaN if it is more than two screens off
}

/// Where a glide to an item begins (`RowViewport.jumpToGlide`)
struct Approach
{
    double peek = 0; /// near: how much of an item out of the window shows at once, at most half of it
    /// How many windows from its place an item is far: a glide to it begins that many windows before the place. At most 2: an
    /// item `topOf` does not know is more than two windows off the window, so it never begins farther than it was
    double lead = 0;
}

/// What `RowViewport.jumpToGlide` did
enum Jump
{
    none, /// the window stays: the item is in it, even in part
    near, /// the item out of the window peeks in at its edge
    far, /// the window jumps to `Approach.lead` windows before the place
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
    private HeightOf _heightOf, _estimate;
    private size_t _count;
    private double _height = 0;
    private ViewState _state;
    private RowSlot[] _slots;
    private double _pending = 0;
    private ScrollAnchor _anchor;
    private double _minHeight = 0;
    private Held _held;

    private enum Held : ubyte
    {
        none,
        pixels,
        anchor,
    }

    /// `heightOf(index)` is the height of an item (it may be costly: what it says is asked for the items
    /// near the window and, on a far scroll, never for the ones passed)
    /// `estimate(index)`: what a sum over all the rows of a list scrolled by pixels takes, the height as known (measured at
    /// another width: no new measure); null, `heightOf`
    this(HeightOf heightOf, HeightOf estimate = null)
    {
        _heightOf = heightOf;
        _estimate = estimate !is null ? estimate : heightOf;
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

    /// How the item `index` is to be shown: whether it has to be, where it is to stand, and where it stands now. Shown already: wholly in the window, or
    /// taller than the window and covering it (a second click on it does not scroll it). Else it is brought in with `margin` pixels left on the
    /// side it came from: under it if it came from below, above it if from above; one that does not fit the window with its margin is brought to
    /// the top of the window, except one taller than the window that came from above: its bottom is brought to the bottom of the window (the least
    /// scroll that makes it cover the window). `top`: where it stands now from the top of the window, NaN if it is more than two screens off (the
    /// caller jumps to it)
    RevealPlan revealPlan(size_t index, double margin)
    {
        import std.math : isNaN;

        const height = _heightOf(index);
        const top = topOf(index);
        if (!top.isNaN)
        {
            if (top >= 0 && top + height <= _height)
                return RevealPlan(false, 0, top);
            if (height > _height && top <= 0 && top + height >= _height)
                return RevealPlan(false, 0, top);
        }
        const above = top.isNaN ? (_slots.length > 0 && index < _slots[0].index) : top < 0;
        const fits = height + margin <= _height;
        const dy = fits ? (above ? margin : _height - margin - height) : (above && height > _height ? _height - height : 0);
        return RevealPlan(true, dy, top);
    }

    /// Before a glide that brings the top of the item `index`, now at `top` (NaN: far off, `topOf`), to `dy` from the top of the
    /// window, the window jumps to where the glide begins (`dy` one the item can reach: `reachableTop`). Far (`top` NaN, or more than `approach.lead` windows from `dy`): the
    /// item stands `lead` windows before its place on the side it comes from, the ends of the list cutting that short. Near and out
    /// of the window: `approach.peek` pixels of it, at most half of it, show at the edge it comes from. Near and in the window, even
    /// in part: it stays. The slots are laid out again by the caller when it moved
    Jump jumpToGlide(size_t index, double dy, double top, Approach approach, double fallbackHeight)
    {
        import std.math : abs, isNaN;

        if (top.isNaN || abs(top - dy) > approach.lead * _height)
        {
            const below = top.isNaN ? index > _state.first : top > dy;
            const lead = approach.lead * _height;
            scrollToRow(index, dy); // at its place first: what is before it is walked back from there, the ends stop it
            scrollBy(below ? -lead : lead, fallbackHeight);
            return Jump.far;
        }
        const height = _heightOf(index);
        if (top < _height && top + height > 0)
            return Jump.none;
        const shown = min(approach.peek, height / 2);
        scrollToRow(index, top >= _height ? _height - shown : shown - height);
        return Jump.near;
    }

    /// Where the top of the item `index` can stand when it is asked to stand `dy` from the top of the window: the start of the
    /// list keeps it no lower than the items above it reach, the end keeps the bottom of the last item no higher than the bottom
    /// of the window (a list shorter than the window stays at its top). Walks no more items than fill the window
    double reachableTop(size_t index, double dy)
    {
        if (_count == 0)
            return dy;
        double below = 0; // the item and the ones after it, until they fill the window under dy
        for (size_t i = index; i < _count && below < _height - dy; ++i)
            below += _heightOf(i);
        if (below < _height - dy)
            dy = _height - below;
        double above = 0; // the items before it, until they reach dy
        for (size_t i = index; i > 0 && above < dy; --i)
            above += _heightOf(i - 1);
        return min(dy, above);
    }

    /// Shows the item `index` by the least scroll if it is among the items on the screen, or not more than two screens off them
    /// (it then stands at the edge it came from); false if it is farther (the caller then scrolls to it)
    bool reveal(size_t index, double fallbackHeight)
    {
        import std.math : isNaN;

        const plan = revealPlan(index, 0);
        if (plan.top.isNaN)
            return false;
        if (plan.needed)
            scrollBy(plan.top - plan.dy, fallbackHeight);
        return true;
    }

    /// No row is lower than `value` (0: not known): with it a short list is scrolled by pixels (`ptable.scrollscale`)
    void minHeight(double value)
    {
        _minHeight = value;
    }

    /// Whether the list is scrolled by pixels, every row of it measured (`exactPixels`), or as `holdScale` keeps it: by
    /// pixels until the list grows far past the threshold (the sum of all its rows would cost too much), by the anchor unless
    /// it would move the rows back
    bool exact() const
    {
        final switch (_held)
        {
        case Held.none:
            return exactPixels(_count, _minHeight, _height);
        case Held.pixels:
            return _count <= 2 * exactRows || exactPixels(_count, _minHeight, _height);
        case Held.anchor:
            return _minHeight > 0 && _count * _minHeight < _height;
        }
    }

    /// A thumb is pressed (`on`) or released: while it is dragged the scale stays the one it had at the press (by pixels or by
    /// the anchor), so a list growing past `exactRows` under the drag does not move the rows under a mouse that stood still
    void holdScale(bool on)
    {
        _held = on ? (exact ? Held.pixels : Held.anchor) : Held.none;
    }

    /// What a scroll bar shows, as `layout` last put the rows: exactly 0 at the start and 1 with the end in view
    ScrollMetrics metrics()
    {
        if (_count == 0 || _slots.length == 0)
            return ScrollMetrics.init;
        const atStart = _state.first == 0 && _state.offset == 0, atEnd = endInView();
        if (atStart && atEnd)
            return ScrollMetrics.init; // all of it in the window
        if (exact)
        {
            const span = pixelSpan(_state, _count, _estimate);
            const fraction = atStart ? 0 : atEnd ? 1 : pixelFraction(span, _height);
            return ScrollMetrics(fraction, span.total > 0 ? min(1.0, _height / span.total) : 1);
        }
        const fraction = atStart ? 0 : atEnd ? 1 : anchorFraction(_slots, _count, _height);
        return ScrollMetrics(fraction, rowsShown(_slots, _count, _height));
    }

    /// The window stands where a bar at `fraction` (0 .. 1) says: the point of the list at that fraction at that fraction
    /// of the window, or for a short list (`exact`) that fraction of the pixels it can scroll
    void scrollToFraction(double fraction)
    {
        if (_count == 0)
            return;
        if (exact)
        {
            _anchor = ScrollAnchor.init;
            _state = pixelState(fraction, _count, _height, _estimate);
            return;
        }
        const at = anchorPlace(fraction, _count, _height, _heightOf);
        scrollToRow(at.row, at.dy);
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

@("RowViewport.jumpToGlide: a place far off or more than lead windows away begins the glide lead windows before it, on the side the item comes from")
unittest
{
    auto view = new RowViewport(rowsOf(20)); // rows of 20 in a window of 100
    view.count = 1000;
    view.height = 100;
    view.layout();
    enum approach = Approach(20, 2);
    assert(view.jumpToGlide(500, 60, view.topOf(500), approach, 20) == Jump.far, "far below");
    view.layout();
    assert(view.topOf(500) == 60 + 200, "two windows under its place");
    assert(view.jumpToGlide(10, 24, view.topOf(10), approach, 20) == Jump.far, "far above");
    view.layout();
    assert(view.topOf(10) == 24 - 200, "two windows over its place");
    view.scrollTo(0);
    view.layout();
    assert(view.topOf(13) == 260 && view.jumpToGlide(13, 0, 260, approach, 20) == Jump.far, "known, but more than two windows from its place");
    view.layout();
    assert(view.topOf(13) == 200, "it comes no farther than lead windows");
    view.scrollTo(600);
    view.layout();
    assert(view.jumpToGlide(0, 0, view.topOf(0), approach, 20) == Jump.far);
    view.layout();
    assert(view.topOf(0) == -200, "the first item from far below: two windows over the top");
}

@("RowViewport.jumpToGlide: near, an item out of the window peeks in at its edge, at most half of it; one in the window stays")
unittest
{
    auto view = new RowViewport(rowsOf(20));
    view.count = 1000;
    view.height = 100;
    view.layout();
    enum approach = Approach(20, 2);
    assert(view.jumpToGlide(5, 60, view.topOf(5), approach, 20) == Jump.near, "row 5 at 100, 40 from its place: near");
    view.layout();
    assert(view.topOf(5) == 90, "half of it (10, less than 20) in at the bottom");
    assert(view.jumpToGlide(1, 24, view.topOf(1), approach, 20) == Jump.none, "in the window: no jump");
    view.layout();
    assert(view.topOf(1) == 10, "in the window (partly): it stays");
    view.scrollTo(10);
    view.layout();
    assert(view.jumpToGlide(9, 24, view.topOf(9), Approach(8, 2), 20) == Jump.near);
    view.layout();
    assert(view.topOf(9) == 8 - 20, "above: 8 of it in at the top");
}

@("RowViewport.reachableTop: where an item can stand: the start of the list keeps it no lower than the items above it, the end no higher than its bottom at the bottom")
unittest
{
    auto view = new RowViewport(rowsOf(20)); // rows of 20 in a window of 100
    view.count = 1000;
    view.height = 100;
    assert(view.reachableTop(0, 24) == 0 && view.reachableTop(1, 24) == 20 && view.reachableTop(2, 24) == 24, "the start");
    assert(view.reachableTop(999, 60) == 80 && view.reachableTop(998, 0) == 60, "the end");
    assert(view.reachableTop(500, 60) == 60 && view.reachableTop(500, -30) == -30, "the middle: as asked");
    view.count = 3;
    assert(view.reachableTop(2, 80) == 40, "a list shorter than the window stays at its top");
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

@("RowViewport.metrics: the fraction of the bar and the part of the rows in view; all in the window is nothing to scroll")
unittest
{
    auto view = new RowViewport(rowsOf(20));
    view.minHeight = 20;
    view.count = 1000;
    view.height = 100;
    view.layout();
    assert(view.metrics() == ScrollMetrics(0, 5.0 / 1000));
    view.scrollToFraction(0.5);
    view.layout();
    const m = view.metrics();
    assert(m.fraction - 0.5 < 1e-9 && m.fraction - 0.5 > -1e-9, "the fraction it was put at");
    view.count = 3;
    view.layout();
    assert(view.metrics() == ScrollMetrics.init, "three rows in the window: nothing to scroll");
}

@("RowViewport.metrics: the end in view is exactly 1, and a bar at 1 brings the end in view (it did not: the thumb stopped short)")
unittest
{
    auto view = new RowViewport(rowsOf(20));
    view.minHeight = 20;
    view.count = 30;
    view.height = 90; // four and a half rows
    view.scrollToEnd();
    view.layout();
    assert(view.metrics().fraction == 1);
    view.scrollTo(0);
    view.layout();
    view.scrollToFraction(1);
    view.layout();
    assert(view.endInView() && view.metrics().fraction == 1);
}

@("RowViewport.scrollToFraction: a bar dragged down never moves wrapped rows back, and reaches the end; the rows give back the fraction")
unittest
{
    auto view = new RowViewport((size_t i) nothrow => i % 7 == 3 ? 300.0 : i % 3 == 0 ? 48.0 : 16.0);
    view.minHeight = 16;
    view.count = exactRows + 200; // by the anchor
    view.height = 250;
    double last = -1;
    foreach (step; 0 .. 501)
    {
        const p = step / 500.0;
        view.scrollToFraction(p);
        view.layout();
        double above = view.state.offset;
        foreach (i; 0 .. view.state.first)
            above += i % 7 == 3 ? 300.0 : i % 3 == 0 ? 48.0 : 16.0;
        assert(above >= last - 1e-6, "never back");
        last = above;
        const back = view.metrics().fraction;
        assert(back - p < 1e-9 && back - p > -1e-9, "the fraction it was put at");
    }
    assert(view.endInView());
}

@("RowViewport: a list shorter than a window of its least rows, wrapped taller than the window, is scrolled by pixels")
unittest
{
    auto view = new RowViewport((size_t i) nothrow => i == 2 ? 400.0 : 20.0); // 5 rows: 480 px
    view.minHeight = 20;
    view.count = 5;
    view.height = 200; // 5 · 20 < 200
    assert(view.exact);
    view.scrollToFraction(0.5); // 140 of 280
    view.layout();
    assert(view.state == ViewState(2, 100));
    assert(view.metrics() == ScrollMetrics(0.5, 200.0 / 480));
    view.count = exactRows + 1;
    view.minHeight = 0;
    assert(!view.exact, "many rows, the least height not known: by the anchor");
}

@("RowViewport: a few tall rows in a small window are scrolled by pixels: the thumb keeps its size and goes by the pixels")
unittest
{
    HeightOf h = (size_t i) nothrow => i % 3 == 0 ? 500.0 : 20.0; // 10 rows: 4 of 500, 6 of 20: 2120 px
    auto view = new RowViewport(h);
    view.minHeight = 20;
    view.count = 10;
    view.height = 60;
    double shown = double.nan;
    foreach (step; 0 .. 101)
    {
        view.scrollToFraction(step / 100.0);
        view.layout();
        const m = view.metrics();
        if (step > 0 && step < 100)
            assert(shown != shown || m.shown == shown, "the thumb is as long all the way");
        if (step > 0 && step < 100)
            shown = m.shown;
    }
    assert(shown == 60.0 / 2120);
    view.scrollToFraction(500.0 / 2060); // the first tall row scrolled away: the top of row 1
    view.layout();
    assert(view.state == ViewState(1, 0), "by the pixels, not by the rows");
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

@("RowViewport.revealPlan: an item is brought in with the margin on the side it came from; one that does not fit goes to the top; one shown is left")
unittest
{
    auto view = new RowViewport((size_t i) nothrow => i == 5 ? 250.0 : 20.0); // the window is 100: item 5 is taller
    view.count = 40;
    view.height = 100;
    view.layout(); // items 0..4 fill the window
    auto plan = view.revealPlan(2, 24);
    assert(!plan.needed && plan.top == 40, "wholly in the window: shown, margins or not");
    plan = view.revealPlan(5, 24);
    assert(plan.needed && plan.dy == 0 && plan.top == 100, "taller than the window: its top goes to the top of the window");
    view.scrollToRow(10, 70); // item 10 is 70 under the top: wholly in the window, items 8 and 9 above it
    view.layout();
    assert(!view.revealPlan(10, 24).needed);
    plan = view.revealPlan(12, 24); // 70 + 20 + 20 = 110: below the window (100), whole item cut
    assert(plan.needed && plan.top == 110 && plan.dy == 100 - 24 - 20, "from below: 24 under it");
    view.scrollToRow(10, 0);
    view.layout();
    plan = view.revealPlan(9, 24); // 20 above the top
    assert(plan.needed && plan.top == -20 && plan.dy == 24, "from above: 24 over it");
    plan = view.revealPlan(14, 24); // 80: cut at the bottom (80 + 20 = 100: not cut)
    assert(!plan.needed, "ends at the edge: wholly in");
    view.scrollToRow(10, -5); // item 10 is cut at the top by 5
    view.layout();
    plan = view.revealPlan(10, 24);
    assert(plan.needed && plan.dy == 24 && plan.top == -5, "cut at the top counts as from above");
    plan = view.revealPlan(30, 24);
    assert(plan.needed && plan.top != plan.top && plan.dy == 100 - 24 - 20, "far off below: NaN where it stands, the place to stand is known");
    plan = view.revealPlan(1, 24);
    assert(plan.needed && plan.top != plan.top && plan.dy == 24, "far off above");
    assert(view.revealPlan(16, 0).dy == 80 && view.revealPlan(8, 0).dy == 0, "no margin: at the edge it came from");
    assert(view.revealPlan(16, 90).dy == 0, "a margin that leaves no room for the item: the top");
}

@("RowViewport.revealPlan: an item taller than the window that covers it is shown; one that does not is brought to cover it from the side it came from")
unittest
{
    auto view = new RowViewport((size_t i) nothrow => i == 5 ? 250.0 : 20.0);
    view.count = 20;
    view.height = 100;
    view.scrollToRow(5, -60); // 60 of it are above, 190 below the bottom
    view.layout();
    assert(!view.revealPlan(5, 24).needed, "it covers the window");
    view.scrollToRow(5, 0);
    view.layout();
    assert(!view.revealPlan(5, 24).needed, "its top at the top of the window: it covers it");
    view.scrollToRow(5, 50); // starts 50 under the top
    view.layout();
    auto plan = view.revealPlan(5, 24);
    assert(plan.needed && plan.dy == 0 && plan.top == 50);
    view.scrollToRow(5, -200); // its last 50 are in the window
    view.layout();
    plan = view.revealPlan(5, 24);
    assert(plan.needed && plan.dy == 100 - 250 && plan.top == -200, "cut at the top: its bottom comes to the bottom of the window");
    view.scrollToRow(15, 0); // item 5 is far off above
    view.layout();
    plan = view.revealPlan(5, 24);
    assert(plan.needed && plan.top != plan.top && plan.dy == 100 - 250, "far off above: its bottom comes to the bottom of the window");
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
    assert(view.slots.length == 0 && view.metrics() == ScrollMetrics.init);
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

@("RowViewport: a list scrolled by pixels sums the estimates of its rows: only the rows on the screen are measured")
unittest
{
    size_t measured;
    auto view = new RowViewport((size_t i) nothrow { ++measured; return 20.0; }, (size_t i) nothrow => 20.0);
    view.minHeight = 20;
    view.count = 100;
    view.height = 100;
    assert(view.exact);
    view.scrollToFraction(0.5);
    view.layout();
    measured = 0;
    const m = view.metrics();
    assert(m == ScrollMetrics(0.5, 100.0 / 2000) && measured == 0, "the sum is of the estimates");
}

@("RowViewport.holdScale: while a thumb is dragged the scale stays the one it had at the press, though the list grows past the threshold")
unittest
{
    auto view = new RowViewport(rowsOf(20));
    view.minHeight = 20;
    view.height = 100;
    view.count = exactRows;
    view.holdScale(true);
    view.count = exactRows + 10; // a search goes on finding rows
    assert(view.exact, "held: by pixels, as at the press");
    view.count = 3 * exactRows;
    assert(!view.exact, "grown far past: the sum of all the rows would cost too much, held or not");
    view.holdScale(false);
    view.count = exactRows + 10;
    assert(!view.exact, "released: by the anchor");
    view.holdScale(true);
    view.count = exactRows;
    assert(!view.exact, "held by the anchor though the list got few rows");
    view.count = 2; // 2 · 20 < 100: the anchor would move back
    assert(view.exact, "but not when the anchor would move the rows back");
    view.holdScale(false);
}
