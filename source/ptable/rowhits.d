//! What a point of the table hits in the rows on the screen: the text position under it, the position a drag
//! reaches wherever the mouse is, the word or the cell under it. It only reads the store, the viewport and the row
//! view; the table lays the rows out before it asks and keeps the selection itself. See docs/stories/painted-table.md.
module ptable.rowhits;

version (unittest) import ptable.testing : portsOf;
import ptable.painter : RowContext;
import ptable.rowcache : Entry;
import ptable.rowlayout : RowSlot;
import ptable.rowranges : RowRanges;
import ptable.rowstore : RowStore;
import ptable.rowview : RowView;
import ptable.model : ItemKind;
import ptable.column : Unit;
import ptable.ports : Rect;
import ptable.selection : Position, Selection;
import ptable.viewport : RowViewport;

final class RowHits
{
    private RowStore _store;
    private RowViewport _viewport;
    private RowView _rows;

    this(RowStore store, RowViewport viewport, RowView rows)
    {
        _store = store;
        _viewport = viewport;
        _rows = rows;
    }

    // The row under the point's y: its slot, its entry and its context. False with no rows on the screen or for a
    // row that is not a real one. The store is current before the regions are read.
    private struct RowUnder
    {
        RowSlot slot;
        Entry* entry;
        RowContext row;
    }

    private bool rowUnder(double y, ref const RowRanges selected, out RowUnder under)
    {
        _store.ensure();
        if (_viewport.slots.length == 0)
            return false;
        const by = y - _store.space.regions.rows.y;
        const slot = _viewport.slots[_viewport.slotAt(by)];
        auto e = _store.entry(slot.index);
        if (!e.valid || e.data.kind == ItemKind.virtual_ || by < slot.top + e.margin)
            return false; // the margin above a group's first row is no part of it
        under = RowUnder(slot, e, _rows.rowContextAt(e, slot.index, slot, selected));
        return true;
    }

    /// The text position under the point (x, y) of the table; false with no rows, in a margin or where no cell has text.
    /// `selected` are the rows picked: the painter may place a selected row's text differently.
    bool positionAt(double x, double y, ref const RowRanges selected, out Position at)
    {
        RowUnder under;
        if (!rowUnder(y, selected, under))
            return false;
        return hit(under, x, y, at);
    }

    /// The row at the height `y` of the table, for picking rows: the one under the point, the first in sight above the rows, the
    /// last in sight below them (a margin belongs to the row under it); false with no rows on the screen
    bool rowAt(double y, out size_t row)
    {
        _store.ensure();
        if (_viewport.slots.length == 0)
            return false;
        const by = y - _store.space.regions.rows.y;
        const slots = _viewport.slots;
        if (by < 0)
        {
            row = slots[0].index;
            return true;
        }
        if (by >= _store.space.regions.rows.h)
        {
            size_t last = 0;
            foreach (i, ref slot; slots)
                if (slot.top < _store.space.regions.rows.h)
                    last = i;
            row = slots[last].index;
            return true;
        }
        row = slots[_viewport.slotAt(by)].index;
        return true;
    }

    /// The real row under the height `y` of the table, strictly: none above or below the rows, in a margin or over a separator
    bool realRowAt(double y, out size_t row)
    {
        _store.ensure();
        const by = y - _store.space.regions.rows.y;
        if (_viewport.slots.length == 0 || by < 0 || by >= _store.space.regions.rows.h)
            return false;
        foreach (ref slot; _viewport.slots)
        {
            if (by < slot.top || by >= slot.top + slot.height)
                continue;
            auto e = _store.entry(slot.index);
            if (!e.valid || e.data.kind == ItemKind.virtual_ || by < slot.top + e.margin)
                return false;
            row = slot.index;
            return true;
        }
        return false;
    }

    /// The word the point is on (not the room right of the text, not a margin): the caret nearest to the point in the text of the cell
    /// and the word at it, as its column takes a double click there; false if the point is off the word
    bool textAt(double x, double y, ref const RowRanges selected, out long offset, out wstring word)
    {
        RowUnder under;
        Position at;
        if (!rowUnder(y, selected, under) || !hit(under, x, y, at))
            return false;
        auto cells = _rows.focused(under.entry, under.row, _store.columns.selectable(_store.places()));
        auto info = cells.cell(at.col);
        const text = info.text;
        const range = info.column.expand(info.input, at.at, Unit.word);
        const from = range[0] < text.length ? range[0] : text.length, to = range[1] < text.length ? range[1] : text.length;
        if (to <= from)
            return false;
        bool on;
        info.column.rects(info.input, info.area, from, to, (Rect r) { on = on || (x >= r.x && x < r.right && y >= r.y && y < r.bottom); });
        if (!on)
            return false;
        offset = cast(long) at.at;
        word = text[from .. to].idup;
        return true;
    }

    private bool hit(ref RowUnder under, double x, double y, out Position at)
    {
        auto cells = _rows.focused(under.entry, under.row, _store.columns.selectable(_store.places()));
        if (cells.length == 0)
            return false;
        return _rows.hit(cells, under.slot.index, x, y, at);
    }

    /// Where a drag reaches, wherever the mouse is (it is captured): the text under it; above the rows the start of the
    /// first row in sight, below them the end of the last; over the margin of a group the end of the row above it when
    /// the press (at the row `pressRow`) was above, else the start of the row under it
    bool dragPositionAt(double x, double y, size_t pressRow, ref const RowRanges selected, out Position at)
    {
        _store.ensure();
        if (_viewport.slots.length == 0)
            return false;
        const columns = _store.columns.selectable(_store.places()).length;
        if (columns == 0)
            return false;
        const by = y - _store.space.regions.rows.y;
        const slots = _viewport.slots;
        if (by < 0) // above the rows (over the header, out of the window): the start of the first row in sight
        {
            at = Position(slots[0].index, 0, Position.begin);
            return true;
        }
        if (by >= _store.space.regions.rows.h) // below them: the end of the last row in sight
        {
            size_t last = 0;
            foreach (i, ref slot; slots)
                if (slot.top < _store.space.regions.rows.h)
                    last = i;
            at = Position(slots[last].index, columns - 1, Position.end);
            return true;
        }
        const slot = slots[_viewport.slotAt(by)];
        auto e = _store.entry(slot.index);
        if (e.valid && by >= slot.top && by < slot.top + e.margin)
        {
            at = pressRow < slot.index ? Position(slot.index - 1, columns - 1, Position.end) : Position(slot.index, 0, Position.begin);
            return true;
        }
        return positionAt(x, y, selected, at);
    }

    /// The word (`word`) or the whole cell under the point, as a double and a triple click take it. False: no text is
    /// there. `any` false: the part is empty (nothing to select), `part` is not set.
    bool partAt(double x, double y, bool word, ref const RowRanges selected, out Selection part, out bool any)
    {
        RowUnder under;
        Position at;
        any = false;
        if (!rowUnder(y, selected, under) || !hit(under, x, y, at))
            return false;
        auto cells = _rows.focused(under.entry, under.row, _store.columns.selectable(_store.places()));
        auto info = cells.cell(at.col);
        const range = info.column.expand(info.input, at.at, word ? Unit.word : Unit.cell);
        const length = info.text.length;
        if ((range[1] < length ? range[1] : length) <= (range[0] < length ? range[0] : length))
            return true;
        any = true;
        part = Selection(Position(at.row, at.col, range[0]), Position(at.row, at.col, range[1]));
        return true;
    }
}

version (unittest)
{
    private immutable RowRanges none;
    import ptable.layout : ColumnLayout;
    import ptable.model : TableModel;
    import ptable.painter : Painter, TableGeometry;
    import ptable.rowview : RowEnv;
    import ptable.tableports : TablePorts;
    import ptable.testing : DatedModel;

    // A painter with a margin of 20 over the first row of a day
    private final class Grouping : Painter
    {
        override TableGeometry geometry() { TableGeometry g; g.groupHeight = 20; return g; }
    }

    private struct Rig
    {
        RowStore store;
        RowViewport viewport;
        RowHits hits;
    }

    // 400 x 200: the header 21, the rows from y 21; laid out as `Table.layout` does
    private Rig rigOf(TableModel model, Painter painter)
    {
        Rig rig;
        rig.store = new RowStore(model, new ColumnLayout, portsOf(painter));
        bool widthChanged;
        rig.store.resize(400, 200, widthChanged);
        rig.viewport = new RowViewport(&rig.store.heightOf);
        auto rows = new RowView(RowEnv(rig.store.columns, rig.store.space));
        rig.hits = new RowHits(rig.store, rig.viewport, rows);
        rig.store.ensure();
        rig.viewport.height(rig.store.space.regions.rows.h);
        rig.viewport.count(rig.store.itemCount);
        rig.viewport.restorePlace();
        rig.store.fitRestart();
        rig.viewport.layout();
        while (rig.store.fitToWindow(rig.viewport.slots))
            rig.viewport.layout();
        return rig;
    }
}

@("RowHits: the point finds the row under it and the caret in its text; a point below the rows finds none")
unittest
{
    auto rig = rigOf(new DatedModel(100, 1000), new Painter);
    Position at;
    // the rows are 16 high from y 21; the time column is the first and begins at x 0, a glyph is 10 wide
    assert(rig.hits.positionAt(12, 21 + 16 + 3, none, at));
    assert(at.row == 1 && at.col == 0, "the second row, the first column");
    const first = at.at;
    assert(rig.hits.positionAt(22, 21 + 16 + 3, none, at) && at.at > first && at.at <= 2, "a glyph to the right");
    assert(rig.hits.positionAt(32, 21 + 16 + 3, none, at) && at.col == 0 && at.at == 2, "right of the text of the cell (\"t1\"): its end");
    assert(!rig.hits.positionAt(12, 5, none, at), "over the header: the row under y is the first, but the header is no row");
}

@("RowHits: realRowAt finds a row only where one is: not over the header, a margin or below the rows")
unittest
{
    auto rig = rigOf(new DatedModel(100, 3), new Grouping);
    size_t row;
    assert(rig.hits.realRowAt(30, row) && row == 0);
    assert(rig.hits.realRowAt(21 + 16 + 3, row) && row == 1);
    assert(!rig.hits.realRowAt(5, row), "the header");
    assert(!rig.hits.realRowAt(75, row), "the margin over a day's first row");
    assert(rig.hits.realRowAt(95, row) && row == 3);
    assert(!rig.hits.realRowAt(5000, row), "below the rows");
    assert(!rigOf(new DatedModel(0, 3), new Painter).hits.realRowAt(30, row), "no rows");
}

@("RowHits: textAt finds the character the point is on and its word, not the room right of the text")
unittest
{
    auto rig = rigOf(new DatedModel(100, 1000), new Painter);
    long offset;
    wstring word;
    const y = 21 + 16 + 3;
    assert(rig.hits.textAt(12, y, none, offset, word) && offset >= 0 && word.length > 0);
    assert(!rig.hits.textAt(32, y, none, offset, word), "right of the text of the cell");
    assert(!rig.hits.textAt(12, 5, none, offset, word), "the header");
}

@("RowHits: an empty table hits nothing, and a drag has nowhere to reach")
unittest
{
    auto rig = rigOf(new DatedModel(0, 3), new Painter);
    Position at;
    assert(!rig.hits.positionAt(10, 30, none, at));
    assert(!rig.hits.dragPositionAt(10, 30, 0, none, at));
    Selection part;
    bool any;
    assert(!rig.hits.partAt(10, 30, true, none, part, any) && !any);
}

@("RowHits: the margin over the first row of a day is no part of the row; a drag over it reaches the row above or below")
unittest
{
    auto rig = rigOf(new DatedModel(100, 3), new Grouping);
    // header 21; row 0 16 (no margin: its head is in the header), rows 1, 2 to 69; row 3: a margin 69..89, the row 89..105
    Position at;
    assert(rig.hits.positionAt(5, 30, none, at) && at.row == 0);
    assert(!rig.hits.positionAt(5, 75, none, at), "the margin");
    assert(rig.hits.positionAt(5, 95, none, at) && at.row == 3);
    assert(rig.hits.dragPositionAt(5, 75, 0, none, at));
    assert(at.row == 2 && at.at == Position.end, "the press was above: the end of the row above the margin");
    assert(rig.hits.dragPositionAt(5, 75, 5, none, at));
    assert(at.row == 3 && at.col == 0 && at.at == Position.begin, "the press was below: the start of the row under it");
}

@("RowHits: a drag above the rows reaches the start of the first in sight, below them the end of the last")
unittest
{
    auto rig = rigOf(new DatedModel(100, 1000), new Painter);
    Position at;
    assert(rig.hits.dragPositionAt(200, -50, 3, none, at));
    assert(at.row == 0 && at.col == 0 && at.at == Position.begin);
    assert(rig.hits.dragPositionAt(200, 900, 3, none, at));
    assert(at.row == rig.viewport.slots[$ - 1].index && at.col == 1 && at.at == Position.end, "the last column, its end");
}

@("RowHits: a double click takes what the column says, a triple one the cell, none over the header")
unittest
{
    auto rig = rigOf(new DatedModel(100, 1000), new Painter);
    Selection part;
    bool any;
    const y = 21 + 3; // row 0: the time cell reads "d0 t0": the head is the day, the rest "t0"
    assert(rig.hits.partAt(2, y, false, none, part, any) && any);
    assert(part.anchor.row == 0 && part.anchor.col == 0 && part.anchor.at == Position.begin && part.focus.at == Position.end, "the cell");
    assert(rig.hits.partAt(2, y, true, none, part, any) && any);
    assert(part.anchor.at == Position.begin && part.focus.at == Position.end, "a box has no words: all of it");
    assert(!rig.hits.partAt(10, 5, true, none, part, any) && !any, "over the header: no row");
}
