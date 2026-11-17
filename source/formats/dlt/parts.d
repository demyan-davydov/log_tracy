//! The parts of a DLT message its writer cut (not a segmentation of the protocol): into
//! verbose messages of one string argument "<k>/<n>: <text>" each, or with no mark into
//! pieces at a limit of its text (tellPiece). Tells what a record is as a part (dltPartOf)
//! and decodes the parts of a message as one record (parseDltParts), for DltFormat as a
//! PartedFormat.
module formats.dlt.parts;

import formats.dlt.fields;
import formats.dlt.header_v2 : ContentInfo, HeaderTypeV2, HeaderV2, HeaderV2Status, baseHeaderV2Size,
    protocolVersion, readHeaderV2;
import formats.dlt.parser : ArgumentKind, LogItemHeaders, VerboseArgument, VerboseStart, ecuIdOf, findHeaders,
    findVerboseStart, parseDltItem, readArgument, readMarkedAscii, storageSizeOf;
import formats.dlt.protocol;

import log_core.log_format : PieceKind, RecordPart;
import log_core.log_level : LogLevel;
import log_core.log_message : LogMessage;
import log_core.text_encoding : asciiLength, isUtf8, utf8CutTail;

import std.traits : isSomeChar;

//! The limits of a text its writers cut at, in bytes, the least first: a longer one goes
//! on in pieces. 1024, or 1023 and the zero after them (a buffer of 1024)
static immutable size_t[] dltPieceLimits = [1023, 1024];

//! @returns what the record at the start of `data` (whole, as DltFormat.scanRecords
//! found it; the bytes after it may follow) is as a part of a message (readPart): a
//! numbered part, a piece, another record of its writer; RecordPart.init if whose it is
//! is not known (not verbose, not readable)
RecordPart dltPartOf(const(ubyte)[] data, bool hasStorageHeader) nothrow @nogc
{
    PartText part;
    readPart(data, hasStorageHeader, part);
    return part.part;
}

//! @returns false if the record at the start of `data` is surely not a part, by a look
//! at a few of its bytes; true for every part (dltPartOf tells). The look of a record on
//! its own, for the tests: DltFormat.marksOf walks the header once for it and
//! dltMayBeTransfer (dltMayBePartAt)
bool dltMayBePart(const(ubyte)[] data, bool hasStorageHeader) pure nothrow @nogc
{
    const storage = hasStorageHeader ? storageSizeOf(data) : 0;
    if (storage >= data.length)
        return false;
    return mayBePartOf(data[storage .. $]);
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
    // Never completed, the cut is UTF-8 cut short ("?") if its part is surely UTF-8 (marked so,
    // or beyond ASCII before it: readMarkedAscii), else a character per byte
    bool cutUtf8;
    void flushCut()
    {
        if (cutLength != 0 && (cutUtf8 || isUtf8(cut[0 .. cutLength])))
            builder.appendUtf8(cut[0 .. cutLength], false);
        else if (cutLength != 0)
            builder.appendAscii(cut[0 .. cutLength], false);
        cutLength = 0;
    }

    PartText part;
    bool numbered;
    foreach (i, record; parts)
    {
        // The parts of one message: all numbered, or all pieces
        if (!readPart(record, hasStorageHeader, part) || i != 0 && part.part.isPart != numbered)
            return false;
        numbered = part.part.isPart;
        const(char)[] text = part.text;

        // The rest of the cut character: the continuation bytes it lacks, at the start
        size_t rest = 0;
        if (cutLength != 0)
        {
            const need = cut[0] >= 0xF0 ? 4 : cut[0] >= 0xE0 ? 3 : 2;
            while (rest < text.length && cutLength + rest < need && (text[rest] & 0xC0) == 0x80)
                ++rest;
        }
        bool beyondAscii = part.utf8;
        if (!part.utf8)
        {
            const after = text[rest .. $];
            const r = readMarkedAscii(after);
            if (!r.utf8)
            {
                flushCut();
                builder.appendAscii(text, false);
                continue;
            }
            beyondAscii = r.beyondAscii(after.length);
        }
        foreach (c; text[0 .. rest])
            cut[cutLength++] = c;
        text = text[rest .. $];
        flushCut();

        const whole = text.length - utf8CutTail(text);
        // Its start in ASCII as it is, in words (asciiLength): pieces are of long texts
        const ascii = asciiLength(text[0 .. whole]);
        builder.appendAscii(text[0 .. ascii], false);
        builder.appendUtf8(text[ascii .. whole], false);
        foreach (c; text[whole .. $])
            cut[cutLength++] = c;
        cutUtf8 = beyondAscii;
    }
    flushCut();

    // A message of pieces whose last one is cut: its text goes on beyond what came
    if (!numbered && part.part.piece == PieceKind.cut)
        builder.appendAscii(" [cut]", false);

    // A message whose last parts never came (PartJoiner closed it): how many it got
    if (part.part.number != part.part.count)
    {
        char[32] note;
        size_t length = 0;
        void add(const(char)[] piece)
        {
            note[length .. length + piece.length] = piece;
            length += piece.length;
        }
        void addNumber(uint value) // at most 4 digits: takeNumber
        {
            char[4] digits;
            size_t n = 0;
            do
            {
                digits[n++] = cast(char)('0' + value % 10);
                value /= 10;
            }
            while (value != 0);
            foreach_reverse (d; digits[0 .. n])
                note[length++] = d;
        }

        add(" [");
        addNumber(cast(uint) parts.length);
        add(" of ");
        addNumber(part.part.count);
        add(" parts]");
        builder.appendAscii(note[0 .. length], false);
    }
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
//! part of a message: a numbered part, a piece of a text cut at its writer's limit
//! (tellPiece), another record of its writer (PieceKind.other), RecordPart.init if whose
//! it is is not known
//! @returns true if it is a verbose record of one string argument: `part.text` is its
//! text, without its number if it is numbered
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
    long time = RecordPart.noTime;
    LogLevel level = LogLevel.None;
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
        long ns;
        if (h.hasTimestamp && toTimeNs(h.seconds, h.nanoseconds, ns))
            time = ns;
        if (h.hasMessageInfo)
            level = h.messageInfo.logLevel();
    }
    else if (version_ <= 1)
    {
        if (message.length < StandardHeader.sizeof)
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
        if (headers.standard.withTimestamp)
            time = headers.extraTimestamp * 100_000L; // in 0.1 ms
        level = headers.extended.messageInfo.logLevel();
    }
    else
        return false;

    part.part.sender = senderOf(removeIdPadding(ecuId), removeIdPadding(appId), removeIdPadding(ctxId));
    part.part.counter = counter;
    part.part.nextCounter = cast(ubyte)(counter + 1);
    part.part.time = time;
    part.part.level = level;
    part.part.piece = PieceKind.other;

    VerboseArgument argument;
    if (arguments != 1 || !readArgument(payload, msbf, argument) || argument.kind != ArgumentKind.String)
        return false;
    part.text = argument.text;
    part.utf8 = argument.utf8;
    uint number, count;
    if (takeNumber(part.text, number, count))
    {
        part.part.number = number;
        part.part.count = count;
        part.part.piece = PieceKind.unknown; // numbered: not a piece
    }
    else
        tellPiece(part.part, part.text);
    return true;
}

//! @brief The rule of the pieces of a text its writer cut at its limit with no mark
//! (dltPieceLimits): a text of a limit, or up to 3 bytes under it where the limit would
//! cut a UTF-8 character, with no line break at its end, is cut: the next record of the
//! writer goes on with it. Which one does, PartJoiner tells: its next counter, at once,
//! starting with a character the room left didn't take (the room under the nearest limit:
//! whose limit the writer has is not known)
private void tellPiece(ref RecordPart part, const(char)[] text) pure nothrow @nogc
{
    part.firstCharLength = text.length == 0 ? 0 : utf8LengthOf(text[0]);
    if (isCutAtLimit(text.length, text.length == 0 ? '\0' : text[$ - 1]))
    {
        part.piece = PieceKind.cut;
        foreach (limit; dltPieceLimits)
            if (limit >= text.length)
            {
                part.room = cast(uint)(limit - text.length);
                break;
            }
    }
    else
        part.piece = PieceKind.text;
}

//! @returns true if a text of `length` bytes ending in `last` is cut at a limit (tellPiece)
private bool isCutAtLimit(size_t length, char last) pure nothrow @nogc
{
    enum maxRoom = 3; // a UTF-8 character the limit would cut: of 4 bytes at most
    return length <= dltPieceLimits[$ - 1] && length + maxRoom >= dltPieceLimits[0] && last != '\n';
}

//! @returns the bytes of the UTF-8 character `lead` starts, 1 if it starts none
private uint utf8LengthOf(char lead) pure nothrow @nogc
{
    return lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1;
}

//! @returns true if the bytes after a record, by its length, start with a storage header
//! (or what may be the start of one) or are none: a length too long, which DltFormat cuts
//! at the next header inside the record, is not trusted with a part
private bool endsAtHeader(const(ubyte)[] after) pure nothrow @nogc
{
    return after.length >= DLT_PATTERN.length ? startsWithStoragePattern(after)
        : after == DLT_PATTERN[0 .. after.length];
}

//! @returns false if the message at the start of `message` (no storage header) is surely
//! not a part, by a look at a few of its bytes: asked of every record as the offset index
//! grows
private bool mayBePartOf(const(ubyte)[] message) pure nothrow @nogc
{
    VerboseStart start;
    return findVerboseStart(message, start) && dltMayBePartAt(message, start);
}

//! @returns false if the verbose message at the start of `message` (no storage header),
//! whose arguments start as findVerboseStart found, is surely not a part: the look of
//! dltMayBePart once the header is walked, which DltFormat.marksOf shares
bool dltMayBePartAt()(const(ubyte)[] message, in VerboseStart start) pure nothrow @nogc
{
    if (!start.hasAppContextId || start.arguments != 1)
        return false;
    // The type info, the length, a digit
    if (start.at + 7 > message.length)
        return false;
    const typeInfo = readValue!uint(message[start.at .. start.at + 4], start.msbf);
    if (!(typeInfo & TypeInfoFlags.TypeString))
        return false;
    if (typeInfo & TypeInfoFlags.VariableInfo)
        return true; // the name comes first: left to readPart
    const c = message[start.at + 6];
    if (c >= '0' && c <= '9')
        return true;
    // A piece cut at the limit: its length and its last character
    const length = readValue!ushort(message[start.at + 4 .. start.at + 6], start.msbf);
    const end = start.at + 6 + length;
    if (length + 3 < dltPieceLimits[0] || end > message.length)
        return false; // zeros at its end make it shorter still, never longer
    auto text = cast(const(char)[]) message[start.at + 6 .. end];
    while (text.length != 0 && text[$ - 1] == '\0')
        text = text[0 .. $ - 1];
    return isCutAtLimit(text.length, text.length == 0 ? '\0' : text[$ - 1]);
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

    //! A verbose record of version 1 of one string argument, its timestamp in 0.1 ms
    private ubyte[] timedRecord(const(char)[] text, ubyte counter, uint timestamp)
    {
        BuildV1 r;
        r.counter = counter;
        r.withTimestamp = true;
        r.timestamp = timestamp;
        r.numberOfArguments = 1;
        r.payload = argument(0x200, bytesOf(cast(ushort)(text.length + 1))
            ~ cast(const(ubyte)[]) text ~ cast(ubyte) 0);
        return r.bytes();
    }

    //! `length` bytes of ASCII text, `last` its last character
    private string longText(size_t length, char last = 'z')
    {
        import std.array : replicate;

        return "a".replicate(length - 1) ~ last;
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

@("dltPartOf: a text of the limit of its writer with no line break at its end is a cut piece")
unittest
{
    const cut = dltPartOf(timedRecord(longText(dltPieceLimits[$ - 1]), 41, 12_345), true);
    assert(!cut.isPart && cut.piece == PieceKind.cut && cut.room == 0);
    assert(cut.counter == 41 && cut.nextCounter == 42);
    assert(cut.time == 12_345 * 100_000L, "the timestamp of the header, in ns");
    assert(cut.level == LogLevel.Info, "the level of the message info");
    assert(cut.sender == dltPartOf(textRecord("x", 0), true).sender);

    // Writers of either limit: 1024 bytes of text, or 1023 and the zero after them
    assert(dltPieceLimits == [1023, 1024]);
    const of1023 = dltPartOf(timedRecord(longText(1023), 0, 0), true);
    assert(of1023.piece == PieceKind.cut && of1023.room == 0, "the room of the nearest limit");

    // The writer keeps a UTF-8 character whole: up to 3 bytes under its limit
    const short_ = dltPartOf(timedRecord(longText(1021), 0, 0), true);
    assert(short_.piece == PieceKind.cut && short_.room == 2);
    assert(dltPartOf(timedRecord(longText(1020), 0, 0), true).room == 3);
    assert(dltPartOf(timedRecord(longText(1019), 0, 0), true).piece == PieceKind.text);
    assert(dltPartOf(timedRecord(longText(1025), 0, 0), true).piece == PieceKind.text);
    assert(dltPartOf(timedRecord(longText(1024, '\n'), 0, 0), true).piece == PieceKind.text,
        "a line break at its end: a whole message");
}

@("dltPartOf: any record of one text may go on with a cut piece, others of its writer end it")
unittest
{
    const text = dltPartOf(timedRecord("дальше", 7, 1), true);
    assert(!text.isPart && text.piece == PieceKind.text && text.firstCharLength == 2);
    assert(text.counter == 7 && text.time == 100_000);
    assert(dltPartOf(textRecord("x"), true).time == RecordPart.noTime, "no timestamp");
    assert(dltPartOf(textRecord("x"), true).firstCharLength == 1);

    BuildV1 two;
    two.counter = 3;
    two.numberOfArguments = 2;
    two.payload = argument(0x200, bytesOf(cast(ushort) 2) ~ cast(ubyte[]) "x\0".dup)
        ~ argument(0x200, bytesOf(cast(ushort) 2) ~ cast(ubyte[]) "y\0".dup);
    const other = dltPartOf(two.bytes(), true);
    assert(other.piece == PieceKind.other && other.counter == 3);
    assert(other.sender == text.sender);

    BuildV1 nonVerbose;
    nonVerbose.verbose = false;
    nonVerbose.payload = bytesOf(5u) ~ cast(ubyte[]) "x".dup;
    assert(dltPartOf(nonVerbose.bytes(), true) == RecordPart.init, "whose: not told");
}

@("parseDltParts: the pieces of a text cut at the limit are joined as they are")
unittest
{
    const first = longText(dltPieceLimits[$ - 1]);
    assert(payloadOf(timedRecord(first, 0, 0), timedRecord("goes on\n", 1, 0)) == first ~ "goes on\n");
}

@("parseDltParts: a message of pieces whose last one is cut tells it")
unittest
{
    const first = longText(dltPieceLimits[$ - 1]);
    assert(payloadOf(timedRecord(first, 0, 0), timedRecord(first, 1, 0)) == first ~ first ~ " [cut]");
}

@("parseDltParts: a numbered part and a piece are not joined, the first is left as it is")
unittest
{
    const piece = timedRecord(longText(dltPieceLimits[$ - 1]), 1, 0);
    assert(payloadOf(textRecord("1/2: one", 0), piece) == "1/2: one");
    assert(payloadOf(piece, textRecord("2/2: two", 2)) == longText(dltPieceLimits[$ - 1]));
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

@("parseDltParts: parts marked ASCII are joined as UTF-8 when their bytes are UTF-8")
unittest
{
    const text = "даль";
    const a = textRecord("1/2: " ~ text[0 .. 3], 0); // "д" and half of "а"
    const b = textRecord("2/2: " ~ text[3 .. $], 1);
    assert(payloadOf(a, b) == "даль");
    assert(payloadOf(textRecord("1/2: \xE9", 0), textRecord("2/2: x", 1)) == "\u00e9x",
        "not UTF-8: a character per byte");
    assert(payloadOf(textRecord("1/2: ok\xD0", 0), textRecord("2/2: \xB4", 1)) == "okд",
        "a character cut after ASCII alone, completed by the next part");
    assert(payloadOf(textRecord("1/2: abc\xC3", 0), textRecord("2/2: \xA9x", 1)) == "abcéx");
}

@("parseDltParts: a character cut short in the last part marked ASCII reads as in one argument")
unittest
{
    const cut = "好呀"[0 .. 5];
    assert(payloadOf(textRecord("1/2: a", 0), textRecord("2/2: " ~ cut, 1)) == "a好??");
    assert(payloadOf(textRecord("1/2: a", 0), textRecord("2/2: c\xE9", 1)) == "ac\u00e9");
}

@("parseDltParts: a message without its last parts tells how many it got")
unittest
{
    assert(payloadOf(textRecord("1/3: one ", 0), textRecord("2/3: two", 1)) == "one two [2 of 3 parts]");
}

@("parseDltParts: a part that can't be read leaves the first part as it is")
unittest
{
    const first = textRecord("1/2: one", 0);
    assert(payloadOf(first, cast(const(ubyte)[]) null) == "1/2: one");
    assert(payloadOf(first, textRecord("a text", 1)) == "1/2: one");
}
