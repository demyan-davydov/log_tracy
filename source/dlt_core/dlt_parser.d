module dlt_core.dlt_parser;

import dlt_core.dlt;
import dlt_core.log_item;
import dlt_core.fibex;
import std.stdio;
import std.array;
import std.conv : to;
import std.format : format;

// Message structure:
//   StorageHeader (16 bytes)
//   StandardHeader (16 bytes)
//   ExtendedHeader (optional)
//   Payload

LogItem parseDltItem(const(ubyte)[] data, FibexParser fibex)
{
    LogItem item;
    //item.index = realIndex;
    //item.offset = msg.offset;
    //item.length = msg.length;
    //item.timestamp = msg.timestamp;

    // ECU ID is stored as uint (4 bytes) in indexer, convert to ubyte[4] and clean
    //ubyte[4] ecuBytes = (cast(ubyte*)&msg.ecuId)[0 .. 4];
    //item.ecu = cleanId(ecuBytes);

    item.level = LogLevel.Info;
    item.appId = "-";
    item.ctxId = "-";
    item.type = LogType.Log;

    if (data.length >= StorageHeader.sizeof + StandardHeader.sizeof)
    {
        const(ubyte)* stdPtr = data.ptr + StorageHeader.sizeof;
        uint headerSize = getHeaderSize(stdPtr);
        if (data.length >= StorageHeader.sizeof + headerSize)
        {
            const(ubyte)[] payload = data[StorageHeader.sizeof + headerSize .. $];
            item.payload = decodePayload(stdPtr, payload, fibex);

            // ... (rest of parsing logic matching getLogItem)

            item.messageId = peekMessageId(stdPtr);
            auto stdHdr = cast(const(StandardHeader)*) stdPtr;
            if (useExtendedHeader(stdHdr.headerType))
            {
                uint extOffset = StandardHeader.sizeof;
                if (stdHdr.headerType & HeaderType.WithEcuId)
                    extOffset += 4;
                if (stdHdr.headerType & HeaderType.WithSessionId)
                    extOffset += 4;
                if (stdHdr.headerType & HeaderType.WithTimestamp)
                    extOffset += 4;

                auto extHdr = cast(const(ExtendedHeader)*)(stdPtr + extOffset);
                item.level = getLogLevel(extHdr.messageInfo);

                // LogType is in bits 1-3 of messageInfo
                item.type = cast(LogType)((extHdr.messageInfo & MessageInfo.TypeMask) >> 1);

                // DLT IDs are 4 bytes, usually ASCII. 
                // Use cleanId to strip null bytes and non-printable characters
                item.appId = cleanId(extHdr.applicationId);
                item.ctxId = cleanId(extHdr.contextId);
            }
        }
        else
        {
            item.payload = "Invalid header size";
        }
    }
    else
    {
        item.payload = "Data truncated";
    }

    return item;
}

string decodePayload(const(ubyte)* stdHdrPtr, const(ubyte)[] payload, FibexParser fibex)
{
    auto stdHdr = cast(const(StandardHeader)*) stdHdrPtr;
    const bool msbf = (stdHdr.headerType & HeaderType.MostSignificantByteFirst) != 0;

    bool isVerbose = false;
    if (useExtendedHeader(stdHdr.headerType))
    {
        uint extOffset = StandardHeader.sizeof;
        if (stdHdr.headerType & HeaderType.WithEcuId)
            extOffset += 4;
        if (stdHdr.headerType & HeaderType.WithSessionId)
            extOffset += 4;
        if (stdHdr.headerType & HeaderType.WithTimestamp)
            extOffset += 4;

        auto extHdr = cast(const(ExtendedHeader)*)(stdHdrPtr + extOffset);
        if (extHdr.messageInfo & MessageInfo.Verbose)
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
                        }
                    }
                }
                else if (typeInfo & TypeInfoFlags.FixedPoint)
                {
                    if (p.length >= 8)
                        p = p[8 .. $];
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
                                // 

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
                            /*else if (len <= 16)
                                {
                                    string hex;
                                    foreach (b; rawData)
                                        hex ~= format("%02X", b);
                                    args ~= "[" ~ hex ~ "]";
                                }
                                else
                                    args ~= format("Raw(%d bytes)", len);*/

                            p = p[len .. $];
                        }
                    }
                }
                else
                    args ~= format("<UnknownTI:0x%08X>", typeInfo);
            }

            if (args.length > 0)
            {
                debug
                {
                    import std.stdio;

                    writeln("str: ", args.join(" "));
                }
                return args.join(" ");
            }

            return "Verbose Msg (" ~ to!string(extHdr.numberOfArguments) ~ " args)";
        }
    }
    else // not useExtendedHeader
    {
        debug
        {
            import std.stdio;

            writeln("useExtendedHeader = false");
        }
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
