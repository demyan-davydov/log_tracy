//! StaticBitArray: a fixed number of bits, read and written by index, a value type in words
//! of its own (std.bitmanip.BitArray only views a buffer given to it).
module utils.static_bit_array;

//! `bits` bits, all clear at first
struct StaticBitArray(size_t bits)
{
    private enum wordBits = 8 * size_t.sizeof;
    private size_t[(bits + wordBits - 1) / wordBits] _words;

    //! The number of bits
    enum size_t length = bits;

    //! @returns the bit `i` < length
    bool opIndex(size_t i) const pure nothrow @nogc @safe
    {
        assert(i < bits);
        return (_words[i / wordBits] & mask(i)) != 0;
    }

    //! Sets the bit `i` < length to `value`
    void opIndexAssign(bool value, size_t i) pure nothrow @nogc @safe
    {
        assert(i < bits);
        if (value)
            _words[i / wordBits] |= mask(i);
        else
            _words[i / wordBits] &= ~mask(i);
    }

    private static size_t mask(size_t i) pure nothrow @nogc @safe
    {
        return size_t(1) << (i % wordBits);
    }
}

@("StaticBitArray: every bit by its index, clear at first")
unittest
{
    StaticBitArray!130 bits; // more than two words
    foreach (i; 0 .. bits.length)
        assert(!bits[i]);

    bits[0] = true;
    bits[64] = true;
    bits[129] = true;
    assert(bits[0] && bits[64] && bits[129]);
    assert(!bits[1] && !bits[63] && !bits[65] && !bits[128]);

    bits[64] = false;
    assert(!bits[64] && bits[0] && bits[129]);
}

@("StaticBitArray: a copy has bits of its own")
unittest
{
    StaticBitArray!8 a;
    a[3] = true;
    auto b = a;
    b[3] = false;
    assert(a[3] && !b[3]);
}
