//! The rows of a table: what the model gave for an item as the table lays it out (`Entry`), for the pass of a frame
//! (`RowWindow`), the room the rows near the window take (`RowGeometry`) and what the columns noted of their cells (`CellMemos`,
//! let go with the room), brought together over the units that read,
//! wrap and measure them. Nothing of a row's content lives from one frame to the next: the model is asked again. The
//! facade the table's store talks to. Not thread safe. See docs/stories/painted-table.md.
module ptable.rowcache;

version (unittest) import ptable.testing : withBoxes;
import ptable.cellmemo : CellMemo, CellMemos;
import ptable.column : TableColumn;
import ptable.layout : ColumnDef;
import ptable.memory : mallocAllocator;
import ptable.model : TableModel;
import ptable.painter : Painter, TableGeometry;
import ptable.rowgeometry : RowGeometry;
import ptable.rowgrow : RowGrow;
import ptable.rowgroups : RowGroups;
import ptable.rowreader : RowReader;
import ptable.rowspec : RowSpec;
import ptable.rowwindow : RowWindow;
import ptable.rowwrap : RowWrap;
public import ptable.rowentry : Entry;
public import ptable.rowspec : maxFitWidth;

import std.experimental.allocator : RCIAllocator;

version (unittest)
{
    import ptable.model : Fragment;
    import ptable.rowlayout : rowHeight;

    import std.algorithm.comparison : max;
}

final class RowCache
{
    private RowSpec _spec;
    private RowWrap _wrap;
    private RowGrow _grow;
    private RowReader _reader;
    private RowGeometry _geometry;
    private RowWindow _window;
    private CellMemos _memos;
    private double _fallback; // the height of an empty row, made at the first ask after the columns or the wanted ones changed

    this(TableModel model, RCIAllocator source = mallocAllocator())
    {
        _wrap = new RowWrap(&_spec);
        _grow = new RowGrow(&_spec);
        _reader = new RowReader(model, &_spec, _wrap);
        _geometry = new RowGeometry(_reader, &_spec, source);
        _geometry.floor = &fallbackHeight;
        _window = new RowWindow(_reader, _geometry, source);
        _memos = new CellMemos(source);
    }

    /// The columns and the geometry: the rows are read again
    void configure(TableColumn[] columns, size_t flexDef, ref const TableGeometry geometry)
    {
        _spec.columns = columns;
        _spec.flexDef = flexDef;
        _spec.groups.configure(columns);
        _spec.geometry = geometry;
        _fallback = double.nan;
        clear();
    }

    /// The columns the model is to fill: the visible ones. The rows are read again.
    void setWanted(const(bool)[] wanted)
    {
        _spec.wanted.length = wanted.length;
        _spec.wanted[] = wanted[];
        _fallback = double.nan;
        clear();
    }

    /// Which columns the model is asked to fill
    const(bool)[] wanted() const
    {
        return _spec.wanted;
    }

    /// What a row not read yet is guessed to be high: an empty row as the wanted columns make it
    double fallbackHeight()
    {
        import std.math : isNaN;

        if (isNaN(_fallback))
            _fallback = _wrap.emptyHeight();
        return _fallback;
    }

    /// The width the flex column has: rows wrapped to another one are wrapped again
    void setFlexWidth(double width)
    {
        if (width == _spec.flexWidth)
            return;
        // a flex column that does not wrap grows to its longest text and no row is laid out by its width (only whether it
        // has any): what is known of the rows stays
        const keeps = _spec.flexDef < _spec.columns.length && !_spec.columns[_spec.flexDef].wraps() && (width > 0) == (_spec.flexWidth > 0);
        _spec.flexWidth = width;
        if (keeps)
            return;
        _geometry.markStale(); // the heights known are estimates now: a sum over all the rows does not measure them again
        _memos.clear(); // the lines of a wrapped cell are others
        _window.clear();
    }

    /// Gives all the memory back to the source (the rows are none after it and may be asked for again)
    void release()
    {
        _window.release();
        _geometry.release();
        _memos.release();
    }

    /// The width the flex column has now
    double flexWidthOf() const
    {
        return _spec.flexWidth;
    }

    /// How many rows the pass has read
    size_t count() const
    {
        return _window.count;
    }

    /// Items read from the model
    size_t fetches() const
    {
        return _reader.fetches;
    }

    /// What the row `e` needs of each column (`RowGrow.needs`)
    void needs(ref Entry e, double[] into)
    {
        _grow.needs(e, into);
    }

    /// The widths of the columns changed to what the rows need: the rows are laid out again
    void fitted()
    {
        _grow.fitted();
    }

    /// Counts the widths changed: a layout made before one is made again
    uint growths() const
    {
        return _grow.growths;
    }

    /// Lets go of every row and the room they took
    void clear()
    {
        _geometry.clear();
        _memos.clear();
        _window.clear();
    }

    /// Lets go of the items from `first` on
    void removeFrom(size_t first)
    {
        removeRange(first, size_t.max);
    }

    /// Lets go of the items from `first` to `last` (not including) and the one under them, whose margin depends on the row above
    void removeRange(size_t first, size_t last)
    {
        _geometry.removeRange(first, last);
        _memos.removeRange(first, last);
        _window.clear();
    }

    /// A frame begins: what the last pass read is let go
    void beginPass()
    {
        _window.beginPass();
    }

    /// The window shows `rowsInSight` rows: the room of the rows near it is kept for that many and a reserve around them
    void fit(size_t rowsInSight)
    {
        _geometry.fit(rowsInSight);
        _memos.fit(_geometry.capacity);
    }

    /// What the columns noted of the cells of the rows near the window, let go with their room
    CellMemos memos()
    {
        return _memos;
    }

    /// The memo of the cell of the row `index` in the column `col` (`CellMemos.of`): null if none can be kept
    CellMemo* memoOf(size_t index, uint col)
    {
        return _memos.of(index, col);
    }

    /// The item `index` as it lays out; valid until the next pass begins
    Entry* entry(size_t index)
    {
        return _window.entry(index);
    }

    /// The height of the item `index`, as it is known without its content: from the room the rows near the window take
    /// The height of the row `index` as known, though measured at another width of the flex column (`RowGeometry.estimate`)
    double estimateOf(size_t index)
    {
        return _geometry.estimate(index).height;
    }

    double heightOf(size_t index)
    {
        return _geometry.of(index).height;
    }

    /// The heads of the item `index` (`Entry.heads`)
    const(const(wchar)[])[] headsOf(size_t index)
    {
        return entry(index).heads;
    }

    /// Which columns group the rows
    ref const(RowGroups) groups() const
    {
        return _spec.groups;
    }
}

@("RowCache: a cell with a head keeps its body as its text, the row keeps the head, a fragment moves with the body")
unittest
{
    import ptable.testing : DatedModel;

    auto model = new DatedModel(100, 10);
    model.marked = 23;
    auto cache = new RowCache(model);
    TableGeometry geometry;
    cache.configure(model.columns(), 1, geometry);
    auto e = cache.entry(23);
    assert(e.data.cells[0].text == "t23" && e.heads == ["d2"w], "the body shown, the head apart");
    assert(e.data.cells[1].text == "row 23", "a plain column keeps its text");
    assert(e.data.fragments[0] == [Fragment(1, 3)], "the fragment is where it was in the body");
    assert(cache.entry(5).heads == ["d0"w] && cache.entry(5).data.fragments.length == 0);
}

@("RowCache: the first row of a group has a margin above it in its height; the row above is read to measure it, once, and not kept")
unittest
{
    import ptable.testing : DatedModel;

    auto model = new DatedModel(100, 10);
    auto cache = new RowCache(model);
    TableGeometry geometry;
    geometry.groupHeight = 20;
    cache.configure(model.columns(), 1, geometry);
    const plain = rowHeight(1, 14, 1);
    auto first = cache.entry(10);
    assert(first.margin == 20 && first.height == plain + 20, "a new day: the margin is in the height");
    assert(cache.count == 1 && model.reads.get(9, 0) == 1, "the row above was read for its head, the pass has only the row");
    cache.beginPass();
    assert(cache.entry(10).margin == 20 && cache.heightOf(10) == plain + 20, "a pass later the room is known: it is not measured again");
    assert(model.reads.get(9, 0) == 1, "the row above is not read again");
    assert(cache.entry(11).margin == 0 && cache.entry(11).height == plain, "the same day: no margin");
    assert(cache.entry(0).margin == 0, "the first row of all has no margin: its head is in the header");

    TableGeometry none;
    cache.configure(model.columns(), 1, none);
    assert(cache.entry(10).margin == 0, "a painter with no room for heads: no margins");
}

@("RowCache: a row dropped is measured again and so is the row under it, whose margin depends on it")
unittest
{
    import ptable.testing : DatedModel;

    auto model = new DatedModel(100, 10);
    auto cache = new RowCache(model);
    TableGeometry geometry;
    geometry.groupHeight = 20;
    cache.configure(model.columns(), 1, geometry);
    foreach (i; 0 .. 20)
        cache.heightOf(i);
    const read = cache.fetches;
    foreach (i; 0 .. 20)
        cache.heightOf(i);
    assert(cache.fetches == read, "the room of the rows is known: nothing is read");
    cache.removeRange(5, 10);
    foreach (i; 0 .. 20)
        cache.heightOf(i);
    assert(cache.fetches == read + 6 * 2, "the five and the row under them are measured again, each by itself and the row above it");
}

@("RowCache: the margins are right when the rows come from below or above, and a head is read from the pass")
unittest
{
    import ptable.testing : DatedModel;

    auto model = new DatedModel(100, 3);
    auto cache = new RowCache(model);
    TableGeometry geometry;
    geometry.groupHeight = 20;
    cache.configure(model.columns(), 1, geometry);
    foreach_reverse (i; 1 .. 30)
        cache.heightOf(i);
    assert(cache.entry(27).margin == 20 && cache.entry(28).margin == 0 && cache.entry(3).margin == 20, "the margins are right");
    assert(cache.headsOf(2) == ["d0"w] && cache.headsOf(3) == ["d1"w], "a head of a row of the pass");
}

@("RowCache: the column that groups is as wide as its head in the header font too, so a head is never cut")
unittest
{
    import ptable.testing : DatedModel;

    auto model = new DatedModel(100, 3);
    model.dayPrefix = "a long day "; // the head "a long day 0" is wider than the body "t5"
    auto cache = new RowCache(model);
    TableGeometry geometry;
    geometry.groupHeight = 20;
    cache.configure(model.columns(), 1, geometry);
    auto needs = new double[model.columns().length];
    needs[] = 0;
    cache.needs(*cache.entry(5), needs);
    assert(needs[0] >= "a long day 1".length * 10 + 2 * 3, "the head's width: the first column is the time");
}

@("RowCache: a row keeps the head of every column that groups; it has a margin when any changed, and says which")
unittest
{
    import ptable.testing : TwoHeadsModel;

    auto model = new TwoHeadsModel(100);
    auto cache = new RowCache(model);
    TableGeometry geometry;
    geometry.groupHeight = 20;
    cache.configure(model.columns(), 2, geometry);
    auto both = cache.entry(15);
    assert(both.heads == ["D3"w, "S5"w] && both.changed == 0b11 && both.margin == 20, "the day and the shift");
    assert(both.data.cells[0].text == "d15" && both.data.cells[1].text == "s15", "both cells show their bodies");
    assert(cache.entry(10).changed == 0b01 && cache.entry(9).changed == 0b10, "the day alone, the shift alone");
    assert(cache.entry(11).changed == 0 && cache.entry(11).margin == 0, "neither");
    assert(cache.headsOf(14) == ["D2"w, "S4"w]);
    auto needs = new double[2];
    needs[] = 0;
    cache.needs(*both, needs);
    assert(needs[0] >= "D3".length * 10 && needs[1] >= "S5".length * 10, "each needs the width of its heads");
}

@("RowCache: the margin of a group is the room above its plate, the plate and the room under it")
unittest
{
    import ptable.testing : DatedModel;

    auto model = new DatedModel(100, 3);
    auto cache = new RowCache(model);
    TableGeometry geometry;
    geometry.groupHeight = 20;
    geometry.groupPadTop = 6;
    geometry.groupPadBottom = 1;
    cache.configure(model.columns(), 1, geometry);
    assert(cache.entry(3).margin == 27 && cache.entry(3).height == rowHeight(1, 14, 1) + 27);
}

@("RowCache: the memo of a cell stays from pass to pass, and goes with the room of its row: cleared, removed, a new width of the wrapping column")
unittest
{
    import ptable.cellmemo : PlaceMark;
    import ptable.testing : DatedModel;

    auto model = new DatedModel(1000, 10);
    auto cache = new RowCache(model);
    TableGeometry geometry;
    cache.configure(model.columns(), 1, geometry);
    cache.fit(30);
    assert(cache.memoOf(1, 1) !is null);

    void mark(size_t row)
    {
        auto memo = cache.memoOf(row, 1);
        memo.use(7);
        memo.put(PlaceMark(5, 50));
    }

    size_t marks(size_t row) { return cache.memoOf(row, 1).marks.length; }

    mark(3);
    cache.beginPass();
    assert(marks(3) == 1, "a pass later");
    cache.removeRange(3, 4);
    assert(marks(3) == 0, "the row was removed");
    mark(3);
    cache.clear();
    assert(marks(3) == 0, "every row let go");
    mark(3);
    cache.setFlexWidth(300);
    assert(marks(3) == 0, "the lines of the wrapping column are others");
    mark(3);
    cache.configure(model.columns(), 1, geometry);
    assert(marks(3) == 0, "the columns were set again");
    mark(3);
    cache.fit(300);
    assert(marks(3) == 1, "a bigger ring keeps them");
}
