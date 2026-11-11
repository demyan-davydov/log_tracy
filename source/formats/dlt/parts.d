//! The numbered parts of a DLT message: a writer that cuts a long text into verbose
//! messages of one string argument "<k>/<n>: <text>" each (not a segmentation of the
//! protocol). Tells what a record is as a part (dltPartOf) and decodes the parts of a
//! message as one record (parseDltParts), for DltFormat as a PartedFormat.
module formats.dlt.parts;

import formats.dlt.fields;
import formats.dlt.header_v2 : ContentInfo, HeaderTypeV2, HeaderV2, HeaderV2Status, baseHeaderV2Size,
    protocolVersion, readHeaderV2;
import formats.dlt.parser : ArgumentKind, LogItemHeaders, VerboseArgument, ecuIdOf, findHeaders,
    parseDltItem, readArgument;
import formats.dlt.protocol;

import log_core.log_format : RecordPart;
import log_core.log_message : LogMessage;

import std.traits : isSomeChar;

//! @returns what the record at the start of `data` (whole, as DltFormat.scanRecords
//! found it; the bytes after it may follow) is as a part of a message: not a part,
//! RecordPart.init
RecordPart dltPartOf(const(ubyte)[] data, bool hasStorageHeader) nothrow @nogc
{
    PartText part;
    return readPart(data, hasStorageHeader, part) ? part.part : RecordPart.init;
}

//! @returns false if the record at the start of `data` is surely not a part, by a look
//! at a few of its bytes; true for every part (dltPartOf tells)
bool dltMayBePart(const(ubyte)[] data, bool hasStorageHeader) pure nothrow @nogc
{
    size_t storage = 0;
    if (hasStorageHeader)
        storage = data.length < StorageHeader.sizeof ? 0 : data[3] == 1 ? StorageHeader.sizeof : 14 + data[13];
    if (storage >= data.length)
        return false;
    const message = data[storage .. $];
    const version_ = protocolVersion(message);
    return version_ <= 1 ? mayBePartV1(message) : version_ == 2 && mayBePartV2(message);
}

//! @brief Decodes the parts of one message (records as DltFormat.recordAt gives them,
//! the first one first) into one record: the fields of the first part, the texts of all
//! without their numbers. A part that can't be read leaves the first one as it is.
//! @returns false if the first part is not a valid record
bool parseDltParts(Char)(ref LogMessage!Char msg, const(ubyte[])[] parts, bool hasStorageHeader) nothrow @nogc
        if (isSomeChar!Char)
{
    if (!parseDltItem(msg, parts[0], hasStorageHeader))
        return false;
    if (appendTexts(msg.payloadBuilder(), parts, hasStorageHeader)) // over the text of the first part
        return true;
    // Rare (a lost file): the first part as it is, decoded again
    return parseDltItem(msg, parts[0], hasStorageHeader);
}

//! @brief Appends the texts of the parts, without their numbers, joined
//! @returns false if a part can't be read: the payload is then of no use
private bool appendTexts(Builder)(Builder builder, const(ubyte[])[] parts, bool hasStorageHeader) nothrow @nogc
{
    // A UTF-8 character the writer cut between two parts: its bytes in the part before
    char[4] cut;
    size_t cutLength = 0;
    void flushCut()
    {
        if (cutLength != 0)
            builder.appendUtf8(cut[0 .. cutLength], false);
        cutLength = 0;
    }

    PartText part;
    foreach (record; parts)
    {
        if (!readPart(record, hasStorageHeader, part))
            return false;
        const(char)[] text = part.text;
        if (!part.utf8)
        {
            flushCut();
            builder.appendAscii(text, false);
            continue;
        }
        if (cutLength != 0)
        {
            // Its rest: the continuation bytes the next part starts with
            size_t i = 0;
            while (i < text.length && cutLength < cut.length && (text[i] & 0xC0) == 0x80)
                cut[cutLength++] = text[i++];
            text = text[i .. $];
            flushCut();
        }
        const whole = text.length - cutTail(text);
        builder.appendUtf8(text[0 .. whole], false);
        foreach (c; text[whole .. $])
            cut[cutLength++] = c;
    }
    flushCut();
    return true;
}

//! A part and its text after the number
private struct PartText
{
    RecordPart part;
    const(char)[] text;
    bool utf8; // the text is UTF-8, else ASCII
}

//! @brief Reads the record at the start of `record` (the bytes after it may follow) as a
//! part of a message
//! @returns false if it isn't one: not a verbose record of one string argument "k/n: "
private bool readPart(const(ubyte)[] record, bool hasStorageHeader, out PartText part) nothrow @nogc
{
    StorageInfo storage;
    const(ubyte)[] message = record;
    if (hasStorageHeader)
    {
        storage = readStorageHeader(record);
        if (storage.size == 0)
            return false;
        message = record[storage.size .. $];
    }

    const(char)[] ecuId, appId, ctxId;
    LogItemHeaders headers; // its ECU is sliced: it lives as long as the IDs are used
    const(ubyte)[] payload;
    uint arguments;
    ubyte counter;
    bool msbf;
    const version_ = protocolVersion(message);
    if (version_ == 2)
    {
        HeaderV2 h;
        if (readHeaderV2(message, h) != HeaderV2Status.ok || h.content != ContentInfo.Verbose
            || h.segmented || !h.hasAppContextId || h.length > message.length)
            return false;
        if (hasStorageHeader && !endsAtHeader(message[h.length .. $]))
            return false;
        ecuId = ecuIdOf(h, storage);
        appId = h.appId;
        ctxId = h.ctxId;
        payload = message[h.size .. h.length];
        arguments = h.numberOfArguments;
        counter = h.counter;
        msbf = false; // as the parser reads version 2
    }
    else if (version_ <= 1)
    {
        if (!mayBePartV1(message))
            return false;
        const length = (cast(const(StandardHeader)*) message.ptr).nativeLength;
        if (length > message.length || hasStorageHeader && !endsAtHeader(message[length .. $]))
            return false;
        headers = findHeaders(message[0 .. length]);
        if (headers.standard is null || headers.extended is null || !headers.extended.messageInfo.isVerbose)
            return false;
        ecuId = ecuIdOf(headers, storage);
        appId = cast(const(char)[]) headers.extended.applicationId[];
        ctxId = cast(const(char)[]) headers.extended.contextId[];
        payload = headers.payload;
        arguments = headers.extended.numberOfArguments;
        counter = headers.standard.messageCounter;
        msbf = headers.standard.isBigEndian();
    }
    else
        return false;

    VerboseArgument argument;
    if (arguments != 1 || !readArgument(payload, msbf, argument) || argument.kind != ArgumentKind.String)
        return false;
    part.text = argument.text;
    part.utf8 = argument.utf8;
    if (!takeNumber(part.text, part.part.number, part.part.count))
        return false;
    part.part.sender = senderOf(removeIdPadding(ecuId), removeIdPadding(appId), removeIdPadding(ctxId));
    part.part.counter = counter;
    part.part.nextCounter = cast(ubyte)(counter + 1);
    return true;
}

//! @returns true if the bytes after a record, by its length, start with a storage header
//! (or what may be the start of one) or are none: a length too long, which DltFormat cuts
//! at the next header inside the record, is not trusted with a part
private bool endsAtHeader(const(ubyte)[] after) pure nothrow @nogc
{
    return after.length >= DLT_PATTERN.length ? startsWithStoragePattern(after)
        : after == DLT_PATTERN[0 .. after.length];
}

//! @returns false if the version 2 message at the start of `message` is surely not a
//! part, by a walk over its header to the first bytes of its argument: asked of every
//! record as the offset index grows, cheaper than readHeaderV2
private bool mayBePartV2(const(ubyte)[] message) pure nothrow @nogc
{
    import std.bitmanip : littleEndianToNative;

    alias T = HeaderTypeV2;
    // HTYP2, MCNT, LEN, then MSIN and NOAR of a verbose message
    if (message.length < baseHeaderV2Size + 2)
        return false;
    const htyp = littleEndianToNative!uint(message[0 .. 4]);
    if ((htyp & T.ContentMask) != ContentInfo.Verbose || !(htyp & T.WithAppContextId)
        || (htyp & T.WithSegmentation) || message[baseHeaderV2Size + 1] != 1)
        return false;

    size_t p = baseHeaderV2Size + 2 + 9; // the time stamp of a verbose message
    bool skipText() // a length, then the text
    {
        if (p >= message.length)
            return false;
        p += 1 + message[p];
        return true;
    }

    if ((htyp & T.WithEcuId) && !skipText())
        return false;
    if (!skipText() || !skipText()) // APID, CTID
        return false;
    if (htyp & T.WithSessionId)
        p += 4;
    if (htyp & T.WithSourceFileName)
    {
        if (!skipText())
            return false;
        p += 4;
    }
    if (htyp & T.WithTags)
    {
        if (p >= message.length)
            return false;
        const tags = message[p++];
        foreach (_; 0 .. tags)
            if (!skipText())
                return false;
    }
    if (htyp & T.WithPrivacyLevel)
        p += 1;

    // The type info (little-endian), the length, a digit
    if (p + 7 > message.length)
        return false;
    const typeInfo = readValue!uint(message[p .. p + 4], false);
    if (!(typeInfo & TypeInfoFlags.TypeString))
        return false;
    if (typeInfo & TypeInfoFlags.VariableInfo)
        return true; // the name comes first: left to readPart
    const c = message[p + 6];
    return c >= '0' && c <= '9';
}

//! @returns false if the version 1 message at the start of `message` is surely not a
//! part, by a look at a few bytes: asked of every record as the offset index grows
private bool mayBePartV1(const(ubyte)[] message) pure nothrow @nogc
{
    alias T = StandardHeader.Type;
    if (message.length < StandardHeader.sizeof)
        return false;
    const htyp = message[0];
    if (!(htyp & T.UseExtendedHeader))
        return false;
    const p = StandardHeader.sizeof + (htyp & T.WithEcuId ? 4 : 0)
        + (htyp & T.WithSessionId ? 4 : 0) + (htyp & T.WithTimestamp ? 4 : 0);
    // The extended header (MSIN, NOAR, APID, CTID), the type info, the length, a digit
    enum extended = 10, text = extended + 4 + 2;
    if (message.length <= p + text || !(message[p] & 1) || message[p + 1] != 1)
        return false; // not verbose, not one argument
    const typeInfo = readValue!uint(message[p + extended .. p + extended + 4], (htyp & T.MostSignificantByteFirst) != 0);
    if (typeInfo & TypeInfoFlags.VariableInfo)
        return true; // the name comes first: left to readPart
    const c = message[p + text];
    return (typeInfo & TypeInfoFlags.TypeString) && c >= '0' && c <= '9';
}

//! @brief Takes the number "<k>/<n>: " off the start of `text`: 1 <= k <= n, at most
//! 4 digits each
//! @returns false, `text` as it was, if it doesn't start with one
private bool takeNumber(ref const(char)[] text, out uint number, out uint count) pure nothrow @nogc
{
    const(char)[] s = text;
    bool takeDigits(out uint value)
    {
        size_t n = 0;
        while (n < s.length && n < 5 && s[n] >= '0' && s[n] <= '9')
            value = value * 10 + (s[n++] - '0');
        s = s[n .. $];
        return n >= 1 && n <= 4;
    }

    if (!takeDigits(number) || s.length == 0 || s[0] != '/')
        return false;
    s = s[1 .. $];
    if (!takeDigits(count) || s.length < 2 || s[0 .. 2] != ": ")
        return false;
    if (number == 0 || number > count)
        return false;
    text = s[2 .. $];
    return true;
}

//! The sender of a part: its ECU, application and context. An ID of version 2 longer
//! than 4 characters is told apart by a hash of the three
private ubyte[16] senderOf(const(char)[] ecuId, const(char)[] appId, const(char)[] ctxId) pure nothrow @nogc
{
    ubyte[16] sender;
    uint hash = 2_166_136_261; // FNV-1a
    foreach (i, id; [ecuId, appId, ctxId])
    {
        foreach (j, c; id)
        {
            if (j < 4)
                sender[i * 4 + j] = c;
            hash = (hash ^ c) * 16_777_619;
        }
        hash = (hash ^ 0) * 16_777_619; // "AB"+"C" apart from "A"+"BC"
    }
    sender[12 .. 16] = (cast(ubyte*)&hash)[0 .. 4];
    return sender;
}

//! @returns how many bytes at the end of `text` are a UTF-8 character cut short
private size_t cutTail(const(char)[] text) pure nothrow @nogc
{
    // The lead byte of the last character, at most 3 bytes back
    foreach (back; 1 .. 4)
    {
        if (back > text.length)
            return 0;
        const ubyte b = text[$ - back];
        if ((b & 0xC0) == 0x80)
            continue; // a continuation byte
        const size_t need = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1;
        return need > back ? back : 0;
    }
    return 0;
}

version (unittest)
{
    import formats.dlt.testing_utils;

    //! A verbose record of version 1 of one string argument
    private ubyte[] textRecord(string text, ubyte counter = 0, bool utf8 = false,
        char[4] appId = "APP1", bool msbf = true)
    {
        BuildV1 r;
        r.msbf = msbf;
        r.counter = counter;
        r.appId = appId;
        r.numberOfArguments = 1;
        r.payload = argument(0x200 | (utf8 ? 0x8000 : 0), bytesOf(cast(ushort)(text.length + 1), msbf)
            ~ cast(const(ubyte)[]) text ~ cast(ubyte) 0, msbf);
        return r.bytes();
    }

    private string payloadOf(const(ubyte[])[] parts...)
    {
        import std.conv : to;

        LogMessage!wchar msg;
        assert(parseDltParts(msg, parts, true));
        return msg.payloadText.to!string;
    }
}

@("dltPartOf: a verbose record of one string argument numbered k/n is a part")
unittest
{
    const part = dltPartOf(textRecord("2/3: the middle", 41), true);
    assert(part.isPart && part.number == 2 && part.count == 3);
    assert(part.counter == 41 && part.nextCounter == 42);
    assert(dltPartOf(textRecord("1/2: x", 255), true).nextCounter == 0, "the counter is 8 bits");
    assert(dltPartOf(textRecord("10/12: x", 0, false, "APP1", false), true).number == 10, "little-endian");

    assert(dltPartOf(textRecord("1/2: x", 0, false, "APP1"), true).sender
        != dltPartOf(textRecord("1/2: x", 0, false, "APP2"), true).sender, "senders apart");
    assert(dltPartOf(textRecord("1/2: x", 0), true).sender == dltPartOf(textRecord("2/2: y", 1), true).sender);
}

@("dltPartOf: the sender takes the ECU of the message over the one of the storage")
unittest
{
    RecordPart withEcu(string ecuId)
    {
        BuildV1 r;
        r.ecuId = ecuId;
        r.numberOfArguments = 1;
        r.payload = argument(0x200, bytesOf(cast(ushort) 6) ~ cast(ubyte[]) "1/2: x".dup);
        return dltPartOf(r.bytes(), true);
    }

    assert(withEcu("E1").isPart && withEcu("E1").sender != withEcu("E2").sender);
}

@("dltPartOf: a string argument with a name may be a part")
unittest
{
    // VARI: the length of the value, of the name, the name, then the value
    BuildV1 r;
    r.numberOfArguments = 1;
    r.payload = argument(0x200 | 0x800, bytesOf(cast(ushort) 6) ~ bytesOf(cast(ushort) 4)
        ~ cast(ubyte[]) "name".dup ~ cast(ubyte[]) "2/3: x".dup);
    const part = dltPartOf(r.bytes(), true);
    assert(part.isPart && part.number == 2 && part.count == 3);
}

@("dltMayBePart: every part may be one, most other records surely are not")
unittest
{
    foreach (text; ["1/2: x", "2/2: y", "10/12: z"])
        assert(dltMayBePart(textRecord(text), true), text);
    assert(!dltMayBePart(textRecord("a text"), true));

    BuildV1 nonVerbose;
    nonVerbose.verbose = false;
    nonVerbose.payload = bytesOf(5u) ~ cast(ubyte[]) "1/2: x".dup;
    assert(!dltMayBePart(nonVerbose.bytes(), true));

    BuildV2 v2;
    v2.ecuId = "ECU";
    v2.appId = "APP";
    v2.ctxId = "CTX";
    v2.numberOfArguments = 1;
    v2.payload = argument(0x200, bytesOf(cast(ushort) 6, false) ~ cast(ubyte[]) "1/2: x".dup, false);
    assert(dltMayBePart(storageV2("ECU", 1, 0) ~ v2.bytes(), true));
    assert(!dltMayBePart(null, true));
}

@("dltPartOf: other records are not parts")
unittest
{
    foreach (text; ["a text", "1/2 x", "1/2:x", "0/2: x", "3/2: x", "/2: x", "1/: x", "12345/99999: x", ""])
        assert(!dltPartOf(textRecord(text), true).isPart, text);

    BuildV1 two;
    two.numberOfArguments = 2;
    two.payload = argument(0x200, bytesOf(cast(ushort) 7) ~ cast(ubyte[]) "1/2: x\0".dup)
        ~ argument(0x200, bytesOf(cast(ushort) 2) ~ cast(ubyte[]) "y\0".dup);
    assert(!dltPartOf(two.bytes(), true).isPart, "more than one argument");

    BuildV1 nonVerbose;
    nonVerbose.verbose = false;
    nonVerbose.payload = bytesOf(5u) ~ cast(ubyte[]) "1/2: x".dup;
    assert(!dltPartOf(nonVerbose.bytes(), true).isPart);

    assert(!dltPartOf(null, true).isPart && !dltPartOf(textRecord("1/2: x")[0 .. 20], true).isPart);
}

@("dltPartOf: the record ends at its own length, whatever bytes follow it")
unittest
{
    const next = textRecord("2/2: next", 1);
    assert(dltPartOf(textRecord("1/2: x", 0) ~ next, true).number == 1);

    // A string longer than its record: the bytes after it are the next record's
    BuildV1 r;
    r.numberOfArguments = 1;
    r.payload = argument(0x200, bytesOf(cast(ushort)(6 + next.length)) ~ cast(ubyte[]) "1/2: x".dup);
    assert(!dltPartOf(r.bytes() ~ next, true).isPart);

    // A length too long, into the next record: the record DltFormat.recordAt cuts at the
    // next header is not a part, the record with its length isn't either
    BuildV1 broken;
    broken.numberOfArguments = 1;
    broken.payload = argument(0x200, bytesOf(cast(ushort) 6) ~ cast(ubyte[]) "1/2: x".dup);
    broken.length = cast(int)(broken.bytes().length - StorageHeader.sizeof + 5);
    assert(!dltPartOf(broken.bytes() ~ next, true).isPart);
}

@("dltPartOf: a record of version 2 may be a part")
unittest
{
    BuildV2 r;
    r.ecuId = "ECU";
    r.appId = "APP";
    r.ctxId = "CTX";
    r.counter = 9;
    r.numberOfArguments = 1;
    r.payload = argument(0x200, bytesOf(cast(ushort) 6, false) ~ cast(ubyte[]) "1/2: x".dup, false);
    const part = dltPartOf(storageV2("ECU", 1, 0) ~ r.bytes(), true);
    assert(part.isPart && part.number == 1 && part.count == 2 && part.counter == 9);
}

@("dltPartOf: a part of version 2 with every optional field of the header")
unittest
{
    BuildV2 r;
    r.ecuId = "ECU";
    r.appId = "APPLICATION";
    r.ctxId = "C";
    r.withSessionId = true;
    r.sessionId = 3;
    r.sourceFile = "main.cpp";
    r.lineNumber = 42;
    r.tags = ["one", "two"];
    r.withPrivacyLevel = true;
    r.privacyLevel = 1;
    r.numberOfArguments = 1;
    r.payload = argument(0x200, bytesOf(cast(ushort) 6, false) ~ cast(ubyte[]) "2/2: x".dup, false);
    const part = dltPartOf(storageV2("ECU", 1, 0) ~ r.bytes(), true);
    assert(part.isPart && part.number == 2 && part.count == 2);
    assert(dltMayBePart(storageV2("ECU", 1, 0) ~ r.bytes(), true), "the walk over the header");

    r.payload = argument(0x200, bytesOf(cast(ushort) 6, false) ~ cast(ubyte[]) "a text".dup, false);
    assert(!dltPartOf(storageV2("ECU", 1, 0) ~ r.bytes(), true).isPart);
}

@("parseDltParts: the texts of the parts without their numbers, the fields of the first one")
unittest
{
    LogMessage!wchar msg;
    const(ubyte[])[] parts = [textRecord("1/3: one ", 7), textRecord("2/3: two ", 8), textRecord("3/3: three", 9)];
    assert(parseDltParts(msg, parts, true));
    assert(msg.payloadText == "one two three"w);
    assert(msg.counter == 7 && msg.appId == "APP1"w);
}

@("parseDltParts: a UTF-8 character cut between two parts is joined whole")
unittest
{
    const text = "даль";
    const a = textRecord("1/2: " ~ text[0 .. 3], 0, true); // "д" and half of "а"
    const b = textRecord("2/2: " ~ text[3 .. $], 1, true);
    assert(payloadOf(a, b) == "даль");
}

@("parseDltParts: a UTF-8 character cut before an ASCII part keeps its place")
unittest
{
    const a = textRecord("1/2: a" ~ "д"[0 .. 1], 0, true);
    const b = textRecord("2/2: bc", 1, false);
    assert(payloadOf(a, b) == "a?bc");
}

@("parseDltParts: a part that can't be read leaves the first part as it is")
unittest
{
    const first = textRecord("1/2: one", 0);
    assert(payloadOf(first, cast(const(ubyte)[]) null) == "1/2: one");
    assert(payloadOf(first, textRecord("a text", 1)) == "1/2: one");
}
