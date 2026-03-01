module utils.index_array;

import utils.mmap_array;

@nogc:

//! Container to store indexes of DLT messages in file.
struct IndexArray
{
    alias Type = size_t;
    private MmapArray!Type _data;

    @disable this();
    @disable this(ref IndexArray);
    @disable void opAssign(ref IndexArray);

    this(size_t capacity) @nogc
    {
        _data = MmapArray!Type(capacity);
    }

    ~this() @nogc
    {
    }

    void append(Type offset) pure @nogc
    {
        _data.append(offset);
    }

    void append(const(Type)[] slice) pure @nogc
    {
        _data.append(slice);
    }

    Type opIndex(size_t i) const pure @nogc
    {
        return _data[i];
    }

    inout(Type)[] opSlice(size_t i, size_t j) inout pure @nogc
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
