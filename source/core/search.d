module core.search;

import core.indexer;
import std.algorithm;
import std.array;
import std.regex;
import std.string;
import core.thread;
import core.atomic;
import std.stdio;
import std.json;
import core.dlt;
import core.fibex;

/// Structure defining active filters
struct FilterConfig
{
    string ecuId;
    string appId;
    string ctxId;
    string payloadRegex;
}

/// Represents a decoded log message
struct LogItem
{
    size_t index;
    ulong offset;
    ushort length;
    ulong timestamp;
    uint ecu;
    string appId;
    string ctxId;
    LogLevel level;
    DltType type;
    string payload;
}

class SearchEngine
{
    private Indexer _indexer;
    private size_t[] _filteredIndices;
    private bool _isFiltered = false;
    public FibexParser _fibex;

    private Thread _searchThread;
    private shared bool _isSearching;
    private shared int _progress; // 0 to 100
    private bool _cancelFlag;

    this(Indexer indexer)
    {
        this._indexer = indexer;
        _isFiltered = false;
        _filteredIndices = [];
    }

    void reset()
    {
        cancel();
        _isFiltered = false;
        _filteredIndices = [];
    }

    void cancel()
    {
        if (atomicLoad(_isSearching))
        {
            _cancelFlag = true;
            if (_searchThread)
                _searchThread.join();
        }
        _cancelFlag = false;
    }

    bool isFiltered() const
    {
        return _isFiltered;
    }

    bool isSearching()
    {
        return atomicLoad(_isSearching);
    }

    int getProgress()
    {
        return atomicLoad(_progress);
    }

    size_t[] getIndices()
    {
        if (_isFiltered)
            return _filteredIndices;
        return _filteredIndices;
    }

    ulong getLogCount()
    {
        if (_isFiltered)
            return _filteredIndices.length;
        return _indexer.totalMessages;
    }

    /// Apply filters asynchronously
    void applyFilter(FilterConfig config)
    {
        // Cancel existing
        cancel();

        // If config is empty, just reset
        if (config.ecuId.empty && config.appId.empty && config.ctxId.empty && config
            .payloadRegex.empty)
        {
            reset();
            return;
        }

        atomicStore(_isSearching, true);
        atomicStore(_progress, 0);
        _cancelFlag = false; // Reset flag

        _searchThread = new Thread({
            try
            {
                runFilter(config);
            }
            catch (Exception e)
            {
                writeln("Search Thread Error: ", e.msg);
            }
            atomicStore(_isSearching, false);
            atomicStore(_progress, 100);
        });
        _searchThread.start();
    }

    private void runFilter(FilterConfig config)
    {
        import std.conv : to;

        size_t[] newIndices;

        // Setup Regex
        Regex!char re;
        bool useRegex = !config.payloadRegex.empty;
        if (useRegex)
        {
            try
            {
                re = regex(config.payloadRegex);
            }
            catch (Exception e)
            {
                useRegex = false;
            }
        }

        auto total = _indexer.totalMessages;
        auto msgs = _indexer.index;

        // Iterate
        int lastProg = 0;

        for (size_t i = 0; i < total; ++i)
        {
            if (_cancelFlag)
                break;

            int p = cast(int)((i * 100) / total);
            if (p > lastProg)
            {
                atomicStore(_progress, p);
                lastProg = p;
            }

            bool match = true;

            if (useRegex)
            {
                auto msg = msgs[i];
                auto slice = _indexer.getSlice(msg.offset, msg.length);
                if (slice)
                {
                    string s = cast(string) slice;
                    if (matchFirst(s, re).empty)
                        match = false;
                }
                else
                {
                    match = false;
                }
            }

            if (match)
            {
                newIndices ~= i;
            }
        }

        if (!_cancelFlag)
        {
            _filteredIndices = newIndices;
            _isFiltered = true;
        }
    }

    LogItem getLogItem(int index)
    {
        import std.conv : to;

        ulong total = getLogCount();
        if (index < 0 || index >= total)
            return LogItem.init;

        size_t realIndex = _isFiltered ? _filteredIndices[index] : index;
        auto msg = _indexer.index[realIndex];

        // Fetch real data for decoding
        const(ubyte[]) data = _indexer.getSlice(msg.offset, msg.length + StorageHeader.sizeof);

        LogItem item;
        item.index = realIndex;
        item.offset = msg.offset;
        item.length = msg.length;
        item.timestamp = msg.timestamp;
        item.ecu = msg.ecuId;
        item.level = LogLevel.Info;
        item.appId = "-";
        item.ctxId = "-";
        item.type = DltType.Log;

        if (data.length >= StorageHeader.sizeof + StandardHeader.sizeof)
        {
            const(ubyte)* stdPtr = data.ptr + StorageHeader.sizeof;
            uint headerSize = getHeaderSize(stdPtr);
            if (data.length >= StorageHeader.sizeof + headerSize)
            {
                const(ubyte)[] payload = data[StorageHeader.sizeof + headerSize .. $];
                item.payload = decodePayload(stdPtr, payload);

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

                    // DltType is in bits 1-3 of messageInfo
                    item.type = cast(DltType)((extHdr.messageInfo & MessageInfo.TypeMask) >> 1);

                    // DLT IDs are 4 bytes, usually ASCII. 
                    // Since they are now ubyte[4], no reversal happens during access.
                    item.appId = cast(string) extHdr.applicationId.dup;
                    item.ctxId = cast(string) extHdr.contextId.dup;
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

    string getLogItemAsJson(int index)
    {
        import std.conv : to;

        ulong total = getLogCount();
        if (index < 0 || index >= total)
            return "{}";

        LogItem item = getLogItem(index);

        string typeStr;
        switch (item.type)
        {
        case DltType.Log:
            typeStr = "LOG";
            break;
        case DltType.AppTrace:
            typeStr = "APP";
            break;
        case DltType.NwTrace:
            typeStr = "NW";
            break;
        case DltType.Control:
            typeStr = "CTRL";
            break;
        default:
            typeStr = "UNK";
            break;
        }

        JSONValue j = [
            "index": JSONValue(item.index),
            "offset": JSONValue(item.offset),
            "length": JSONValue(item.length),
            "timestamp": JSONValue(item.timestamp),
            "ecu": JSONValue(to!string(item.ecu)),
            "appId": JSONValue(item.appId),
            "ctxId": JSONValue(item.ctxId),
            "level": JSONValue(to!string(item.level)),
            "type": JSONValue(typeStr),
            "payload": JSONValue(item.payload)
        ];

        return j.toString();
    }

    private string decodePayload(const(ubyte)* stdHdrPtr, const(ubyte)[] payload)
    {
        import std.conv : to;
        import std.format : format;

        auto stdHdr = cast(const(StandardHeader)*) stdHdrPtr;
        bool msbf = (stdHdr.headerType & HeaderType.MostSignificantByteFirst) != 0;

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

                    if (typeInfo & TypeInfoFlags.FixedPoint)
                    {
                        if (p.length >= 8)
                            p = p[8 .. $];
                    }

                    if (typeInfo & TypeInfoFlags.TypeBoolean)
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
                                bool printable = (len > 0);
                                foreach (b; rawData)
                                    if (b < 32 && b != 10 && b != 13 && b != 9)
                                    {
                                        printable = false;
                                        break;
                                    }

                                if (printable)
                                    args ~= "\"" ~ cast(string) rawData ~ "\"";
                                else if (len <= 16)
                                {
                                    string hex;
                                    foreach (b; rawData)
                                        hex ~= format("%02X", b);
                                    args ~= "[" ~ hex ~ "]";
                                }
                                else
                                    args ~= format("Raw(%d bytes)", len);
                                p = p[len .. $];
                            }
                        }
                    }
                    else
                        args ~= format("<UnknownTI:0x%08X>", typeInfo);
                }
                if (args.length > 0)
                    return args.join(" ");
                return "Verbose Msg (" ~ to!string(extHdr.numberOfArguments) ~ " args)";
            }
        }

        if (!isVerbose)
        {
            // Non-Verbose: Use MsgID for FIBEX lookup
            uint msgId = peekMessageId(stdHdrPtr);
            if (_fibex)
            {
                string desc = _fibex.getDescription(msgId);
                if (!desc.empty)
                    return desc;
            }
            return format("Non-Verbose ID: 0x%08X", msgId);
        }

        return "Legacy DLT Message";
    }

    string getLogItemsAsJson(int start, int count)
    {
        import std.conv : to;

        JSONValue[] arr;
        int total = cast(int) getLogCount();
        for (int i = start; i < start + count && i < total; ++i)
        {
            LogItem item = getLogItem(i);

            string typeStr;
            switch (item.type)
            {
            case DltType.Log:
                typeStr = "LOG";
                break;
            case DltType.AppTrace:
                typeStr = "APP";
                break;
            case DltType.NwTrace:
                typeStr = "NW";
                break;
            case DltType.Control:
                typeStr = "CTRL";
                break;
            default:
                typeStr = "UNK";
                break;
            }

            JSONValue j = [
                "index": JSONValue(item.index),
                "offset": JSONValue(item.offset),
                "length": JSONValue(item.length),
                "timestamp": JSONValue(item.timestamp),
                "ecu": JSONValue(to!string(item.ecu)),
                "appId": JSONValue(item.appId),
                "ctxId": JSONValue(item.ctxId),
                "level": JSONValue(to!string(item.level)),
                "type": JSONValue(typeStr),
                "payload": JSONValue(item.payload)
            ];
            arr ~= j;
        }
        return JSONValue(arr).toString();
    }
}
