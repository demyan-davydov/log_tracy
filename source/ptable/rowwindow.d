//! The rows of the pass of the table: what a frame, the hits and the keys between two frames read of the rows near the window,
//! each read once from the model and kept until the next pass begins (`beginPass`, at the start of a frame). Nothing lives
//! longer: a row out of the window is read again when it comes back. The room a row takes is `RowGeometry`'s.
//! The `Entry*` it gives are valid until the next `beginPass`, `clear` or `removeRange`. Not thread safe.
//! See docs/stories/painted-table.md.
module ptable.rowwindow;

import ptable.memory;
import ptable.rowentry : Entry;
import ptable.rowgeometry : RowGeometry;
import ptable.rowreader : RowReader;

import std.experimental.allocator : RCIAllocator;

final class RowWindow
{
    private Arena _arena;
    private HashMap!(size_t, Entry*) _rows;
    private RowReader _reader;
    private RowGeometry _geometry;

    this(RowReader reader, RowGeometry geometry, RCIAllocator source)
    {
        _reader = reader;
        _geometry = geometry;
        _arena = Arena(source);
        _rows = HashMap!(size_t, Entry*)(source);
    }

    /// A new pass: the rows of the last one are let go (their memory is reused)
    void beginPass()
    {
        _rows.clear();
        _arena.reset();
    }

    /// The item `index` as it lays out, read now if the pass has not read it yet
    Entry* entry(size_t index)
    {
        if (auto found = index in _rows)
            return *found;
        const geom = _geometry.of(index);
        auto e = _reader.read(_arena, index);
        e.height = geom.height;
        e.margin = geom.margin;
        e.changed = geom.changed;
        _rows.set(index, e);
        return e;
    }

    /// How many rows the pass has read
    size_t count() const
    {
        return _rows.length;
    }

    /// Lets go of every row
    void clear()
    {
        beginPass();
    }

    /// Gives all the memory back to the source
    void release()
    {
        _rows.clear();
        _arena.release();
        _rows.free();
    }
}

@("RowWindow: a row is read once for the pass, the pass lets go of it, the room of the row is the geometry's")
unittest
{
    import ptable.painter : Painter, TableGeometry;
    import ptable.rowcache : RowCache;
    import ptable.testing : DatedModel;

    auto model = new DatedModel(100, 10);
    auto cache = new RowCache(model);
    TableGeometry geometry;
    geometry.groupHeight = 20;
    cache.configure(model.columns(), 1, geometry);
    cache.setFlexWidth(200);
    auto first = cache.entry(10);
    const reads = model.reads.get(10, 0);
    assert(cache.entry(10) is first && model.reads.get(10, 0) == reads, "the second ask of a pass: the same row, no read");
    assert(first.margin == 20 && first.height == cache.heightOf(10), "the room is the geometry's");
    cache.beginPass();
    assert(cache.count == 0);
    cache.entry(10);
    assert(model.reads.get(10, 0) == reads + 1 && cache.count == 1, "a new pass reads the row again, nothing else");
}
