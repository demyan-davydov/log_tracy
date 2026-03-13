module domain.document_item;

import dlt_core.dlt_protocol : LogLevel, MessageType;
import dlt_core.decoded_message : DecodedMessage;

import std.stdint;

//! @brief represents a single item in the document
//! contains decoded message and metadata
struct DocumentItem
{
    alias Char = wchar;

    @disable this(this); // disable copy constructor

    // index in the original log file, can differ from the index in the document if filters are applied
    size_t realIndex;
    uint32_t filterMask;
    uint32_t searchMask;
    bool anchored;
    bool selected;
    // bool visible;

    package DecodedMessage!Char _decodedMessage;

    //public alias _decodedMessage this;

    // Public read-only forwarding properties.
    uint timestampSeconds() const pure nothrow @nogc @property
    {
        return _decodedMessage.timestampSeconds;
    }

    uint timestampMicroseconds() const pure nothrow @nogc @property
    {
        return _decodedMessage.timestampMicroseconds;
    }

    const(Char)[] ecu() const pure nothrow @nogc @property
    {
        return _decodedMessage.ecu;
    }

    const(Char)[] appId() const pure nothrow @nogc @property
    {
        return _decodedMessage.appId;
    }

    const(Char)[] ctxId() const pure nothrow @nogc @property
    {
        return _decodedMessage.ctxId;
    }

    uint messageId() const pure nothrow @nogc @property
    {
        return _decodedMessage.messageId;
    }

    LogLevel level() const pure nothrow @nogc @property
    {
        return _decodedMessage.level;
    }

    MessageType type() const pure nothrow @nogc @property
    {
        return _decodedMessage.type;
    }
    /// payload text (alias for DecodedMessage.payloadText)
    const(Char)[] payload() const pure nothrow @nogc @property
    {
        return _decodedMessage.payloadText;
    }
}
