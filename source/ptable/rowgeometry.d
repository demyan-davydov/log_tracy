//! How much room the rows take, kept for the rows near the window: the height, the lines of the flex cell, the margin a
//! group's first row has above it. Small (no text), in a ring whose size follows the window (the rows in sight and a reserve
//! above and below them, no fixed limit). A row not in it is measured: read, its row above
//! read for the heads of the groups; then the texts are let go. Not thread safe. See docs/stories/painted-table.md.
module ptable.rowgeometry;

import ptable.memory : Arena;
import ptable.model : ItemKind;
import ptable.rowgroups : RowGroups;
import ptable.rowreader : RowReader;
import ptable.rowspec : RowSpec;

import std.algorithm.comparison : max;
import std.experimental.allocator : RCIAllocator;

/// The room of one row
struct RowGeom
{
    size_t tag = size_t.max; /// the item it is of; size_t.max: nothing
    bool valid; /// the model had the item
    ItemKind kind;
    double height = 0; /// with the margin
    double margin = 0; /// above the row, part of `height`
    ulong changed; /// which heads differ from the row's above (`RowGroups.changes`)
    bool stale; /// measured at another width of the flex column: an estimate (`RowGeometry.estimate`), measured again when asked
}

final class RowGeometry
{
    private RowReader _reader;
    private const(RowSpec)* _spec;
    private RowGeom[] _ring; // [item & (length - 1)]: the length is a power of two
    private Arena _probe, _above; // where a row and the row above it are read to be measured

    /// The least height of a row (an empty one, as the wanted columns make it): no row is lower, whatever a column measures, so a
    /// scroll bar may count on it (`ptable.scrollscale`). Null: no least
    double delegate() floor;

    private enum size_t minCapacity = 64; // the least the ring has: rows

    this(RowReader reader, const(RowSpec)* spec, RCIAllocator source)
    {
        _reader = reader;
        _spec = spec;
        _probe = Arena(source);
        _above = Arena(source);
    }

    /// The window shows `rowsInSight` rows: the ring is four times that (the window and a reserve of a window above and a
    /// window below), at least `minCapacity`, a power of two. It grows at once, and shrinks only when four times less would
    /// do: a window of a size at the edge of a power of two (one row more or less with the scroll) does not make it anew
    /// every frame. A ring made anew keeps the rows known (a list growing row by row is not measured again at each size).
    void fit(size_t rowsInSight)
    {
        size_t capacity = 1;
        const wanted = max(minCapacity, 4 * rowsInSight);
        while (capacity < wanted)
            capacity *= 2;
        if (capacity == _ring.length || (capacity < _ring.length && capacity * 4 > _ring.length))
            return;
        auto ring = new RowGeom[capacity];
        foreach (ref geom; _ring)
            if (geom.tag != size_t.max)
                ring[geom.tag & (capacity - 1)] = geom; // of two rows at one place in a smaller ring, one stays
        _ring = ring;
    }

    /// The places of the ring (a power of two; 0 before the first `fit`): `CellMemos` keeps the same
    size_t capacity() const
    {
        return _ring.length;
    }

    /// The room of the item `index`, measured if it is not known
    RowGeom of(size_t index)
    {
        if (_ring.length == 0)
            fit(0);
        auto at = index & (_ring.length - 1);
        if (_ring[at].tag == index && !_ring[at].stale)
            return _ring[at];
        const geom = measure(index);
        _ring[at] = geom;
        return geom;
    }

    /// The room of the item `index` as known, though measured at another width (`markStale`): what a sum over many rows
    /// can do with; measured if it is not known at all
    RowGeom estimate(size_t index)
    {
        if (_ring.length > 0)
        {
            const at = index & (_ring.length - 1);
            if (_ring[at].tag == index)
                return _ring[at];
        }
        return of(index);
    }

    /// The rows known were measured at another width: they are estimates now, measured again when their room is asked
    /// (`of`), not when their estimate is
    void markStale()
    {
        foreach (ref geom; _ring)
            if (geom.tag != size_t.max)
                geom.stale = true;
    }

    /// Forgets every row
    void clear()
    {
        foreach (ref geom; _ring)
            geom.tag = size_t.max;
    }

    /// Forgets the rows from `first` to `last` (not including) and the one under them, whose margin depends on the row above
    void removeRange(size_t first, size_t last)
    {
        if (last != size_t.max)
            ++last;
        foreach (ref geom; _ring)
            if (geom.tag != size_t.max && geom.tag >= first && geom.tag < last)
                geom.tag = size_t.max;
    }

    /// Gives the memory back
    void release()
    {
        _probe.release();
        _above.release();
        _ring = null;
    }

    // Reads the row, finds its margin: nothing of the row is kept
    private RowGeom measure(size_t index)
    {
        _probe.reset();
        auto e = _reader.read(_probe, index);
        RowGeom geom;
        geom.tag = index;
        geom.valid = e.valid;
        geom.kind = e.data.kind;
        geom.height = floor !is null ? max(e.height, floor()) : e.height;
        if (!e.valid)
            return geom;
        if (_spec.groups.grouping(_spec.geometry.groupHeight) && index > 0)
        {
            _above.reset();
            const above = _reader.read(_above, index - 1);
            geom.changed = RowGroups.changes(index, e.heads, above.heads);
            if (geom.changed != 0)
            {
                geom.margin = _spec.geometry.groupPadTop + _spec.geometry.groupHeight + _spec.geometry.groupPadBottom;
                geom.height += geom.margin;
            }
        }
        return geom;
    }
}

version (unittest)
{
    import ptable.painter : Painter, TableGeometry;
    import ptable.rowcache : RowCache;
    import ptable.testing : DatedModel;
}

@("RowGeometry: a row is measured once, then its room is known without the model; the ring follows the window")
unittest
{
    auto model = new DatedModel(1000, 10);
    auto cache = new RowCache(model);
    TableGeometry geometry;
    cache.configure(model.columns(), 1, geometry);
    cache.setFlexWidth(200);
    cache.fit(10);
    assert(cache.heightOf(5) == 16 && model.reads.get(5, 0) == 1);
    assert(cache.heightOf(5) == 16 && model.reads.get(5, 0) == 1, "known: the model is not asked");
    cache.fit(10);
    assert(cache.heightOf(5) == 16 && model.reads.get(5, 0) == 1, "the same window: the ring stays");
    cache.fit(100);
    assert(cache.heightOf(5) == 16 && model.reads.get(5, 0) == 1, "another size of the window: the rows known move into the new ring");
}

@("RowGeometry: the ring has no fixed limit: four windows of rows, at least the least; a far row takes the place of its neighbor")
unittest
{
    auto model = new DatedModel(100_000, 10);
    auto cache = new RowCache(model);
    TableGeometry geometry;
    cache.configure(model.columns(), 1, geometry);
    cache.setFlexWidth(200);
    cache.fit(10);
    cache.heightOf(0);
    cache.heightOf(64); // the least ring is 64: it lands where row 0 stood
    cache.heightOf(0);
    assert(model.reads.get(0, 0) == 2, "pushed out by a row 64 away, read again");
    cache.fit(100); // 4 x 100 -> 512
    foreach (i; 0 .. 300)
        cache.heightOf(i);
    foreach (i; 0 .. 300)
        cache.heightOf(i);
    assert(model.reads.get(150, 0) == 1, "300 rows are in a ring of 512: the second round reads nothing");
}

@("RowGeometry: a row measured sets no width of a column")
unittest
{
    auto model = new DatedModel(100, 10);
    auto cache = new RowCache(model);
    TableGeometry geometry;
    cache.configure(model.columns(), 1, geometry);
    cache.setFlexWidth(200);
    cache.heightOf(5);
    cache.entry(5);
    assert(cache.growths == 0, "the rows that are read set no width: the window does (RowStore.measure, ColumnHost.settle)");
}

@("RowGeometry: the ring grows at once and shrinks only when four times less would do, so a window at the edge of a size does not make it anew")
unittest
{
    auto model = new DatedModel(1000, 10);
    auto cache = new RowCache(model);
    TableGeometry geometry;
    cache.configure(model.columns(), 1, geometry);
    cache.setFlexWidth(200);
    cache.fit(16); // 64
    cache.fit(17); // 68 -> 128: another size, grown at once
    cache.heightOf(5);
    foreach (i; 0 .. 20)
    {
        cache.fit(16 + i % 2); // the window at the edge: 16, 17, 16, 17 ...
        cache.heightOf(5);
    }
    assert(model.reads.get(5, 0) == 1, "the ring was not made anew once: the room of the row is known");
    cache.fit(2); // 64: four times less than 128 is 32: 64 is more, it stays
    cache.heightOf(5);
    assert(model.reads.get(5, 0) == 1);
    cache.fit(1000); // grows at once
    cache.heightOf(5);
    assert(model.reads.get(5, 0) == 1, "a ring made anew keeps the rows known");
}

@("RowGeometry: no row is lower than an empty one, though a column measures a filled cell lower: the scroll bar counts on it")
unittest
{
    import ptable.column : CellInput, Measured, TableColumn;
    import ptable.layout : ColumnDef;

    // empty: 40 high; filled: 5
    static final class Shrinking : TableColumn
    {
        this()
        {
            super(ColumnDef("time", "Time"));
        }

        override Measured measure(ref const CellInput cell, double width, bool widths)
        {
            return Measured(10, 10, cell.data is null ? 40 : 5);
        }
    }

    auto model = new DatedModel(100, 10);
    model.columns()[0] = new Shrinking;
    auto cache = new RowCache(model);
    TableGeometry geometry;
    cache.configure(model.columns(), 1, geometry);
    cache.setFlexWidth(200);
    assert(cache.fallbackHeight == 40);
    assert(cache.heightOf(5) == 40, "as high as an empty row, not 16");
}

@("RowGeometry: a new width of the flex column keeps the heights known as estimates: a row is measured again when its height is asked, not its estimate")
unittest
{
    auto model = new DatedModel(100, 10);
    auto cache = new RowCache(model);
    TableGeometry geometry;
    cache.configure(model.columns(), 1, geometry);
    cache.setFlexWidth(200);
    const wide = cache.heightOf(5);
    import ptable.testing : BoxColumn;

    cache.setFlexWidth(20);
    (cast(BoxColumn) model.columns()[1]).line = 30; // the text wraps to more lines at that width
    assert(cache.estimateOf(5) == wide && model.reads.get(5, 0) == 1, "the estimate is the height it had: nothing read");
    const narrow = cache.heightOf(5);
    assert(narrow > wide && model.reads.get(5, 0) == 2, "its height is measured again");
    assert(cache.estimateOf(5) == narrow, "measured: the estimate is the height");
    assert(cache.estimateOf(7) > wide && model.reads.get(7, 0) == 1, "a row not known is measured for its estimate");
}
