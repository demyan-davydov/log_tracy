module dlt_core.dlt_parser;

import dlt_core.dlt_protocol;
import dlt_core.log_item;
import dlt_core.fibex;
import std.stdio;
import std.array;
import std.conv : to;
import std.format : format;
import std.stdint;
import std.traits : isSomeChar;

import dlt_core.decoded_message;

//! @brief DLT Message structure:
//! [ Storage Header ]        (16 bytes, always in file)
//! [ Standard Header ]       (minimum 4 bytes)
//! [ Extra Header Fields ]   (up to 12 bytes, depends on 'StandardHeader.headerType', byte order depends on 'StandardHeader.isBigEndian()')
//! [ Extended Header ]       (if 'StandardHeader.headerType' has 'UseExtendedHeader' flag)
//! [ Payload ]

struct LogItemHeaders
{
    const(StorageHeader)* storage;
    const(StandardHeader)* standard;
    const(ExtendedHeader)* extended;
    const(ubyte)[] payload;

    uint32_t messageId; // 0 by default, set if standard header has message id

    // Extra header fields for StandardHeader.Type.WithEcuId, StandardHeader.Type.WithSessionId, StandardHeader.Type.WithTimestamp
    char[4] extraEcuId = 0;
    uint32_t extraSessionId;
    uint32_t extraTimestamp;
}

LogItemHeaders findHeaders(const(ubyte)[] data, bool hasStorageHeader = true) pure nothrow @nogc
{
    LogItemHeaders headers;

    if (hasStorageHeader)
    {
        if (data.length < StorageHeader.sizeof)
            return headers; // invalid

        headers.storage = cast(const(StorageHeader)*) data.ptr;

        data = data[StorageHeader.sizeof .. $];
    }

    if (data.length < StandardHeader.sizeof)
        return headers; // invalid (no standard header)

    headers.standard = cast(const(StandardHeader)*) data.ptr;
    data = data[StandardHeader.sizeof .. $];

    // read extra fields;

    const bool msbf = headers.standard.isBigEndian();

    if (headers.standard.withEcuId)
    {
        if (data.length >= 4)
        {
            headers.extraEcuId[] = cast(char[4]) data[0 .. 4];
            data = data[4 .. $];
        }
        else
            return headers;
    }

    if (headers.standard.withSessionId)
    {
        if (data.length >= 4)
        {
            headers.extraSessionId = readValue!uint(data[0 .. 4], msbf);
            data = data[4 .. $];
        }
        else
            return headers;
    }

    if (headers.standard.withTimestamp)
    {
        if (data.length >= 4)
        {
            headers.extraTimestamp = readValue!uint(data[0 .. 4], msbf);
            data = data[4 .. $];
        }
        else
            return headers;
    }

    if (headers.standard.useExtendedHeader)
    {
        if (data.length < ExtendedHeader.sizeof)
            return headers; // invalid (no extended header)

        headers.extended = cast(const(ExtendedHeader)*) data.ptr;
        data = data[ExtendedHeader.sizeof .. $];

        // Non-Verbose: Message ID is in the first 4 bytes of payload
        // Standard DLT says for Non-Verbose, Message ID is mandatory? 
        // Usually yes. Some implementations might vary, but we'll follow common practice.
        if (headers.extended.messageInfo.isVerbose)
        {
            headers.payload = data;
        }
        else
        {
            if (data.length >= 4)
            {
                headers.messageId = readValue!uint(data[0 .. 4], msbf);
                headers.payload = data[4 .. $];
            }
        }
    }
    else
    {
        headers.payload = data;
    }

    return headers;
}

LogItem parseDltItem(size_t index, ulong offset, const(ubyte)[] data, bool hasStorageHeader = true, FibexParser fibex = null)
{
    const LogItemHeaders headers = findHeaders(data, hasStorageHeader);

    LogItem item;
    item.index = index;
    item.offset = offset;

    if (headers.standard is null)
    {
        item.payload = "<Truncated Data>";
        return item;
    }

    const ulong timestamp = headers.storage !is null ? cast(ulong) headers
        .storage.nativeSeconds * 1_000_000 + headers
        .storage.nativeMicroseconds : 0;

    const ushort length = headers.standard.nativeLength;

    item.length = length;
    item.timestamp = timestamp;

    // ECU ID is stored as uint (4 bytes) in indexer, convert to ubyte[4] and clean
    if (headers.storage !is null)
        item.ecu = cleanId(headers.storage.ecuId);
    else
        item.ecu = "";

    item.level = LogLevel.Info;
    item.appId = "-";
    item.ctxId = "-";
    item.type = MessageType.Log;
    item.messageId = headers.messageId;

    if (headers.extended)
    {
        item.level = headers.extended.messageInfo.logLevel();
        item.type = headers.extended.messageInfo.messageType();

        // DLT IDs are 4 bytes, usually ASCII. 
        // Use cleanId to strip null bytes and non-printable characters
        item.appId = cleanId(headers.extended.applicationId);
        item.ctxId = cleanId(headers.extended.contextId);
    }

    item.payload = decodePayload(headers.standard, headers.extended, headers.payload, fibex, headers
            .messageId);

    debug
    {
        //if (item.messageId != 0)
        //    writefln("messageId: [%d] %s", item.messageId, item.payload);
    }

    return item;
}

//string decodePayload(const(ubyte)* stdHdrPtr, const(ubyte)[] payload, FibexParser fibex)
string decodePayload(const(StandardHeader)* stdHdr, const(ExtendedHeader)* extHdr, const(ubyte)[] payload, FibexParser fibex = null, uint messageId = 0)
{
    const bool msbf = (stdHdr.headerType & StandardHeader.Type.MostSignificantByteFirst) != 0;

    bool isVerbose = false;
    if (extHdr)
    {
        if (extHdr.messageInfo.isVerbose())
        {
            isVerbose = true;
            string[] args;
            const(ubyte)[] p = payload;
            int numArgs = extHdr.numberOfArguments;

            for (int i = 0; i < numArgs && p.length >= 4; ++i)
            {
                uint typeInfo = readValue!uint(p[0 .. 4], msbf);
                p = p[4 .. $];

                debug
                {
                    //writefln("type info: %b", typeInfo);
                }

                if (typeInfo & TypeInfoFlags.VariableInfo)
                {
                    for (int k = 0; k < 2; ++k)
                    {
                        if (p.length >= 2)
                        {
                            ushort strLen = readValue!ushort(p[0 .. 2], msbf);
                            p = p[2 .. $];
                            if (p.length >= strLen)
                                p = p[strLen .. $];
                            else
                            {
                                p = []; // Truncated
                                break;
                            }
                        }
                        else
                        {
                            p = []; // Truncated
                            break;
                        }
                    }
                }
                else if (typeInfo & TypeInfoFlags.FixedPoint)
                {
                    if (p.length >= 8)
                        p = p[8 .. $];
                    else
                        p = [];
                }
                else if (typeInfo & TypeInfoFlags.TypeBoolean)
                {
                    if (p.length >= 1)
                    {
                        args ~= p[0] ? "true" : "false";
                        p = p[1 .. $];
                    }
                }
                else if (typeInfo & TypeInfoFlags.TypeSigned)
                {
                    int typeSize = typeInfo & 0x0F;
                    if (typeSize == 0 && p.length >= 1)
                    {
                        args ~= to!string(cast(byte) p[0]);
                        p = p[1 .. $];
                    }
                    else if (typeSize == 1 && p.length >= 2)
                    {
                        args ~= to!string(readValue!short(p[0 .. 2], msbf));
                        p = p[2 .. $];
                    }
                    else if (typeSize == 2 && p.length >= 4)
                    {
                        args ~= to!string(readValue!int(p[0 .. 4], msbf));
                        p = p[4 .. $];
                    }
                    else if (typeSize == 3 && p.length >= 8)
                    {
                        args ~= to!string(readValue!long(p[0 .. 8], msbf));
                        p = p[8 .. $];
                    }
                }
                else if (typeInfo & TypeInfoFlags.TypeUnsigned)
                {
                    int typeSize = typeInfo & 0x0F;
                    if (typeSize == 0 && p.length >= 1)
                    {
                        args ~= to!string(p[0]);
                        p = p[1 .. $];
                    }
                    else if (typeSize == 1 && p.length >= 2)
                    {
                        args ~= to!string(readValue!ushort(p[0 .. 2], msbf));
                        p = p[2 .. $];
                    }
                    else if (typeSize == 2 && p.length >= 4)
                    {
                        args ~= to!string(readValue!uint(p[0 .. 4], msbf));
                        p = p[4 .. $];
                    }
                    else if (typeSize == 3 && p.length >= 8)
                    {
                        args ~= to!string(readValue!ulong(p[0 .. 8], msbf));
                        p = p[8 .. $];
                    }
                }
                else if (typeInfo & TypeInfoFlags.TypeFloat)
                {
                    int typeSize = typeInfo & 0x0F;
                    if (typeSize == 2 && p.length >= 4)
                    {
                        args ~= format("%.3f", readValue!float(p[0 .. 4], msbf));
                        p = p[4 .. $];
                    }
                    else if (typeSize == 3 && p.length >= 8)
                    {
                        args ~= format("%.3f", readValue!double(p[0 .. 8], msbf));
                        p = p[8 .. $];
                    }
                }
                else if (typeInfo & TypeInfoFlags.TypeString)
                {
                    if (p.length >= 2)
                    {
                        ushort len = readValue!ushort(p[0 .. 2], msbf);
                        p = p[2 .. $];
                        if (p.length >= len)
                        {
                            string s = cast(string) p[0 .. len];
                            if (len > 0 && s[len - 1] == 0)
                                s = s[0 .. len - 1];
                            args ~= s;
                            p = p[len .. $];
                        }
                        else
                        {
                            p = [];
                        }
                    }
                }
                else if (typeInfo & TypeInfoFlags.TypeRaw)
                {
                    if (p.length >= 2)
                    {
                        ushort len = readValue!ushort(p[0 .. 2], msbf);
                        p = p[2 .. $];
                        if (p.length >= len)
                        {
                            const(ubyte)[] rawData = p[0 .. len];

                            // some strings are null terminated, just remove null terminator
                            if (len > 0 && rawData[$ - 1] == 0)
                                rawData = rawData[0 .. $ - 1];

                            bool printable = (rawData.length > 0);
                            foreach (b; rawData)
                                if (b < 32 && b != 10 && b != 13 && b != 9)
                                {
                                    printable = false;
                                    break;
                                }

                            if (printable)
                                args ~= cast(string) rawData;
                            else
                            {
                                string res;
                                foreach (const(ubyte) b; rawData)
                                {
                                    if (b < 32 && b != 10 && b != 13 && b != 9)
                                    {
                                        res ~= format("[%02X]", b);
                                    }
                                    else
                                    {
                                        res ~= cast(char) b;
                                    }
                                }

                                args ~= res;
                            }

                            p = p[len .. $];
                        }
                        else
                        {
                            p = [];
                        }
                    }
                }
                else
                    args ~= format("<UnknownTI:0x%08X>", typeInfo);
            }

            if (args.length > 0)
            {
                return args.join(" ");
            }

            return "Verbose Msg (" ~ to!string(extHdr.numberOfArguments) ~ " args)";
        }
    }

    // Non-Verbose or Legacy
    if (fibex !is null && messageId != 0)
    {
        string desc = fibex.getDescription(messageId);
        if (desc.length > 0)
        {
            // TODO: Real PDUs decoding? 
            // For now just return description?
            return "FIBEX: " ~ desc;
        }
        return format("ID: %u", messageId);
    }

    return "Legacy DLT Message";
}

private string cleanId(const(char)[] id) pure
{
    import std.ascii : isPrintable;

    string s;
    foreach (b; id)
    {
        if (b == 0)
            break; // Stop at null terminator
        if (isPrintable(b))
            s ~= b;
        else
            s ~= '.'; // Replace non-printable with dot
    }
    return s.empty ? "-?-" : s;
}

bool parseDltItem(Char)(out DecodedMessage!Char msg, const(ubyte)[] data, bool hasStorageHeader = true) nothrow @nogc
        if (isSomeChar!Char)
{
    const LogItemHeaders headers = findHeaders(data, hasStorageHeader);

    if (headers.standard is null)
        return false;

    const bool msbf = headers.standard.isBigEndian();

    // ── ECU ID ──────────────────────────────────────────────────────────────
    // Storage header has ecuId as char[4]; cast to char[] for allocAndCopyAscii
    const char[] ecuId = headers.storage !is null ? headers.storage.ecuId : headers.extraEcuId;

    // ── AppId / CtxId / level / type ────────────────────────────────────────
    const(char)[] appId = "-";
    const(char)[] ctxId = "-";
    LogLevel level = LogLevel.Info;
    MessageType msgType = MessageType.Log;

    if (headers.extended)
    {
        appId = cast(const char[]) headers.extended.applicationId[];
        ctxId = cast(const char[]) headers.extended.contextId[];
        level = headers.extended.messageInfo.logLevel();
        msgType = headers.extended.messageInfo.messageType();
    }

    // setupPayload also resets the allocator and stores ecu/appId/ctxId
    auto builder = msg.setupPayload(ecuId, appId, ctxId);

    // ── scalar metadata ─────────────────────────────────────────────────────
    msg.timestampSeconds = headers.storage ? headers.storage.nativeSeconds : 0;
    msg.timestampMicroseconds = headers.storage ? headers.storage.nativeMicroseconds : 0;
    msg.level = level;
    msg.type = msgType;
    msg.messageId = headers.messageId;

    // ── Payload decoding ────────────────────────────────────────────────────
    const(ubyte)[] p = headers.payload;

    bool payloadDecoded = false;

    if (headers.extended && headers.extended.messageInfo.isVerbose())
    {
        // ── Verbose message: iterate typed arguments ─────────────────────
        const int numArgs = headers.extended.numberOfArguments;

        for (int i = 0; i < numArgs && p.length >= 4; ++i)
        {
            const uint typeInfo = readValue!uint(p[0 .. 4], msbf);
            p = p[4 .. $];

            // Skip VariableInfo metadata (name + unit, each prefixed with ushort length)
            if (typeInfo & TypeInfoFlags.VariableInfo)
            {
                foreach (_; 0 .. 2) // name, then unit
                {
                    if (p.length < 2)
                    {
                        p = [];
                        break;
                    }
                    const ushort slen = readValue!ushort(p[0 .. 2], msbf);
                    p = p[2 .. $];
                    if (p.length < slen)
                    {
                        p = [];
                        break;
                    }
                    p = p[slen .. $];
                }
            }

            // Skip FixedPoint quantization block (4 bytes offset + 4 bytes quant = 8)
            if (typeInfo & TypeInfoFlags.FixedPoint)
            {
                if (p.length >= 8)
                    p = p[8 .. $];
                else
                    p = [];
            }

            if (typeInfo & TypeInfoFlags.TypeBoolean)
            {
                if (p.length >= 1)
                {
                    builder.appendBool(p[0] != 0);
                    p = p[1 .. $];
                }
            }
            else if (typeInfo & TypeInfoFlags.TypeSigned)
            {
                const uint tyle = typeInfo & TypeInfoFlags.LengthMask;
                if (tyle == Tyle.Tyle8Bit && p.length >= 1)
                {
                    builder.append(cast(byte) p[0]);
                    p = p[1 .. $];
                }
                else if (tyle == Tyle.Tyle16Bit && p.length >= 2)
                {
                    builder.append(readValue!short(p[0 .. 2], msbf));
                    p = p[2 .. $];
                }
                else if (tyle == Tyle.Tyle32Bit && p.length >= 4)
                {
                    builder.append(readValue!int(p[0 .. 4], msbf));
                    p = p[4 .. $];
                }
                else if (tyle == Tyle.Tyle64Bit && p.length >= 8)
                {
                    builder.append(readValue!long(p[0 .. 8], msbf));
                    p = p[8 .. $];
                }
            }
            else if (typeInfo & TypeInfoFlags.TypeUnsigned)
            {
                const uint tyle = typeInfo & TypeInfoFlags.LengthMask;
                if (tyle == Tyle.Tyle8Bit && p.length >= 1)
                {
                    builder.append(cast(ubyte) p[0]);
                    p = p[1 .. $];
                }
                else if (tyle == Tyle.Tyle16Bit && p.length >= 2)
                {
                    builder.append(readValue!ushort(p[0 .. 2], msbf));
                    p = p[2 .. $];
                }
                else if (tyle == Tyle.Tyle32Bit && p.length >= 4)
                {
                    builder.append(readValue!uint(p[0 .. 4], msbf));
                    p = p[4 .. $];
                }
                else if (tyle == Tyle.Tyle64Bit && p.length >= 8)
                {
                    builder.append(readValue!ulong(p[0 .. 8], msbf));
                    p = p[8 .. $];
                }
            }
            else if (typeInfo & TypeInfoFlags.TypeFloat)
            {
                const uint tyle = typeInfo & TypeInfoFlags.LengthMask;
                if (tyle == Tyle.Tyle32Bit && p.length >= 4)
                {
                    builder.append(readValue!float(p[0 .. 4], msbf));
                    p = p[4 .. $];
                }
                else if (tyle == Tyle.Tyle64Bit && p.length >= 8)
                {
                    builder.append(readValue!double(p[0 .. 8], msbf));
                    p = p[8 .. $];
                }
            }
            else if (typeInfo & TypeInfoFlags.TypeString)
            {
                if (p.length >= 2)
                {
                    const ushort slen = readValue!ushort(p[0 .. 2], msbf);
                    p = p[2 .. $];
                    if (p.length >= slen)
                    {
                        const(char)[] str = cast(const char[]) p[0 .. slen];
                        // strip trailing null terminator if present
                        if (str.length > 0 && str[$ - 1] == '\0')
                            str = str[0 .. $ - 1];

                        const bool isUtf8 =
                            (typeInfo & TypeInfoFlags.StringCodingMask)
                            == TypeInfoFlags.StringCodingUTF8;

                        if (isUtf8)
                            builder.appendUtf8(str);
                        else
                            builder.appendAscii(str);

                        p = p[slen .. $];
                    }
                    else
                    {
                        p = [];
                    }
                }
            }
            else if (typeInfo & TypeInfoFlags.TypeRaw)
            {
                if (p.length >= 2)
                {
                    const ushort rlen = readValue!ushort(p[0 .. 2], msbf);
                    p = p[2 .. $];
                    if (p.length >= rlen)
                    {
                        builder.appendHex(cast(const char[]) p[0 .. rlen]);
                        p = p[rlen .. $];
                    }
                    else
                    {
                        p = [];
                    }
                }
            }
            // Unknown TypeInfo — skip silently
        }

        payloadDecoded = true;
    }

    if (!payloadDecoded)
    {
        // ── Non-Verbose or no Extended Header ────────────────────────────
        if (headers.messageId != 0)
        {
            msg.messageId = headers.messageId;
        }
        else
        {
            builder.appendAscii("Legacy DLT Message");
        }
    }

    // builder destructor calls storePayload() automatically
    return true;
}

/// Non-@nogc overload that also performs FIBEX lookup.
/// Call this when you have a FibexParser and don't need @nogc.
bool parseDltItemWithFibex(Char)(out DecodedMessage!Char msg, const(ubyte)[] data, FibexParser fibex)
        if (isSomeChar!Char)
{
    if (!parseDltItem(msg, data))
        return false;

    // If the result is a bare "ID:N" message and FIBEX has a description, replace it.
    if (msg.messageId != 0 && fibex !is null)
    {
        string desc = fibex.getDescription(msg.messageId);
        if (desc.length > 0)
        {
            // Re-decode: append the FIBEX description instead
            auto builder = msg.setupPayload(
                cast(const char[]) msg.ecu,
                cast(const char[]) msg.appId,
                cast(const char[]) msg.ctxId);
            builder.appendAscii("FIBEX: ");
            builder.appendAscii(desc);
        }
    }

    return true;
}

// ─── Helper: build a minimal raw DLT message byte array ──────────────────────
// Returns a ubyte[] with StorageHeader + StandardHeader + optional ExtendedHeader + payload.
version (unittest)
{
    import std.bitmanip : nativeToBigEndian, nativeToLittleEndian;

    // Build a complete DLT message in a ubyte[] for unit testing.
    // All pointer casts are safe because we own the GC array.
    ubyte[] buildDltMessage_without_storage_header(
        bool withExtHeader,
        bool verbose,
        ubyte numArgs,
        ubyte msgType, // MessageType raw value
        ubyte logLevel, // LogLevel raw value (used in MessageInfo bits 4-7)
        uint messageId, // for non-verbose (big endian in payload)
        ubyte[] payload, // for verbose: raw argument bytes; for non-verbose: appended after messageId
        string appId = "APP1",
        string ctxId = "CTX1",
    )
    {
        import core.stdc.string : memset, memcpy;

        // ── Standard Header ──────────────────────────────────────────────
        StandardHeader stdH;
        ubyte ht = StandardHeader.Type.MostSignificantByteFirst; // big-endian
        if (withExtHeader)
            ht |= StandardHeader.Type.UseExtendedHeader;
        stdH.headerType = ht;

        // ── Extended Header ──────────────────────────────────────────────
        ExtendedHeader extH;
        if (withExtHeader)
        {
            // MessageInfo: bits [0]=verbose, [1-3]=msgType, [4-7]=logLevel
            ubyte info = cast(ubyte)((verbose ? 1 : 0)
                    | ((msgType & 0x07) << 1)
                    | (
                        (logLevel & 0x0F) << 4));
            extH.messageInfo = MessageInfo(info);
            extH.numberOfArguments = numArgs;
            foreach (i, c; appId[0 .. (appId.length < 4 ? appId.length : 4)])
                extH.applicationId[i] = cast(ubyte) c;
            foreach (i, c; ctxId[0 .. (ctxId.length < 4 ? ctxId.length : 4)])
                extH.contextId[i] = cast(ubyte) c;
        }

        // ── Assemble ─────────────────────────────────────────────────────
        ubyte[] body;
        if (!verbose && withExtHeader)
        {
            // Non-verbose: prepend message ID (big endian)
            ubyte[4] idBytes = nativeToBigEndian(messageId);
            body ~= idBytes[];
        }
        body ~= payload;

        const size_t totalLen = StandardHeader.sizeof
            + (withExtHeader ? ExtendedHeader.sizeof : 0)
            + body.length;

        stdH.nativeLength = cast(ushort) totalLen;

        ubyte[] result;
        result ~= (cast(ubyte*)&stdH)[0 .. StandardHeader.sizeof];
        if (withExtHeader)
            result ~= (cast(ubyte*)&extH)[0 .. ExtendedHeader.sizeof];
        result ~= body;

        return result;
    }

    // Build a complete DLT message in a ubyte[] for unit testing.
    // All pointer casts are safe because we own the GC array.
    ubyte[] buildDltMessage(
        bool withExtHeader,
        bool verbose,
        ubyte numArgs,
        ubyte msgType, // MessageType raw value
        ubyte logLevel, // LogLevel raw value (used in MessageInfo bits 4-7)
        uint messageId, // for non-verbose (big endian in payload)
        ubyte[] payload, // for verbose: raw argument bytes; for non-verbose: appended after messageId
        string ecuId = "ECU1",
        string appId = "APP1",
        string ctxId = "CTX1",
        uint seconds = 1000,
        uint usecs = 500
    )
    {
        import core.stdc.string : memset, memcpy;

        // ── Storage Header ───────────────────────────────────────────────
        StorageHeader sh;
        sh.pattern = cast(char[4]) "DLT\x01";
        sh.nativeSeconds = seconds;
        sh.nativeMicroseconds = usecs;
        foreach (i, c; ecuId[0 .. (ecuId.length < 4 ? ecuId.length : 4)])
            sh.ecuId[i] = c;

        ubyte[] result;
        result ~= (cast(ubyte*)&sh)[0 .. StorageHeader.sizeof];

        result ~= buildDltMessage_without_storage_header(
            withExtHeader,
            verbose,
            numArgs,
            msgType,
            logLevel,
            messageId,
            payload,
            appId,
            ctxId);

        return result;
    }

    // Helper: pack a 4-byte TypeInfo word + data bytes for a verbose uint32 argument
    ubyte[] verboseUint32Arg(uint value)
    {
        import std.bitmanip : nativeToBigEndian;

        // TypeInfo: TypeUnsigned | Tyle32Bit
        const uint ti = TypeInfoFlags.TypeUnsigned | Tyle.Tyle32Bit;
        ubyte[4] tib = nativeToBigEndian(ti);
        ubyte[4] vb = nativeToBigEndian(value);
        return tib[] ~ vb[];
    }

    ubyte[] verboseInt32Arg(int value)
    {
        import std.bitmanip : nativeToBigEndian;

        const uint ti = TypeInfoFlags.TypeSigned | Tyle.Tyle32Bit;
        ubyte[4] tib = nativeToBigEndian(ti);
        ubyte[4] vb = nativeToBigEndian(cast(uint) value);
        return tib[] ~ vb[];
    }

    ubyte[] verboseBoolArg(bool value)
    {
        import std.bitmanip : nativeToBigEndian;

        const uint ti = TypeInfoFlags.TypeBoolean;
        ubyte[4] tib = nativeToBigEndian(ti);
        return tib[] ~ [cast(ubyte)(value ? 1 : 0)];
    }

    ubyte[] verboseAsciiStringArg(string s)
    {
        import std.bitmanip : nativeToBigEndian;

        const uint ti = TypeInfoFlags.TypeString | TypeInfoFlags.StringCodingASCII;
        ubyte[4] tib = nativeToBigEndian(ti);
        ushort len = cast(ushort)(s.length + 1); // +1 for null terminator
        ubyte[2] lb = nativeToBigEndian(len);
        ubyte[] result = tib[] ~ lb[];
        result ~= cast(ubyte[]) s;
        result ~= [cast(ubyte) 0]; // null terminator
        return result;
    }

    ubyte[] verboseFloat32Arg(float value)
    {
        import std.bitmanip : nativeToBigEndian;

        const uint ti = TypeInfoFlags.TypeFloat | Tyle.Tyle32Bit;
        ubyte[4] tib = nativeToBigEndian(ti);
        ubyte[4] vb = nativeToBigEndian(*cast(uint*)&value);
        return tib[] ~ vb[];
    }
}

// ─── parseDltItem Tests ───────────────────────────────────────────────────────

@("parseDltItem: truncated data returns false")
unittest
{
    DecodedMessage!char msg;
    ubyte[] data = [0, 1, 2]; // too short
    assert(parseDltItem(msg, data) == false);
}

@("parseDltItem: non-verbose without extended header and with storage header")
unittest
{
    auto data = buildDltMessage_without_storage_header(
        false, // no ext header
        false, // non-verbose
        0, // numArgs
        0, // msgType
        0, // logLevel
        0, // messageId
        [] // payload

        

    );

    DecodedMessage!char msg;
    assert(parseDltItem(msg, data, false));
    writeln("---------- msg.ecu: ", msg.ecu);
    assert(msg.ecu == "");
    assert(msg.payloadText == "Legacy DLT Message");
}

@("parseDltItem: non-verbose without extended header")
unittest
{
    auto data = buildDltMessage(
        false, // no ext header
        false, // non-verbose
        0, // numArgs
        0, // msgType
        0, // logLevel
        0, // messageId
        [] // payload

        

    );

    DecodedMessage!char msg;
    assert(parseDltItem(msg, data));
    assert(msg.ecu == "ECU1");
    assert(msg.payloadText == "Legacy DLT Message");
}

@("parseDltItem: non-verbose with message ID, no FIBEX")
unittest
{
    auto data = buildDltMessage(
        true, // with ext header
        false, // non-verbose
        0, // numArgs
        0, // msgType Log
        0, // logLevel
        0xDEAD, // messageId
        [], // extra payload after ID

        

    );

    DecodedMessage!char msg;
    assert(parseDltItem(msg, data));
    writefln("msg: %s (%d) msgId: %x", msg.payloadText, msg.payloadText.length, msg.messageId);
    assert(msg.messageId == 0xDEAD);
    import std.string : startsWith;
}

@("parseDltItem: verbose bool argument") unittest
{
    ubyte[] args = verboseBoolArg(true) ~ verboseBoolArg(false);
    auto data = buildDltMessage(
        true, // with ext header
        true, // verbose
        2, // numArgs
        cast(ubyte) MessageType.Log,
        cast(ubyte) LogLevel.Info,
        0,
        args,
    );

    DecodedMessage!char msg;
    assert(parseDltItem(msg, data));
    assert(msg.payloadText == "true false");
}

@("parseDltItem: verbose int32 argument")
unittest
{
    ubyte[] args = verboseInt32Arg(-42);
    auto data = buildDltMessage(true, true, 1,
        cast(ubyte) MessageType.Log, cast(ubyte) LogLevel.Error, 0, args);

    DecodedMessage!char msg;
    assert(parseDltItem(msg, data));
    assert(msg.payloadText == "-42");
    assert(msg.level == LogLevel.Error);
}

@("parseDltItem: verbose uint32 argument")
unittest
{
    ubyte[] args = verboseUint32Arg(12_345);
    auto data = buildDltMessage(true, true, 1,
        cast(ubyte) MessageType.Log, cast(ubyte) LogLevel.Debug, 0, args);

    DecodedMessage!char msg;
    assert(parseDltItem(msg, data));
    assert(msg.payloadText == "12345");
    assert(msg.level == LogLevel.Debug);
}

@("parseDltItem: verbose ASCII string argument")
unittest
{
    ubyte[] args = verboseAsciiStringArg("Hello DLT");
    auto data = buildDltMessage(true, true, 1,
        cast(ubyte) MessageType.Log, cast(ubyte) LogLevel.Info, 0, args);

    DecodedMessage!char msg;
    assert(parseDltItem(msg, data));
    assert(msg.payloadText == "Hello DLT");
}

@("parseDltItem: verbose mixed arguments")
unittest
{
    ubyte[] args = verboseAsciiStringArg("count")
        ~ verboseUint32Arg(7)
        ~ verboseBoolArg(true);

    auto data = buildDltMessage(true, true, 3,
        cast(ubyte) MessageType.Log, cast(ubyte) LogLevel.Warn, 0, args);

    DecodedMessage!char msg;
    assert(parseDltItem(msg, data));
    assert(msg.payloadText == "count 7 true");
    assert(msg.level == LogLevel.Warn);
}

@("parseDltItem: ECU/AppId/CtxId populated correctly")
unittest
{
    ubyte[] args = verboseBoolArg(true);
    auto data = buildDltMessage(true, true, 1,
        cast(ubyte) MessageType.Log, cast(ubyte) LogLevel.Info, 0, args,
        "MYEC", "MYAP", "MYCT");

    DecodedMessage!char msg;
    assert(parseDltItem(msg, data));
    assert(msg.ecu == "MYEC");
    assert(msg.appId == "MYAP");
    assert(msg.ctxId == "MYCT");
}

@("parseDltItem: timestamp populated correctly")
unittest
{
    ubyte[] args = verboseBoolArg(true);
    auto data = buildDltMessage(true, true, 1,
        cast(ubyte) MessageType.Log, cast(ubyte) LogLevel.Info, 0, args,
        "ECU1", "APP1", "CTX1", 9999, 123);

    DecodedMessage!char msg;
    assert(parseDltItem(msg, data));
    assert(msg.timestampSeconds == 9999);
    assert(msg.timestampMicroseconds == 123);
}

@("parseDltItem: message type AppTrace")
unittest
{
    ubyte[] args = verboseBoolArg(false);
    auto data = buildDltMessage(true, true, 1,
        cast(ubyte) MessageType.AppTrace, 0, 0, args);

    DecodedMessage!char msg;
    assert(parseDltItem(msg, data));
    assert(msg.type == MessageType.AppTrace);
}

@("parseDltItem: verbose float32 argument")
unittest
{
    ubyte[] args = verboseFloat32Arg(1.5f);
    auto data = buildDltMessage(true, true, 1,
        cast(ubyte) MessageType.Log, cast(ubyte) LogLevel.Info, 0, args);

    DecodedMessage!char msg;
    assert(parseDltItem(msg, data));
    import std.string : startsWith;

    assert(msg.payloadText.startsWith("1.5"));
}

@("parseDltItem: truncated verbose payload is handled gracefully")
unittest
{
    // Claim 3 args but supply bytes only for 1
    ubyte[] args = verboseUint32Arg(1); // only 1 arg worth of bytes
    auto data = buildDltMessage(true, true, 3,
        cast(ubyte) MessageType.Log, cast(ubyte) LogLevel.Info, 0, args);

    DecodedMessage!char msg;
    assert(parseDltItem(msg, data)); // must not crash
    // At least the one valid arg was decoded
    assert(msg.payloadText == "1");
}
