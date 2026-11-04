module domain.index.base_index;

import utils.chunked_array;

//! An index of a log: grows as it fills (see ChunkedArray), its entries
//! don't move, so the indexing thread may read them while the UI thread
//! appends, and the other way round, as LogIndex does.
struct BaseIndex(T)
{
    alias Type = T;
    private ChunkedArray!Type _data;
    public bool isReady = false;

    //! Memory the index has taken, in bytes
    size_t reservedBytes() const pure nothrow @nogc
    {
        return _data.allocatedChunks * _data.chunkLength * Type.sizeof;
    }

    //! @return false if the index is full (2^32 entries) or out of memory
    bool append(Type value) nothrow @nogc
    {
        return _data.append(value);
    }

    //! @return false if the slice doesn't fit
    bool append(const(Type)[] slice) nothrow @nogc
    {
        return _data.append(slice);
    }

    //! @brief For an index sorted ascending: position of the first element >= value.
    //! Templated, so it is only instantiated for comparable element types.
    size_t lowerBound()(Type value) const pure nothrow @nogc
    {
        size_t lo = 0, hi = _data.length;
        while (lo < hi)
        {
            const mid = lo + (hi - lo) / 2;
            if (_data[mid] < value)
                lo = mid + 1;
            else
                hi = mid;
        }
        return lo;
    }

    //! @brief Inserts `value` keeping the index sorted; no-op if already present.
    //! @return false if the index is full (2^32 entries) or out of memory
    bool insertSorted()(Type value) nothrow @nogc
    {
        const pos = lowerBound(value);
        if (pos < _data.length && _data[pos] == value)
            return true;
        return _data.insertAt(pos, value);
    }

    //! @brief Removes `value` from a sorted index.
    //! @return false if it was not present
    bool removeSorted()(Type value) nothrow @nogc
    {
        const pos = lowerBound(value);
        if (pos < _data.length && _data[pos] == value)
            return _data.removeAt(pos);
        return false;
    }

    Type opIndex(size_t i) const pure nothrow @nogc
    {
        return _data[i];
    }


    size_t length() const pure nothrow @nogc
    {
        return _data.length;
    }

    void clear() nothrow @nogc
    {
        _data.clear();
    }
}

@("BaseIndex: sorted insert and remove")
unittest
{
    BaseIndex!uint index;
    assert(index.append([2u, 5, 9]));

    assert(index.insertSorted(7)); // [2, 5, 7, 9]
    assert(index.insertSorted(0)); // [0, 2, 5, 7, 9]
    assert(index.insertSorted(5) && index.length == 5, "present values are not duplicated");
    assert(index[0] == 0 && index[3] == 7 && index[4] == 9);

    assert(index.removeSorted(5)); // [0, 2, 7, 9]
    assert(!index.removeSorted(5), "already removed");
    assert(index.length == 4 && index[2] == 7);
    assert(index.lowerBound(8) == 3 && index.lowerBound(100) == 4);
}
