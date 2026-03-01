module domain.index.base_index;

import utils.mmap_array;

struct BaseIndex(T)
{
    alias Type = T;
    private MmapArray!Type _data;
    public bool isReady;

    this(size_t capacity)
    {
        _data = MmapArray!Type(capacity);
    }

    void append(Type value) pure @nogc
    {
        _data.append(value);
    }

    void append(const(Type)[] slice) pure @nogc
    {
        _data.append(slice);
    }

    Type opIndex(size_t i) const pure nothrow @nogc
    {
        return _data[i];
    }

    inout(Type)[] opSlice(size_t i, size_t j) inout pure nothrow @nogc
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

    size_t[2] opSlice(size_t start, size_t end) const pure nothrow @nogc
    {
        return _data.opSlice(start, end);
    }

    auto range() const pure nothrow @nogc @property
    {
        return _data.range();
    }
}
