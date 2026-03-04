module domain.index.offset_index;

import domain.index.base_index;
import core.stdc.stdint : uint16_t;

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

    uint16_t filterMask() const pure nothrow @nogc @property
    {
        return cast(uint16_t)(data >> 48);
    }

    void filterMask(uint16_t value) pure nothrow @nogc @property
    {
        data = (data & 0x0000_FFFF_FFFF_FFFF) | (cast(size_t) value << 48);
    }
}

//! offset index refers position of message in file
alias OffsetIndex = BaseIndex!OffsetIndexItem;
