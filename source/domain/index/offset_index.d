//! The offset index: where each record of a log starts in its source, and whether it is
//! joined of parts (domain/index/part_joiner). Kept compact, 4 bytes a record: an offset
//! from the start of the record's block, the block's start kept once.
module domain.index.offset_index;

import utils.chunked_array;

//! A record of the offset index as it goes in and comes out (OffsetIndex): its offset and
//! whether it is joined of parts. Not the form it is kept in (CompactOffsets)
struct OffsetIndexItem
{
    size_t data;

    size_t offset() const pure nothrow @nogc @property
    {
        return data & 0x0000_FFFF_FFFF_FFFF;
    }

    void offset(size_t value) pure nothrow @nogc @property
    {
        data = (data & 0xFFFF_0000_0000_0000) | value;
    }

    //! The record is joined of parts: RecordStore keeps the offsets of the parts after
    //! the first one
    bool joined() const pure nothrow @nogc @property
    {
        return (data & joinedBit) != 0;
    }

    void joined(bool value) pure nothrow @nogc @property
    {
        data = value ? data | joinedBit : data & ~joinedBit;
    }

    private enum size_t joinedBit = size_t(1) << 63;
}

@("OffsetIndexItem: the offset and the joined flag don't touch each other")
unittest
{
    OffsetIndexItem item;
    item.offset = 0x0000_FFFF_FFFF_FFFF;
    item.joined = true;
    assert(item.joined && item.offset == 0x0000_FFFF_FFFF_FFFF);
    item.offset = 5;
    assert(item.joined && item.offset == 5);
    item.joined = false;
    assert(!item.joined && item.offset == 5);
}

//! The offset index of a log: an array of OffsetIndexItem to its user, 4 bytes a record
//! inside. Records are grouped in blocks of 2^blockBits in a row; a block keeps the offset
//! of its first record (its base) once, a record its distance from the base in 30 bits.
//! A record farther than that (bytes skipped between records, parts of a message that
//! are not records) keeps its full offset in a list of far offsets, and its place there
//! instead of the distance. A record is at most 64 KB long, so a block of records in a
//! row spans at most 256 MB and far offsets are rare; nothing depends on that but the size.
//!
//! Grows by chunks, its entries never move (ChunkedArray): readers may read the records
//! below a length while one writer appends after them, the holder publishing what is
//! appended (domain/index/record_store). A template so that reads are inlined where they
//! are made.
//! @param blockBits - a block holds 2^blockBits records
//! @param chunkBits, maxChunks - of the array of records: at most maxChunks << chunkBits
struct CompactOffsets(size_t blockBits = 12, size_t chunkBits = 16, size_t maxChunks = 1 << 16)
{
    //! Records appended at a time at most: a bunch of RecordStore
    enum size_t maxAppend = 32;
    //! Records the index holds at most
    enum size_t maxLength = Words.maxLength;
    //! Far offsets it holds at most: their place is kept in 30 bits
    enum size_t maxFar = size_t(1) << 30;

    private enum size_t blockLength = size_t(1) << blockBits;
    private enum size_t blockMask = blockLength - 1;
    private enum uint joinedBit = 1u << 31;
    private enum uint farBit = 1u << 30;
    private enum uint valueMask = farBit - 1;

    // Small chunks: few blocks to a log, far offsets seldom
    private enum size_t smallChunkBits = 10;
    private enum size_t maxBlocks = (maxLength + blockMask) >> blockBits;

    private alias Words = ChunkedArray!(uint, chunkBits, maxChunks);
    private Words _words; // a record each: the joined bit, the far bit, the distance or the place
    private ChunkedArray!(size_t, smallChunkBits, chunkCount(maxBlocks)) _bases; // a block each
    private ChunkedArray!(size_t, smallChunkBits, chunkCount(maxFar)) _far;

    @disable this(this); // owns its memory

    //! Memory the index has taken, in bytes
    size_t reservedBytes() const pure nothrow @nogc
    {
        return bytesOf(_words) + bytesOf(_bases) + bytesOf(_far);
    }

    //! @brief Appends at most maxAppend records, in the order of the source.
    //! @return false if the index is full or out of memory: nothing a reader sees
    //! changes then (far offsets written for the failed records stay, pointed at by none)
    bool append(const(OffsetIndexItem)[] items) nothrow @nogc
    {
        assert(items.length <= maxAppend);
        const first = _words.length;

        // The records are encoded first; the far offsets and the starts of new blocks
        // go in before the records, which are appended at once and alone make the
        // append: what a failed one left is pointed at by no record, and a block start
        // left is replaced by the next append that starts the block
        uint[maxAppend] words;
        size_t[maxAppend] far;
        size_t farCount = 0;
        size_t[maxAppend] starts; // of the blocks that start in this append
        size_t startCount = 0;
        size_t base = (first & blockMask) != 0 ? _bases[first >> blockBits] : 0;
        foreach (n, entry; items)
        {
            const offset = entry.offset;
            if (((first + n) & blockMask) == 0)
            {
                base = offset;
                starts[startCount++] = offset;
            }
            uint word;
            if (offset >= base && offset - base <= valueMask)
                word = cast(uint)(offset - base);
            else
            {
                word = farBit | cast(uint)(_far.length + farCount);
                far[farCount++] = offset;
            }
            words[n] = entry.joined ? word | joinedBit : word;
        }

        if (farCount > maxFar - _far.length || !_far.append(far[0 .. farCount]))
            return false;
        const firstBlock = (first + blockMask) >> blockBits; // the first block that starts here
        foreach (n, start; starts[0 .. startCount])
        {
            const block = firstBlock + n;
            if (block < _bases.length)
                _bases[block] = start;
            else if (!_bases.append(start))
                return false;
        }
        return _words.append(words[0 .. items.length]);
    }

    OffsetIndexItem opIndex(size_t i) const pure nothrow @nogc
    {
        const word = _words[i];
        const value = word & valueMask;
        OffsetIndexItem result;
        result.offset = (word & farBit) ? _far[value] : _bases[i >> blockBits] + value;
        result.joined = (word & joinedBit) != 0;
        return result;
    }

    size_t length() const pure nothrow @nogc
    {
        return _words.length;
    }

    //! Removes all records and gives their memory back
    void clear() nothrow @nogc
    {
        _words.clear();
        _bases.clear();
        _far.clear();
    }

    version (unittest)
    {
        //! Records kept by their full offset
        size_t farCount() const pure nothrow @nogc
        {
            return _far.length;
        }
    }

    private static size_t bytesOf(Array)(ref const Array array) pure nothrow @nogc
    {
        return array.allocatedChunks * array.chunkLength * Array.Type.sizeof;
    }

    private static size_t chunkCount(size_t entries)
    {
        const chunks = (entries + (size_t(1) << smallChunkBits) - 1) >> smallChunkBits;
        return chunks == 0 ? 1 : chunks;
    }
}

//! The offset index of a log
alias OffsetIndex = CompactOffsets!();

// ─── Tests ──────────────────────────────────────────────────────────────────

version (unittest)
{
    //! Blocks of 4 records, at most 16 records: tests cross blocks and fill the index
    private alias Small = CompactOffsets!(2, 2, 4);

    private OffsetIndexItem item(size_t offset, bool joined = false)
    {
        OffsetIndexItem result;
        result.offset = offset;
        result.joined = joined;
        return result;
    }

    private size_t[] offsets(Index)(ref const Index index)
    {
        size_t[] result;
        foreach (i; 0 .. index.length)
            result ~= index[i].offset;
        return result;
    }

    private enum size_t gigabyte = size_t(1) << 30;
}

@("CompactOffsets: reads back the offsets across blocks")
unittest
{
    Small index;
    assert(index.append([item(0), item(180), item(350)]));
    assert(index.append([item(500), item(720), item(900), item(1000), item(1200), item(1300)]));
    assert(index.length == 9);
    assert(offsets(index) == [0, 180, 350, 500, 720, 900, 1000, 1200, 1300]);
    assert(index.farCount == 0);
}

@("CompactOffsets: the joined flag and the offset don't touch each other")
unittest
{
    Small index;
    assert(index.append([item(10, true), item(20), item(30, true), item(40), item(50, true)]));
    assert(offsets(index) == [10, 20, 30, 40, 50]);
    assert(index[0].joined && !index[1].joined && index[2].joined && !index[3].joined && index[4].joined);
}

@("CompactOffsets: a record over 1 GB past its block's start keeps its full offset")
unittest
{
    Small index;
    const far = 3 * gigabyte + 7;
    // Block 0: 0, far, far + 100, far + 200; block 1 starts at 6 GB, after a gap
    assert(index.append([item(0), item(far, true), item(far + 100), item(far + 200)]));
    assert(index.farCount == 3, "the records after the gap are far from the start of their block");
    assert(index.append([item(6 * gigabyte), item(6 * gigabyte + 50)]));
    assert(index.farCount == 3, "the first record of a block is its start: never far");
    assert(offsets(index) == [0, far, far + 100, far + 200, 6 * gigabyte, 6 * gigabyte + 50]);
    assert(index[1].joined && !index[2].joined);
}

@("CompactOffsets: a distance of just under 1 GB is kept as a distance")
unittest
{
    Small index;
    assert(index.append([item(5), item(5 + gigabyte - 1), item(5 + gigabyte)]));
    assert(index.farCount == 1);
    assert(offsets(index) == [5, 5 + gigabyte - 1, 5 + gigabyte]);
}

@("CompactOffsets: an append that doesn't fit leaves the index as it was")
unittest
{
    Small index;
    foreach (i; 0 .. 10)
        assert(index.append([item(i * 10)]));
    // Records 10..16, the index holds 16: the far offset of record 11 and the start of
    // block 3 (record 12) are written before the records fail
    const far = 5 * gigabyte;
    assert(!index.append([item(100), item(far), item(120), item(130), item(140), item(150), item(160)]));
    assert(index.length == 10);
    assert(offsets(index) == [0, 10, 20, 30, 40, 50, 60, 70, 80, 90]);
    assert(index.farCount == 1, "the far offset is left, pointed at by no record");
    // The start of block 3 left is replaced; a far offset goes after the one left
    assert(index.append([item(200), item(far + 1), item(220), item(230)]));
    assert(offsets(index)[10 .. $] == [200, far + 1, 220, 230]);
}

@("CompactOffsets: clear gives the memory back, the index fills again")
unittest
{
    Small index;
    assert(index.append([item(1), item(2), item(3), item(4), item(5 * gigabyte)]));
    assert(index.reservedBytes > 0);
    index.clear();
    assert(index.length == 0 && index.reservedBytes == 0 && index.farCount == 0);
    assert(index.append([item(7), item(8)]));
    assert(offsets(index) == [7, 8]);
}

@("CompactOffsets: takes about half the memory of 8 bytes a record")
unittest
{
    import domain.index.base_index : BaseIndex;

    OffsetIndex compact;
    BaseIndex!OffsetIndexItem wide;
    OffsetIndexItem[OffsetIndex.maxAppend] bunch;
    size_t offset = 0;
    foreach (_; 0 .. 3 * 65_536 / bunch.length) // three chunks of records
    {
        foreach (ref entry; bunch)
        {
            entry = item(offset);
            offset += 180;
        }
        assert(compact.append(bunch[]));
        assert(wide.append(bunch[]));
    }
    assert(compact[compact.length - 1].offset == offset - 180);
    assert(compact.reservedBytes * 2 < wide.reservedBytes * 105 / 100,
        "4 bytes a record and little more");
}
