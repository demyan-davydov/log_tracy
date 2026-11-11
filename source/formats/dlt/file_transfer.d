//! The file transfer of dlt-daemon (COVESA, dlt_filetransfer.c): a file sent as verbose
//! log messages whose first and last arguments are the same marker. FLST: the file (serial,
//! name, size, date, packets, buffer size); FLDA: a packet of its bytes (serial, number,
//! raw data); FLFI: the end (serial); FLER: an error (code, errno, then serial and the
//! file, or its name alone when it could not be read). Tells what a record is to a
//! transfer, for DltFormat as a TransferringFormat (docs/stories/file-transfer.md).
module formats.dlt.file_transfer;

import formats.dlt.parser : ArgumentKind, VerboseArgument, VerboseMessage, VerboseStart, findVerboseStart,
    readArgument, readVerbose, storageSizeOf;
import formats.dlt.protocol;

import log_core.log_format : TransferKind, TransferMessage;

//! @returns false if the record at the start of `data` (as DltFormat.scanRecords found it;
//! the bytes after it may follow) is surely not a message of a transfer, by a look at a
//! few of its bytes; true for every one (dltTransferOf tells). The look of a record on its
//! own, for the tests: DltFormat.marksOf walks the header once for it and dltMayBePart
//! (dltMayBeTransferAt)
bool dltMayBeTransfer(const(ubyte)[] data, bool hasStorageHeader) pure nothrow @nogc
{
    const storage = hasStorageHeader ? storageSizeOf(data) : 0;
    if (storage >= data.length)
        return false;
    const message = data[storage .. $];
    VerboseStart start;
    return findVerboseStart(message, start) && dltMayBeTransferAt(message, start);
}

//! @returns false if the verbose message at the start of `message` (no storage header),
//! whose arguments start as findVerboseStart found, is surely not a message of a
//! transfer: the look of dltMayBeTransfer once the header is walked, which
//! DltFormat.marksOf shares
bool dltMayBeTransferAt()(const(ubyte)[] message, in VerboseStart start) pure nothrow @nogc
{
    if (start.messageInfo.messageType != MessageType.Log || start.arguments < minArguments)
        return false;
    // The type info, the length, "FL"
    if (start.at + 8 > message.length)
        return false;
    const typeInfo = readValue!uint(message[start.at .. start.at + 4], start.msbf);
    if (!(typeInfo & TypeInfoFlags.TypeString))
        return false;
    if (typeInfo & TypeInfoFlags.VariableInfo)
        return true; // the name comes first: left to dltTransferOf
    const length = readValue!ushort(message[start.at + 4 .. start.at + 6], start.msbf);
    return (length == 4 || length == 5) && message[start.at + 6] == 'F' && message[start.at + 7] == 'L';
}

//! @returns what the record `record` (whole, as DltFormat.recordAt gives it) is to a
//! transfer: kind none if it is not a message of one. Its texts and bytes are slices of
//! `record`
TransferMessage dltTransferOf(const(ubyte)[] record, bool hasStorageHeader) nothrow @nogc
{
    TransferMessage none;
    VerboseMessage verbose;
    if (!readVerbose(record, hasStorageHeader, verbose) || verbose.messageInfo.messageType != MessageType.Log
        || verbose.arguments < minArguments || verbose.arguments > maxArguments)
        return none;

    VerboseArgument[maxArguments] args;
    const count = verbose.arguments;
    const(ubyte)[] payload = verbose.payload;
    foreach (i; 0 .. count)
        if (!readArgument(payload, verbose.msbf, args[i]))
            return none;
    const marker = textOf(args[0]);
    if (marker.length != 4 || textOf(args[count - 1]) != marker)
        return none;

    const msbf = verbose.msbf;
    TransferMessage m;
    bool ok;
    bool serialAt(size_t i)
    {
        m.hasSerial = unsignedOf(args[i], msbf, m.serial);
        return m.hasSerial;
    }

    bool fileAt(size_t i) // name, size, date, packets
    {
        m.name = textOf(args[i]);
        m.date = textOf(args[i + 2]);
        return isText(args[i]) && unsignedOf(args[i + 1], msbf, m.size) && isText(args[i + 2])
            && unsignedOf(args[i + 3], msbf, m.packets);
    }

    switch (marker)
    {
    case "FLST":
        m.kind = TransferKind.start;
        ok = count == 8 && serialAt(1) && fileAt(2) && unsignedOf(args[6], msbf, m.bufferSize);
        break;
    case "FLDA":
        m.kind = TransferKind.data;
        m.bytes = args[3].value;
        ok = count == 5 && serialAt(1) && unsignedOf(args[2], msbf, m.packet) && args[3].kind == ArgumentKind.Raw;
        break;
    case "FLFI":
        m.kind = TransferKind.end;
        ok = count == 3 && serialAt(1);
        break;
    case "FLER":
        m.kind = TransferKind.error;
        ok = signedOf(args[1], msbf, m.error) && signedOf(args[2], msbf, m.osError);
        // Writers differ in what follows the codes: the serial and the file, the buffer
        // size or not after them; or the name alone, after a label or not, when the
        // file could not be read
        if (count >= 9 && serialAt(3))
            ok = ok && fileAt(4);
        else
        {
            m.hasSerial = false;
            m.name = textOf(args[count - 2]);
            foreach (i; 3 .. count - 1)
                ok = ok && isText(args[i]);
            ok = ok && count >= 5;
        }
        break;
    default:
        break;
    }
    return ok ? m : none;
}

//! The fewest arguments of a message of a transfer (FLFI) and the most (FLIF, not read)
private enum minArguments = 3, maxArguments = 12;

private bool isText(ref const VerboseArgument argument) pure nothrow @nogc
{
    return argument.kind == ArgumentKind.String;
}

//! The text of a string argument, empty for another one
private const(char)[] textOf(ref const VerboseArgument argument) pure nothrow @nogc
{
    return isText(argument) ? argument.text : null;
}

//! @returns false if `argument` is not an integer (signed or unsigned, of up to 64 bits)
private bool signedOf(ref const VerboseArgument argument, bool msbf, out long value) pure nothrow @nogc
{
    const isSigned = argument.kind == ArgumentKind.Signed;
    if (!isSigned && argument.kind != ArgumentKind.Unsigned)
        return false;
    const v = argument.value;
    // Each side to long: int and uint would meet in uint
    switch (v.length)
    {
    case 1:
        value = isSigned ? long(cast(byte) v[0]) : long(v[0]);
        return true;
    case 2:
        value = isSigned ? long(readValue!short(v, msbf)) : long(readValue!ushort(v, msbf));
        return true;
    case 4:
        value = isSigned ? long(readValue!int(v, msbf)) : long(readValue!uint(v, msbf));
        return true;
    case 8:
        value = readValue!long(v, msbf);
        return isSigned || value >= 0;
    default:
        return false;
    }
}

//! @returns false if `argument` is not an integer that fits in T and isn't negative
private bool unsignedOf(T)(ref const VerboseArgument argument, bool msbf, out T value) pure nothrow @nogc
{
    long v;
    if (!signedOf(argument, msbf, v) || v < 0 || v > T.max)
        return false;
    value = cast(T) v;
    return true;
}

version (unittest)
{
    import formats.dlt.testing_utils;

    //! A verbose log record of version 1 with these arguments
    private ubyte[] recordV1(VerboseArgs args, ubyte type = MessageType.Log, char[4] ctxId = "FILE")
    {
        BuildV1 r;
        r.msbf = args.msbf;
        r.type = type;
        r.ctxId = ctxId;
        r.numberOfArguments = args.count;
        r.payload = args.bytes;
        return r.bytes();
    }

    //! A verbose log record of version 2 (little-endian) with these arguments, after a
    //! storage header of version 2
    private ubyte[] recordV2(VerboseArgs args)
    {
        BuildV2 r;
        r.appId = "TICC";
        r.ctxId = "FILE";
        r.ecuId = "ECU1";
        r.numberOfArguments = args.count;
        r.payload = args.bytes;
        return storageV2("ECU1", 1000, 0) ~ r.bytes();
    }

    private TransferMessage transferOf(const(ubyte)[] record, bool hasStorageHeader = true)
    {
        assert(dltMayBeTransfer(record, hasStorageHeader), "a message of a transfer may be one");
        return dltTransferOf(record, hasStorageHeader);
    }

    private VerboseArgs flst(bool msbf = true)
    {
        return VerboseArgs(msbf).str("FLST").u32(3_033_975_044).str("trigger.tar.lz4").u32(119_480_325)
            .str("Mon Nov  3 10:19:51 2025\n").u32(116_681).u32(1024).str("FLST");
    }
}

@("dltTransferOf: FLST tells the file: serial, name, size, date, packets, buffer size")
unittest
{
    foreach (msbf; [true, false])
    {
        const record = recordV1(flst(msbf));
        const m = transferOf(record);
        assert(m.kind == TransferKind.start && m.hasSerial && m.serial == 3_033_975_044);
        assert(m.name == "trigger.tar.lz4" && m.size == 119_480_325);
        assert(m.date == "Mon Nov  3 10:19:51 2025\n", "the date as written");
        assert(m.packets == 116_681 && m.bufferSize == 1024);
    }
}

@("dltTransferOf: FLDA gives a packet: its serial, number and bytes")
unittest
{
    const ubyte[] bytes = [0x04, 0x22, 0x4D, 0x18, 0x60];
    foreach (msbf; [true, false])
    {
        const record = recordV1(VerboseArgs(msbf).str("FLDA").u32(7).u32(2).raw(bytes).str("FLDA"));
        const m = transferOf(record);
        assert(m.kind == TransferKind.data && m.hasSerial && m.serial == 7);
        assert(m.packet == 2 && m.bytes == bytes);
        assert(m.bytes.ptr >= record.ptr && m.bytes.ptr < record.ptr + record.length, "a slice of the record");
    }
}

@("dltTransferOf: FLFI ends the transfer of its serial")
unittest
{
    const m = transferOf(recordV1(VerboseArgs(true).str("FLFI").u32(7).str("FLFI")));
    assert(m.kind == TransferKind.end && m.hasSerial && m.serial == 7);
}

@("dltTransferOf: FLER of a file being sent has its serial and the file")
unittest
{
    const record = recordV1(VerboseArgs(true).str("FLER").i32(-400).i32(-5).u32(7).str("a.bin").u32(10)
            .str("today").u32(1).str("FLER"));
    const m = transferOf(record);
    assert(m.kind == TransferKind.error && m.hasSerial && m.serial == 7);
    assert(m.error == -400 && m.osError == -5);
    assert(m.name == "a.bin" && m.size == 10 && m.date == "today" && m.packets == 1);
}

@("dltTransferOf: FLER of a file that could not be read has its name alone")
unittest
{
    const m = transferOf(recordV1(VerboseArgs(true).str("FLER").i32(-400).i32(-2).str("/no/such").str("FLER")));
    assert(m.kind == TransferKind.error && !m.hasSerial);
    assert(m.error == -400 && m.osError == -2 && m.name == "/no/such");
}

@("dltTransferOf: FLER is read whatever follows its fields: a buffer size, a label before the name")
unittest
{
    const withBuffer = transferOf(recordV1(VerboseArgs(true).str("FLER").i32(-400).i32(-5).u32(7).str("a.bin")
            .u32(10).str("today").i32(1).u32(1024).str("FLER")));
    assert(withBuffer.kind == TransferKind.error && withBuffer.serial == 7 && withBuffer.name == "a.bin");
    assert(withBuffer.size == 10 && withBuffer.packets == 1, "the count of packets written as a signed number");

    const labelled = transferOf(recordV1(VerboseArgs(true).str("FLER").i32(-400).i32(-2).str("Filename:")
            .str("/no/such").str("FLER")));
    assert(labelled.kind == TransferKind.error && !labelled.hasSerial && labelled.name == "/no/such");
}

@("dltTransferOf: a message of version 2 is read too")
unittest
{
    const m = transferOf(recordV2(VerboseArgs(false).str("FLDA").u32(9).u32(1).raw([1, 2, 3]).str("FLDA")));
    assert(m.kind == TransferKind.data && m.serial == 9 && m.packet == 1 && m.bytes == [1, 2, 3]);
}

@("dltTransferOf: no storage header")
unittest
{
    BuildV1 r;
    r.storage = false;
    r.numberOfArguments = 3;
    r.payload = VerboseArgs(true).str("FLFI").u32(7).str("FLFI").bytes;
    const m = transferOf(r.bytes(), false);
    assert(m.kind == TransferKind.end && m.serial == 7);
}

@("dltTransferOf: the last argument must be the marker of the first, the arguments of their kinds")
unittest
{
    alias none = TransferKind.none;
    assert(dltTransferOf(recordV1(VerboseArgs(true).str("FLFI").u32(7).str("FLDA")), true).kind == none, "another marker last");
    assert(dltTransferOf(recordV1(VerboseArgs(true).str("FLFI").u32(7)), true).kind == none, "no marker last");
    assert(dltTransferOf(recordV1(VerboseArgs(true).str("FLFI").str("7").str("FLFI")), true).kind == none, "a serial as text");
    assert(dltTransferOf(recordV1(VerboseArgs(true).str("FLDA").u32(7).u32(1).str("ab").str("FLDA")), true).kind == none,
        "data as text");
    assert(dltTransferOf(recordV1(VerboseArgs(true).str("FLXX").u32(7).str("FLXX")), true).kind == none, "an unknown marker");
    assert(dltTransferOf(recordV1(VerboseArgs(true).str("FLST").u32(7).str("FLST")), true).kind == none,
        "FLST without its fields");
    assert(dltTransferOf(recordV1(VerboseArgs(true).str("FLFI").u32(7).str("FLFI"), MessageType.AppTrace), true).kind == none,
        "not a log message");
}

@("dltMayBeTransfer: a look at the first argument rules out the usual messages")
unittest
{
    assert(!dltMayBeTransfer(recordV1(VerboseArgs(true).str("FLDA is a context").u32(1).str("x"), MessageType.Log, "FLDA"), true),
        "a text that starts with a marker, in the context FLDA");
    assert(!dltMayBeTransfer(recordV1(VerboseArgs(true).str("FLFI").str("FLFI")), true), "two arguments");
    assert(!dltMayBeTransfer(recordV1(VerboseArgs(true).u32(1).u32(7).str("FLFI")), true), "a number first");
    assert(!dltMayBeTransfer(recordV1(VerboseArgs(true).str("FLFI").u32(7).str("FLFI"), MessageType.AppTrace), true),
        "not a log message");
    assert(!dltMayBeTransfer(buildDltMessage(), true), "a usual message");
    assert(dltMayBeTransfer(recordV2(VerboseArgs(false).str("FLFI").u32(7).str("FLFI")), true), "version 2");
}
