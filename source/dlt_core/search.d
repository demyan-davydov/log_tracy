module dlt_core.search;

import dlt_core.indexer;
import dlt_core.dlt;
import dlt_core.fibex;

import std.algorithm;
import std.array;
import std.regex;
import std.string;
import core.thread;
import core.atomic;
import std.stdio;
import std.json;

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
    string ecu;
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

    bool isFiltered() const pure nothrow
    {
        return _isFiltered;
    }

    bool isSearching() const pure nothrow
    {
        return atomicLoad(_isSearching);
    }

    //! @returns progress as value [0..100]
    int getProgress() const pure nothrow @nogc
    {
        return atomicLoad(_progress);
    }

    const(size_t[]) getIndices() const pure nothrow @nogc
    {
        if (_isFiltered)
            return _filteredIndices;
        return _filteredIndices;
    }

    size_t getLogCount() const pure nothrow @nogc
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

    LogItem getLogItem(size_t index)
    {
        import std.conv : to;

        const size_t total = getLogCount();
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

        // ECU ID is stored as uint (4 bytes) in indexer, convert to ubyte[4] and clean
        ubyte[4] ecuBytes = (cast(ubyte*)&msg.ecuId)[0 .. 4];
        item.ecu = cleanId(ecuBytes);

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
                item.payload = decodePayload(stdPtr, payload, _fibex);

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

    string getLogItemAsJson(size_t index)
    {
        import std.conv : to;

        const size_t total = getLogCount();
        if (index < 0 || index >= total)
            return "{}";

        LogItem item = getLogItem(index);

        JSONValue j = [
            "index": JSONValue(item.index),
            "offset": JSONValue(item.offset),
            "length": JSONValue(item.length),
            "timestamp": JSONValue(item.timestamp),
            "ecu": JSONValue(item.ecu),
            "appId": JSONValue(item.appId),
            "ctxId": JSONValue(item.ctxId),
            "level": JSONValue(to!string(item.level)),
            "type": JSONValue(dlt_core.dlt.toString(item.type)),
            "payload": JSONValue(item.payload)
        ];

        return j.toString();
    }

    private string cleanId(const ubyte[4] id) const pure
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

    static private string decodePayload(const(ubyte)* stdHdrPtr, const(ubyte)[] payload, in FibexParser fibex) pure
    {
        import std.conv : to;
        import std.format : format;

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
            if (fibex)
            {
                string desc = fibex.getDescription(msgId);
                if (!desc.empty)
                    return desc;
            }
            return format("Non-Verbose ID: 0x%08X", msgId);
        }

        return "Legacy DLT Message";
    }

    string getLogItemsAsJson(size_t start, size_t count)
    {
        import std.conv : to;

        JSONValue[] arr;
        const auto total = getLogCount();
        for (size_t i = start; i < start + count && i < total; ++i)
        {
            LogItem item = getLogItem(i);

            JSONValue j = [
                "index": JSONValue(item.index),
                "offset": JSONValue(item.offset),
                "length": JSONValue(item.length),
                "timestamp": JSONValue(item.timestamp),
                "ecu": JSONValue(item.ecu),
                "appId": JSONValue(item.appId),
                "ctxId": JSONValue(item.ctxId),
                "level": JSONValue(to!string(item.level)),
                "type": JSONValue(dlt_core.dlt.toString(item.type)),
                "payload": JSONValue(item.payload)
            ];
            arr ~= j;
        }
        return JSONValue(arr).toString();
    }
}
