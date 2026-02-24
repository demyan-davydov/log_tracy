module domain.index.base_index;

import utils.mmap_array;

struct BaseIndex(T)
{
    private MmapArray!T _data;
    public bool isReady;

    this(size_t capacity)
    {
        _data = MmapArray!T(capacity);
    }

    void append(T value)
    {
        _data.append(value);
    }

    void append(const(T)[] slice)
    {
        _data.append(slice);
    }

    T opIndex(size_t i) const
    {
        return _data[i];
    }

    inout(T)[] opSlice(size_t i, size_t j) inout
    {
        return _data[i .. j];
    }

    size_t length() const
    {
        return _data.length;
    }

    size_t capacity() const
    {
        return _data.capacity;
    }

    void clear()
    {
        _data.clear();
    }
}
