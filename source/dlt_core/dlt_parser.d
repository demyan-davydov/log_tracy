module dlt_core.dlt_parser;

import dlt_core.dlt_protocol;
import std.stdio;
import std.stdint;
import std.traits : isSomeChar;

import log_core.log_message;

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
            // is little-endian
            const bool isBigEndian = true;
            headers.extraTimestamp = readValue!uint(data[0 .. 4], isBigEndian);
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

bool parseDltItem(Char)(out LogMessage!Char msg, const(ubyte)[] data, bool hasStorageHeader = true) nothrow @nogc
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
    msg.relativeTimestamp_10000 = headers.extraTimestamp;
    msg.sessionId = headers.extraSessionId;
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
                        const(char)[] rawData = cast(const char[]) p[0 .. rlen];

                        // Strip trailing null terminator if present
                        if (rawData.length > 0 && rawData[$ - 1] == '\0')
                            rawData = rawData[0 .. $ - 1];

                        // If all bytes are printable ASCII, treat as text (same as old decodePayload)
                        const bool printable = isPrintable(rawData);

                        if (printable)
                            builder.appendUtf8(rawData); // handles ASCII + UTF-8 correctly
                        else
                            builder.appendHex(rawData);

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

    // ── Control message decoding (non-verbose Control type) ──────────────────
    // For non-verbose messages, findHeaders() puts the first 4 payload bytes
    // (the DLT Message ID / Service ID) into headers.messageId, and
    // headers.payload (= p) starts AFTER those 4 bytes.
    if (!payloadDecoded && headers.extended &&
        headers.extended.messageInfo.messageType() == MessageType.Control)
    {
        // Service ID already extracted by findHeaders → headers.messageId
        const uint svcId = headers.messageId;
        const ubyte ctrlTypeInfo = headers.extended.messageInfo.messageTypeInfo();
        // p already points past the service ID, at status byte (response) or request data

        // Helper function for service names including higher IDs (0xfXX)
        const(char)[] getControlServiceName(uint id) @nogc nothrow
        {
            switch (id)
            {
            case 0x01:
                return "set_log_level";
            case 0x02:
                return "set_trace_status";
            case 0x03:
                return "get_log_info";
            case 0x04:
                return "get_default_log_level";
            case 0x05:
                return "store_config";
            case 0x06:
                return "reset_to_factory_default";
            case 0x07:
                return "set_com_interface_status";
            case 0x08:
                return "set_com_bw";
            case 0x09:
                return "set_verbose_mode";
            case 0x0A:
                return "set_msg_filtering";
            case 0x0B:
                return "set_timing_packets";
            case 0x0C:
                return "get_local_time";
            case 0x0D:
                return "use_ecu_id";
            case 0x0E:
                return "use_session_id";
            case 0x0F:
                return "use_timestamp";
            case 0x10:
                return "use_extended_header";
            case 0x11:
                return "set_default_log_level";
            case 0x12:
                return "set_default_trace_status";
            case 0x13:
                return "get_software_version";
            case 0x14:
                return "message_buffer_overflow";
            case 0xf01:
                return "unregister_context";
            case 0xf02:
                return "connection_info";
            case 0xf03:
                return "timezone";
            case 0xf04:
                return "marker";
            default:
                return "ctrl";
            }
        }

        const(char)[] svcName = getControlServiceName(svcId);

        const bool isResponse = (ctrlTypeInfo == cast(ubyte) ControlType.Response);

        // Build prefix "[svcname ok]" / "[svcname err]" / "[svcname req]" in one call.
        // PayloadBuilder adds a space separator between consecutive append*() calls,
        // so we must write the full prefix as a SINGLE appendAscii() to avoid
        // unwanted extra spaces. Content appended after will get exactly one separator.
        char[64] label;
        size_t llen = 0;
        void addToLabel(const(char)[] s) @nogc nothrow
        {
            foreach (c; s)
                if (llen < label.length)
                    label[llen++] = c;
        }

        addToLabel("[");
        addToLabel(svcName);

        if (isResponse && p.length >= 1)
        {
            const ubyte status = p[0];
            p = p[1 .. $];
            const bool ok = (status == ServiceResponseStatus.Ok);

            addToLabel(ok ? " ok]" : " err]");
            builder.appendAscii(label[0 .. llen]); // single call: "[svcname ok]"

            // GET_SOFTWARE_VERSION: uint32 length + string
            if (svcId == ServiceID.GetSoftwareVersion && ok && p.length >= 4)
            {
                const uint strLen = readValue!uint(p[0 .. 4], msbf);
                p = p[4 .. $];
                if (p.length >= strLen)
                {
                    const(char)[] sv = cast(const char[]) p[0 .. strLen];
                    if (sv.length > 0 && sv[$ - 1] == '\0')
                        sv = sv[0 .. $ - 1];
                    if (sv.length > 0) // skip empty: appendUtf8("") still adds a separator
                        builder.appendUtf8(sv); // separator + version string
                    p = p[strLen .. $];
                }
            }
            // CONNECTION_INFO: payload often starts with state byte (1=Disconnected, 2=Connected)
        else if (svcId == ServiceID.ConnectionInfo && ok && p.length >= 1)
            {
                // State is usually the first byte
                const ubyte state = msbf && p.length >= 4 ? p[3] : p[0];
                if (state == ServiceConnectionState.Connected)
                    builder.appendAscii("connected");
                else if (state == ServiceConnectionState.Disconnected)
                    builder.appendAscii("disconnected");
                else
                    builder.appendHex(cast(const char[]) p); // unknown format, dump hex
            }
            else if (p.length > 0)
            {
                // Generic: remaining payload as text or hex
                const(char)[] rest = cast(const char[]) p;
                if (isPrintable(rest))
                    builder.appendUtf8(rest);
                else
                    builder.appendHex(rest);
            }
        }
        else
        {
            // Request or missing status: show "[svcname req]" + optional data
            addToLabel(" req]");
            builder.appendAscii(label[0 .. llen]); // single call: "[svcname req]"
            if (p.length > 0)
            {
                const(char)[] rest = cast(const char[]) p;
                if (isPrintable(rest))
                    builder.appendUtf8(rest);
                else
                    builder.appendHex(rest);
            }
        }

        msg.messageId = svcId;
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

bool isPrintable(const(char)[] s) @nogc nothrow
{
    foreach (c; s)
    {
        if (c < 32 && c != '\n' && c != '\r' && c != '\t')
            return false;
    }
    return true;
}

bool isPrintable(const(ubyte)[] s) @nogc nothrow
{
    return isPrintable(cast(const(char)[]) s);
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
    LogMessage!char msg;
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

    LogMessage!char msg;
    assert(parseDltItem(msg, data, false));
    assert(msg.ecuId == "");
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

    LogMessage!char msg;
    assert(parseDltItem(msg, data));
    assert(msg.ecuId == "ECU1");
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

    LogMessage!char msg;
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

    LogMessage!char msg;
    assert(parseDltItem(msg, data));
    assert(msg.payloadText == "true false");
}

@("parseDltItem: verbose int32 argument")
unittest
{
    ubyte[] args = verboseInt32Arg(-42);
    auto data = buildDltMessage(true, true, 1,
        cast(ubyte) MessageType.Log, cast(ubyte) LogLevel.Error, 0, args);

    LogMessage!char msg;
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

    LogMessage!char msg;
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

    LogMessage!char msg;
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

    LogMessage!char msg;
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

    LogMessage!char msg;
    assert(parseDltItem(msg, data));
    assert(msg.ecuId == "MYEC");
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

    LogMessage!char msg;
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

    LogMessage!char msg;
    assert(parseDltItem(msg, data));
    assert(msg.type == MessageType.AppTrace);
}

@("parseDltItem: verbose float32 argument")
unittest
{
    ubyte[] args = verboseFloat32Arg(1.5f);
    auto data = buildDltMessage(true, true, 1,
        cast(ubyte) MessageType.Log, cast(ubyte) LogLevel.Info, 0, args);

    LogMessage!char msg;
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

    LogMessage!char msg;
    assert(parseDltItem(msg, data)); // must not crash
    // At least the one valid arg was decoded
    assert(msg.payloadText == "1");
}

// ─── Control Message Tests ────────────────────────────────────────────────────
//
// buildDltMessage sets MSBF=1 (big-endian), so uint32 fields in payload must be BE.
// Control message payload structure (response):
//   [4 bytes service ID BE] [1 byte status] [service-specific data]
// Control message payload structure (request):
//   [4 bytes service ID BE] [service-specific data]

version (unittest)
{
    // Build a non-verbose control message.
    // ctrlType: ControlType.Request (1) or ControlType.Response (2)
    ubyte[] buildControlMsg(uint svcId, ubyte ctrlType, ubyte[] payload,
        string ecuId = "ECU1", string appId = "APP1", string ctxId = "CTX1")
    {
        return buildDltMessage(
            true, // with extended header
            false, // non-verbose
            0, // numArgs unused for control
            cast(ubyte) MessageType.Control,
            ctrlType, // goes into bits 4-7 of messageInfo
            svcId, // messageId (for non-verbose this is prepended by buildDltMessage)
            payload,
            ecuId, appId, ctxId,
        );
    }

    // Build [status | extra] payload (service ID is handled by buildControlMsg)
    ubyte[] ctrlResponsePayload(ubyte status, ubyte[] extra = [])
    {
        return [status] ~ extra;
    }

    // Build GET_SOFTWARE_VERSION ok response payload (string)
    ubyte[] getSoftwareVersionPayload(string version_)
    {
        import std.bitmanip : nativeToBigEndian;

        ubyte[] str = cast(ubyte[])(version_ ~ "\0"); // null-terminated
        ubyte[4] len = nativeToBigEndian(cast(uint) str.length);
        return ctrlResponsePayload(0x00, len[] ~ str);
    }
}

@("parseDltItem: control get_software_version response ok")
unittest
{
    // Use default 4-char IDs — 3-char IDs leave 4th byte as char.init=0xFF which fails isASCII
    auto data = buildControlMsg(
        0x13,
        cast(ubyte) ControlType.Response,
        getSoftwareVersionPayload("MyApp v2.5.1"),
    );

    LogMessage!char msg;
    assert(parseDltItem(msg, data));
    assert(msg.type == MessageType.Control);
    assert(msg.messageId == 0x13);
    assert(msg.payloadText == "[get_software_version ok] MyApp v2.5.1");
}

@("parseDltItem: control get_software_version response ok - empty version string")
unittest
{
    // Edge: version string is just a null terminator (length=1, string="")
    auto data = buildControlMsg(
        0x13,
        cast(ubyte) ControlType.Response,
        getSoftwareVersionPayload(""),
    );
    LogMessage!char msg;
    assert(parseDltItem(msg, data));
    assert(msg.messageId == 0x13);
    assert(msg.payloadText == "[get_software_version ok]");
}

@("parseDltItem: control get_software_version response error")
unittest
{
    ubyte[] payload = [cast(ubyte) ServiceResponseStatus.Error];
    auto data = buildControlMsg(0x13, cast(ubyte) ControlType.Response, payload);

    LogMessage!char msg;
    assert(parseDltItem(msg, data));
    assert(msg.messageId == 0x13);

    import std.algorithm : startsWith;

    assert(msg.payloadText.startsWith("[get_software_version err]"));
}

@("parseDltItem: control set_log_level response ok")
unittest
{
    auto data = buildControlMsg(
        0x01,
        cast(ubyte) ControlType.Response,
        ctrlResponsePayload(ServiceResponseStatus.Ok),
    );
    LogMessage!char msg;
    assert(parseDltItem(msg, data));
    assert(msg.messageId == 0x01);

    import std.algorithm : startsWith;

    assert(msg.payloadText.startsWith("[set_log_level ok]"));
}

@("parseDltItem: control unknown service response")
unittest
{
    // Service ID 0xFF (unknown) → falls into generic branch with "ctrl" name
    ubyte[] payload = [cast(ubyte) ServiceResponseStatus.Ok] ~ cast(ubyte[]) "hello";
    auto data = buildControlMsg(0xFF, cast(ubyte) ControlType.Response, payload);

    LogMessage!char msg;
    assert(parseDltItem(msg, data));
    assert(msg.messageId == 0xFF);

    import std.algorithm : startsWith, canFind;

    assert(msg.payloadText.startsWith("[ctrl ok]"));
    assert(msg.payloadText.canFind("hello"));
}

@("parseDltItem: control request message")
unittest
{
    // Request: ctrlType = ControlType.Request, no status byte
    auto data = buildControlMsg(0x09, cast(ubyte) ControlType.Request, []);

    LogMessage!char msg;
    assert(parseDltItem(msg, data));
    assert(msg.messageId == 0x09);

    import std.algorithm : startsWith;

    assert(msg.payloadText.startsWith("[set_verbose_mode req]"));
}

@("parseDltItem: control golden test - real get_software_version from DLT file")
unittest
{
    // Bytes captured from real DLT file, MSBF=0 (little-endian), with storage header.
    // Message index=6: GET_SOFTWARE_VERSION response, payload = "ID=mbient\n..."
    static immutable ubyte[] raw = cast(immutable ubyte[]) x"
        444C5401 A6B03769 00000000 4C4E5800
        350000E0 4C4E5800 0012D390 26014441
        31004443 31001300 000000C1 00000049
        443D6D62 69656E74 0A49445F 4C494B45
        3D226175 746F6D6F 74697665 220A4E41
        4D453D22 4D426945 4E542028 4275696C
        74206F6E 20596F63 746F2031 2E302922
        0A564552 53494F4E 3D22312E 3020286B
        69726B73 746F6E65 29220A56 45525349
        4F4E5F49 443D312E 300A5052 45545459
        5F4E414D 453D224D 4269454E 54202842
        75696C74 206F6E20 596F6374 6F20312E
        30292031 2E302028 6B69726B 73746F6E
        6529220A 44495354 524F5F43 4F44454E
        414D453D 226B6972 6B73746F 6E65220A
    ";

    LogMessage!char msg;
    assert(parseDltItem(msg, raw));

    // Metadata from storage/standard/extended headers
    assert(msg.ecuId == "LNX");
    assert(msg.appId == "DA1");
    assert(msg.ctxId == "DC1");
    assert(msg.type == MessageType.Control);
    writeln("msg.messageId: ", msg.messageId);
    assert(msg.messageId == 0x13);

    // Relative timestamp: 0x0012D390 = 1233808 × 0.1ms ≈ 123380.8ms → stored as-is
    // (relativeTimestamp_10000 lives in LogMessage; we just check it parses):

    import std.algorithm : startsWith, canFind;

    assert(msg.payloadText.startsWith("[get_software_version ok]"));
    assert(msg.payloadText.canFind("ID=mbient"));
    assert(msg.payloadText.canFind("kirkstone"));
}
