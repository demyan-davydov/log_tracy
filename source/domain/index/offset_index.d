//! The offset index: where each record of a log starts in its source, 48 bits of an
//! entry; the top bit tells a record joined of parts (domain/index/part_joiner), the 15
//! bits between are kept for later (docs/backlog.md).
module domain.index.offset_index;

import domain.index.base_index;

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

//! offset index refers position of message in file
alias OffsetIndex = BaseIndex!OffsetIndexItem;
