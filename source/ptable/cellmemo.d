//! What a column notes of the geometry of a cell's text from one frame to the next: marks (a place in the text, its x), kept by the
//! table for the rows near the window (`CellMemos`, the same ring as `RowGeometry`) and let go with them, when the model, the columns
//! or the width of a wrapping column change. The table doesn't read the marks: a place and an x are numbers only the column
//! understands, as a `Position` is. A text column marks every so many runs of a long line (ptable_text/runs) so that a frame doesn't
//! sum the widths of all the runs before the part seen. Memory of the allocator given, not of the collector.
module ptable.cellmemo;

import ptable.memory : Buffer;
import std.experimental.allocator : RCIAllocator;

/// A place in the text of a cell and its x
struct PlaceMark
{
    size_t at;
    double x = 0;
}

/// The marks of a cell
struct CellMemo
{
    private Buffer!PlaceMark _marks;
    private ulong _key = ulong.max;

    this(RCIAllocator allocator) nothrow
    {
        _marks = Buffer!PlaceMark(allocator);
    }

    @disable this(this);

    /// The marks are of `key` from now on (what they were made for: a line, a font; the column's business): those of another go
    void use(ulong key) nothrow @nogc
    {
        if (key == _key)
            return;
        _marks.clear();
        _key = key;
    }

    const(PlaceMark)[] marks() const nothrow @nogc
    {
        return _marks[];
    }

    /// Appends a mark; false if there is no memory (the marks stay as they were)
    bool put(PlaceMark mark) nothrow
    {
        return _marks.put(mark);
    }
}

/// The memo of a cell as `CellInput` carries it: a cell is given as const, its memo is not part of what it is (a cache the column
/// fills while it draws), so it is reached through this. Null: no memo (a row the table keeps nothing of, a test).
struct MemoRef
{
    private CellMemo* _memo;

    this(CellMemo* memo) nothrow @nogc
    {
        _memo = memo;
    }

    CellMemo* get() const nothrow @nogc @trusted
    {
        return cast(CellMemo*) _memo; // logical const: the cell is not changed, the cache next to it is
    }
}

/// The memos of the cells of the rows near the window: a ring of the size of `RowGeometry`'s (a row at `row & (length - 1)`), a few
/// cells of a row each (`ways`: the long ones, a Payload). A row that takes the place of another lets the other's memos go; the table
/// lets them go with its rows too (`clear`, `removeRange`). Not thread safe.
final class CellMemos
{
    enum size_t ways = 4; /// cells of a row that keep a memo: more are given none, and their column walks from the start

    private static struct Slot
    {
        size_t tag = size_t.max; // the row; size_t.max: none
        uint[ways] cols = uint.max;
        CellMemo[ways] memos;
    }

    private Slot[] _slots;
    private RCIAllocator _alloc;

    this(RCIAllocator allocator)
    {
        _alloc = allocator;
    }

    /// The ring has `capacity` places (a power of two, `RowGeometry.capacity`); the memos of the rows that keep a place stay
    void fit(size_t capacity)
    {
        import core.lifetime : move;

        if (capacity == _slots.length)
            return;
        auto fresh = new Slot[capacity];
        foreach (ref slot; _slots)
        {
            if (slot.tag == size_t.max)
                continue;
            auto into = &fresh[slot.tag & (capacity - 1)];
            if (into.tag == size_t.max)
                move(slot, *into);
            else
                drop(slot); // of two rows at one place in a smaller ring, one stays
        }
        _slots = fresh;
    }

    /// The memo of the cell of `row` in the column `col`, made empty if there is none; null without a ring, or with `ways` cells of
    /// the row memoized already. Valid until the next `fit`.
    CellMemo* of(size_t row, uint col)
    {
        if (_slots.length == 0)
            return null;
        auto slot = &_slots[row & (_slots.length - 1)];
        if (slot.tag != row)
        {
            drop(*slot);
            slot.tag = row;
        }
        size_t free = ways;
        foreach (w; 0 .. ways)
        {
            if (slot.cols[w] == col)
                return &slot.memos[w];
            if (slot.cols[w] == uint.max && free == ways)
                free = w;
        }
        if (free == ways)
            return null;
        slot.cols[free] = col;
        slot.memos[free] = CellMemo(_alloc);
        return &slot.memos[free];
    }

    /// Lets go of every memo
    void clear()
    {
        foreach (ref slot; _slots)
            drop(slot);
    }

    /// Lets go of the memos of the rows from `first` to `last` (not including)
    void removeRange(size_t first, size_t last)
    {
        foreach (ref slot; _slots)
            if (slot.tag != size_t.max && slot.tag >= first && slot.tag < last)
                drop(slot);
    }

    /// How many cells have a memo
    size_t count() const
    {
        size_t n;
        foreach (ref slot; _slots)
            foreach (col; slot.cols)
                n += col != uint.max;
        return n;
    }

    /// Gives all the memory back (the ring is none after it)
    void release()
    {
        clear();
        _slots = null;
    }

    // The memos of the row in `slot` go, their marks given back
    private static void drop(ref Slot slot)
    {
        foreach (w; 0 .. ways)
            if (slot.cols[w] != uint.max)
            {
                slot.memos[w] = CellMemo.init;
                slot.cols[w] = uint.max;
            }
        slot.tag = size_t.max;
    }
}

version (unittest)
{
    import ptable.memory : mallocAllocator;

    private CellMemos ringOf(size_t capacity)
    {
        auto memos = new CellMemos(mallocAllocator());
        memos.fit(capacity);
        return memos;
    }

    private void mark(CellMemo* memo, size_t at)
    {
        memo.use(1);
        memo.put(PlaceMark(at, at * 10.0));
    }
}

@("CellMemos: a cell has the same memo from frame to frame, another column of the row another")
unittest
{
    auto memos = ringOf(64);
    auto a = memos.of(5, 2);
    assert(a !is null);
    mark(a, 7);
    assert(memos.of(5, 2) is a && memos.of(5, 2).marks.length == 1);
    assert(memos.of(5, 3) !is a && memos.of(5, 3).marks.length == 0);
    assert(memos.count == 2);
}

@("CellMemos: a row that takes the place of another in the ring lets the other's memos go")
unittest
{
    auto memos = ringOf(64);
    mark(memos.of(5, 2), 7);
    memos.of(5 + 64, 2);
    assert(memos.of(5, 2).marks.length == 0, "the memo of a row that went");
}

@("CellMemos: clear and removeRange let the memos go, the others stay")
unittest
{
    auto memos = ringOf(64);
    foreach (row; 5 .. 8)
        mark(memos.of(row, 2), row);
    memos.removeRange(6, 7);
    assert(memos.of(5, 2).marks.length == 1 && memos.of(7, 2).marks.length == 1);
    assert(memos.of(6, 2).marks.length == 0);
    memos.clear();
    assert(memos.of(5, 2).marks.length == 0 && memos.of(7, 2).marks.length == 0);
}

@("CellMemos: a ring of another size keeps the memos of the rows that find a place in it")
unittest
{
    auto memos = ringOf(64);
    mark(memos.of(5, 2), 5);
    mark(memos.of(100, 2), 100); // 100 & 63 = 36
    memos.fit(128);
    assert(memos.of(5, 2).marks == [PlaceMark(5, 50)] && memos.of(100, 2).marks == [PlaceMark(100, 1000)]);
    memos.fit(64);
    assert(memos.of(5, 2).marks.length == 1);
}

@("CellMemos: no memo without a ring, nor for more cells of a row than `ways`")
unittest
{
    auto none = new CellMemos(mallocAllocator());
    assert(none.of(1, 1) is null);
    auto memos = ringOf(64);
    foreach (uint col; 0 .. CellMemos.ways)
        assert(memos.of(3, col) !is null);
    assert(memos.of(3, CellMemos.ways) is null);
}

@("CellMemos: the memory of the marks is given back when their memos go")
unittest
{
    import std.experimental.allocator : allocatorObject;
    import std.experimental.allocator.building_blocks.stats_collector : Options, StatsCollector;
    import std.experimental.allocator.mallocator : Mallocator;

    StatsCollector!(Mallocator, Options.bytesUsed) stats;
    auto memos = new CellMemos(allocatorObject(&stats));
    const base = stats.bytesUsed; // the object of the allocator is in it
    memos.fit(64);
    foreach (row; 0 .. 10)
        foreach (i; 0 .. 100)
            mark(memos.of(row, 1), i);
    assert(stats.bytesUsed > base);
    memos.of(64, 1); // row 0 goes
    memos.removeRange(1, 3);
    memos.fit(128);
    memos.clear();
    assert(stats.bytesUsed == base, "marks not given back");
    mark(memos.of(5, 1), 1);
    memos.release();
    assert(stats.bytesUsed == base && memos.of(5, 1) is null);
}
