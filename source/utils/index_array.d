module utils.index_array;

import utils.mmap_array;

@nogc:

//! Container to store indexes of DLT messages in file.
struct IndexArray
{
    private MmapArray!size_t _data;

    @disable this();
    @disable this(ref IndexArray);
    @disable void opAssign(ref IndexArray);

    this(size_t capacity) @nogc
    {
        _data = MmapArray!size_t(capacity);
    }

    ~this() @nogc
    {
    }

    void append(size_t offset) pure @nogc
    {
        _data.append(offset);
    }

    void append(const(size_t)[] slice) pure @nogc
    {
        _data.append(slice);
    }

    size_t opIndex(size_t i) const pure @nogc
    {
        return _data[i];
    }

    inout(size_t)[] opSlice(size_t i, size_t j) inout pure @nogc
    {
        return _data[i .. j];
    }

    size_t length() const pure nothrow @nogc
    {
        return _data.length;
    }

    size_t capacity() const pure nothrow @nogc
    {
        return _data.capacity;
    }

    void clear() @nogc
    {
        _data.clear();
    }
}
