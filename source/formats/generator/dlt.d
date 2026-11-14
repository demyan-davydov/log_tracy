//! The DLT records of the log generator, version 1 or 2, built by the builders of the tests
//! (formats/dlt/testing_utils), and the ways to break one. Not in the program: only in
//! unittests and with -d-version=LogGenerator.
module formats.generator.dlt;

version (unittest)
    version = LogGeneratorCode;
else version (LogGenerator)
    version = LogGeneratorCode;

version (LogGeneratorCode):

import formats.dlt.header_v2 : ContentInfo;
import formats.dlt.protocol : MessageType, StorageHeader, Tyle, TypeInfoFlags;
import formats.dlt.testing_utils : BuildV1, BuildV2, argument, bytesOf, storageV2;
import formats.generator.content : RecordContent, shortId;

//! @returns a DLT record of `r` with its storage header: version 2 for `v2`, else 1.
//! The time of the record is `timeUs` (the content's, or one moved by a corruption).
ubyte[] dltRecord(in RecordContent r, long timeUs, bool v2)
{
    const ecu = shortId('E', r.ecu);
    const app = shortId('A', r.app);
    const context = shortId('C', r.context);
    const seconds = timeUs / 1_000_000;
    const microseconds = cast(uint)(timeUs % 1_000_000);

    if (!v2)
    {
        BuildV1 b;
        b.storageEcu = ecu;
        b.storageSeconds = cast(uint) seconds;
        b.storageMicroseconds = microseconds;
        b.msbf = r.ecu % 2 == 0; // the ECUs differ in byte order, as real ones may
        b.counter = r.counter;
        b.ecuId = ecu[];
        b.withSessionId = true;
        b.sessionId = r.app + 1;
        b.withTimestamp = true;
        b.timestamp = cast(uint)(r.uptimeUs / 100); // 0.1 ms since the start of the ECU
        b.type = MessageType.Log;
        b.typeInfo = r.level;
        b.appId = app;
        b.ctxId = context;
        b.verbose = !r.nonVerbose;
        b.numberOfArguments = r.nonVerbose ? 0 : (r.withNumber ? 2 : 1);
        b.payload = payload(r, b.msbf, false);
        return b.bytes();
    }

    BuildV2 b;
    b.content = r.nonVerbose ? ContentInfo.NonVerbose : ContentInfo.Verbose;
    b.counter = r.counter;
    b.messageInfo = cast(ubyte)(1 | MessageType.Log << 1 | r.level << 4); // verbose
    b.numberOfArguments = r.withNumber ? 2 : 1;
    b.seconds = seconds;
    b.nanoseconds = microseconds * 1000;
    b.messageId = r.messageId;
    b.ecuId = ecu[];
    b.appId = app[];
    b.ctxId = context[];
    b.withSessionId = true;
    b.sessionId = r.app + 1;
    b.payload = payload(r, false, true); // version 2 payloads are read little-endian
    return storageV2(ecu[], seconds, microseconds * 1000) ~ b.bytes();
}

//! The verbose arguments of `r` (a UTF-8 text, maybe a number), or for a non-verbose
//! message its raw data, after its message ID in version 1 (version 2 has it in the header)
private ubyte[] payload(in RecordContent r, bool msbf, bool v2)
{
    const text = cast(const(ubyte)[]) r.text;
    if (r.nonVerbose)
    {
        const data = text[0 .. text.length < 16 ? text.length : 16];
        return v2 ? data.dup : bytesOf(r.messageId, msbf) ~ data;
    }
    auto result = argument(TypeInfoFlags.TypeString | TypeInfoFlags.StringCodingUTF8,
        bytesOf(cast(ushort)(text.length + 1), msbf) ~ text ~ cast(ubyte) 0, msbf);
    if (r.withNumber)
        result ~= argument(TypeInfoFlags.TypeUnsigned | Tyle.Tyle32Bit, bytesOf(r.number, msbf), msbf);
    return result;
}

//! @returns where the standard header of a record of dltRecord() starts
size_t standardHeaderAt(const(ubyte)[] record, bool v2) pure nothrow @nogc @safe
{
    return v2 ? 14 + record[13] : StorageHeader.sizeof; // the v2 storage header ends with its ECU ID
}

//! Breaks the header type: a protocol version that does not exist (7)
void breakHeaderType(ubyte[] record, bool v2) pure nothrow @nogc @safe
{
    const at = standardHeaderAt(record, v2);
    record[at] = cast(ubyte)((record[at] & 0x1F) | 7 << 5);
}

//! Sets the length of the standard header to `length`, whatever the record holds
void setLength(ubyte[] record, bool v2, ushort length) pure nothrow @nogc @safe
{
    const at = standardHeaderAt(record, v2) + (v2 ? 5 : 2); // after the header type and counter
    record[at] = cast(ubyte)(length >> 8);
    record[at + 1] = cast(ubyte) length;
}

//! @returns the length the standard header of a record of dltRecord() announces
ushort lengthOf(const(ubyte)[] record, bool v2) pure nothrow @nogc @safe
{
    const at = standardHeaderAt(record, v2) + (v2 ? 5 : 2);
    return cast(ushort)(record[at] << 8 | record[at + 1]);
}

@("dltRecord: the length of the standard header is that of the record without its storage header")
unittest
{
    RecordContent r;
    r.text = "hello".dup;
    foreach (v2; [false, true])
    {
        auto record = dltRecord(r, 1_767_225_600_000_000, v2);
        assert(lengthOf(record, v2) == record.length - standardHeaderAt(record, v2));
        setLength(record, v2, 3);
        assert(lengthOf(record, v2) == 3);
    }
}

@("dltRecord: a non-verbose message of version 2 has its ID in the header only, its data after it")
unittest
{
    RecordContent r;
    r.text = "raw data".dup;
    r.nonVerbose = true;
    r.messageId = 0x01020304;
    auto v1 = dltRecord(r, 0, false);
    assert(v1[$ - 12 .. $ - 8] == [1, 2, 3, 4] && v1[$ - 8 .. $] == cast(const(ubyte)[]) "raw data"); // the ID, big-endian
    auto v2 = dltRecord(r, 0, true);
    assert(v2[$ - 8 .. $] == cast(const(ubyte)[]) "raw data");
    assert(v2[$ - 12 .. $ - 8] != [4, 3, 2, 1] && v2[$ - 12 .. $ - 8] != [1, 2, 3, 4]);
}
