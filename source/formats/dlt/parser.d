module formats.dlt.parser;

//! Decodes a DLT record (protocol version 1 or 2) into a LogMessage: the
//! headers, the arguments of a verbose message, the services of a control
//! message and the message ID and data of a non-verbose one.

import formats.dlt.protocol;
import formats.dlt.header_v2;
import std.stdio;
import std.stdint;
import std.traits : isSomeChar;

import log_core.log_message;
import formats.dlt.fields;

//! @brief DLT Message structure (protocol version 1, see header_v2 for version 2):
//! [ Storage Header ]        (in files: 16 bytes in version 1, 14 + ECU ID in version 2)
//! [ Standard Header ]       (minimum 4 bytes)
//! [ Extra Header Fields ]   (up to 12 bytes, depends on 'StandardHeader.headerType', always big-endian)
//! [ Extended Header ]       (if 'StandardHeader.headerType' has 'UseExtendedHeader' flag)
//! [ Payload ]               (byte order depends on 'StandardHeader.isBigEndian()')

//! The headers of a protocol version 1 message, after its storage header
struct LogItemHeaders
{
    const(StandardHeader)* standard;
    const(ExtendedHeader)* extended;
    const(ubyte)[] payload; // after the message ID when the record has one

    // A non-verbose message (with or without extended header) starts its payload
    // with a message ID; a control message keeps its service ID there
    bool hasMessageId;
    uint32_t messageId;

    // Extra header fields for StandardHeader.Type.WithEcuId, StandardHeader.Type.WithSessionId, StandardHeader.Type.WithTimestamp
    char[4] extraEcuId = 0;
    uint32_t extraSessionId;
    uint32_t extraTimestamp;
}

//! Finds the headers of the protocol version 1 message at the start of `data`
//! (no storage header): `standard` is null if it is too short
LogItemHeaders findHeaders(const(ubyte)[] data) pure nothrow @nogc
{
    LogItemHeaders headers;

    if (data.length < StandardHeader.sizeof)
        return headers; // invalid (no standard header)

    headers.standard = cast(const(StandardHeader)*) data.ptr;
    data = data[StandardHeader.sizeof .. $];

    // The extra fields are big-endian whatever the byte order of the payload
    enum bool bigEndian = true;

    if (headers.standard.withEcuId)
    {
        if (data.length < 4)
            return headers;
        headers.extraEcuId[] = cast(char[4]) data[0 .. 4];
        data = data[4 .. $];
    }

    if (headers.standard.withSessionId)
    {
        if (data.length < 4)
            return headers;
        headers.extraSessionId = readValue!uint(data[0 .. 4], bigEndian);
        data = data[4 .. $];
    }

    if (headers.standard.withTimestamp)
    {
        if (data.length < 4)
            return headers;
        headers.extraTimestamp = readValue!uint(data[0 .. 4], bigEndian);
        data = data[4 .. $];
    }

    bool verbose = false; // a message without extended header is non-verbose
    if (headers.standard.useExtendedHeader)
    {
        if (data.length < ExtendedHeader.sizeof)
            return headers; // invalid (no extended header)

        headers.extended = cast(const(ExtendedHeader)*) data.ptr;
        data = data[ExtendedHeader.sizeof .. $];
        verbose = headers.extended.messageInfo.isVerbose;
    }

    if (!verbose && data.length >= 4)
    {
        headers.hasMessageId = true;
        headers.messageId = readValue!uint(data[0 .. 4], headers.standard.isBigEndian());
        data = data[4 .. $];
    }

    headers.payload = data;
    return headers;
}

//! @brief Decodes a DLT message into `msg`, reusing its buffer
//! @note `msg` is `ref`, not `out`: `out` resets it to .init without its
//! destructor, which leaks the buffer and allocates a new one on every call.
bool parseDltItem(Char)(ref LogMessage!Char msg, const(ubyte)[] data, bool hasStorageHeader = true) nothrow @nogc
        if (isSomeChar!Char)
{
    StorageInfo storage;
    const(ubyte)[] message = data;
    if (hasStorageHeader)
    {
        storage = readStorageHeader(data);
        if (storage.size == 0)
        {
            msg.clear();
            return false;
        }
        message = data[storage.size .. $];
    }

    const ubyte version_ = protocolVersion(message);
    if (version_ == 2)
        return decodeV2(msg, storage, message);

    const LogItemHeaders headers = findHeaders(message);
    if (headers.standard is null)
    {
        msg.clear();
        return false;
    }

    const bool msbf = headers.standard.isBigEndian();

    if (version_ > 2) // 0 is written by old loggers
    {
        // Only the storage header is known: the rest has another layout
        auto builder = msg.beginDltRecord(storage.ecuId, "", "");
        setStorageTime(msg, storage);
        msg.level = LogLevel.None;

        ShortText!48 text;
        text.add("[DLT protocol version ");
        text.add(version_);
        text.add(" is not supported]");
        builder.appendAscii(text.text);
        return true;
    }

    // ── ECU ID ──────────────────────────────────────────────────────────────
    // The ECU of the message itself wins over the one of the storage header:
    // a logger behind a gateway is stored with the ECU of the gateway
    const char[] ecuId = headers.standard.withEcuId || storage.size == 0
        ? headers.extraEcuId[] : storage.ecuId;

    // ── AppId / CtxId / level / type ────────────────────────────────────────
    const(char)[] appId = "-";
    const(char)[] ctxId = "-";
    LogLevel level = LogLevel.None;
    MessageType msgType = MessageType.Log;

    if (headers.extended)
    {
        appId = cast(const char[]) headers.extended.applicationId[];
        ctxId = cast(const char[]) headers.extended.contextId[];
        level = headers.extended.messageInfo.logLevel();
        msgType = headers.extended.messageInfo.messageType();
    }

    // Resets the message and stores ecu/appId/ctxId
    auto builder = msg.beginDltRecord(ecuId, appId, ctxId);

    // ── scalar metadata ─────────────────────────────────────────────────────
    setStorageTime(msg, storage);
    msg.setNumber(DltField.Counter, headers.standard.messageCounter);
    if (headers.standard.withTimestamp)
        msg.setNumber(DltField.Timestamp, headers.extraTimestamp);
    if (headers.standard.withSessionId)
        msg.setNumber(DltField.SessionId, headers.extraSessionId);
    msg.level = level;
    msg.setNumber(DltField.Type, msgType);
    if (headers.hasMessageId)
        msg.messageId = headers.messageId;

    // ── Payload ─────────────────────────────────────────────────────────────
    if (headers.extended && headers.extended.messageInfo.isVerbose())
        decodeArguments(builder, headers.payload, headers.extended.numberOfArguments, msbf);
    else if (headers.extended && msgType == MessageType.Control)
        decodeControl(builder, headers.messageId,
            headers.extended.messageInfo.messageTypeInfo(), headers.payload, msbf);
    else
        decodeNonVerbose(builder, headers.hasMessageId, headers.messageId, headers.payload);

    // builder destructor calls storePayload() automatically
    return true;
}

//! Decodes a message of protocol version 2 (no storage header in `message`).
//! Its payload is little-endian: dlt-viewer reads it so, the protocol doesn't say.
private bool decodeV2(Char)(ref LogMessage!Char msg, ref const StorageInfo storage,
    const(ubyte)[] message) nothrow @nogc
{
    HeaderV2 h;
    if (readHeaderV2(message, h) != HeaderV2Status.ok)
    {
        auto builder = msg.beginDltRecord(storage.ecuId, "", "");
        setStorageTime(msg, storage);
        msg.level = LogLevel.None;
        builder.appendAscii("[invalid DLT version 2 header]");
        return true;
    }

    auto builder = msg.beginDltRecord(h.hasEcuId ? h.ecuId : storage.ecuId,
        h.hasAppContextId ? h.appId : "-", h.hasAppContextId ? h.ctxId : "-");

    setStorageTime(msg, storage);
    msg.setNumber(DltField.Counter, h.counter);
    if (h.hasTimestamp)
    {
        long utc;
        if (h.sinceStartup) // in the 0.1 ms of version 1
            msg.setNumber(DltField.Timestamp, h.seconds * 10_000 + h.nanoseconds / 100_000);
        else if ((h.seconds != 0 || h.nanoseconds != 0) && toTimeNs(h.seconds, h.nanoseconds, utc))
        {
            // The time of the message wins over the time it was stored, as in
            // dlt-viewer; a logger that leaves it at zero keeps the stored time
            msg.timeNs = utc;
            msg.timeKind = TimeKind.Absolute;
        }
    }
    if (h.hasSessionId)
        msg.setNumber(DltField.SessionId, h.sessionId);
    msg.level = h.hasMessageInfo ? h.messageInfo.logLevel() : LogLevel.None;
    if (h.hasMessageInfo)
        msg.setNumber(DltField.Type, h.messageInfo.messageType());
    if (h.hasMessageId)
        msg.messageId = h.messageId;

    enum bool msbf = false;
    const(ubyte)[] payload = message[h.size .. h.length <= message.length ? h.length : $];

    if (h.segmented)
    {
        appendSegment(builder, h);
        return true;
    }

    final switch (h.content)
    {
    case ContentInfo.Verbose:
        decodeArguments(builder, payload, h.numberOfArguments, msbf);
        break;
    case ContentInfo.NonVerbose:
        decodeNonVerbose(builder, true, h.messageId, payload);
        break;
    case ContentInfo.Control:
        uint serviceId = 0;
        if (payload.length >= 4)
        {
            serviceId = readValue!uint(payload[0 .. 4], msbf);
            msg.messageId = serviceId;
            payload = payload[4 .. $];
        }
        decodeControl(builder, serviceId, h.messageInfo.messageTypeInfo(), payload, msbf);
        break;
    }
    return true;
}

//! Appends the frame of a segmented version 2 message, as dlt-viewer shows it
private void appendSegment(Builder)(ref Builder builder, ref const HeaderV2 h) nothrow @nogc
{
    ShortText!64 text;
    text.add("Segmentation: ");
    switch (h.segmentFrame)
    {
    case SegmentFrame.First:
        text.add("First Frame with total length ");
        text.add(h.segmentTotalLength);
        break;
    case SegmentFrame.Consecutive:
        text.add("Consecutive Frame number ");
        text.add(h.segmentNumber);
        break;
    case SegmentFrame.Last:
        text.add("Last Frame");
        break;
    case SegmentFrame.Abort:
        text.add("Abort Frame with abort reason ");
        text.add(h.segmentAbortReason);
        break;
    default:
        text.add("Frame of type ");
        text.add(h.segmentFrame);
        break;
    }
    builder.appendAscii(text.text);
}

//! Sets the time of the storage header, if the record has one
private void setStorageTime(Char)(ref LogMessage!Char msg, ref const StorageInfo storage) nothrow @nogc
{
    long timeNs;
    if (storage.size == 0 || !toTimeNs(storage.seconds, storage.nanoseconds, timeNs))
        return;
    msg.timeNs = timeNs;
    msg.timeKind = TimeKind.Absolute;
}

//! A text of at most `capacity` characters built from pieces: what doesn't
//! fit is dropped
private struct ShortText(size_t capacity)
{
    private char[capacity] _chars;
    private size_t _length;

    void add(const(char)[] piece) pure nothrow @nogc
    {
        foreach (c; piece)
            if (_length < capacity)
                _chars[_length++] = c;
    }

    void add(T)(T number) pure nothrow @nogc if (__traits(isIntegral, T))
    {
        import std.conv : toChars;

        foreach (c; toChars(number))
            if (_length < capacity)
                _chars[_length++] = c;
    }

    const(char)[] text() const pure nothrow @nogc return
    {
        return _chars[0 .. _length];
    }
}

//! Appends the arguments of a verbose message. An argument that can't be
//! decoded stops decoding: it and the rest of the payload are shown in hex.
private void decodeArguments(Builder)(ref Builder builder, const(ubyte)[] payload,
    uint count, bool msbf) nothrow @nogc
{
    foreach (_; 0 .. count)
    {
        if (payload.length == 0)
            return;

        const rest = payload;
        if (!decodeArgument(builder, payload, msbf))
        {
            builder.appendHex(cast(const(char)[]) rest);
            return;
        }
    }
}

//! Appends the argument at the start of `payload` and moves `payload` past it.
//! @returns false, leaving `payload` as it was, if the argument has a type that
//! isn't supported or doesn't fit in the payload
private bool decodeArgument(Builder)(ref Builder builder, ref const(ubyte)[] payload, bool msbf) nothrow @nogc
{
    alias F = TypeInfoFlags;
    enum Kind
    {
        String,
        Bool,
        Signed,
        Unsigned,
        Float,
        Raw,
        Trace
    }

    const(ubyte)[] p = payload;

    bool take(T)(ref T value)
    {
        if (p.length < T.sizeof)
            return false;
        value = readValue!T(p[0 .. T.sizeof], msbf);
        p = p[T.sizeof .. $];
        return true;
    }

    bool skip(size_t count)
    {
        if (p.length < count)
            return false;
        p = p[count .. $];
        return true;
    }

    uint typeInfo;
    if (!take(typeInfo))
        return false;

    // The same priority as dlt-viewer when several type bits are set
    Kind kind;
    if (typeInfo & F.TypeString)
        kind = Kind.String;
    else if (typeInfo & F.TypeBoolean)
        kind = Kind.Bool;
    else if (typeInfo & F.TypeSigned)
        kind = Kind.Signed;
    else if (typeInfo & F.TypeUnsigned)
        kind = Kind.Unsigned;
    else if (typeInfo & F.TypeFloat)
        kind = Kind.Float;
    else if (typeInfo & F.TypeRaw)
        kind = Kind.Raw;
    else if (typeInfo & F.TypeTraceInfo)
        kind = Kind.Trace;
    else
        return false; // arrays, structs, nothing at all

    const bool hasLength = kind == Kind.String || kind == Kind.Raw || kind == Kind.Trace;
    const bool isNumber = kind == Kind.Signed || kind == Kind.Unsigned || kind == Kind.Float;

    // A length-prefixed value: its length comes first, before the variable info
    ushort dataLength;
    if (hasLength && !take(dataLength))
        return false;

    // Variable info: the lengths of the name (and of the unit for a number),
    // then the name (and the unit). Neither is shown.
    if (typeInfo & F.VariableInfo)
    {
        ushort nameLength, unitLength;
        if (!take(nameLength) || (isNumber && !take(unitLength)))
            return false;
        if (!skip(nameLength + unitLength))
            return false;
    }

    size_t valueSize = dataLength;
    if (kind == Kind.Bool)
        valueSize = 1;
    else if (isNumber)
    {
        valueSize = sizeOfTyle(typeInfo & F.LengthMask);
        if (valueSize == 0)
            return false;
    }

    // Fixed point: a float32 quantization and an offset of the size of the
    // value, 32 bits at least. The raw value is shown.
    if (isNumber && (typeInfo & F.FixedPoint))
    {
        if (!skip(4 + (valueSize < 4 ? 4 : valueSize)))
            return false;
    }

    if (p.length < valueSize)
        return false;
    const(ubyte)[] value = p[0 .. valueSize];
    p = p[valueSize .. $];

    final switch (kind)
    {
    case Kind.String:
    case Kind.Trace:
        const text = withoutTrailingZeros(cast(const(char)[]) value);
        if ((typeInfo & F.StringCodingMask) == F.StringCodingUTF8)
            builder.appendUtf8(text);
        else
            builder.appendAscii(text);
        break;
    case Kind.Raw:
        builder.appendHex(cast(const(char)[]) value);
        break;
    case Kind.Bool:
        builder.appendBool(value[0] != 0);
        break;
    case Kind.Signed:
    case Kind.Unsigned:
        appendInteger(builder, value, typeInfo, kind == Kind.Signed, msbf);
        break;
    case Kind.Float:
        if (valueSize == 2)
            builder.append(halfToFloat(readValue!ushort(value, msbf)));
        else if (valueSize == 4)
            builder.append(readValue!float(value, msbf));
        else if (valueSize == 8)
            builder.append(readValue!double(value, msbf));
        else
            builder.appendAscii("?"); // 8 or 128 bits: no such float to show
        break;
    }

    payload = p;
    return true;
}

//! @returns the size in bytes of a TYLE value, 0 for an invalid one
private size_t sizeOfTyle(uint tyle) pure nothrow @nogc
{
    switch (tyle)
    {
    case Tyle.Tyle8Bit:
        return 1;
    case Tyle.Tyle16Bit:
        return 2;
    case Tyle.Tyle32Bit:
        return 4;
    case Tyle.Tyle64Bit:
        return 8;
    case Tyle.Tyle128Bit:
        return 16;
    default:
        return 0;
    }
}

//! Appends an integer of 1..16 bytes: in decimal, or in hex or binary when its
//! coding says so. 128-bit values are always shown in hex.
private void appendInteger(Builder)(ref Builder builder, const(ubyte)[] value, uint typeInfo,
    bool signed, bool msbf) nothrow @nogc
{
    const coding = typeInfo & TypeInfoFlags.StringCodingMask;

    if (coding == TypeInfoFlags.StringCodingBIN)
    {
        char[2 + 16 * 8] text = "0b";
        size_t length = 2;
        foreach (i; 0 .. value.length)
        {
            const b = value[msbf ? i : value.length - 1 - i];
            foreach_reverse (bit; 0 .. 8)
                text[length++] = (b >> bit) & 1 ? '1' : '0';
        }
        builder.appendAscii(text[0 .. length]);
        return;
    }

    if (coding == TypeInfoFlags.StringCodingHEX || value.length == 16)
    {
        static immutable char[16] digits = "0123456789ABCDEF";
        char[2 + 16 * 2] text = "0x";
        size_t length = 2;
        foreach (i; 0 .. value.length)
        {
            const b = value[msbf ? i : value.length - 1 - i];
            text[length++] = digits[b >> 4];
            text[length++] = digits[b & 0x0F];
        }
        builder.appendAscii(text[0 .. length]);
        return;
    }

    switch (value.length)
    {
    case 1:
        if (signed)
            builder.append(cast(byte) value[0]);
        else
            builder.append(value[0]);
        break;
    case 2:
        if (signed)
            builder.append(readValue!short(value, msbf));
        else
            builder.append(readValue!ushort(value, msbf));
        break;
    case 4:
        if (signed)
            builder.append(readValue!int(value, msbf));
        else
            builder.append(readValue!uint(value, msbf));
        break;
    default:
        if (signed)
            builder.append(readValue!long(value, msbf));
        else
            builder.append(readValue!ulong(value, msbf));
        break;
    }
}

//! @returns an IEEE 754 half-precision value as a float
float halfToFloat(ushort half) pure nothrow @nogc
{
    import std.math : ldexp;

    const negative = (half & 0x8000) != 0;
    const int exponent = (half >> 10) & 0x1F;
    const int mantissa = half & 0x3FF;

    float result;
    if (exponent == 0) // subnormal
        result = ldexp(cast(float) mantissa, -24);
    else if (exponent == 0x1F)
        result = mantissa == 0 ? float.infinity : float.nan;
    else
        result = ldexp(cast(float)(mantissa | 0x400), exponent - 25);

    return negative ? -result : result;
}

//! Appends the message ID of a non-verbose message, if its payload is long
//! enough to hold one, and its data as a hex dump
private void decodeNonVerbose(Builder)(ref Builder builder, bool hasMessageId, uint messageId,
    const(ubyte)[] data) nothrow @nogc
{
    if (hasMessageId)
    {
        ShortText!16 label;
        label.add("[");
        label.add(messageId);
        label.add("]");
        builder.appendAscii(label.text);
    }
    if (data.length == 0)
        return;
    builder.appendHex(cast(const(char)[]) data);
    builder.appendAsciiDump(cast(const(char)[]) data);
}

//! Appends a control message: "[service status]" and what the service answered
//! `controlType` is the MTIN of the message, `data` follows the service ID.
private void decodeControl(Builder)(ref Builder builder, uint serviceId, ubyte controlType,
    const(ubyte)[] data, bool msbf) nothrow @nogc
{
    const(ubyte)[] p = data;

    ShortText!64 label;
    label.add("[");
    label.add(controlServiceName(serviceId));

    if (controlType != ControlType.Response || p.length == 0)
    {
        if (controlType == ControlType.Request)
            label.add(" req");
        else if (controlType == ControlType.Time)
            label.add(" time");
        label.add("]");
        builder.appendAscii(label.text);
        appendData(builder, p);
        return;
    }

    const ubyte status = p[0];
    p = p[1 .. $];
    const bool ok = status == ServiceResponseStatus.Ok
        || (serviceId == ServiceID.GetLogInfo && status >= 3 && status <= 7);

    if (ok && serviceId == ServiceID.Marker)
    {
        builder.appendAscii("MARKER");
        return;
    }

    label.add(" ");
    if (ok)
        label.add("ok");
    else
        addResponseStatus(label, status);
    label.add("]");
    builder.appendAscii(label.text);

    if (!ok)
    {
        appendData(builder, p);
        return;
    }

    switch (serviceId)
    {
    case ServiceID.GetSoftwareVersion:
        // uint32 length, then the version
        if (p.length >= 4)
        {
            const uint strLen = readValue!uint(p[0 .. 4], msbf);
            if (p.length - 4 >= strLen)
            {
                const version_ = withoutTrailingZeros(cast(const(char)[]) p[4 .. 4 + strLen]);
                if (version_.length > 0)
                    builder.appendUtf8(version_);
                return;
            }
        }
        break;

    case ServiceID.GetLogInfo:
        // Its status is the options it was asked for: 0 says nothing of the layout
        if (status >= 3 && appendLogInfo(builder, status, p, msbf))
            return;
        break;

    case ServiceID.ConnectionInfo:
        // state, then the communication interface
        if (p.length >= 1)
        {
            if (p[0] == ServiceConnectionState.Connected)
                builder.appendAscii("connected");
            else if (p[0] == ServiceConnectionState.Disconnected)
                builder.appendAscii("disconnected");
            else
                builder.appendAscii("unknown");
            if (p.length >= 5)
                builder.appendAscii(removeIdPadding(cast(const(char)[]) p[1 .. 5]));
            return;
        }
        break;

    case ServiceID.Timezone:
        // int32 offset from UTC in seconds, then a daylight saving time flag
        if (p.length >= 5)
        {
            builder.append(readValue!int(p[0 .. 4], msbf));
            builder.appendAscii("s");
            if (p[4] != 0)
                builder.appendAscii("DST");
            return;
        }
        break;

    default:
        break;
    }

    appendData(builder, p);
}

//! Appends the applications and contexts of a get_log_info response:
//! "APP (description): CTX level=info trace=on (description), CTX2; APP2: ..."
//! Its options (the status) say what a context has, as dlt-daemon writes it:
//! 4 the log level, 5 the trace status, 6 both, 7 both and the descriptions
//! (an application has its own after its contexts). The communication
//! interface may follow the applications ("remo"), it is not shown.
//! @returns false, appending nothing, if `data` doesn't hold what it announces
//! or holds more
private bool appendLogInfo(Builder)(ref Builder builder, ubyte options, const(ubyte)[] data,
    bool msbf) nothrow @nogc
{
    const bool hasLevel = options == 4 || options == 6 || options == 7;
    const bool hasTrace = options == 5 || options == 6 || options == 7;
    const bool hasDescriptions = options == 7;

    static struct Reader
    {
        const(ubyte)[] p;
        bool msbf;

        bool count(out ushort value) nothrow @nogc
        {
            if (p.length < 2)
                return false;
            value = readValue!ushort(p[0 .. 2], msbf);
            p = p[2 .. $];
            return true;
        }

        bool bytes(size_t length, out const(ubyte)[] value) nothrow @nogc
        {
            if (p.length < length)
                return false;
            value = p[0 .. length];
            p = p[length .. $];
            return true;
        }

        bool text(out const(char)[] value) nothrow @nogc
        {
            ushort length;
            const(ubyte)[] b;
            if (!count(length) || !bytes(length, b))
                return false;
            value = withoutTrailingZeros(cast(const(char)[]) b);
            return true;
        }
    }

    // One context, given to `visit` unless it is null
    static bool context(ref Reader r, bool hasLevel, bool hasTrace, bool hasDescriptions,
        scope void delegate(const(char)[] id, int level, int trace, const(char)[] description) nothrow @nogc visit) nothrow @nogc
    {
        const(ubyte)[] id, level, trace;
        const(char)[] description;
        if (!r.bytes(4, id) || (hasLevel && !r.bytes(1, level)) || (hasTrace && !r.bytes(1, trace))
                || (hasDescriptions && !r.text(description)))
            return false;
        if (visit !is null)
            visit(removeIdPadding(cast(const(char)[]) id),
                hasLevel ? cast(byte) level[0] : int.min, hasTrace ? cast(byte) trace[0] : int.min, description);
        return true;
    }

    // An application: its ID, contexts and description, given to `visit` unless null
    static bool application(ref Reader r, bool hasLevel, bool hasTrace, bool hasDescriptions,
        scope void delegate(const(char)[] id, const(char)[] description) nothrow @nogc visitApp,
        scope void delegate(const(char)[] id, int level, int trace, const(char)[] description) nothrow @nogc visitContext) nothrow @nogc
    {
        const(ubyte)[] id;
        ushort contexts;
        if (!r.bytes(4, id) || !r.count(contexts))
            return false;

        // The description comes after the contexts: read it first
        Reader ahead = r;
        foreach (_; 0 .. contexts)
            if (!context(ahead, hasLevel, hasTrace, hasDescriptions, null))
                return false;
        const(char)[] description;
        if (hasDescriptions && !ahead.text(description))
            return false;

        if (visitApp !is null)
            visitApp(removeIdPadding(cast(const(char)[]) id), description);
        if (visitContext !is null)
            foreach (_; 0 .. contexts)
                context(r, hasLevel, hasTrace, hasDescriptions, visitContext);
        r = ahead;
        return true;
    }

    // Checks the whole response before appending anything
    Reader check = Reader(data, msbf);
    ushort applications;
    if (!check.count(applications))
        return false;
    foreach (_; 0 .. applications)
        if (!application(check, hasLevel, hasTrace, hasDescriptions, null, null))
            return false;
    if (check.p.length != 0 && check.p.length != 4)
        return false; // more than the communication interface: another layout

    bool firstApp = true, firstContext;
    void visitApp(const(char)[] id, const(char)[] description) nothrow @nogc
    {
        if (!firstApp)
            builder.appendAscii(";", false);
        firstApp = false;
        firstContext = true;
        builder.appendAscii(id.length > 0 ? id : "-");
        if (description.length > 0)
        {
            builder.appendAscii("(");
            builder.appendUtf8(description, false);
            builder.appendAscii(")", false);
        }
        builder.appendAscii(":", false);
    }

    void visitContext(const(char)[] id, int level, int trace, const(char)[] description) nothrow @nogc
    {
        if (!firstContext)
            builder.appendAscii(",", false);
        firstContext = false;
        builder.appendAscii(id.length > 0 ? id : "-");
        if (level != int.min)
        {
            ShortText!24 text;
            text.add("level=");
            addLevelName(text, level);
            builder.appendAscii(text.text);
        }
        if (trace != int.min)
        {
            ShortText!24 text;
            text.add("trace=");
            addTraceName(text, trace);
            builder.appendAscii(text.text);
        }
        if (description.length > 0)
        {
            builder.appendAscii("(");
            builder.appendUtf8(description, false);
            builder.appendAscii(")", false);
        }
    }

    Reader r = Reader(data, msbf);
    r.count(applications);
    foreach (_; 0 .. applications)
        application(r, hasLevel, hasTrace, hasDescriptions, &visitApp, &visitContext);
    return true;
}

//! Adds the name of a log level of a context: -1 is its default, 0 off
private void addLevelName(size_t capacity)(ref ShortText!capacity text, int level) pure nothrow @nogc
{
    static immutable string[] names = ["off", "fatal", "error", "warn", "info", "debug", "verbose"];
    if (level == -1)
        text.add("default");
    else if (level >= 0 && level < names.length)
        text.add(names[level]);
    else
        text.add(level);
}

//! Adds the name of a trace status of a context: -1 is its default
private void addTraceName(size_t capacity)(ref ShortText!capacity text, int trace) pure nothrow @nogc
{
    if (trace == -1)
        text.add("default");
    else if (trace == 0)
        text.add("off");
    else if (trace == 1)
        text.add("on");
    else
        text.add(trace);
}

//! @returns the name of a control service, "ctrl" for an unknown one
const(char)[] controlServiceName(uint id) pure nothrow @nogc
{
    switch (id)
    {
    case ServiceID.SetLogLevel:
        return "set_log_level";
    case ServiceID.SetTraceStatus:
        return "set_trace_status";
    case ServiceID.GetLogInfo:
        return "get_log_info";
    case ServiceID.GetDefaultLogLevel:
        return "get_default_log_level";
    case ServiceID.StoreConfig:
        return "store_config";
    case ServiceID.ResetToFactoryDefault:
        return "reset_to_factory_default";
    case ServiceID.SetComInterfaceStatus:
        return "set_com_interface_status";
    case ServiceID.SetComInterfaceMaxBandwidth:
        return "set_com_interface_max_bandwidth";
    case ServiceID.SetVerboseMode:
        return "set_verbose_mode";
    case ServiceID.SetMessageFiltering:
        return "set_message_filtering";
    case ServiceID.SetTimingPackets:
        return "set_timing_packets";
    case ServiceID.GetLocalTime:
        return "get_local_time";
    case ServiceID.UseEcuId:
        return "use_ecu_id";
    case ServiceID.UseSessionId:
        return "use_session_id";
    case ServiceID.UseTimestamp:
        return "use_timestamp";
    case ServiceID.UseExtendedHeader:
        return "use_extended_header";
    case ServiceID.SetDefaultLogLevel:
        return "set_default_log_level";
    case ServiceID.SetDefaultTraceStatus:
        return "set_default_trace_status";
    case ServiceID.GetSoftwareVersion:
        return "get_software_version";
    case ServiceID.MessageBufferOverflow:
        return "message_buffer_overflow";
    case ServiceID.UnregisterContext:
        return "unregister_context";
    case ServiceID.ConnectionInfo:
        return "connection_info";
    case ServiceID.Timezone:
        return "timezone";
    case ServiceID.Marker:
        return "marker";
    default:
        return "ctrl";
    }
}

//! Adds the name of a response status that isn't ok, or its number
private void addResponseStatus(size_t capacity)(ref ShortText!capacity text, ubyte status) pure nothrow @nogc
{
    switch (status)
    {
    case ServiceResponseStatus.NotSupported:
        return text.add("not_supported");
    case ServiceResponseStatus.Error:
        return text.add("error");
    case ServiceResponseStatus.PermissionDenied:
        return text.add("perm_denied");
    case ServiceResponseStatus.Warning:
        return text.add("warning");
    case ServiceResponseStatus.NoMatchingContextId:
        return text.add("no_matching_context_id");
    case ServiceResponseStatus.Overflow:
        return text.add("overflow");
    default:
        return text.add(status);
    }
}

//! Appends data of a control message: as text when it is printable UTF-8
//! (trailing zeros aside), in hex otherwise
private void appendData(Builder)(ref Builder builder, const(ubyte)[] data) nothrow @nogc
{
    if (data.length == 0)
        return;
    const text = withoutTrailingZeros(cast(const(char)[]) data);
    if (text.length > 0 && isPrintableUtf8(text))
        builder.appendUtf8(text);
    else
        builder.appendHex(cast(const(char)[]) data);
}

private const(char)[] withoutTrailingZeros(const(char)[] s) pure nothrow @nogc
{
    while (s.length > 0 && s[$ - 1] == '\0')
        s = s[0 .. $ - 1];
    return s;
}

//! @returns true if `s` is valid UTF-8 without control characters other than
//! tab and line breaks
bool isPrintableUtf8(const(char)[] s) pure nothrow @nogc
{
    size_t i = 0;
    while (i < s.length)
    {
        const ubyte b = s[i];
        if (b < 0x80)
        {
            if ((b < 0x20 && b != '\t' && b != '\n' && b != '\r') || b == 0x7F)
                return false;
            ++i;
            continue;
        }

        size_t continuation;
        if (b >= 0xC2 && b <= 0xDF)
            continuation = 1;
        else if (b >= 0xE0 && b <= 0xEF)
            continuation = 2;
        else if (b >= 0xF0 && b <= 0xF4)
            continuation = 3;
        else
            return false;

        if (i + continuation >= s.length)
            return false;
        foreach (k; 1 .. continuation + 1)
            if ((cast(ubyte) s[i + k] & 0xC0) != 0x80)
                return false;
        i += continuation + 1;
    }
    return true;
}

// ─── Helper: build a minimal raw DLT message byte array ──────────────────────
// Returns a ubyte[] with StorageHeader + StandardHeader + optional ExtendedHeader + payload.
version (unittest)
{
private:
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
    assert(msg.payloadText == "", "no message ID, no payload");
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
    assert(msg.payloadText == "", "no message ID, no payload");
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
private:
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

    assert(msg.payloadText == "[get_software_version error]");
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

// ─── Records built field by field ─────────────────────────────────────────────

version (unittest)
{
private:
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

    //! A DLT record with every header field under control
    struct Record
    {
        bool storage = true;
        char[4] storageEcu = "STOR";
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
                result ~= bytesOf(1000u, false);
                result ~= bytesOf(0u, false);
                result ~= cast(const(ubyte)[]) storageEcu[];
            }
            result ~= htyp;
            result ~= counter;
            result ~= bytesOf(cast(ushort)(length >= 0 ? length : 4 + rest.length), true);
            return result ~ rest;
        }
    }

    //! A verbose log record of the arguments
    Record verbose(const(ubyte)[] args, ubyte count, bool msbf = true)
    {
        Record r;
        r.msbf = msbf;
        r.numberOfArguments = count;
        r.payload = args;
        return r;
    }

    //! A non-verbose control record of the service with the data after its ID
    Record control(uint serviceId, ControlType controlType, const(ubyte)[] data, bool msbf = true)
    {
        Record r;
        r.msbf = msbf;
        r.verbose = false;
        r.type = MessageType.Control;
        r.typeInfo = controlType;
        r.payload = bytesOf(serviceId, msbf) ~ data;
        return r;
    }

    //! The payload text of a decoded record
    string payloadOf(const Record r)
    {
        LogMessage!char msg;
        assert(parseDltItem(msg, r.bytes(), r.storage));
        return msg.payloadText.idup;
    }

    enum uint u32 = TypeInfoFlags.TypeUnsigned | Tyle.Tyle32Bit;
}

@("parseDltItem: the session ID is big-endian in a little-endian record")
unittest
{
    Record r;
    r.msbf = false;
    r.withSessionId = true;
    r.sessionId = 0x01020304;
    r.withTimestamp = true;
    r.timestamp = 0x0A0B0C0D;

    LogMessage!char msg;
    assert(parseDltItem(msg, r.bytes()));
    assert(msg.sessionId == 0x01020304);
    assert(msg.relativeTimestamp_10000 == 0x0A0B0C0D);
}

@("parseDltItem: a non-verbose log record has the level of its extended header")
unittest
{
    Record r;
    r.verbose = false;
    r.typeInfo = LogLevel.Error;
    r.payload = bytesOf(0x10u);

    LogMessage!char msg;
    assert(parseDltItem(msg, r.bytes()));
    assert(msg.level == LogLevel.Error);
}

@("parseDltItem: a record that is not a log has no level")
unittest
{
    LogMessage!char msg;

    Record trace = verbose([], 0);
    trace.type = MessageType.AppTrace;
    trace.typeInfo = AppTraceType.Variable; // 1, the value of Fatal
    assert(parseDltItem(msg, trace.bytes()));
    assert(msg.level == LogLevel.None);

    Record ctrl = control(ServiceID.SetLogLevel, ControlType.Response, [0]);
    assert(parseDltItem(msg, ctrl.bytes()));
    assert(msg.level == LogLevel.None);

    Record noExtended;
    noExtended.extended = false;
    noExtended.payload = bytesOf(1u);
    assert(parseDltItem(msg, noExtended.bytes()));
    assert(msg.level == LogLevel.None);

    Record badLevel = verbose([], 0);
    badLevel.typeInfo = 9;
    assert(parseDltItem(msg, badLevel.bytes()));
    assert(msg.level == LogLevel.None);
}

@("parseDltItem: variable info (name, unit) comes before the value")
unittest
{
    foreach (msbf; [true, false])
    {
        alias f = TypeInfoFlags;
        ubyte[] str(string s) { return cast(ubyte[]) s.dup; }

        // number: name length, unit length, name, unit, value
        auto number = argument(u32 | f.VariableInfo,
            bytesOf(cast(ushort) 4, msbf) ~ bytesOf(cast(ushort) 3, msbf)
            ~ str("cnt\0") ~ str("ms\0") ~ bytesOf(7u, msbf), msbf);
        // string: string length, name length, name, string
        auto text = argument(f.TypeString | f.VariableInfo,
            bytesOf(cast(ushort) 3, msbf) ~ bytesOf(cast(ushort) 5, msbf)
            ~ str("name\0") ~ str("ok\0"), msbf);
        // bool: name length, name, value
        auto flag = argument(f.TypeBoolean | Tyle.Tyle8Bit | f.VariableInfo,
            bytesOf(cast(ushort) 5, msbf) ~ str("flag\0") ~ [cast(ubyte) 1], msbf);
        // raw: data length, name length, name, data
        auto raw = argument(f.TypeRaw | f.VariableInfo,
            bytesOf(cast(ushort) 2, msbf) ~ bytesOf(cast(ushort) 4, msbf)
            ~ str("raw\0") ~ cast(ubyte[])[0xAB, 0xCD], msbf);
        auto last = argument(u32, bytesOf(9u, msbf), msbf);

        assert(payloadOf(verbose(number ~ text ~ flag ~ raw ~ last, 5, msbf)) == "7 ok true ABCD 9");
    }
}

@("parseDltItem: 128-bit integers are shown in hex, the next argument is in place")
unittest
{
    ubyte[16] bytes;
    foreach (i, ref b; bytes)
        b = cast(ubyte) i;

    auto big = argument(TypeInfoFlags.TypeUnsigned | Tyle.Tyle128Bit, bytes[])
        ~ argument(TypeInfoFlags.TypeSigned | Tyle.Tyle128Bit, bytes[])
        ~ argument(u32, bytesOf(7u));
    assert(payloadOf(verbose(big, 3)) == "0x000102030405060708090A0B0C0D0E0F "
        ~ "0x000102030405060708090A0B0C0D0E0F 7");

    auto little = argument(TypeInfoFlags.TypeUnsigned | Tyle.Tyle128Bit, bytes[], false)
        ~ argument(u32, bytesOf(7u, false), false);
    assert(payloadOf(verbose(little, 2, false)) == "0x0F0E0D0C0B0A09080706050403020100 7");
}

@("parseDltItem: 16-bit floats are decoded, 128-bit ones are skipped")
unittest
{
    enum f16 = TypeInfoFlags.TypeFloat | Tyle.Tyle16Bit;
    ubyte[16] zeros;
    auto args = argument(f16, bytesOf(cast(ushort) 0x3C00)) // 1.0
        ~ argument(f16, bytesOf(cast(ushort) 0xC000)) // -2.0
        ~ argument(TypeInfoFlags.TypeFloat | Tyle.Tyle128Bit, zeros[])
        ~ argument(u32, bytesOf(7u));
    assert(payloadOf(verbose(args, 4)) == "1.00000000 -2.00000000 ? 7");
}

@("parseDltItem: fixed point quantization and offset are skipped by the size of the type")
unittest
{
    enum fixp = TypeInfoFlags.TypeSigned | TypeInfoFlags.FixedPoint;
    // quantization is a float32, the offset has the size of the value (32 bits at least)
    auto i64 = argument(fixp | Tyle.Tyle64Bit, bytesOf(1.0f) ~ bytesOf(0L) ~ bytesOf(-5L));
    auto i32 = argument(fixp | Tyle.Tyle32Bit, bytesOf(1.0f) ~ bytesOf(0) ~ bytesOf(-6));
    auto i16 = argument(fixp | Tyle.Tyle16Bit, bytesOf(1.0f) ~ bytesOf(0) ~ bytesOf(cast(short)-7));
    auto last = argument(u32, bytesOf(9u));
    assert(payloadOf(verbose(i64 ~ i32 ~ i16 ~ last, 4)) == "-5 -6 -7 9");
}

@("parseDltItem: an argument of an unknown type stops decoding, the rest is shown in hex")
unittest
{
    auto first = argument(u32, bytesOf(7u));
    // array, struct, no type at all, an integer of an invalid length
    foreach (typeInfo; [0x100 | Tyle.Tyle32Bit, 0x4000, 0, TypeInfoFlags.TypeUnsigned | 6])
    {
        auto args = first ~ argument(typeInfo, bytesOf(1u)) ~ argument(u32, bytesOf(9u));
        import std.format : format;

        assert(payloadOf(verbose(args, 3)) == format!"7 %08X 00000001 %08X 00000009"(typeInfo, u32));
    }
}

@("parseDltItem: an argument cut by the end of the payload is shown in hex")
unittest
{
    auto args = argument(u32, bytesOf(7u))
        ~ argument(TypeInfoFlags.TypeString, bytesOf(cast(ushort) 10) ~ cast(ubyte[]) "abc".dup);
    assert(payloadOf(verbose(args, 2)) == "7 00000200 000A6162 63");
}

@("parseDltItem: a record without extended header starts with its message ID")
unittest
{
    foreach (msbf; [true, false])
    {
        Record r;
        r.msbf = msbf;
        r.extended = false;
        r.payload = bytesOf(0x1234u, msbf) ~ cast(ubyte[])[0x41, 0x42];

        LogMessage!char msg;
        assert(parseDltItem(msg, r.bytes()));
        assert(msg.messageId == 0x1234);
        assert(msg.payloadText == "[4660] 4142 |AB");
    }
}

@("parseDltItem: a non-verbose record shows its message ID and data")
unittest
{
    Record r;
    r.verbose = false;
    r.payload = bytesOf(57_005u) ~ cast(ubyte[])[0x41, 0x42, 0x01, 0x7F, 0xC3];
    assert(payloadOf(r) == "[57005] 4142017F C3 |AB...");

    r.payload = bytesOf(57_005u);
    assert(payloadOf(r) == "[57005]");
}

@("parseDltItem: connection_info shows the state and the interface")
unittest
{
    foreach (msbf; [true, false])
    {
        auto data = cast(ubyte[])[0, ServiceConnectionState.Connected] ~ cast(ubyte[]) "CI01".dup;
        assert(payloadOf(control(ServiceID.ConnectionInfo, ControlType.Response, data, msbf))
            == "[connection_info ok] connected CI01");
    }
    auto gone = cast(ubyte[])[0, ServiceConnectionState.Disconnected] ~ cast(ubyte[]) "CI\0\0".dup;
    assert(payloadOf(control(ServiceID.ConnectionInfo, ControlType.Response, gone))
        == "[connection_info ok] disconnected CI");
}

@("parseDltItem: the response status is shown by its name")
unittest
{
    string status(uint service, ubyte value)
    {
        return payloadOf(control(service, ControlType.Response, [value]));
    }

    assert(status(ServiceID.SetLogLevel, 0) == "[set_log_level ok]");
    assert(status(ServiceID.SetLogLevel, 1) == "[set_log_level not_supported]");
    assert(status(ServiceID.SetLogLevel, 2) == "[set_log_level error]");
    assert(status(ServiceID.SetLogLevel, 3) == "[set_log_level perm_denied]");
    assert(status(ServiceID.SetLogLevel, 4) == "[set_log_level warning]");
    assert(status(ServiceID.SetLogLevel, 42) == "[set_log_level 42]");

    // get_log_info echoes the options it was asked for (3..7) when it succeeds
    foreach (ubyte options; 3 .. 8)
        assert(status(ServiceID.GetLogInfo, options) == "[get_log_info ok]");
    assert(status(ServiceID.GetLogInfo, 8) == "[get_log_info no_matching_context_id]");
    assert(status(ServiceID.GetLogInfo, 9) == "[get_log_info overflow]");
    assert(status(ServiceID.GetLogInfo, 1) == "[get_log_info not_supported]");
}

@("parseDltItem: timezone and marker responses")
unittest
{
    foreach (msbf; [true, false])
    {
        auto summer = [cast(ubyte) 0] ~ bytesOf(3600, msbf) ~ [cast(ubyte) 1];
        assert(payloadOf(control(ServiceID.Timezone, ControlType.Response, summer, msbf))
            == "[timezone ok] 3600 s DST");
        auto winter = [cast(ubyte) 0] ~ bytesOf(-7200, msbf) ~ [cast(ubyte) 0];
        assert(payloadOf(control(ServiceID.Timezone, ControlType.Response, winter, msbf))
            == "[timezone ok] -7200 s");
    }
    assert(payloadOf(control(ServiceID.Marker, ControlType.Response, [0])) == "MARKER");
}

@("parseDltItem: control requests and keep-alives are labelled by their kind")
unittest
{
    assert(payloadOf(control(ServiceID.SetComInterfaceMaxBandwidth, ControlType.Request, []))
        == "[set_com_interface_max_bandwidth req]");
    assert(payloadOf(control(ServiceID.SetMessageFiltering, ControlType.Request, []))
        == "[set_message_filtering req]");
    assert(payloadOf(control(ServiceID.GetLocalTime, ControlType.Time, []))
        == "[get_local_time time]");
}

@("parseDltItem: the ECU ID of the standard header wins over the storage header")
unittest
{
    Record r = verbose([], 0);
    r.ecuId = "WEID";

    LogMessage!char msg;
    assert(parseDltItem(msg, r.bytes()));
    assert(msg.ecuId == "WEID");

    r.ecuId = null;
    assert(parseDltItem(msg, r.bytes()));
    assert(msg.ecuId == "STOR");
}

@("parseDltItem: a record of an unknown protocol version is not decoded")
unittest
{
    Record r = verbose(argument(u32, bytesOf(7u)), 1);
    r.protocolVersion = 3;
    assert(payloadOf(r) == "[DLT protocol version 3 is not supported]");

    r.protocolVersion = 0; // written by old loggers
    assert(payloadOf(r) == "7");
}

@("parseDltItem: unsigned integers coded as hex or binary")
unittest
{
    enum hex = TypeInfoFlags.TypeUnsigned | StringCoding.StringCodingHEX;
    enum bin = TypeInfoFlags.TypeUnsigned | StringCoding.StringCodingBIN;
    auto args = argument(hex | Tyle.Tyle16Bit, bytesOf(cast(ushort) 0xAB))
        ~ argument(hex | Tyle.Tyle64Bit, bytesOf(0x1234_5678_9ABC_DEF0UL))
        ~ argument(bin | Tyle.Tyle8Bit, [cast(ubyte) 5])
        ~ argument(bin | Tyle.Tyle16Bit, bytesOf(cast(ushort) 0x0102));
    assert(payloadOf(verbose(args, 4)) == "0x00AB 0x123456789ABCDEF0 0b00000101 0b0000000100000010");

    auto little = argument(hex | Tyle.Tyle32Bit, bytesOf(0xABu, false), false);
    assert(payloadOf(verbose(little, 1, false)) == "0x000000AB");
}

@("parseDltItem: raw data is always shown in hex")
unittest
{
    auto args = argument(TypeInfoFlags.TypeRaw, bytesOf(cast(ushort) 4) ~ cast(ubyte[]) "abc\0".dup);
    assert(payloadOf(verbose(args, 1)) == "61626300");
}

@("parseDltItem: control data is text only when it is printable UTF-8")
unittest
{
    auto text = cast(ubyte[])[0] ~ cast(ubyte[]) "привет".dup;
    assert(payloadOf(control(0xFF, ControlType.Response, text)) == "[ctrl ok] привет");

    auto binary = cast(ubyte[])[0, 0xFF, 0xFE, 0x41];
    assert(payloadOf(control(0xFF, ControlType.Response, binary)) == "[ctrl ok] FFFE41");
}

@("parseDltItem: argument types by the values of the protocol (dlt_protocol.h)")
unittest
{
    // DLT_TYPE_INFO_STRG 0x200, DLT_SCOD_UTF8 0x8000, DLT_TYPE_INFO_RAWD 0x400,
    // DLT_TYPE_INFO_ARAY 0x100, DLT_TYPE_INFO_UINT 0x40, DLT_TYLE_32BIT 3
    auto args = argument(0x200, bytesOf(cast(ushort) 3) ~ cast(ubyte[]) "hi\0".dup)
        ~ argument(0x200 | 0x8000, bytesOf(cast(ushort) 4) ~ cast(ubyte[]) "ая".dup)
        ~ argument(0x400, bytesOf(cast(ushort) 2) ~ cast(ubyte[])[0x01, 0x02])
        ~ argument(0x40 | 3, bytesOf(7u));
    assert(payloadOf(verbose(args, 4)) == "hi ая 0102 7");

    auto array = argument(0x100 | 3, bytesOf(1u));
    assert(payloadOf(verbose(array, 1)) == "00000103 00000001", "an array is not a string");
}

@("parseDltItem: message counter, session ID and timestamp are fields only when present")
unittest
{
    Record r = verbose([], 0);
    r.counter = 42;

    LogMessage!char msg;
    assert(parseDltItem(msg, r.bytes()));
    assert(msg.counter == 42);
    assert(!msg.hasField(DltField.SessionId));
    assert(!msg.hasField(DltField.Timestamp));
    assert(!msg.hasField(DltField.MessageId), "a verbose record has no message ID");

    r.withSessionId = true;
    r.sessionId = 7;
    r.withTimestamp = true;
    r.timestamp = 12_345;
    assert(parseDltItem(msg, r.bytes()));
    assert(msg.hasField(DltField.SessionId) && msg.sessionId == 7);
    assert(msg.hasField(DltField.Timestamp) && msg.relativeTimestamp_10000 == 12_345);
}

@("parseDltItem: a non-verbose payload too short for a message ID is shown in hex")
unittest
{
    Record r;
    r.extended = false;
    r.payload = cast(ubyte[])[0x41, 0x01];

    LogMessage!char msg;
    assert(parseDltItem(msg, r.bytes()));
    assert(!msg.hasField(DltField.MessageId));
    assert(msg.payloadText == "4101 |A.");

    r.extended = true;
    r.verbose = false;
    assert(payloadOf(r) == "4101 |A.");
}

@("parseDltItem: a record of an unknown protocol version has no fields of version 1")
unittest
{
    Record r = verbose(argument(u32, bytesOf(7u)), 1);
    r.protocolVersion = 3;
    r.ecuId = "WEID";
    r.withSessionId = true;
    r.withTimestamp = true;
    r.typeInfo = LogLevel.Error;

    LogMessage!char msg;
    assert(parseDltItem(msg, r.bytes()));
    assert(msg.ecuId == "STOR", "the storage header is still version 1");
    assert(msg.appId == "" && msg.ctxId == "");
    assert(msg.level == LogLevel.None);
    foreach (field; [DltField.Type, DltField.SessionId, DltField.Timestamp,
            DltField.Counter, DltField.MessageId])
        assert(!msg.hasField(field));
}

@("parseDltItem: a marker response with an error status is shown like other services")
unittest
{
    assert(payloadOf(control(ServiceID.Marker, ControlType.Response, [2])) == "[marker error]");
}

// ─── Protocol version 2 ───────────────────────────────────────────────────────

version (unittest)
{
private:
    import formats.dlt.header_v2 : BuildV2, ContentInfo, SegmentFrame, dltViewerTestFile;

    //! A storage header of version 2
    ubyte[] storageV2(const(char)[] ecuId, ulong seconds, uint nanoseconds)
    {
        ubyte[] bytes = cast(ubyte[]) "DLT\x02".dup;
        bytes ~= bytesOf(nanoseconds, false);
        bytes ~= bytesOf(seconds, false)[0 .. 5];
        bytes ~= cast(ubyte) ecuId.length;
        return bytes ~ cast(const(ubyte)[]) ecuId;
    }

    //! The decoded payload text of a version 2 message without storage header
    string payloadV2(const BuildV2 b)
    {
        LogMessage!char msg;
        assert(parseDltItem(msg, b.bytes(), false));
        return msg.payloadText.idup;
    }
}

@("parseDltItem v2: the test file of dlt-viewer")
unittest
{
    LogMessage!char msg;
    assert(parseDltItem(msg, dltViewerTestFile, false));
    assert(msg.ecuId == "ECU1" && msg.appId == "logd" && msg.ctxId == "RBUF");
    assert(msg.type == MessageType.Log && msg.level == LogLevel.Info);
    assert(msg.counter == 1);
    assert(msg.payloadText == "Start logging after ECU startup");
    // 2 s and 874416044 ns since startup, in 0.1 ms
    assert(msg.hasField(DltField.Timestamp) && msg.relativeTimestamp_10000 == 28_744);
    assert(msg.timeKind == TimeKind.None, "no storage header, no time of day");
}

@("parseDltItem v2: the storage header gives the time and the ECU the message lacks")
unittest
{
    LogMessage!char msg;
    const storage = storageV2("STOR", 1_700_000_000, 5_000);

    assert(parseDltItem(msg, storage ~ dltViewerTestFile));
    assert(msg.ecuId == "ECU1", "the ECU of the message wins");
    assert(msg.timeKind == TimeKind.Absolute);
    assert(msg.timeNs == 1_700_000_000_000_005_000);

    BuildV2 b;
    assert(parseDltItem(msg, storage ~ b.bytes()));
    assert(msg.ecuId == "STOR");
    assert(msg.appId == "-" && msg.ctxId == "-", "no application and context IDs");
}

@("parseDltItem v2: a UTC timestamp is the time of the message")
unittest
{
    BuildV2 b;
    b.seconds = 1_800_000_000;
    b.nanoseconds = 250_000_000; // bit 31 clear: UTC

    LogMessage!char msg;
    assert(parseDltItem(msg, storageV2("STOR", 1_700_000_000, 0) ~ b.bytes()));
    assert(msg.timeKind == TimeKind.Absolute);
    assert(msg.timeNs == 1_800_000_000_250_000_000);
    assert(!msg.hasField(DltField.Timestamp), "not a time since startup");
}

@("parseDltItem v2: IDs, session ID and arguments")
unittest
{
    BuildV2 b;
    b.ecuId = "ECU12";
    b.appId = "APP";
    b.ctxId = "CONTEXT";
    b.withSessionId = true;
    b.sessionId = 77;
    b.messageInfo = 1 | LogLevel.Warn << 4;
    b.numberOfArguments = 2;
    b.payload = argument(u32, bytesOf(7u, false), false)
        ~ argument(TypeInfoFlags.TypeString, bytesOf(cast(ushort) 3, false) ~ cast(ubyte[]) "ok\0".dup, false);

    LogMessage!char msg;
    assert(parseDltItem(msg, b.bytes(), false));
    assert(msg.ecuId == "ECU12" && msg.appId == "APP" && msg.ctxId == "CONTEXT");
    assert(msg.sessionId == 77);
    assert(msg.level == LogLevel.Warn);
    assert(msg.payloadText == "7 ok");
}

@("parseDltItem v2: a non-verbose message has its message ID in the header")
unittest
{
    BuildV2 b;
    b.content = ContentInfo.NonVerbose;
    b.messageId = 1234;
    b.payload = [0x41, 0x01];

    LogMessage!char msg;
    assert(parseDltItem(msg, b.bytes(), false));
    assert(msg.messageId == 1234);
    assert(msg.payloadText == "[1234] 4101 |A.");
    assert(msg.level == LogLevel.None && !msg.hasField(DltField.Type), "no message info");
}

@("parseDltItem v2: a control message")
unittest
{
    BuildV2 b;
    b.content = ContentInfo.Control;
    b.messageInfo = ControlType.Response << 4 | MessageType.Control << 1;
    b.payload = bytesOf(cast(uint) ServiceID.GetSoftwareVersion, false) ~ [cast(ubyte) 0]
        ~ bytesOf(3u, false) ~ cast(ubyte[]) "v1\0".dup;

    LogMessage!char msg;
    assert(parseDltItem(msg, b.bytes(), false));
    assert(msg.type == MessageType.Control && msg.messageId == ServiceID.GetSoftwareVersion);
    assert(msg.payloadText == "[get_software_version ok] v1");
}

@("parseDltItem v2: a segmented message shows its frame instead of arguments")
unittest
{
    BuildV2 b;
    b.numberOfArguments = 1;
    b.payload = argument(u32, bytesOf(7u, false), false);

    b.segmentation = [cast(ubyte) SegmentFrame.First] ~ bytesOf(1000UL);
    assert(payloadV2(b) == "Segmentation: First Frame with total length 1000");
    b.segmentation = [cast(ubyte) SegmentFrame.Consecutive] ~ bytesOf(5u);
    assert(payloadV2(b) == "Segmentation: Consecutive Frame number 5");
    b.segmentation = [cast(ubyte) SegmentFrame.Last];
    assert(payloadV2(b) == "Segmentation: Last Frame");
    b.segmentation = [cast(ubyte) SegmentFrame.Abort, 9];
    assert(payloadV2(b) == "Segmentation: Abort Frame with abort reason 9");
}

@("parseDltItem v2: an invalid header is shown as such")
unittest
{
    auto bytes = dltViewerTestFile.dup;
    bytes[0] |= 0x03; // CNTI 3 is reserved

    LogMessage!char msg;
    assert(parseDltItem(msg, storageV2("STOR", 1, 0) ~ bytes));
    assert(msg.ecuId == "STOR");
    assert(msg.payloadText == "[invalid DLT version 2 header]");
}

@("parseDltItem v2: an empty or impossible UTC timestamp keeps the time of the storage header")
unittest
{
    LogMessage!char msg;
    const storage = storageV2("STOR", 1_700_000_000, 5_000);

    BuildV2 empty; // the logger left TMSP at zero
    assert(parseDltItem(msg, storage ~ empty.bytes()));
    assert(msg.timeNs == 1_700_000_000_000_005_000);

    BuildV2 huge;
    huge.seconds = 0xFF_FFFF_FFFF; // beyond the range of the time
    assert(parseDltItem(msg, storage ~ huge.bytes()));
    assert(msg.timeNs == 1_700_000_000_000_005_000);
}

@("parseDltItem: corrupt storage header times don't wrap")
unittest
{
    LogMessage!char msg;

    Record r = verbose([], 0);
    auto bytes = r.bytes();
    bytes[8 .. 12] = bytesOf(5_242_880u, false); // microseconds beyond a second
    assert(parseDltItem(msg, bytes));
    assert(msg.timeNs == 1000 * 1_000_000_000L + 5_242_880_000L);

    BuildV2 b;
    assert(parseDltItem(msg, storageV2("STOR", 0xFF_FFFF_FFFF, 0) ~ b.bytes()));
    assert(msg.timeKind == TimeKind.None, "a time out of range is no time");
}

// ─── get_log_info ─────────────────────────────────────────────────────────────

version (unittest)
{
private:
    //! A get_log_info response: its options (status), then the data as given
    string logInfo(ubyte options, const(ubyte)[] data, bool msbf = false)
    {
        return payloadOf(control(ServiceID.GetLogInfo, ControlType.Response, [options] ~ data, msbf));
    }

    ubyte[] id(string s)
    {
        ubyte[4] bytes = 0;
        bytes[0 .. s.length] = cast(const(ubyte)[]) s;
        return bytes.dup;
    }

    ubyte[] text(string s, bool msbf = false)
    {
        return bytesOf(cast(ushort) s.length, msbf) ~ cast(ubyte[]) s.dup;
    }
}

@("parseDltItem: get_log_info of dlt-daemon (the test of dlt-viewer)")
unittest
{
    import std.conv : hexString;

    // Real payload of dlt-daemon, from qdlt/tests/test_dltctrlmsg.cpp
    enum payload = hexString!("030000000701005359530001004d475200ffff2200436f6e74657874206f66206d61696e"
        ~ "20646c742073797374656d206d616e616765721200444c542053797374656d204d616e6167657272656d6f");
    Record r = control(0, ControlType.Response, [], false);
    r.payload = cast(const(ubyte)[]) payload;
    assert(payloadOf(r) == "[get_log_info ok] SYS (DLT System Manager): "
        ~ "MGR level=default trace=default (Context of main dlt system manager)");
}

@("parseDltItem: get_log_info shows what its options ask for")
unittest
{
    foreach (msbf; [false, true])
    {
        ubyte[] count(ushort n) { return bytesOf(n, msbf); }

        // 3: the IDs only
        assert(logInfo(3, count(2) ~ id("APP1") ~ count(2) ~ id("CTX1") ~ id("CTX2")
                ~ id("APP2") ~ count(0) ~ cast(ubyte[]) "remo".dup, msbf)
            == "[get_log_info ok] APP1: CTX1, CTX2; APP2:");

        // 4: with the log level, 5: with the trace status, 6: with both
        assert(logInfo(4, count(1) ~ id("A") ~ count(2) ~ id("C1") ~ [cast(ubyte) 4]
                ~ id("C2") ~ [cast(ubyte) 0], msbf)
            == "[get_log_info ok] A: C1 level=info, C2 level=off");
        assert(logInfo(5, count(1) ~ id("A") ~ count(1) ~ id("C") ~ [cast(ubyte) 1], msbf)
            == "[get_log_info ok] A: C trace=on");
        assert(logInfo(6, count(1) ~ id("A") ~ count(1) ~ id("C") ~ cast(ubyte[])[6, 0], msbf)
            == "[get_log_info ok] A: C level=verbose trace=off");

        // 7: with the descriptions; an empty one is left out
        assert(logInfo(7, count(1) ~ id("A") ~ count(2)
                ~ id("C1") ~ cast(ubyte[])[0xFF, 0xFF] ~ text("first", msbf)
                ~ id("C2") ~ cast(ubyte[])[1, 0xFF] ~ text("", msbf)
                ~ text("", msbf), msbf)
            == "[get_log_info ok] A: C1 level=default trace=default (first), C2 level=fatal trace=default");
    }
}

@("parseDltItem: a get_log_info that doesn't parse is shown in hex")
unittest
{
    // One application announced, its context count missing
    assert(logInfo(4, bytesOf(cast(ushort) 1, false) ~ id("A")) == "[get_log_info ok] 01004100 0000");
    // Unknown values of level and trace status are shown as numbers
    assert(logInfo(6, bytesOf(cast(ushort) 1, false) ~ id("A") ~ bytesOf(cast(ushort) 1, false)
            ~ id("C") ~ cast(ubyte[])[9, 7]) == "[get_log_info ok] A: C level=9 trace=7");
}

@("parseDltItem: get_log_info data that doesn't match its options is shown in hex")
unittest
{
    // Options 4 announce the log level only, the context has a trace status too
    const extra = bytesOf(cast(ushort) 1, false) ~ id("A") ~ bytesOf(cast(ushort) 1, false)
        ~ id("C") ~ cast(ubyte[])[4, 1];
    assert(logInfo(4, extra) == "[get_log_info ok] 01004100 00000100 43000000 0401");

    // The communication interface may follow, nothing else
    const remo = bytesOf(cast(ushort) 1, false) ~ id("A") ~ bytesOf(cast(ushort) 0, false);
    assert(logInfo(4, remo ~ cast(ubyte[]) "remo".dup) == "[get_log_info ok] A:");
    assert(logInfo(4, remo ~ cast(ubyte[]) "remo!".dup) == "[get_log_info ok] 01004100 00000000 72656D6F 21");
}

@("parseDltItem: get_log_info with status ok has no options to read its data by")
unittest
{
    const data = bytesOf(cast(ushort) 1, false) ~ id("A") ~ bytesOf(cast(ushort) 0, false);
    assert(logInfo(0, data) == "[get_log_info ok] 01004100 00000000");
}

@("parseDltItem: get_log_info shows an empty ID as a dash")
unittest
{
    const data = bytesOf(cast(ushort) 1, false) ~ id("") ~ bytesOf(cast(ushort) 2, false)
        ~ id("") ~ [cast(ubyte) 4] ~ id("C2") ~ [cast(ubyte) 4];
    assert(logInfo(4, data) == "[get_log_info ok] -: - level=info, C2 level=info");
}
