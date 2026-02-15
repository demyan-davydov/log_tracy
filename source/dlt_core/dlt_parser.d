module dlt_core.dlt_parser;

import dlt_core.dlt_protocol;
import dlt_core.log_item;
import dlt_core.fibex;
import std.stdio;
import std.array;
import std.conv : to;
import std.format : format;
import std.stdint;

// Message structure:
//   StorageHeader (16 bytes)
//   StandardHeader (16 bytes)
//   ExtendedHeader (optional)
//   Payload

struct LogItemHeaders
{
    const(StorageHeader)* storage;
    const(StandardHeader)* standard;
    const(ExtendedHeader)* extended;
    const(ubyte)[] payload;
    uint32_t messageId; // 0 by default, set if standard header has message id
}

LogItemHeaders findHeaders(const(ubyte)[] data) pure nothrow
{
    LogItemHeaders headers;

    if (data.length < StorageHeader.sizeof)
        return headers; // invalid

    headers.storage = cast(const(StorageHeader)*) data.ptr;

    if (data.length < StorageHeader.sizeof + StandardHeader.sizeof)
        return headers; // invalid (no standard header)

    headers.standard = cast(const(StandardHeader)*)(data.ptr + StorageHeader.sizeof);
    headers.extended = null;

    if (useExtendedHeader(headers.standard.headerType))
    {
        /*
        uint extOffset = StandardHeader.sizeof;
        if (headers.standard.headerType & StandardHeader.Type.WithEcuId)
            extOffset += 4;
        if (headers.standard.headerType & StandardHeader.Type.WithSessionId)
            extOffset += 4;
        if (headers.standard.headerType & StandardHeader.Type.WithTimestamp)
            extOffset += 4;

        const auto extendedOffset = StorageHeader.sizeof + extOffset;

        if (data.length < extendedOffset + ExtendedHeader.sizeof)
            return headers; // invalid (no extended header)
        */

        const auto extendedOffset = StorageHeader.sizeof + headers.standard.fullHeaderSize();
        const auto headersSize = extendedOffset + ExtendedHeader.sizeof;

        if (data.length < headersSize)
            return headers; // invalid (no extended header)

        headers.extended = cast(const(ExtendedHeader)*)(data.ptr + extendedOffset);

        const size_t payloadOffset = headersSize;
        if (data.length > payloadOffset)
            headers.payload = data[payloadOffset .. $];
        else
            headers.payload = [];

        // Non-Verbose: Message ID is in the first 4 bytes of payload
        // Standard DLT says for Non-Verbose, Message ID is mandatory? 
        // Usually yes. Some implementations might vary, but we'll follow common practice.
        if (headers.extended.messageInfo.isVerbose())
        {
            headers.messageId = 0;
        }
        else
        {
            if (headers.payload.length >= 4)
            {
                const(ubyte)[] msgIdBytes = headers.payload[0 .. 4];
                headers.messageId = readValue!uint(msgIdBytes, headers.standard.isBigEndian());
                headers.payload = headers.payload[4 .. $];
            }
        }
    }
    else
    {
        const size_t payloadOffset = StorageHeader.sizeof + StandardHeader.sizeof;
        if (data.length > payloadOffset)
            headers.payload = data[payloadOffset .. $];
        else
            headers.payload = [];
    }

    return headers;
}

LogItem parseDltItem(size_t index, ulong offset, const(ubyte)[] data, FibexParser fibex = null)
{
    const LogItemHeaders headers = findHeaders(data);

    LogItem item;
    item.index = index;
    item.offset = offset;

    if (headers.storage is null || headers.standard is null)
    {
        item.payload = "<Truncated Data>";
        return item;
    }

    const ulong timestamp = cast(ulong) headers.storage.seconds * 1_000_000 + headers
        .storage.microseconds;

    const ushort length = headers.standard.nativeLength();

    item.length = length;
    item.timestamp = timestamp;

    // ECU ID is stored as uint (4 bytes) in indexer, convert to ubyte[4] and clean
    item.ecu = cleanId(cast(const(ubyte)[4]) headers.storage.ecuId);

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
                    writefln("type info: %b", typeInfo);
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

private string cleanId(const ubyte[4] id) pure
{
    import std.ascii : isPrintable;

    string s;
    foreach (b; id)
    {
        if (b == 0)
            break; // Stop at null terminator
        if (isPrintable(b))
            s ~= cast(char) b;
        else
            s ~= '.'; // Replace non-printable with dot
    }
    return s.empty ? "-" : s;
}
