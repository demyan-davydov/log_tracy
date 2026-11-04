module utils.mmap_array;

import core.sys.posix.sys.mman;
import core.sys.posix.unistd;

// todo: import std.experimental.allocator.mmap_allocator : MmapAllocator;


//! Array that stores data in memory mapped file.
struct MmapArray(T)
{
    private T* _data;
    private size_t _capacity;
    private size_t _length;

    alias Type = T;

    //! @return false if the memory can't be mapped: the array is empty then,
    //! with no capacity
    private bool alloc(size_t capacity) nothrow @nogc
    {
        _data = null;
        _capacity = 0;
        _length = 0;
        if (capacity > size_t.max / T.sizeof)
            return false;

        void* ptr = mmap(
            null,
            capacity * T.sizeof,
            PROT_READ | PROT_WRITE,
            MAP_PRIVATE | MAP_ANON,
            -1,
            0
        );
        if (ptr == MAP_FAILED)
            return false;

        _data = cast(T*) ptr;
        _capacity = capacity;
        return true;
    }

    //! @throws Exception if that much memory can't be mapped
    this(size_t maxElements)
    {
        if (!alloc(maxElements))
            throw new Exception("not enough address space for an index of this file");
    }

    ~this() @nogc
    {
        if (_data)
            munmap(_data, _capacity * T.sizeof);
    }

    //! Unmap file to free memory and reallocate it.
    //! If the memory can't be mapped again, the capacity becomes 0: appends fail.
    void clear() @nogc
    {
        const capacity = _capacity;
        if (_data)
            munmap(_data, _capacity * T.sizeof);
        alloc(capacity);
    }

    //! Append element to array.
    //! @return false (array unchanged) if capacity is exhausted
    bool append(T v) pure @nogc
    {
        if (_length >= _capacity)
            return false;
        _data[_length++] = v;
        return true;
    }

    //! Append slice of elements to array.
    //! @return false (array unchanged) if the slice doesn't fit
    bool append(const(T)[] slice) pure @nogc
    {
        if (slice.length > _capacity - _length)
            return false;
        _data[_length .. _length + slice.length] = slice;
        _length += slice.length;
        return true;
    }

    //! Inserts `v` at position `pos`, shifting the tail.
    //! @return false (array unchanged) if capacity is exhausted or pos > length
    bool insertAt(size_t pos, T v) pure @nogc
    {
        import core.stdc.string : memmove;

        if (_length >= _capacity || pos > _length)
            return false;
        memmove(_data + pos + 1, _data + pos, (_length - pos) * T.sizeof);
        _data[pos] = v;
        ++_length;
        return true;
    }

    //! Removes the element at position `pos`, shifting the tail.
    //! @return false (array unchanged) if pos is out of range
    bool removeAt(size_t pos) pure @nogc
    {
        import core.stdc.string : memmove;

        if (pos >= _length)
            return false;
        memmove(_data + pos, _data + pos + 1, (_length - pos - 1) * T.sizeof);
        --_length;
        return true;
    }

    //! Get element at index.
    T opIndex(size_t i) const pure @nogc
    {
        return _data[i];
    }

    inout(T)[] opSlice(size_t i, size_t j) inout pure @nogc
    {
        return _data[i .. j];
    }

    size_t length() const pure nothrow @nogc
    {
        return _length;
    }

    size_t capacity() const pure nothrow @nogc
    {
        return _capacity;
    }

    size_t[2] opSlice(size_t start, size_t end) const pure nothrow @nogc
    {
        return [start, end];
    }

    size_t[2] range() const pure nothrow @nogc
    {
        return [0, _length];
    }
}

@("MmapArray: append reports overflow instead of writing past capacity")
unittest
{
    auto a = MmapArray!int(3);
    assert(a.append(1));
    assert(a.append([2, 3]));
    assert(!a.append(4), "single append past capacity must fail");
    assert(!a.append([4]), "slice append past capacity must fail");
    assert(a.length == 3 && a[2] == 3, "failed appends must not change the array");
}

@("MmapArray: insertAt and removeAt shift the tail")
unittest
{
    auto a = MmapArray!int(4);
    assert(a.append([1, 3]));
    assert(a.insertAt(1, 2)); // [1, 2, 3]
    assert(a.insertAt(0, 0)); // [0, 1, 2, 3]
    assert(a[0] == 0 && a[1] == 1 && a[2] == 2 && a[3] == 3);
    assert(!a.insertAt(4, 4), "full");

    assert(a.removeAt(0)); // [1, 2, 3]
    assert(a.removeAt(2)); // [1, 2]
    assert(a.length == 2 && a[0] == 1 && a[1] == 2);
    assert(!a.removeAt(2), "out of range");
    assert(a.insertAt(2, 9) && a[2] == 9, "insert at the end");
}

@("MmapArray: a capacity that can't be mapped throws instead of asserting")
unittest
{
    import std.exception : assertThrown;

    assertThrown!Exception(MmapArray!ulong(1UL << 50)); // 8 PB: more than the address space
    assertThrown!Exception(MmapArray!ulong(size_t.max / 4), "the size in bytes overflows");
}
