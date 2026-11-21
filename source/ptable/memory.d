//! Memory of the table that is not the garbage collector's: where blocks come from (an `RCIAllocator` of
//! `std.experimental.allocator`: the C heap by default, any other the host gives), an arena that hands out pieces of them and gives
//! them all back at once (`Arena`), a growing array (`Buffer`) and a hash map (`HashMap`) on the same
//! source. What the table keeps near its rows (the cache of rows, the texts and lines in it) lives in an
//! arena that is dropped whole when the cache is: no collection to wait for, and nothing allocates in a
//! frame once the blocks have grown. See docs/stories/painted-table.md.
module ptable.memory;

import core.stdc.string : memcpy, memset;
import std.experimental.allocator : RCIAllocator, allocatorObject;
import std.experimental.allocator.mallocator : Mallocator;

/// The allocator the table uses unless the host gives another: the C heap, through the allocator interface of
/// `std.experimental.allocator`. Any `RCIAllocator` can take its place (a region, a pool, the collector's).
RCIAllocator mallocAllocator() nothrow
{
    static __gshared RCIAllocator instance;
    if (instance.isNull)
        instance = allocatorObject(Mallocator.instance);
    return instance;
}

private void* take(RCIAllocator a, size_t bytes) nothrow
{
    return a.allocate(bytes).ptr; // null if there is no memory
}

private void give(RCIAllocator a, void* block, size_t bytes) nothrow
{
    if (block !is null)
        a.deallocate(block[0 .. bytes]);
}

private struct BlockHeader
{
    BlockHeader* next;
    size_t size; // of the block after this header
    size_t used;
    size_t padding; // the header is 32 bytes: what follows is aligned to 16
}

private enum size_t align_ = 16;

private size_t aligned(size_t n) pure nothrow @nogc @safe
{
    return (n + align_ - 1) & ~(align_ - 1);
}

/// A bump allocator: pieces come one after another from big blocks and are all given back by `reset`
/// (the first block is kept) or `release` (all). Not thread safe: the table is of one thread.
struct Arena
{
    private RCIAllocator _alloc;
    private BlockHeader* _first, _current;
    private size_t _blockSize;
    size_t blocks; /// how many blocks it holds

    this(RCIAllocator allocator, size_t blockSize = 64 * 1024) nothrow
    {
        _alloc = allocator;
        _blockSize = blockSize;
    }

    @disable this(this);

    ~this() nothrow
    {
        release();
    }

    /// `bytes` of zeroed memory aligned to 16; null if the source has none
    void* allocate(size_t bytes) nothrow
    {
        bytes = aligned(bytes == 0 ? 1 : bytes);
        if (_current is null || _current.used + bytes > _current.size)
        {
            // the next block already held (after a reset) if it is big enough, else a new one
            BlockHeader* next = _current is null ? _first : _current.next;
            if (next is null || next.size < bytes)
            {
                const size = bytes > _blockSize ? bytes : _blockSize;
                auto fresh = cast(BlockHeader*) take(_alloc, BlockHeader.sizeof + size);
                if (fresh is null)
                    return null;
                fresh.size = size;
                fresh.next = next;
                if (_current is null)
                    _first = fresh;
                else
                    _current.next = fresh;
                blocks++;
                next = fresh;
            }
            next.used = 0;
            _current = next;
        }
        auto piece = cast(ubyte*)(_current + 1) + _current.used;
        _current.used += bytes;
        memset(piece, 0, bytes);
        return piece;
    }

    /// An array of `count` elements, zeroed (as `.init` for the plain data the table keeps)
    T[] makeArray(T)(size_t count) nothrow
    {
        if (count == 0)
            return null;
        auto piece = cast(T*) allocate(count * T.sizeof);
        return piece is null ? null : piece[0 .. count];
    }

    T* make(T)() nothrow
    {
        return cast(T*) allocate(T.sizeof);
    }

    /// A copy of `text` in the arena
    const(wchar)[] copy(const(wchar)[] text) nothrow
    {
        auto piece = makeArray!wchar(text.length);
        if (piece.length)
            memcpy(piece.ptr, text.ptr, text.length * wchar.sizeof);
        return piece;
    }

    /// Everything given out is free again; the blocks stay for the next round
    void reset() nothrow
    {
        _current = null;
    }

    /// Gives every block back
    void release() nothrow
    {
        for (auto block = _first; block !is null;)
        {
            auto next = block.next;
            give(_alloc, block, BlockHeader.sizeof + block.size);
            block = next;
        }
        _first = _current = null;
        blocks = 0;
    }

    /// The bytes handed out since the last reset
    size_t used() const nothrow
    {
        size_t total;
        for (auto block = cast(const(BlockHeader)*) _first; block !is null; block = block.next)
        {
            total += block.used;
            if (block is _current)
                break;
        }
        return _current is null ? 0 : total;
    }
}

/// A growing array of plain data on a block source: `put` appends, `clear` empties it and keeps the room
struct Buffer(T)
{
    private RCIAllocator _alloc;
    private T* _data;
    private size_t _length, _capacity;

    this(RCIAllocator allocator) nothrow
    {
        _alloc = allocator;
    }

    @disable this(this);

    ~this() nothrow
    {
        give(_alloc, _data, _capacity * T.sizeof);
    }

    size_t length() const pure nothrow @nogc @safe
    {
        return _length;
    }

    /// What it holds: valid until the next `put`
    inout(T)[] opSlice() inout pure nothrow @nogc @trusted
    {
        return _data is null ? null : _data[0 .. _length];
    }

    /// Appends; false if the source has no memory (nothing is added). By value, not const: a `T` with pointers (a handle) is kept too
    bool put(T item) nothrow
    {
        if (!reserve(_length + 1))
            return false;
        _data[_length++] = item;
        return true;
    }

    bool put(const(T)[] items) nothrow
    {
        if (!reserve(_length + items.length))
            return false;
        if (items.length)
            memcpy(_data + _length, items.ptr, items.length * T.sizeof);
        _length += items.length;
        return true;
    }

    /// Room for `count` elements in all
    bool reserve(size_t count) nothrow
    {
        if (count <= _capacity)
            return true;
        size_t grown = _capacity < 8 ? 8 : _capacity * 2;
        if (grown < count)
            grown = count;
        auto fresh = cast(T*) take(_alloc, grown * T.sizeof);
        if (fresh is null)
            return false;
        if (_length)
            memcpy(fresh, _data, _length * T.sizeof);
        give(_alloc, _data, _capacity * T.sizeof);
        _data = fresh;
        _capacity = grown;
        return true;
    }

    void clear() pure nothrow @nogc @safe
    {
        _length = 0;
    }

    /// The length is cut to `n` (not more than it is)
    void truncate(size_t n) pure nothrow @nogc @safe
    {
        if (n < _length)
            _length = n;
    }
}

/// A map from keys to values of plain data on a block source: open addressing, removal by marks. A
/// key is compared with `==` and hashed with `hashOf`; keys and values are not destroyed.
struct HashMap(K, V)
{
    private enum ubyte empty = 0, full = 1, gone = 2;

    private RCIAllocator _alloc;
    private ubyte* _marks;
    private K* _keys;
    private V* _values;
    private size_t _capacity, _count, _used; // used: full and gone

    this(RCIAllocator allocator) nothrow
    {
        _alloc = allocator;
    }

    @disable this(this);

    ~this() nothrow
    {
        free();
    }

    /// Gives the memory back (the map is empty and still usable)
    void free() nothrow
    {
        if (_marks !is null)
        {
            give(_alloc, _marks, _capacity);
            give(_alloc, _keys, _capacity * K.sizeof);
            give(_alloc, _values, _capacity * V.sizeof);
        }
        _marks = null;
        _keys = null;
        _values = null;
        _capacity = _count = _used = 0;
    }

    size_t length() const pure nothrow @nogc @safe
    {
        return _count;
    }

    private size_t find(const K key) const nothrow @trusted
    {
        if (_capacity == 0)
            return size_t.max;
        size_t at = hashOf(key) & (_capacity - 1);
        foreach (probes; 0 .. _capacity)
        {
            if (_marks[at] == empty)
                return size_t.max;
            if (_marks[at] == full && _keys[at] == key)
                return at;
            at = (at + 1) & (_capacity - 1);
        }
        return size_t.max;
    }

    /// The value of `key`, null if there is none: valid until the next `set`
    V* opBinaryRight(string op : "in")(const K key) nothrow
    {
        const at = find(key);
        return at == size_t.max ? null : _values + at;
    }

    /// Sets the value of `key`; false if the source has no memory
    bool set(K key, V value) nothrow
    {
        const at = find(key);
        if (at != size_t.max)
        {
            _values[at] = value;
            return true;
        }
        if ((_used + 1) * 4 > _capacity * 3 && !grow())
            return false;
        size_t slot = hashOf(key) & (_capacity - 1);
        while (_marks[slot] == full)
            slot = (slot + 1) & (_capacity - 1);
        if (_marks[slot] == empty)
            _used++;
        _marks[slot] = full;
        _keys[slot] = key;
        _values[slot] = value;
        _count++;
        return true;
    }

    /// Takes `key` out; true if it was there
    bool remove(const K key) nothrow
    {
        const at = find(key);
        if (at == size_t.max)
            return false;
        _marks[at] = gone;
        _count--;
        return true;
    }

    /// Takes everything out; the room stays
    void clear() nothrow
    {
        if (_marks !is null)
            memset(_marks, 0, _capacity);
        _count = _used = 0;
    }

    /// Calls `visit(key, value)` for each entry
    int opApply(Visit)(scope Visit visit)
    {
        foreach (i; 0 .. _capacity)
            if (_marks[i] == full)
                if (const stop = visit(_keys[i], _values[i]))
                    return stop;
        return 0;
    }

    private bool grow() nothrow
    {
        const wanted = _count * 2 + 1 > _capacity * 3 / 4 / 1 ? (_capacity ? _capacity * 2 : 16) : _capacity; // grows, or only sheds marks
        auto marks = cast(ubyte*) take(_alloc, wanted);
        auto keys = cast(K*) take(_alloc, wanted * K.sizeof);
        auto values = cast(V*) take(_alloc, wanted * V.sizeof);
        if (marks is null || keys is null || values is null)
        {
            give(_alloc, marks, wanted);
            give(_alloc, keys, wanted * K.sizeof);
            give(_alloc, values, wanted * V.sizeof);
            return false;
        }
        memset(marks, 0, wanted);
        auto oldMarks = _marks;
        auto oldKeys = _keys;
        auto oldValues = _values;
        const oldCapacity = _capacity;
        _marks = marks;
        _keys = keys;
        _values = values;
        _capacity = wanted;
        _count = _used = 0;
        foreach (i; 0 .. oldCapacity)
            if (oldMarks[i] == full)
                set(oldKeys[i], oldValues[i]);
        give(_alloc, oldMarks, oldCapacity);
        give(_alloc, oldKeys, oldCapacity * K.sizeof);
        give(_alloc, oldValues, oldCapacity * V.sizeof);
        return true;
    }
}

@("Arena: pieces are zeroed and aligned, a reset gives them all back without freeing the blocks")
unittest
{
    auto arena = Arena(mallocAllocator(), 256);
    auto a = arena.makeArray!ulong(4);
    assert(a.length == 4 && a[0] == 0 && a[3] == 0 && (cast(size_t) a.ptr) % 16 == 0);
    a[0] = 7;
    const text = arena.copy("hello"w);
    assert(text == "hello"w);
    assert(arena.used > 0);
    arena.makeArray!ubyte(1000); // more than a block: a block of its own
    assert(arena.blocks >= 2);
    const blocks = arena.blocks;
    arena.reset();
    assert(arena.used == 0);
    auto b = arena.makeArray!ulong(4);
    assert(b[0] == 0, "zeroed again");
    arena.makeArray!ubyte(1000);
    assert(arena.blocks == blocks, "the blocks were reused");
}

@("Arena: release gives the blocks back, an empty request is a null array")
unittest
{
    import std.experimental.allocator.building_blocks.stats_collector : Options, StatsCollector;

    StatsCollector!(Mallocator, Options.bytesUsed) stats;
    auto allocator = allocatorObject(&stats);
    const base = stats.bytesUsed; // the object of the allocator is in it
    {
        auto arena = Arena(allocator, 64);
        assert(arena.makeArray!int(0) is null);
        arena.makeArray!ubyte(500);
        arena.makeArray!ubyte(500);
        assert(arena.blocks >= 2 && stats.bytesUsed > base);
    }
    assert(stats.bytesUsed == base, "the destructor gives every block back");
}

@("Buffer: appends grow it, clear keeps the room, the slice is what was put")
unittest
{
    auto buffer = Buffer!wchar(mallocAllocator());
    foreach (c; "abcdefghijklmnopqrstuvwxyz"w)
        assert(buffer.put(c));
    assert(buffer[] == "abcdefghijklmnopqrstuvwxyz"w);
    buffer.clear();
    assert(buffer.length == 0 && buffer[].length == 0);
    buffer.put("xyz"w);
    assert(buffer[] == "xyz"w);
    buffer.truncate(1);
    assert(buffer[] == "x"w);
}

@("HashMap: set, find, replace, remove and grow past its first size")
unittest
{
    auto map = HashMap!(size_t, int)(mallocAllocator());
    assert((3 in map) is null);
    foreach (i; 0 .. 1000)
        assert(map.set(i, cast(int) i * 2));
    assert(map.length == 1000);
    foreach (i; 0 .. 1000)
        assert(*(i in map) == i * 2);
    map.set(5, -1);
    assert(*(5 in map) == -1 && map.length == 1000);
    assert(map.remove(5) && !map.remove(5) && (5 in map) is null && map.length == 999);
    assert(*(6 in map) == 12, "the others are found past a removed one");
    map.clear();
    assert(map.length == 0 && (6 in map) is null);
    map.set(6, 1);
    assert(*(6 in map) == 1);
}

@("HashMap: keys of a struct with a text")
unittest
{
    static struct Key
    {
        uint font;
        const(wchar)[] text;
    }

    auto map = HashMap!(Key, int)(mallocAllocator());
    map.set(Key(1, "abc"w), 1);
    map.set(Key(2, "abc"w), 2);
    wchar[3] copy = "abc"w;
    assert(*(Key(1, copy[]) in map) == 1 && *(Key(2, "abc"w) in map) == 2, "equal by value, not by address");
    assert((Key(3, "abc"w) in map) is null);
}
