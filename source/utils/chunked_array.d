module utils.chunked_array;

//! An array that grows by chunks of memory: elements never move once written,
//! so a reader may keep reading what is there while the array grows, and
//! memory is taken only as the array fills.

//! @param chunkBits - a chunk holds 2^chunkBits elements
//! @param maxChunks - at most that many chunks: the array holds at most
//! maxChunks << chunkBits elements
struct ChunkedArray(T, size_t chunkBits = 16, size_t maxChunks = 1 << 16)
{
    import core.sys.posix.sys.mman : mmap, munmap, MAP_ANON, MAP_FAILED, MAP_PRIVATE,
        PROT_READ, PROT_WRITE;

    alias Type = T;
    enum size_t chunkLength = size_t(1) << chunkBits;
    enum size_t maxLength = chunkLength * maxChunks;
    private enum size_t indexMask = chunkLength - 1;

    //! The directory: maxChunks pointers to chunks, mapped on the first
    //! append and never moved, so a chunk is found the same way while the
    //! array grows. Its pages are taken as the chunk pointers fill them.
    private T** _chunks;
    private size_t _allocatedChunks;
    private size_t _length;

    @disable this(this); // owns its memory

    ~this() nothrow @nogc
    {
        releaseChunks();
        if (_chunks !is null)
            munmap(_chunks, maxChunks * (T*).sizeof);
    }

    //! @return false if the array is full or memory can't be taken; unchanged then
    bool append(T value) nothrow @nogc
    {
        if (!reserve(_length + 1))
            return false;
        slot(_length) = value;
        ++_length;
        return true;
    }

    //! @return false if the slice doesn't fit; unchanged then
    bool append(const(T)[] slice) nothrow @nogc
    {
        if (slice.length > maxLength - _length || !reserve(_length + slice.length))
            return false;
        size_t pos = _length;
        while (slice.length)
        {
            // The part that goes into the chunk of `pos`
            const offset = pos & indexMask;
            const n = slice.length < chunkLength - offset ? slice.length : chunkLength - offset;
            _chunks[pos >> chunkBits][offset .. offset + n] = slice[0 .. n];
            slice = slice[n .. $];
            pos += n;
        }
        _length = pos;
        return true;
    }

    //! Inserts `value` at `pos`, shifting the tail.
    //! @return false (unchanged) if pos > length or the array can't grow
    bool insertAt(size_t pos, T value) nothrow @nogc
    {
        if (pos > _length || !reserve(_length + 1))
            return false;
        for (size_t i = _length; i > pos; --i)
            slot(i) = slot(i - 1);
        slot(pos) = value;
        ++_length;
        return true;
    }

    //! Removes the element at `pos`, shifting the tail.
    //! @return false if pos is out of range
    bool removeAt(size_t pos) nothrow @nogc
    {
        if (pos >= _length)
            return false;
        for (size_t i = pos; i + 1 < _length; ++i)
            slot(i) = slot(i + 1);
        --_length;
        return true;
    }

    T opIndex(size_t i) const pure nothrow @nogc
    {
        assert(i < _length);
        return _chunks[i >> chunkBits][i & indexMask];
    }

    size_t length() const pure nothrow @nogc
    {
        return _length;
    }

    //! Removes all elements and gives their memory back
    void clear() nothrow @nogc
    {
        releaseChunks();
        _length = 0;
    }

    //! Chunks of memory taken: the array uses allocatedChunks * chunkLength * T.sizeof bytes
    size_t allocatedChunks() const pure nothrow @nogc
    {
        return _allocatedChunks;
    }

    version (unittest)
    {
        //! Where element `i` is kept, to check that elements don't move
        const(T)* addressOf(size_t i) const pure nothrow @nogc
        {
            return &_chunks[i >> chunkBits][i & indexMask];
        }
    }

    private ref T slot(size_t i) pure nothrow @nogc
    {
        return _chunks[i >> chunkBits][i & indexMask];
    }

    //! Takes the chunks for `count` elements
    //! @return false if that's more than maxLength or memory can't be taken
    private bool reserve(size_t count) nothrow @nogc
    {
        if (count > maxLength)
            return false;
        if (_chunks is null)
        {
            void* directory = mmap(null, maxChunks * (T*).sizeof, PROT_READ | PROT_WRITE,
                MAP_PRIVATE | MAP_ANON, -1, 0);
            if (directory == MAP_FAILED)
                return false;
            _chunks = cast(T**) directory;
        }
        while (_allocatedChunks * chunkLength < count)
        {
            void* chunk = mmap(null, chunkLength * T.sizeof, PROT_READ | PROT_WRITE,
                MAP_PRIVATE | MAP_ANON, -1, 0);
            if (chunk == MAP_FAILED)
                return false; // the chunks taken so far stay: they are reused
            _chunks[_allocatedChunks++] = cast(T*) chunk;
        }
        return true;
    }

    private void releaseChunks() nothrow @nogc
    {
        foreach (i; 0 .. _allocatedChunks)
            munmap(_chunks[i], chunkLength * T.sizeof);
        _allocatedChunks = 0;
    }
}

// ─── Tests ──────────────────────────────────────────────────────────────────

version (unittest)
{
    //! 4 elements per chunk, at most 3 chunks: every test crosses chunk boundaries
    private alias Small = ChunkedArray!(int, 2, 3);

    private int[] contents(ref const(Small) a)
    {
        int[] result;
        foreach (i; 0 .. a.length)
            result ~= a[i];
        return result;
    }
}

@("ChunkedArray: takes memory only as it fills")
unittest
{
    Small a;
    assert(a.length == 0 && a.allocatedChunks == 0, "nothing taken before the first element");
    assert(a.append(1));
    assert(a.allocatedChunks == 1);
    assert(a.append([2, 3, 4]));
    assert(a.allocatedChunks == 1, "the first chunk holds 4");
    assert(a.append(5));
    assert(a.allocatedChunks == 2);
}

@("ChunkedArray: append and read across chunks")
unittest
{
    Small a;
    assert(a.append([1, 2, 3]));
    assert(a.append([4, 5, 6, 7, 8, 9])); // crosses two chunk boundaries
    assert(a.append(10));
    assert(a.length == 10);
    assert(contents(a) == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
}

@("ChunkedArray: elements don't move when the array grows")
unittest
{
    Small a;
    assert(a.append([1, 2, 3]));
    const first = a.addressOf(0);
    const third = a.addressOf(2);
    assert(first !is null);
    assert(a.append([4, 5, 6, 7, 8, 9, 10, 11]));
    assert(a.addressOf(0) is first && a.addressOf(2) is third);
}

@("ChunkedArray: a full array takes nothing more and stays unchanged")
unittest
{
    Small a;
    assert(a.append([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]));
    assert(!a.append([12, 13]), "the slice doesn't fit");
    assert(a.length == 11);
    assert(a.append(12), "one more fits: 3 chunks of 4");
    assert(!a.append(13));
    assert(!a.insertAt(0, 0));
    assert(a.length == Small.maxLength && a[11] == 12);
}

@("ChunkedArray: insertAt and removeAt shift the tail across chunks")
unittest
{
    Small a;
    int[] model;
    // Insert at the front, the middle and the end, then remove the same way
    foreach (i, pos; [0, 0, 1, 3, 2, 5, 0, 7, 4, 9, 1])
    {
        assert(a.insertAt(pos, cast(int) i), "insert");
        model = model[0 .. pos] ~ cast(int) i ~ model[pos .. $];
        assert(contents(a) == model);
    }
    assert(!a.insertAt(a.length + 1, 99), "past the end");

    foreach (pos; [0, 5, 8, 2, 0, 3])
    {
        assert(a.removeAt(pos), "remove");
        model = model[0 .. pos] ~ model[pos + 1 .. $];
        assert(contents(a) == model);
    }
    assert(!a.removeAt(a.length), "out of range");
}

@("ChunkedArray: clear gives the memory back, the array can be filled again")
unittest
{
    Small a;
    assert(a.append([1, 2, 3, 4, 5, 6]));
    a.clear();
    assert(a.length == 0 && a.allocatedChunks == 0);
    assert(a.append([7, 8, 9, 10, 11]));
    assert(contents(a) == [7, 8, 9, 10, 11]);
}

@("ChunkedArray: the default size holds 2^32 elements in chunks of 64K")
unittest
{
    alias Index = ChunkedArray!uint;
    static assert(Index.chunkLength == 65_536);
    static assert(Index.maxLength == 1UL << 32);

    Index a;
    foreach (i; 0 .. Index.chunkLength + 1)
        assert(a.append(cast(uint) i));
    assert(a.allocatedChunks == 2);
    assert(a[Index.chunkLength] == Index.chunkLength);
}
