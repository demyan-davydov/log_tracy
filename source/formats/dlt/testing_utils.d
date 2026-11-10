//! Builders of DLT records for the unittests of the DLT format and of the
//! modules that need DLT data, and for the log generator (formats/generator):
//! a record of version 1 or 2 built field by field, and a test file of
//! dlt-viewer. Not in the program: only in unittests and with -d-version=LogGenerator.
module formats.dlt.testing_utils;

version (unittest)
    version = DltBuilders;
else version (LogGenerator)
    version = DltBuilders;

version (DltBuilders):

import formats.dlt.protocol;
import formats.dlt.header_v2 : ContentInfo, HeaderTypeV2, baseHeaderV2Size;

//! `value` in the byte order of a message
ubyte[] bytesOf(T)(T value, bool msbf = true)
{
    import std.bitmanip : nativeToBigEndian, nativeToLittleEndian;

    return msbf ? nativeToBigEndian(value).dup : nativeToLittleEndian(value).dup;
}

//! A verbose argument: its type info, then its body as given
ubyte[] argument(uint typeInfo, const(ubyte)[] body, bool msbf = true)
{
    return bytesOf(typeInfo, msbf) ~ body;
}

//! A record of version 1 built field by field: every header field under control
struct BuildV1
{
    bool storage = true;
    char[4] storageEcu = "STOR";
    uint storageSeconds = 1000;
    uint storageMicroseconds;
    ubyte protocolVersion = 1;
    bool msbf = true;
    ubyte counter;
    const(char)[] ecuId; // WEID when set
    bool withSessionId;
    uint sessionId;
    bool withTimestamp;
    uint timestamp;
    bool extended = true;
    bool verbose = true;
    ubyte type = MessageType.Log;
    ubyte typeInfo = LogLevel.Info; // MTIN
    ubyte numberOfArguments;
    char[4] appId = "APP1";
    char[4] ctxId = "CTX1";
    const(ubyte)[] payload;
    int length = -1; // of the standard header; -1: computed

    ubyte[] bytes() const
    {
        ubyte htyp = cast(ubyte)(protocolVersion << 5);
        ubyte[] rest;
        if (extended)
            htyp |= StandardHeader.Type.UseExtendedHeader;
        if (msbf)
            htyp |= StandardHeader.Type.MostSignificantByteFirst;
        if (ecuId !is null)
        {
            htyp |= StandardHeader.Type.WithEcuId;
            char[4] id = 0;
            id[0 .. ecuId.length] = ecuId;
            rest ~= cast(const(ubyte)[]) id[];
        }
        if (withSessionId)
        {
            htyp |= StandardHeader.Type.WithSessionId;
            rest ~= bytesOf(sessionId, true); // always big-endian
        }
        if (withTimestamp)
        {
            htyp |= StandardHeader.Type.WithTimestamp;
            rest ~= bytesOf(timestamp, true);
        }
        if (extended)
        {
            rest ~= cast(ubyte)((verbose ? 1 : 0) | (type & 0x07) << 1 | (typeInfo & 0x0F) << 4);
            rest ~= numberOfArguments;
            rest ~= cast(const(ubyte)[]) appId[];
            rest ~= cast(const(ubyte)[]) ctxId[];
        }
        rest ~= payload;

        ubyte[] result;
        if (storage)
        {
            result ~= DLT_PATTERN[];
            result ~= bytesOf(storageSeconds, false);
            result ~= bytesOf(storageMicroseconds, false);
            result ~= cast(const(ubyte)[]) storageEcu[];
        }
        result ~= htyp;
        result ~= counter;
        result ~= bytesOf(cast(ushort)(length >= 0 ? length : 4 + rest.length), true);
        return result ~ rest;
    }
}

/// A minimal record: storage header, standard header of type `headerType`
/// as it is (its flags announce fields the record doesn't have: a broken
/// record), then `payload`
ubyte[] buildDltMessage(const(char)[4] ecuId = "ECU1", uint seconds = 1000, uint microseconds = 500,
    ubyte headerType = 0, ubyte messageCounter = 0, const(ubyte)[] payload = [])
{
    BuildV1 r;
    r.storageEcu = ecuId;
    r.storageSeconds = seconds;
    r.storageMicroseconds = microseconds;
    r.protocolVersion = 0;
    r.msbf = false;
    r.extended = false;
    r.counter = messageCounter;
    r.payload = payload;
    auto bytes = r.bytes();
    bytes[StorageHeader.sizeof] = headerType;
    return bytes;
}

//! A storage header of version 2
ubyte[] storageV2(const(char)[] ecuId, ulong seconds, uint nanoseconds)
{
    ubyte[] bytes = cast(ubyte[]) "DLT\x02".dup;
    bytes ~= bytesOf(nanoseconds, false);
    bytes ~= bytesOf(seconds, false)[0 .. 5];
    bytes ~= cast(ubyte) ecuId.length;
    return bytes ~ cast(const(ubyte)[]) ecuId;
}

//! testfile.dlt of the dlt-viewer tests (qdlt/tests): a verbose message
//! without storage header, "Start logging after ECU startup"
static immutable ubyte[] dltViewerTestFile = cast(immutable ubyte[]) x"
    4C000000 01004741 01B41E87 AC000000
    00020445 43553104 6C6F6764 04524255
    46008200 00200053 74617274 206C6F67
    67696E67 20616674 65722045 43552073
    74617274 757000
";

//! A version 2 header built field by field
struct BuildV2
{
    ContentInfo content = ContentInfo.Verbose;
    ubyte counter;
    ubyte messageInfo = 0x41; // verbose log info
    ubyte numberOfArguments;
    ulong seconds;
    uint nanoseconds; // with bit 31 for a time since startup
    uint messageId;
    const(char)[] ecuId; // WEID when set
    const(char)[] appId; // WACID when set
    const(char)[] ctxId;
    bool withSessionId;
    uint sessionId;
    const(char)[] sourceFile; // WSFLN when set
    uint lineNumber;
    const(char)[][] tags; // WTGS when set
    bool withPrivacyLevel;
    ubyte privacyLevel;
    const(ubyte)[] segmentation; // WSGM when set: frame type and data, without the length
    const(ubyte)[] payload;
    int length = -1; // LEN; -1: computed

    ubyte[] bytes() const
    {
        import std.bitmanip : nativeToBigEndian;

        uint htyp = 2 << 5 | content;
        ubyte[] rest;
        if (content != ContentInfo.NonVerbose)
            rest ~= [messageInfo, numberOfArguments];
        if (content != ContentInfo.Control)
        {
            rest ~= nativeToBigEndian(nanoseconds)[];
            rest ~= nativeToBigEndian(seconds)[3 .. 8];
        }
        if (content == ContentInfo.NonVerbose)
            rest ~= nativeToBigEndian(messageId)[];

        void text(const(char)[] s)
        {
            rest ~= cast(ubyte) s.length;
            rest ~= cast(const(ubyte)[]) s;
        }

        if (ecuId !is null)
        {
            htyp |= HeaderTypeV2.WithEcuId;
            text(ecuId);
        }
        if (appId !is null)
        {
            htyp |= HeaderTypeV2.WithAppContextId;
            text(appId);
            text(ctxId);
        }
        if (withSessionId)
        {
            htyp |= HeaderTypeV2.WithSessionId;
            rest ~= nativeToBigEndian(sessionId)[];
        }
        if (sourceFile !is null)
        {
            htyp |= HeaderTypeV2.WithSourceFileName;
            text(sourceFile);
            rest ~= nativeToBigEndian(lineNumber)[];
        }
        if (tags !is null)
        {
            htyp |= HeaderTypeV2.WithTags;
            rest ~= cast(ubyte) tags.length;
            foreach (tag; tags)
                text(tag);
        }
        if (withPrivacyLevel)
        {
            htyp |= HeaderTypeV2.WithPrivacyLevel;
            rest ~= privacyLevel;
        }
        if (segmentation !is null)
        {
            htyp |= HeaderTypeV2.WithSegmentation;
            rest ~= cast(ubyte)(segmentation.length - 1);
            rest ~= segmentation;
        }
        rest ~= payload;

        ubyte[] result;
        result ~= [cast(ubyte) htyp, cast(ubyte)(htyp >> 8), cast(ubyte)(htyp >> 16), cast(ubyte)(htyp >> 24)];
        result ~= counter;
        result ~= nativeToBigEndian(cast(ushort)(length >= 0 ? length : baseHeaderV2Size + rest.length))[];
        return result ~ rest;
    }
}
