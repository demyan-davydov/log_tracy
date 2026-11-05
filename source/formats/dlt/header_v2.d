module formats.dlt.header_v2;

//! The header of a DLT message of protocol version 2 (AUTOSAR R20-11), read
//! the way dlt-viewer reads it (QDltMsg::setMsg). Every field but the base
//! header is optional, the flags of HTYP2 say which are present:
//!
//! HTYP2 (4, little-endian) MCNT (1) LEN (2, big-endian)
//! [MSIN (1) NOAR (1)]                      verbose and control messages
//! [TMSP: nanoseconds (4) seconds (5)]      verbose and non-verbose, big-endian
//! [MSID (4, big-endian)]                   non-verbose messages
//! [ECU: length (1) + ID]                   WEID
//! [APID, CTID: length (1) + ID each]       WACID
//! [SEID (4, big-endian)]                   WSID
//! [file name: length (1) + name, line (4)] WSFLN
//! [tags: count (1), length (1) + tag each] WTGS
//! [privacy level (1)]                      WPVL
//! [segmentation: length (1), frame type (1), frame data] WSGM
//! The payload follows, little-endian.

import formats.dlt.protocol : MessageInfo;

//! What a message carries (CNTI)
enum ContentInfo : ubyte
{
    Verbose = 0,
    NonVerbose = 1,
    Control = 2,
}

//! The frame of a segmented message
enum SegmentFrame : ubyte
{
    First = 0, // carries the total length
    Consecutive = 1, // carries its number
    Last = 2,
    Abort = 3, // carries the reason
}

//! The size of the base header: HTYP2, MCNT, LEN
enum size_t baseHeaderV2Size = 7;

//! HTYP2 flags
enum HeaderTypeV2 : uint
{
    ContentMask = 0x03,
    WithEcuId = 0x04,
    WithAppContextId = 0x08,
    WithSessionId = 0x10,
    VersionMask = 0xE0,
    WithSourceFileName = 0x0100,
    WithTags = 0x0200,
    WithPrivacyLevel = 0x0400,
    WithSegmentation = 0x0800,
}

struct HeaderV2
{
    size_t size; // of the whole header, the payload follows
    ubyte counter;
    ushort length; // of the message: header and payload
    ContentInfo content;

    bool hasMessageInfo; // verbose and control messages
    MessageInfo messageInfo;
    ubyte numberOfArguments;

    bool hasTimestamp; // verbose and non-verbose messages
    ulong seconds; // 40 bits
    uint nanoseconds; // without the flag of bit 31
    bool sinceStartup; // bit 31 of the nanoseconds: time since the ECU started, not UTC

    bool hasMessageId; // non-verbose messages
    uint messageId;

    bool hasEcuId;
    const(char)[] ecuId;

    bool hasAppContextId;
    const(char)[] appId;
    const(char)[] ctxId;

    bool hasSessionId;
    uint sessionId;

    bool hasSourceFile;
    const(char)[] sourceFile;
    uint lineNumber;

    ubyte tagCount; // the tags themselves are skipped

    bool hasPrivacyLevel;
    ubyte privacyLevel;

    bool segmented;
    SegmentFrame segmentFrame;
    ulong segmentTotalLength; // First
    uint segmentNumber; // Consecutive
    ubyte segmentAbortReason; // Abort
}

//! What readHeaderV2() found
enum HeaderV2Status : ubyte
{
    ok,
    cut, // the header doesn't fit in the data or in its own length
    reserved, // the header uses a reserved value: its content is unknown
}

//! @returns the protocol version of the standard header at the start of
//! `data` (the bits 5-7 of the first byte in both versions), 0 if empty
ubyte protocolVersion(const(ubyte)[] data) pure nothrow @nogc
{
    return data.length == 0 ? 0 : (data[0] >> 5) & 0x07;
}

//! @returns the length (LEN) of the version 2 message at the start of `data`,
//! 0 if the base header is cut
ushort messageLengthV2(const(ubyte)[] data) pure nothrow @nogc
{
    if (data.length < baseHeaderV2Size)
        return 0;
    return cast(ushort)(data[5] << 8 | data[6]);
}

//! Reads the version 2 header at the start of `data` (no storage header).
//! @returns cut if the header ends after the data or its message, reserved if
//! it uses a reserved value
HeaderV2Status readHeaderV2(const(ubyte)[] data, out HeaderV2 header) pure nothrow @nogc
{
    import std.bitmanip : bigEndianToNative, littleEndianToNative;

    if (data.length < baseHeaderV2Size)
        return HeaderV2Status.cut;

    const uint htyp = littleEndianToNative!uint(data[0 .. 4]);
    const content = htyp & HeaderTypeV2.ContentMask;
    if (content > ContentInfo.Control)
        return HeaderV2Status.reserved;

    header.content = cast(ContentInfo) content;
    header.counter = data[4];
    header.length = messageLengthV2(data);

    if (header.length < baseHeaderV2Size)
        return HeaderV2Status.cut;
    // The header ends inside its message
    const(ubyte)[] optional = data[baseHeaderV2Size .. header.length <= data.length ? header.length : $];
    const(ubyte)[] p = optional;

    bool take(size_t count, out const(ubyte)[] bytes)
    {
        if (p.length < count)
            return false;
        bytes = p[0 .. count];
        p = p[count .. $];
        return true;
    }

    bool takeBigEndian(T)(out T value)
    {
        const(ubyte)[] bytes;
        if (!take(T.sizeof, bytes))
            return false;
        value = bigEndianToNative!T(bytes[0 .. T.sizeof]);
        return true;
    }

    // A text with its length in front
    bool takeText(out const(char)[] text)
    {
        ubyte length;
        const(ubyte)[] bytes;
        if (!takeBigEndian(length) || !take(length, bytes))
            return false;
        text = cast(const(char)[]) bytes;
        return true;
    }

    const(ubyte)[] bytes;

    if (header.content != ContentInfo.NonVerbose)
    {
        if (!take(2, bytes))
            return HeaderV2Status.cut;
        header.hasMessageInfo = true;
        header.messageInfo = MessageInfo(bytes[0]);
        header.numberOfArguments = bytes[1];
        if ((bytes[0] & MessageInfo.MessageTypeMask) >> 1 > 3)
            return HeaderV2Status.reserved; // reserved message type
    }

    if (header.content != ContentInfo.Control)
    {
        uint nanoseconds;
        if (!takeBigEndian(nanoseconds) || !take(5, bytes))
            return HeaderV2Status.cut;
        header.hasTimestamp = true;
        header.sinceStartup = (nanoseconds & 0x8000_0000) != 0;
        header.nanoseconds = nanoseconds & 0x7FFF_FFFF;
        foreach (b; bytes)
            header.seconds = header.seconds << 8 | b;
    }

    if (header.content == ContentInfo.NonVerbose)
    {
        if (!takeBigEndian(header.messageId))
            return HeaderV2Status.cut;
        header.hasMessageId = true;
    }

    if (htyp & HeaderTypeV2.WithEcuId)
    {
        if (!takeText(header.ecuId))
            return HeaderV2Status.cut;
        header.hasEcuId = true;
    }

    if (htyp & HeaderTypeV2.WithAppContextId)
    {
        if (!takeText(header.appId) || !takeText(header.ctxId))
            return HeaderV2Status.cut;
        header.hasAppContextId = true;
    }

    if (htyp & HeaderTypeV2.WithSessionId)
    {
        if (!takeBigEndian(header.sessionId))
            return HeaderV2Status.cut;
        header.hasSessionId = true;
    }

    if (htyp & HeaderTypeV2.WithSourceFileName)
    {
        if (!takeText(header.sourceFile) || !takeBigEndian(header.lineNumber))
            return HeaderV2Status.cut;
        header.hasSourceFile = true;
    }

    if (htyp & HeaderTypeV2.WithTags)
    {
        if (!takeBigEndian(header.tagCount))
            return HeaderV2Status.cut;
        foreach (_; 0 .. header.tagCount)
        {
            const(char)[] tag;
            if (!takeText(tag))
                return HeaderV2Status.cut;
        }
    }

    if (htyp & HeaderTypeV2.WithPrivacyLevel)
    {
        if (!takeBigEndian(header.privacyLevel))
            return HeaderV2Status.cut;
        header.hasPrivacyLevel = true;
    }

    if (htyp & HeaderTypeV2.WithSegmentation)
    {
        ubyte length, frame;
        if (!takeBigEndian(length) || !takeBigEndian(frame))
            return HeaderV2Status.cut;
        header.segmented = true;
        header.segmentFrame = cast(SegmentFrame) frame;
        switch (frame)
        {
        case SegmentFrame.First:
            if (!takeBigEndian(header.segmentTotalLength))
                return HeaderV2Status.cut;
            break;
        case SegmentFrame.Consecutive:
            if (!takeBigEndian(header.segmentNumber))
                return HeaderV2Status.cut;
            break;
        case SegmentFrame.Last:
            break;
        case SegmentFrame.Abort:
            if (!takeBigEndian(header.segmentAbortReason))
                return HeaderV2Status.cut;
            break;
        default:
            if (!take(length, bytes))
                return HeaderV2Status.cut;
            break;
        }
    }

    header.size = baseHeaderV2Size + (optional.length - p.length);
    return HeaderV2Status.ok;
}

// ─── Tests ──────────────────────────────────────────────────────────────────

version (unittest) import formats.dlt.testing_utils : BuildV2, dltViewerTestFile;

@("readHeaderV2: the test file of dlt-viewer")
unittest
{
    HeaderV2 h;
    assert(readHeaderV2(dltViewerTestFile, h) == HeaderV2Status.ok);
    assert(protocolVersion(dltViewerTestFile) == 2);
    assert(messageLengthV2(dltViewerTestFile) == 71);
    assert(h.length == 71 && h.size == 33, "71 bytes, 38 of them payload");
    assert(h.counter == 1);
    assert(h.content == ContentInfo.Verbose);
    assert(h.hasMessageInfo && h.messageInfo == 0x41 && h.numberOfArguments == 1);
    assert(h.hasTimestamp && h.sinceStartup);
    assert(h.seconds == 2 && h.nanoseconds == 0x341E87AC);
    assert(h.hasEcuId && h.ecuId == "ECU1");
    assert(h.hasAppContextId && h.appId == "logd" && h.ctxId == "RBUF");
    assert(!h.hasMessageId && !h.hasSessionId && !h.hasSourceFile && !h.segmented);
}

@("readHeaderV2: a non-verbose message has a timestamp and a message ID, no message info")
unittest
{
    BuildV2 b;
    b.content = ContentInfo.NonVerbose;
    b.seconds = 1_700_000_000;
    b.nanoseconds = 123;
    b.messageId = 0xDEADBEEF;
    b.payload = [1, 2];

    HeaderV2 h;
    assert(readHeaderV2(b.bytes(), h) == HeaderV2Status.ok);
    assert(h.content == ContentInfo.NonVerbose && !h.hasMessageInfo);
    assert(h.hasTimestamp && !h.sinceStartup && h.seconds == 1_700_000_000 && h.nanoseconds == 123);
    assert(h.hasMessageId && h.messageId == 0xDEADBEEF);
    assert(h.size == baseHeaderV2Size + 9 + 4 && h.length == h.size + 2);
}

@("readHeaderV2: a control message has message info, no timestamp")
unittest
{
    BuildV2 b;
    b.content = ContentInfo.Control;
    b.messageInfo = 0x26; // control response

    HeaderV2 h;
    assert(readHeaderV2(b.bytes(), h) == HeaderV2Status.ok);
    assert(h.content == ContentInfo.Control);
    assert(h.hasMessageInfo && h.messageInfo == 0x26);
    assert(!h.hasTimestamp && !h.hasMessageId);
    assert(h.size == baseHeaderV2Size + 2);
}

@("readHeaderV2: the optional fields in their order")
unittest
{
    BuildV2 b;
    b.ecuId = "ECU12"; // IDs are no longer limited to 4 characters
    b.appId = "APP";
    b.ctxId = "CONTEXT";
    b.withSessionId = true;
    b.sessionId = 77;
    b.sourceFile = "main.cpp";
    b.lineNumber = 42;
    b.tags = ["a", "bc"];
    b.withPrivacyLevel = true;
    b.privacyLevel = 3;

    HeaderV2 h;
    assert(readHeaderV2(b.bytes(), h) == HeaderV2Status.ok);
    assert(h.ecuId == "ECU12" && h.appId == "APP" && h.ctxId == "CONTEXT");
    assert(h.hasSessionId && h.sessionId == 77);
    assert(h.hasSourceFile && h.sourceFile == "main.cpp" && h.lineNumber == 42);
    assert(h.tagCount == 2);
    assert(h.hasPrivacyLevel && h.privacyLevel == 3);
    assert(h.size == b.bytes().length);
}

@("readHeaderV2: the frames of a segmented message")
unittest
{
    import std.bitmanip : nativeToBigEndian;

    HeaderV2 h;
    BuildV2 b;

    b.segmentation = [cast(ubyte) SegmentFrame.First] ~ nativeToBigEndian(1000UL)[];
    assert(readHeaderV2(b.bytes(), h) == HeaderV2Status.ok);
    assert(h.segmented && h.segmentFrame == SegmentFrame.First && h.segmentTotalLength == 1000);

    b.segmentation = [cast(ubyte) SegmentFrame.Consecutive] ~ nativeToBigEndian(5u)[];
    assert(readHeaderV2(b.bytes(), h) == HeaderV2Status.ok);
    assert(h.segmentFrame == SegmentFrame.Consecutive && h.segmentNumber == 5);

    b.segmentation = [cast(ubyte) SegmentFrame.Last];
    assert(readHeaderV2(b.bytes(), h) == HeaderV2Status.ok);
    assert(h.segmentFrame == SegmentFrame.Last);

    b.segmentation = [cast(ubyte) SegmentFrame.Abort, 9];
    assert(readHeaderV2(b.bytes(), h) == HeaderV2Status.ok);
    assert(h.segmentFrame == SegmentFrame.Abort && h.segmentAbortReason == 9);
    assert(h.size == b.bytes().length);
}

@("readHeaderV2: a cut, reserved or too long header is refused")
unittest
{
    HeaderV2 h;
    foreach (cut; 0 .. 33)
        assert(readHeaderV2(dltViewerTestFile[0 .. cut], h) == HeaderV2Status.cut, "cut header");
    assert(messageLengthV2(dltViewerTestFile[0 .. 6]) == 0);

    auto reserved = dltViewerTestFile.dup;
    reserved[0] |= 0x03; // CNTI 3
    assert(readHeaderV2(reserved, h) == HeaderV2Status.reserved);

    BuildV2 b;
    b.messageInfo = 4 << 1 | 1; // MSTP has 3 bits, 4..7 are reserved
    assert(readHeaderV2(b.bytes(), h) == HeaderV2Status.reserved, "reserved message type");

    BuildV2 short_;
    short_.ecuId = "ECU1";
    short_.length = baseHeaderV2Size + 2; // ends inside the header
    assert(readHeaderV2(short_.bytes(), h) == HeaderV2Status.cut, "LEN shorter than the header");
}
