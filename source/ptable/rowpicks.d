//! How rows are picked in a table: the set of the rows selected (`RowRanges`), the row a range from the keys or the mouse
//! starts at (the anchor) and the row the last pick made current. The rules of one pick replacing, extending or toggling
//! another live here, as pure functions of what was picked; the host decides which keys mean which `Pick` (nothing here knows
//! a key). Pure. See docs/stories/painted-table.md.
module ptable.rowpicks;

import ptable.rowranges : RowRange, RowRanges;

/// What a pick does to the rows already picked
enum Pick : ubyte
{
    replace, /// only this row
    extend, /// the rows from the anchor to this one, and no others
    toggle, /// this row in or out, the others stay
    extendAdd, /// the rows from the anchor to this one join the others
}

struct RowPicks
{
    RowRanges ranges; /// the rows picked
    long anchor = -1; /// where a range from `extend` starts: the row of the last pick that was not an extension
    long current = -1; /// the row of the last pick (the keyboard's row, the one the other table follows)
    private RowRange[] _base; // the rows picked before a drag: the drag adds to them
    private long _dragRow = -1; // the row the drag reached last

    /// Picks the row `index` by `mode`; true if the rows picked or the current row changed
    bool pick(size_t index, Pick mode)
    {
        const from = anchor < 0 ? index : cast(size_t) anchor;
        bool changed;
        final switch (mode)
        {
        case Pick.replace:
            changed = ranges.only(index);
            anchor = index;
            break;
        case Pick.extend:
            changed = ranges.setRange(from, index);
            anchor = from;
            break;
        case Pick.toggle:
            changed = ranges.toggle(index);
            anchor = index;
            break;
        case Pick.extendAdd:
            changed = ranges.add(from, index);
            anchor = from;
            break;
        }
        changed |= current != cast(long) index;
        current = index;
        return changed;
    }

    /// A plain click on the row `index`: only it, but a click on a row that is picked lets go of all the rows, it too (`deselect`
    /// false: not that, the click is the second one of a double click). True if something changed
    bool click(size_t index, bool deselect = true)
    {
        if (deselect && ranges.has(index))
        {
            anchor = index;
            current = index;
            return ranges.clear();
        }
        return pick(index, Pick.replace);
    }

    /// A press of the mouse that may begin a drag over rows: what is picked now is kept under the drag if `keepRows`
    void beginDrag(bool keepRows)
    {
        _base = keepRows ? ranges.ranges.dup : null;
        _dragRow = current; // the row of the press was picked by it: staying on it changes nothing
    }

    /// The mouse dragged to the row `index`: the rows kept, and those from the anchor to it. True if something changed
    bool dragTo(size_t index)
    {
        if (cast(long) index == _dragRow)
            return false;
        _dragRow = index;
        const from = anchor < 0 ? index : cast(size_t) anchor;
        ranges.assign(_base);
        ranges.add(from, index);
        current = index;
        return true;
    }

    /// A click for a context menu on the row `index`: a row picked keeps the rows, another becomes the only one
    bool keepContext(size_t index)
    {
        bool changed;
        if (!ranges.has(index))
        {
            changed = ranges.only(index);
            anchor = index;
        }
        changed |= current != cast(long) index;
        current = index;
        return changed;
    }

    /// All of the `count` rows are picked; the anchor and the current row stay where they are (the first row if none): nothing
    /// scrolls, and Shift with an arrow goes on from where the user was. True if the rows picked or the current row changed
    bool all(size_t count)
    {
        if (count == 0)
            return false;
        bool changed = ranges.setRange(0, count - 1);
        if (anchor < 0)
            anchor = 0;
        if (current < 0)
        {
            current = 0;
            changed = true;
        }
        return changed;
    }

    /// The row the other table is to follow: the current one if it is picked, else none (-1)
    long followed() const
    {
        return current >= 0 && ranges.has(cast(size_t) current) ? current : -1;
    }

    /// No row is picked; the current row stays. True if there were
    bool clearRows()
    {
        return ranges.clear();
    }

    /// Nothing is picked and no row is current (the rows shown are other ones)
    bool reset()
    {
        const had = !ranges.empty || current >= 0;
        ranges.clear();
        anchor = current = -1;
        return had;
    }
}

@("RowPicks: a click picks only its row and makes it current")
unittest
{
    RowPicks picks;
    assert(picks.pick(5, Pick.replace) && picks.pick(7, Pick.replace));
    assert(picks.ranges.ranges == [RowRange(7, 7)] && picks.current == 7 && picks.anchor == 7);
}

@("RowPicks: extend picks from the anchor either way, and without one only the row")
unittest
{
    RowPicks picks;
    picks.pick(10, Pick.replace);
    picks.pick(14, Pick.extend);
    assert(picks.ranges.ranges == [RowRange(10, 14)] && picks.current == 14);
    picks.pick(8, Pick.extend);
    assert(picks.ranges.ranges == [RowRange(8, 10)], "the range starts from the same row again");
    RowPicks fresh;
    fresh.pick(3, Pick.extend);
    assert(fresh.ranges.ranges == [RowRange(3, 3)]);
}

@("RowPicks: toggle adds or removes a row and starts the next range from it, extendAdd keeps the others")
unittest
{
    RowPicks picks;
    picks.pick(2, Pick.replace);
    picks.pick(6, Pick.toggle);
    assert(picks.ranges.ranges == [RowRange(2, 2), RowRange(6, 6)]);
    picks.pick(3, Pick.toggle);
    assert(picks.ranges.ranges == [RowRange(2, 3), RowRange(6, 6)], "adjacent rows join");
    picks.pick(2, Pick.toggle);
    assert(picks.ranges.ranges == [RowRange(3, 3), RowRange(6, 6)]);
    picks.pick(5, Pick.extend);
    assert(picks.ranges.ranges == [RowRange(2, 5)], "from the row of the last toggle");

    RowPicks more;
    more.pick(1, Pick.replace);
    more.pick(10, Pick.toggle);
    more.pick(12, Pick.extendAdd);
    assert(more.ranges.ranges == [RowRange(1, 1), RowRange(10, 12)]);
}

@("RowPicks: a pick says whether anything changed; the same row again changes nothing")
unittest
{
    RowPicks picks;
    assert(picks.pick(4, Pick.replace));
    assert(!picks.pick(4, Pick.replace), "a key at the edge of the log: no news");
    assert(picks.pick(5, Pick.extend) && !picks.pick(5, Pick.extend));
}

@("RowPicks: a click on a row that is picked lets go of all the rows, on another picks only that; a double click's second click does not let go")
unittest
{
    RowPicks picks;
    picks.click(4);
    assert(picks.click(4) && picks.ranges.empty && picks.current == 4 && picks.followed == -1, "the row is not picked, the other table follows none");
    picks.click(4);
    picks.pick(6, Pick.extend);
    assert(picks.click(5) && picks.ranges.empty, "one of many: all of them go, it too");
    picks.pick(4, Pick.replace);
    picks.pick(6, Pick.extend);
    assert(picks.click(9) && picks.ranges.ranges == [RowRange(9, 9)], "a row that is not picked: only it");
    assert(!picks.click(9, false) && picks.ranges.ranges == [RowRange(9, 9)], "the second click of a double one");
}

@("RowPicks: a drag picks from the anchor to the row under the mouse, over the rows kept if asked")
unittest
{
    RowPicks picks;
    picks.pick(2, Pick.replace);
    picks.pick(20, Pick.toggle);
    picks.beginDrag(true);
    assert(picks.dragTo(23) && picks.ranges.ranges == [RowRange(2, 2), RowRange(20, 23)]);
    assert(!picks.dragTo(23), "the same row under the mouse: nothing");
    picks.dragTo(17);
    assert(picks.ranges.ranges == [RowRange(2, 2), RowRange(17, 20)] && picks.current == 17, "back over the base, not over what the drag added");
    picks.pick(5, Pick.replace);
    picks.beginDrag(false);
    picks.dragTo(8);
    assert(picks.ranges.ranges == [RowRange(5, 8)], "the rows before are not kept");
}

@("RowPicks: a context click keeps the rows if it is on one, else picks it; followed is the current row if picked")
unittest
{
    RowPicks picks;
    picks.pick(3, Pick.replace);
    picks.pick(9, Pick.extend);
    assert(picks.keepContext(5) && picks.ranges.ranges == [RowRange(3, 9)] && picks.current == 5);
    assert(picks.followed == 5);
    assert(picks.keepContext(20) && picks.ranges.ranges == [RowRange(20, 20)]);
    assert(picks.clearRows() && picks.followed == -1 && picks.current == 20);
    assert(picks.reset() && picks.current == -1 && picks.anchor == -1 && !picks.reset());
}

@("RowPicks: all picks every row and keeps the anchor and the current row, the first one if there are none; no rows: nothing")
unittest
{
    RowPicks picks;
    assert(!picks.all(0) && picks.current == -1);
    assert(picks.all(10) && picks.ranges.ranges == [RowRange(0, 9)] && picks.anchor == 0 && picks.current == 0);
    assert(!picks.all(10), "again: no news");
    picks.pick(4, Pick.replace);
    assert(picks.all(10) && picks.anchor == 4 && picks.current == 4, "the user's place stays");
    picks.pick(3, Pick.extend);
    assert(picks.ranges.ranges == [RowRange(3, 4)], "Shift with a key goes on from the anchor");
}
