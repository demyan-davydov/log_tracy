module domain.document_item;

import dlt_core.dlt_protocol : LogLevel, MessageType;
import dlt_core.decoded_message : DecodedMessage;

import std.stdint;

//! @brief represents a single item in the document
//! contains decoded message and metadata
struct DocumentItem
{
    alias Char = wchar;

    // index in the original log file, can differ from the index in the document if filters are applied
    size_t realIndex;
    uint32_t filterMask;
    uint32_t searchMask;
    bool anchored;
    bool selected;
    // bool visible;

    package DecodedMessage!Char _decodedMessage;

    /*DecodedMessage!Char* decodedMessage() const
    {
        return &_decodedMessage;
    }*/

    alias _decodedMessage this;
}
