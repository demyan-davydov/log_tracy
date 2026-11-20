//! The rows a table has picked and how the input picks them: a pick by a mode (replace, extend, toggle, extend and add), a
//! plain click, a press with a mode that picks at once and drags over rows, Escape (the text first, then the rows), and telling the
//! host the current row. What it needs of the table (is an item virtual, which row is at a height, show a row, tell the host)
//! it gets through `PickPorts`; it knows nothing of the scroll, the model or the table. Owns the text selection and the press
//! (`TableSelection`) the rows go with. See docs/stories/painted-table.md.
module ptable.rowpicker;

import ptable.cellpress : CellPress;
import ptable.hovercell : HoverCell;
import ptable.rowpicks : Pick, RowPicks;
import ptable.rowranges : RowRange, RowRanges;
import ptable.tableselection : TableSelection;

/// What the picker asks of the table
struct PickPorts
{
    bool delegate(size_t item) isVirtual; /// the item is a separator: it is not picked
    bool delegate(double y, out size_t row) rowAt; /// the row at the height `y` of the table (clamped to the rows in sight)
    void delegate(size_t item, double timestampMs) show; /// the row is shown (laid out and revealed, by a glide if the time is a number)
    void delegate(size_t item, bool delayed) told; /// the host is told that the row `item` is the current one; `delayed`: a drag or a key moved it, it may move on (the host waits for it to rest)
    void delegate() invalidate; /// the table is to be painted again
}

final class RowPicker
{
    private RowPicks _picks; // the rows picked, where a range starts, the current row
    private Pick _mode; // what the press that is on does to the rows
    private bool _rowDragging; // the press picked a row, a drag from it goes over rows
    private TableSelection _text; // the text selected, the press, the copy
    private PickPorts _ports;
    private CellPress _cell; // a press on a cell of a clickable column: it picks nothing
    private HoverCell _hover; // the cell under the mouse

    this(TableSelection text, PickPorts ports)
    {
        _text = text;
        _ports = ports;
    }

    /// The text selected, the press and the copy
    inout(TableSelection) text() inout
    {
        return _text;
    }

    /// The press on a cell of a clickable column that is on
    ref CellPress cellPress() return
    {
        return _cell;
    }

    /// The cell under the mouse
    ref HoverCell hover() return
    {
        return _hover;
    }

    /// The current row if it is picked, else -1: what the other table follows
    long selected() const
    {
        return _picks.followed;
    }

    /// The row of the last pick, picked or not: the keys move from it; -1 if none
    long currentRow() const
    {
        return _picks.current;
    }

    /// The rows picked
    ref const(RowRanges) rows() const
    {
        return _picks.ranges;
    }

    bool isSelected(size_t index) const
    {
        return _picks.ranges.has(index);
    }

    ulong count() const
    {
        return _picks.ranges.count;
    }

    const(RowRange)[] ranges() const
    {
        return _picks.ranges.ranges;
    }

    /// Picks the item `index` alone and shows it; the host is told, even if it was picked
    void select(long index)
    {
        selectRow(index, Pick.replace, true);
    }

    /// Picks the item `index` (-1: nothing) by `mode` and shows it; a virtual item is not picked. The host is told the current
    /// row when it changed, or always if `always`. `timestampMs`: the clock of the host's frames, for the glide to the row
    void selectRow(long index, Pick mode, bool always = false, double timestampMs = double.nan)
    {
        if (index >= 0 && _ports.isVirtual(cast(size_t) index))
            return;
        const changed = index < 0 ? _picks.reset() : _picks.pick(cast(size_t) index, mode);
        if (index >= 0)
            _ports.show(cast(size_t) index, timestampMs);
        if (changed || always)
            told(!always); // a selection asked for is told at once, a step of the keys may be followed by another
        _ports.invalidate();
    }

    /// The row `index` is picked alone, shown nowhere (a double click gives the row it selected the text in back)
    void pick(size_t index, Pick mode)
    {
        _picks.pick(index, mode);
    }

    /// All of the `count` items are picked; nothing is shown or scrolled. The host is told if the current row changed
    void selectAll(size_t count)
    {
        if (_picks.all(count))
        {
            told(true);
            _ports.invalidate();
        }
    }

    /// A click for a context menu on the row `row`: a row picked keeps the rows, another becomes the only one
    void pickForContext(size_t row)
    {
        if (_ports.isVirtual(row))
            return;
        if (_picks.keepContext(row))
        {
            told(false);
            _ports.invalidate();
        }
    }

    /// Lets go of the rows picked
    void clear()
    {
        if (_picks.clearRows())
            _ports.invalidate();
    }

    /// Escape: lets go of the text, and when there is none of the rows; true if there was something
    bool escape()
    {
        return _text.clearText() || _picks.clearRows();
    }

    /// A press of the mouse at the height `y` with `mode`: any mode but `replace` picks the row under it at once, and a
    /// drag from it goes over rows; a plain press picks nothing yet (a click will, a drag selects text)
    void press(double y, Pick mode)
    {
        _mode = mode;
        _rowDragging = false;
        if (mode == Pick.replace)
            return;
        size_t row;
        if (!_ports.rowAt(y, row) || _ports.isVirtual(row))
            return;
        _picks.pick(row, mode);
        _picks.beginDrag(mode == Pick.toggle || mode == Pick.extendAdd);
        _rowDragging = true;
        told(false); // a press with a mode picks at once, as a click does
        _ports.invalidate();
    }

    /// Whether the press that is on drags over rows
    bool rowDrag() const
    {
        return _rowDragging;
    }

    /// The drag over rows reached the height `y`
    void dragTo(double y)
    {
        size_t row;
        if (_ports.rowAt(y, row) && !_ports.isVirtual(row) && _picks.dragTo(row))
        {
            told(true); // the mouse is still moving
            _ports.invalidate();
        }
    }

    /// A plain click on the row `index`: it alone is picked, and shown (`timestampMs`: the clock of the host's frames, for the
    /// glide to the row)
    void click(size_t index, double timestampMs = double.nan)
    {
        if (_ports.isVirtual(index))
            return;
        const changed = _picks.click(index, false); // a click on a picked row picks only it: letting go of all of them is for later
        _ports.show(index, timestampMs);
        if (changed)
            told(false);
        _ports.invalidate();
    }

    /// The press is over (the button went up, or it was cancelled)
    void endPress()
    {
        _rowDragging = false;
    }

    // The host is told the current row, if it is picked
    private void told(bool delayed)
    {
        const row = _picks.followed;
        if (row >= 0)
            _ports.told(cast(size_t) row, delayed);
    }
}

version (unittest)
{
    // Ports on a list of items of which some are virtual: what is called is written down
    private final class Fake
    {
        bool[size_t] virtual_;
        size_t rows = 20;
        string[] calls;
        double rowHeight = 16;

        PickPorts ports()
        {
            return PickPorts(&isVirtual, &rowAt, &show, &told, &invalidate);
        }

        bool isVirtual(size_t item) { return item in virtual_ ? true : false; }
        bool rowAt(double y, out size_t row)
        {
            row = y < 0 ? 0 : cast(size_t)(y / rowHeight);
            if (row >= rows)
                row = rows - 1;
            return true;
        }
        void show(size_t item, double ts) { calls ~= "show"; }
        void told(size_t item, bool delayed) { calls ~= delayed ? "told, delayed" : "told"; }
        void invalidate() { calls ~= "invalidate"; }
    }
}

@("RowPicker: a row is picked, then shown, then told; a virtual one is not picked; a key at the same row tells nothing")
unittest
{
    auto fake = new Fake;
    fake.virtual_[7] = true;
    auto picker = new RowPicker(new TableSelection(null, null), fake.ports);
    picker.selectRow(3, Pick.replace);
    assert(picker.isSelected(3) && picker.selected == 3 && fake.calls == ["show", "told, delayed", "invalidate"], "in this order; a step of the keys is delayed");
    fake.calls = null;
    picker.selectRow(3, Pick.replace);
    assert(fake.calls == ["show", "invalidate"], "the same row: not told");
    fake.calls = null;
    picker.select(3);
    assert(fake.calls == ["show", "told", "invalidate"], "select tells always, at once");
    fake.calls = null;
    picker.selectRow(7, Pick.replace);
    assert(picker.selected == 3 && fake.calls.length == 0, "a virtual item is not picked, nothing is called");
    picker.selectRow(-1, Pick.replace);
    assert(picker.selected == -1 && picker.count == 0, "nothing picked");
    assert(fake.calls == ["invalidate"], "and nothing is shown");
}

@("RowPicker: a press with a mode picks the row under it at once and drags over rows, a plain press picks nothing")
unittest
{
    auto fake = new Fake;
    auto picker = new RowPicker(new TableSelection(null, null), fake.ports);
    picker.press(20, Pick.replace);
    assert(picker.count == 0 && !picker.rowDrag);
    picker.endPress();
    picker.select(1);
    fake.calls = null;
    picker.press(16 * 4 + 3, Pick.toggle);
    assert(picker.isSelected(4) && picker.isSelected(1) && picker.rowDrag && fake.calls == ["told", "invalidate"], "picked, told at once as a click is, not shown");
    fake.calls = null;
    picker.dragTo(16 * 6 + 3);
    assert(picker.ranges == [RowRange(1, 1), RowRange(4, 6)] && fake.calls == ["told, delayed", "invalidate"], "a drag is delayed");
    fake.calls = null;
    picker.dragTo(16 * 6 + 5);
    assert(fake.calls.length == 0, "the same row under the mouse: no news");
    picker.endPress();
    assert(!picker.rowDrag);
}

@("RowPicker: a press that finds no row to pick does not drag over rows")
unittest
{
    auto fake = new Fake;
    fake.virtual_[2] = true;
    auto picker = new RowPicker(new TableSelection(null, null), fake.ports);
    picker.press(16 * 2 + 3, Pick.extend);
    assert(!picker.rowDrag && picker.count == 0, "the row under it is a separator");
}

@("RowPicker: a click picks the row alone and shows it, on a picked row too; a virtual row is not clicked")
unittest
{
    auto fake = new Fake;
    fake.virtual_[9] = true;
    auto picker = new RowPicker(new TableSelection(null, null), fake.ports);
    picker.click(5);
    assert(picker.ranges == [RowRange(5, 5)] && fake.calls == ["show", "told", "invalidate"]);
    fake.calls = null;
    picker.click(5);
    assert(picker.ranges == [RowRange(5, 5)] && fake.calls == ["show", "invalidate"], "a click on the picked row: it stays, not told again");
    fake.calls = null;
    picker.click(9);
    assert(fake.calls.length == 0 && picker.ranges == [RowRange(5, 5)]);
}

@("RowPicker: Escape lets go of the text first, then of the rows")
unittest
{
    import ptable.selection : Position, Selection;

    auto fake = new Fake;
    auto picker = new RowPicker(new TableSelection(null, null), fake.ports);
    assert(!picker.escape(), "nothing picked");
    picker.select(4);
    picker.text.setText(true, Selection(Position(1, 0, 0), Position(1, 0, 3)));
    assert(picker.escape() && !picker.text.hasText && picker.selected == 4, "the text first");
    assert(picker.escape() && picker.selected == -1, "then the rows");
    assert(!picker.escape());
}

@("RowPicker: select all picks every item without showing one, and tells the host only when the current row changed")
unittest
{
    auto fake = new Fake;
    auto picker = new RowPicker(new TableSelection(null, null), fake.ports);
    picker.selectAll(0);
    assert(picker.count == 0 && fake.calls.length == 0);
    picker.selectAll(20);
    assert(picker.count == 20 && fake.calls == ["told, delayed", "invalidate"], "not shown");
    fake.calls = null;
    picker.selectAll(20);
    assert(fake.calls.length == 0);
}

@("RowPicker: a context pick keeps the rows picked if it is on one, else picks the row alone; a separator is not picked")
unittest
{
    auto fake = new Fake;
    fake.virtual_[9] = true;
    auto picker = new RowPicker(new TableSelection(null, null), fake.ports);
    picker.select(2);
    picker.selectRow(5, Pick.extend);
    fake.calls = null;
    picker.pickForContext(3);
    assert(picker.ranges == [RowRange(2, 5)], "on a row picked: all stay");
    picker.pickForContext(8);
    assert(picker.ranges == [RowRange(8, 8)] && fake.calls[$ - 2 .. $] == ["told", "invalidate"]);
    fake.calls = null;
    picker.pickForContext(9);
    assert(picker.ranges == [RowRange(8, 8)] && fake.calls.length == 0);
}
