module dlt_core.dlt_fields;

//! The format fields of a DLT record in a LogMessage, and the DLT view of a
//! LogMessage: accessors called like members (msg.ecuId) through UFCS.

import log_core.log_message;
import dlt_core.dlt_protocol : MessageType;

import std.traits : isSomeChar;

//! Field indexes of a DLT record in LogMessage
enum DltField : ubyte
{
    EcuId, // text
    AppId, // text
    CtxId, // text
    Type, // number: MessageType
    MessageId, // number
    SessionId, // number
    Timestamp, // number: time since the ECU started, in 0.1 ms (standard header)
}

static assert(DltField.max < LogMessage!char.maxFields);

//! Starts a DLT record: the IDs are stored without their padding.
//! @returns the payload builder, the IDs must not change after it
auto beginDltRecord(Char)(ref LogMessage!Char msg,
    const(char)[] ecuId, const(char)[] appId, const(char)[] ctxId) nothrow @nogc
        if (isSomeChar!Char)
{
    msg.beginRecord();
    msg.setText(DltField.EcuId, removeIdPadding(ecuId));
    msg.setText(DltField.AppId, removeIdPadding(appId));
    msg.setText(DltField.CtxId, removeIdPadding(ctxId));
    msg.setNumber(DltField.Type, MessageType.Log);
    return msg.payloadBuilder();
}

//! Removes the padding of a fixed-size (char[4]) DLT ID.
//! The DLT spec pads short IDs with '\0', but some loggers pad them with
//! spaces (e.g. ECU "CU7 "). Both are dropped, so the ID compares equal to
//! what the user types ("CU7") and looks the same in every view. Only the tail
//! is trimmed: characters inside the ID are kept.
const(char)[] removeIdPadding(const(char)[] src) pure nothrow @nogc
{
    size_t padding = 0;
    foreach_reverse (c; src)
    {
        if (c == 0 || c == ' ')
            ++padding;
        else
            break;
    }

    return src[0 .. src.length - padding];
}

// ─── Accessors ──────────────────────────────────────────────────────────────

const(Char)[] ecuId(Char)(ref const(LogMessage!Char) msg) pure nothrow @nogc
{
    return msg.text(DltField.EcuId);
}

const(Char)[] appId(Char)(ref const(LogMessage!Char) msg) pure nothrow @nogc
{
    return msg.text(DltField.AppId);
}

const(Char)[] ctxId(Char)(ref const(LogMessage!Char) msg) pure nothrow @nogc
{
    return msg.text(DltField.CtxId);
}

MessageType type(Char)(ref const(LogMessage!Char) msg) pure nothrow @nogc
{
    return cast(MessageType) msg.number(DltField.Type);
}

uint messageId(Char)(ref const(LogMessage!Char) msg) pure nothrow @nogc
{
    return cast(uint) msg.number(DltField.MessageId);
}

void messageId(Char)(ref LogMessage!Char msg, uint value) pure nothrow @nogc
{
    msg.setNumber(DltField.MessageId, value);
}

uint sessionId(Char)(ref const(LogMessage!Char) msg) pure nothrow @nogc
{
    return cast(uint) msg.number(DltField.SessionId);
}

uint relativeTimestamp_10000(Char)(ref const(LogMessage!Char) msg) pure nothrow @nogc
{
    return cast(uint) msg.number(DltField.Timestamp);
}

//! Storage header time: seconds since the Unix epoch
uint timestampSeconds(Char)(ref const(LogMessage!Char) msg) pure nothrow @nogc
{
    return cast(uint)(msg.timeNs / 1_000_000_000);
}

//! Storage header time: microseconds within the second
uint timestampMicroseconds(Char)(ref const(LogMessage!Char) msg) pure nothrow @nogc
{
    return cast(uint)(msg.timeNs % 1_000_000_000 / 1000);
}

// ─── Tests ──────────────────────────────────────────────────────────────────

@("removeIdPadding: drops trailing zeros and spaces")
unittest
{
    assert(removeIdPadding("ABCD\0\0") == "ABCD");
    assert(removeIdPadding("ABCD") == "ABCD");
    assert(removeIdPadding("\0\0\0") == "");
    assert(removeIdPadding("") == "");
    assert(removeIdPadding("A\0B\0\0") == "A\0B"); // Only trailing zeros

    // Space padding used by some loggers instead of '\0'
    assert(removeIdPadding("CU7 ") == "CU7");
    assert(removeIdPadding("AB  ") == "AB");
    assert(removeIdPadding("AB \0") == "AB", "mixed padding");
    assert(removeIdPadding("    ") == "");
    assert(removeIdPadding("A B ") == "A B", "inner spaces are part of the ID");
}

@("beginDltRecord: sets ecu/appId/ctxId")
unittest
{
    LogMessage!char msg;
    {
        auto builder = msg.beginDltRecord("ECU1", "APP1", "CTX1");
        builder.appendAscii("text");
    }
    assert(msg.ecuId == "ECU1");
    assert(msg.appId == "APP1");
    assert(msg.ctxId == "CTX1");
    assert(msg.type == MessageType.Log);
    assert(msg.payloadText == "text");
}

@("beginDltRecord: IDs padded with zeros or spaces are trimmed")
unittest
{
    LogMessage!char msg;
    msg.beginDltRecord("CU7 ", "APP ", "C\0\0\0");
    assert(msg.ecuId == "CU7");
    assert(msg.appId == "APP");
    assert(msg.ctxId == "C");
}

@("beginDltRecord: cleans non-printable in IDs")
unittest
{
    LogMessage!char msg;

    char[4] ecuId = ['E', 'C', 0, 0];
    char[4] appId = ['A', 1, 'P', 0];
    char[4] ctxId = ['C', 'T', 'X', '1'];

    msg.beginDltRecord(ecuId[], appId[], ctxId[]);
    assert(msg.ecuId == "EC");
    assert(msg.appId == "A?P");
    assert(msg.ctxId == "CTX1");
}

@("DLT accessors: storage time is split into seconds and microseconds")
unittest
{
    LogMessage!wchar msg;
    msg.timeNs = 1_700_000_000_123_456_000;
    assert(msg.timestampSeconds == 1_700_000_000);
    assert(msg.timestampMicroseconds == 123_456);
}

@("DLT accessors: messageId can be assigned like a member")
unittest
{
    LogMessage!wchar msg;
    msg.messageId = 19;
    assert(msg.messageId == 19);
    assert(msg.number(DltField.MessageId) == 19);
}
