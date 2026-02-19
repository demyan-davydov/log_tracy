module utils.mmap_array;

import core.sys.posix.sys.mman;
import core.sys.posix.unistd;

@nogc:

//! Array that stores data in memory mapped file.
struct MmapArray(T)
{
    private T* _data;
    private size_t _capacity;
    private size_t _length;

    private void alloc(size_t capacity) @nogc
    {
        _capacity = capacity;
        auto bytes = _capacity * T.sizeof;

        void* ptr = mmap(
            null,
            bytes,
            PROT_READ | PROT_WRITE,
            MAP_PRIVATE | MAP_ANON,
            -1,
            0
        );

        assert(ptr != MAP_FAILED);

        _data = cast(T*) ptr;
        _length = 0;
    }

    this(size_t maxElements) @nogc
    {
        alloc(maxElements);
    }

    ~this() @nogc
    {
        munmap(_data, _capacity * T.sizeof);
    }

    //! Unmap file to free memory and reallocate it.
    void clear() @nogc
    {
        munmap(_data, _capacity * T.sizeof);
        alloc(_capacity);
    }

    //! Append element to array.
    void append(T v) pure @nogc
    {
        assert(_length < _capacity);
        _data[_length++] = v;
    }

    //! Append slice of elements to array.
    void append(const(T)[] slice) pure @nogc
    {
        assert(_length + slice.length <= _capacity);
        _data[_length .. _length + slice.length] = slice;
        _length += slice.length;
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

    size_t[2] opSlice(size_t start, size_t end)
    {
        return [start, end];
    }

}
