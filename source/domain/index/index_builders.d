module domain.index.index_builders;

import domain.index.offset_index;
import domain.index.filter_index;
import domain.index.search_index;
import domain.index.anchors;

import dlt_core.dlt_source;
import dlt_core.log_filter;

import dlt_core.dlt_parser;
import dlt_core.decoded_message;

import std.algorithm.comparison : min;
import std.typecons : Nullable;
import std.stdint;

private alias Filter = LogFilter!wchar;
private alias Message = DecodedMessage!wchar;

//! Description:
//! The DLT file has 3 associated indexes:
//! 1. OffsetIndex  - stores byte offsets of message starts within the file
//! 2. FilterIndex  - references OffsetIndex and stores the entries that match
//!    the global filter
//! 3. SearchIndex  - references OffsetIndex and stores the entries that match
//!    the current search query
//!
//! The main view shows either unfiltered messages (when no filter is active)
//! or filtered messages (when a filter is set).
//! The search pane shows messages from the main view that match the search query.
//!

//! @brief Scan DLT file and create offset index for messages
OffsetIndex.Type[] buildOffsetIndexes(OffsetIndex.Type[] buffer, ref DltSourceRange range)
{
    const auto bunchSize = buffer.length;

    size_t i = 0;
    for (; i < bunchSize && range.hasNext; ++i)
    {
        const auto msg = range.pop();
        if (msg.length == 0)
            break;

        buffer[i].offset = range.offset - msg.length;
    }

    return buffer[0 .. i];
}

//! @brief Scan offset indexes created by buildOffsetIndexes() in DLT file and 
//! create filter index for messages
FilterIndex.Type[] buildFilterIndexes(FilterIndex.Type[] buffer,
    uint16_t[] filterMaskBuffer,
    ref Message parsedMessage,
    const(DltSource) source,
    const(OffsetIndex.Type[]) offsetIndexes,
    ref const(Anchors) anchors,
    const(Filter) filter
)
in
{
    debug assert(buffer.length == filterMaskBuffer.length);
    debug assert(buffer.length >= offsetIndexes.length);
}
body
{
    const auto bunchSize = min(buffer.length, offsetIndexes.length);

    auto isMatched = (ref const(Message) msg, size_t fileIndex) {
        const auto matchIndex = filter.matchIndex(msg);
        return matchIndex.isNull
            ? (anchors.has(fileIndex) ? Nullable!uint(-1) : Nullable!uint.init) : matchIndex;
    };

    FilterIndex.Type i = 0;
    size_t j = 0;
    for (; i < bunchSize; ++i)
    {
        const auto msg = source.getMessage(offsetIndexes[i].offset);
        if (msg.length == 0)
            break;

        parseDltItem!wchar(parsedMessage, msg, source.hasStorageHeader);

        const auto matchResult = isMatched(parsedMessage, offsetIndexes[i].offset);
        if (matchResult.isNull)
            continue;

        buffer[j] = i;
        filterMaskBuffer[j] = cast(uint16_t) matchResult.get();
        ++j;
    }

    return buffer[0 .. j];
}

//! @brief Scan offset indexes created by buildOffsetIndexes() in DLT file and 
//! create search index for messages
SearchIndex.Type[] buildSearchIndexes(SearchIndex.Type[] buffer,
    ref Message parsedMessage,
    const(DltSource) source,
    const(OffsetIndex.Type[]) offsetIndexes,
    ref const(Anchors) anchors,
    const(Filter) filter
)
in
{
    debug assert(buffer.length >= offsetIndexes.length);
}
body
{
    const auto bunchSize = min(buffer.length, offsetIndexes.length);

    auto isMatched = (ref const(Message) msg, size_t fileIndex) {
        return anchors.has(fileIndex) || filter.matches(msg);
    };

    SearchIndex.Type i = 0;
    size_t j = 0;
    for (; i < bunchSize; ++i)
    {
        const auto msg = source.getMessage(offsetIndexes[i].offset);
        if (msg.length == 0)
            break;

        parseDltItem!wchar(parsedMessage, msg, source.hasStorageHeader);

        if (!isMatched(parsedMessage, offsetIndexes[i].offset))
            continue;

        buffer[j++] = i;
    }

    return buffer[0 .. j];
}

version (unittest)
{
    import core.stdc.stdint : uint16_t;
    import std.typecons : Nullable;
    import dlt_core.dlt_protocol;
    import std.bitmanip : nativeToBigEndian;

    // ─── Test infrastructure ────────────────────────────────────────────────

    /// Build a raw DLT message (StorageHeader + StandardHeader + optional Extended + payload)
    private ubyte[] makeDltMsg(
        const(char)[4] ecu = "ECU1",
        const(char)[4] app = "APP1",
        const(char)[4] ctx = "CTX1",
        ubyte logLevelInfo = 0x41, // Verbose | Log | Info
        const(ubyte)[] asciiPayload = []
    )
    {
        ubyte[] msg;

        // Storage Header (16 bytes, little-endian)
        msg ~= cast(ubyte[]) DLT_PATTERN;
        msg ~= [0, 0, 0, 0]; // seconds
        msg ~= [0, 0, 0, 0]; // microseconds
        msg ~= cast(ubyte[]) ecu;

        // Standard Header: UseExtendedHeader | MostSignificantByteFirst
        enum ubyte htFlags = StandardHeader.Type.UseExtendedHeader
            | StandardHeader.Type.MostSignificantByteFirst;

        // payload = ExtendedHeader + asciiPayload
        ubyte[] innerPayload;

        // Extended Header (10 bytes)
        ExtendedHeader extHdr;
        extHdr.messageInfo = logLevelInfo;
        extHdr.numberOfArguments = 1;
        extHdr.applicationId = cast(char[4]) app;
        extHdr.contextId = cast(char[4]) ctx;
        innerPayload ~= (cast(ubyte*)&extHdr)[0 .. ExtendedHeader.sizeof];

        // ASCII string argument (TypeInfo 4 bytes + len 2 bytes + data + null)
        if (asciiPayload.length > 0)
        {
            // TypeInfo: TypeString | StringCodingASCII
            uint typeInfo = TypeInfoFlags.TypeString | TypeInfoFlags.StringCodingASCII;
            innerPayload ~= cast(ubyte[4]) nativeToBigEndian(typeInfo);
            ushort strLen = cast(ushort)(asciiPayload.length + 1);
            innerPayload ~= cast(ubyte[2]) nativeToBigEndian(strLen);
            innerPayload ~= asciiPayload;
            innerPayload ~= cast(ubyte) 0; // null terminator
        }

        // Standard Header fields
        msg ~= htFlags;
        msg ~= cast(ubyte) 0; // messageCounter
        ushort totalMsgLen = cast(ushort)(StandardHeader.sizeof + innerPayload.length);
        msg ~= cast(ubyte[2]) nativeToBigEndian(totalMsgLen);

        msg ~= innerPayload;
        return msg;
    }

    /// A DltSource backed by an in-memory ubyte[] buffer — no file I/O required
    private final class MockDltSource : DltSource
    {
        private ubyte[] _data;
        private bool _hasStorageHeader;

        this(ubyte[] data, bool hasStorageHeader = true)
        {
            _data = data;
            _hasStorageHeader = hasStorageHeader;
        }

        override DltSourceRange range() const pure nothrow @nogc @property
        {
            return DltSourceRange(cast(const(ubyte)[]) _data, _hasStorageHeader);
        }

        override size_t overallLength() const pure nothrow @nogc @property
        {
            return _data.length;
        }

        override bool hasStorageHeader() const pure nothrow @nogc @property
        {
            return _hasStorageHeader;
        }

        override const(ubyte)[] getMessage(size_t offset) const pure @nogc nothrow
        {
            if (offset >= _data.length)
                return [];

            const(ubyte)[] buf = _data[offset .. $];

            // Skip storage header pattern
            if (_hasStorageHeader)
            {
                if (buf.length < StorageHeader.sizeof)
                    return [];
                buf = buf[StorageHeader.sizeof .. $];
            }

            if (buf.length < StandardHeader.sizeof)
                return [];

            auto stdHdr = cast(const(StandardHeader)*) buf.ptr;
            const ushort msgLen = stdHdr.nativeLength;

            const size_t fullLen = (_hasStorageHeader ? StorageHeader.sizeof : 0) + msgLen;
            if (offset + fullLen > _data.length)
                return [];

            return _data[offset .. offset + fullLen];
        }
    }

    /// LogFilter stub that always matches
    private final class AlwaysMatchFilter : LogFilter!wchar
    {
        override bool matches(ref const(DecodedMessage!wchar) item) const
        {
            return true;
        }

        override Nullable!uint matchIndex(scope ref const(DecodedMessage!wchar) item) const
        {
            return Nullable!uint(0);
        }

        override immutable(LogFilter!wchar) idup() const pure
        {
            return cast(immutable) dup();
        }

        override LogFilter!wchar dup() const pure
        {
            return new AlwaysMatchFilter();
        }
    }

    /// LogFilter stub that never matches
    private final class NeverMatchFilter : LogFilter!wchar
    {
        override bool matches(ref const(DecodedMessage!wchar) item) const
        {
            return false;
        }

        override Nullable!uint matchIndex(scope ref const(DecodedMessage!wchar) item) const
        {
            return Nullable!uint.init;
        }

        override immutable(LogFilter!wchar) idup() const pure
        {
            return cast(immutable) dup();
        }

        override LogFilter!wchar dup() const pure
        {
            return new NeverMatchFilter();
        }
    }

    /// LogFilter stub that matches messages with specific appId (ASCII)
    private final class AppIdFilter : LogFilter!wchar
    {
        private string _appIdUtf8; // kept for pure dup()
        private wstring _appId; // pre-converted for matching

        this(string appId) pure
        {
            import std.utf : toUTF16;

            _appIdUtf8 = appId;
            _appId = appId.toUTF16();
        }

        override bool matches(ref const(DecodedMessage!wchar) item) const
        {
            return item.appId == _appId;
        }

        override Nullable!uint matchIndex(scope ref const(DecodedMessage!wchar) item) const
        {
            return matches(item) ? Nullable!uint(0u) : Nullable!uint.init;
        }

        override immutable(LogFilter!wchar) idup() const pure
        {
            return cast(immutable) dup();
        }

        override LogFilter!wchar dup() const pure
        {
            return new AppIdFilter(_appIdUtf8);
        }
    }

    /// Build OffsetIndex.Type[] from a DltSourceRange (helper for tests)
    private OffsetIndex.Type[] buildOffsets(ref DltSourceRange range, size_t maxItems = 256)
    {
        auto buf = new OffsetIndex.Type[maxItems];
        return buildOffsetIndexes(buf, range).dup;
    }

    // ─── buildOffsetIndexes tests ───────────────────────────────────────────

    @("buildOffsetIndexes: empty source yields empty result")
    unittest
    {
        auto src = new MockDltSource([]);
        auto range = src.range();
        OffsetIndex.Type[16] buf;
        auto result = buildOffsetIndexes(buf[], range);
        assert(result.length == 0);
    }

    @("buildOffsetIndexes: single message records its offset")
    unittest
    {
        auto raw = makeDltMsg();
        auto src = new MockDltSource(raw.dup);
        auto range = src.range();

        OffsetIndex.Type[16] buf;
        auto result = buildOffsetIndexes(buf[], range);

        assert(result.length == 1);
        // offset is start of message (before pop) == 0 for the first message
        assert(result[0].offset == 0);
    }

    @("buildOffsetIndexes: two messages recorded as two offsets")
    unittest
    {
        auto msg1 = makeDltMsg("ECU1");
        auto msg2 = makeDltMsg("ECU2");
        ubyte[] combined = msg1.dup ~ msg2.dup;
        auto src = new MockDltSource(combined);
        auto range = src.range();

        OffsetIndex.Type[16] buf;
        auto result = buildOffsetIndexes(buf[], range);

        assert(result.length == 2);
        // First offset is start of msg1 == 0
        assert(result[0].offset == 0);
        // Second offset is start of msg2 == msg1.length
        assert(result[1].offset == msg1.length);
    }

    @("buildOffsetIndexes: buffer smaller than message count clips result")
    unittest
    {
        ubyte[] combined;
        foreach (i; 0 .. 5)
            combined ~= makeDltMsg();

        auto src = new MockDltSource(combined.dup);
        auto range = src.range();

        OffsetIndex.Type[3] smallBuf;
        auto result = buildOffsetIndexes(smallBuf[], range);
        assert(result.length == 3);
    }

    @("buildOffsetIndexes: filterMask field is zero-initialized")
    unittest
    {
        auto raw = makeDltMsg();
        auto src = new MockDltSource(raw.dup);
        auto range = src.range();

        OffsetIndex.Type[4] buf;
        auto result = buildOffsetIndexes(buf[], range);

        assert(result.length == 1);
        assert(result[0].filterMask == 0);
    }

    // ─── buildFilterIndexes tests ───────────────────────────────────────────

    @("buildFilterIndexes: AlwaysMatch passes all messages")
    unittest
    {
        auto msg1 = makeDltMsg("ECU1", "APP1");
        auto msg2 = makeDltMsg("ECU2", "APP2");
        ubyte[] combined = msg1.dup ~ msg2.dup;
        auto src = new MockDltSource(combined);
        auto range = src.range();

        OffsetIndex.Type[8] offBuf;
        auto offsets = buildOffsetIndexes(offBuf[], range);

        FilterIndex.Type[8] filtBuf;
        uint16_t[8] maskBuf;
        DecodedMessage!wchar parsedMsg;
        Anchors anchors;
        auto filter = new AlwaysMatchFilter();

        auto result = buildFilterIndexes(filtBuf[], maskBuf[], parsedMsg, src, offsets, anchors, filter);
        assert(result.length == 2);
        assert(result[0] == 0);
        assert(result[1] == 1);
        assert(maskBuf[0] == 0); // AlwaysMatch returns index 0
        assert(maskBuf[1] == 0);
    }

    @("buildFilterIndexes: NeverMatch with no anchors — empty result")
    unittest
    {
        auto msg1 = makeDltMsg();
        auto msg2 = makeDltMsg();
        ubyte[] combined = msg1.dup ~ msg2.dup;
        auto src = new MockDltSource(combined);
        auto range = src.range();

        OffsetIndex.Type[8] offBuf;
        auto offsets = buildOffsetIndexes(offBuf[], range);

        FilterIndex.Type[8] filtBuf;
        uint16_t[8] maskBuf;
        DecodedMessage!wchar parsedMsg;
        Anchors anchors;
        auto filter = new NeverMatchFilter();

        auto result = buildFilterIndexes(filtBuf[], maskBuf[], parsedMsg, src, offsets, anchors, filter);
        assert(result.length == 0);
    }

    @("buildFilterIndexes: anchored message passes even with NeverMatch filter")
    unittest
    {
        auto msg1 = makeDltMsg();
        auto msg2 = makeDltMsg();
        ubyte[] combined = msg1.dup ~ msg2.dup;
        auto src = new MockDltSource(combined);
        auto range = src.range();

        OffsetIndex.Type[8] offBuf;
        auto offsets = buildOffsetIndexes(offBuf[], range);

        // Anchor message at offset = offsets[0].offset == 0 (start of msg1)
        Anchors anchors;
        anchors.set(offsets[0].offset, true); // anchor by file offset (= 0 = start of msg1)

        FilterIndex.Type[8] filtBuf;
        uint16_t[8] maskBuf;
        DecodedMessage!wchar parsedMsg;
        auto filter = new NeverMatchFilter();

        auto result = buildFilterIndexes(filtBuf[], maskBuf[], parsedMsg, src, offsets, anchors, filter);
        // msg1 is anchored (offset == 0), msg2 is not
        assert(result.length == 1);
        assert(result[0] == 0); // index 0 in offsetIndexes
        // filterMask for anchored-only is 0xFFFF (cast of uint(-1))
        assert(maskBuf[0] == cast(uint16_t) cast(uint16_t)(-1));
    }

    @("buildFilterIndexes: AppId filter selects only matching messages")
    unittest
    {
        auto msgA = makeDltMsg("ECU1", "APP1");
        auto msgB = makeDltMsg("ECU1", "APP2");
        auto msgC = makeDltMsg("ECU1", "APP1");
        ubyte[] combined = msgA.dup ~ msgB.dup ~ msgC.dup;
        auto src = new MockDltSource(combined);
        auto range = src.range();

        OffsetIndex.Type[8] offBuf;
        auto offsets = buildOffsetIndexes(offBuf[], range);

        FilterIndex.Type[8] filtBuf;
        uint16_t[8] maskBuf;
        DecodedMessage!wchar parsedMsg;
        Anchors anchors;
        auto filter = new AppIdFilter("APP1");

        auto result = buildFilterIndexes(filtBuf[], maskBuf[], parsedMsg, src, offsets, anchors, filter);
        assert(result.length == 2);
        assert(result[0] == 0); // msgA
        assert(result[1] == 2); // msgC
    }

    @("buildFilterIndexes: empty offsetIndexes yields empty result")
    unittest
    {
        auto src = new MockDltSource([]);
        OffsetIndex.Type[] emptyOffsets = [];

        FilterIndex.Type[8] filtBuf;
        uint16_t[8] maskBuf;
        DecodedMessage!wchar parsedMsg;
        Anchors anchors;
        auto filter = new AlwaysMatchFilter();

        auto result = buildFilterIndexes(filtBuf[], maskBuf[], parsedMsg, src, emptyOffsets, anchors, filter);
        assert(result.length == 0);
    }

    // ─── buildSearchIndexes tests ───────────────────────────────────────────

    @("buildSearchIndexes: AlwaysMatch passes all messages")
    unittest
    {
        auto msg1 = makeDltMsg();
        auto msg2 = makeDltMsg();
        ubyte[] combined = msg1.dup ~ msg2.dup;
        auto src = new MockDltSource(combined);
        auto range = src.range();

        OffsetIndex.Type[8] offBuf;
        auto offsets = buildOffsetIndexes(offBuf[], range);

        SearchIndex.Type[8] searchBuf;
        DecodedMessage!wchar parsedMsg;
        Anchors anchors;
        auto filter = new AlwaysMatchFilter();

        auto result = buildSearchIndexes(searchBuf[], parsedMsg, src, offsets, anchors, filter);
        assert(result.length == 2);
        assert(result[0] == 0);
        assert(result[1] == 1);
    }

    @("buildSearchIndexes: NeverMatch with no anchors — empty result")
    unittest
    {
        ubyte[] combined = makeDltMsg().dup ~ makeDltMsg().dup;
        auto src = new MockDltSource(combined);
        auto range = src.range();

        OffsetIndex.Type[8] offBuf;
        auto offsets = buildOffsetIndexes(offBuf[], range);

        SearchIndex.Type[8] searchBuf;
        DecodedMessage!wchar parsedMsg;
        Anchors anchors;
        auto filter = new NeverMatchFilter();

        auto result = buildSearchIndexes(searchBuf[], parsedMsg, src, offsets, anchors, filter);
        assert(result.length == 0);
    }

    @("buildSearchIndexes: anchored message bypasses NeverMatch filter")
    unittest
    {
        auto msg1 = makeDltMsg();
        auto msg2 = makeDltMsg();
        ubyte[] combined = msg1.dup ~ msg2.dup;
        auto src = new MockDltSource(combined);
        auto range = src.range();

        OffsetIndex.Type[8] offBuf;
        auto offsets = buildOffsetIndexes(offBuf[], range);

        // Anchor by offset of msg1 == offsets[0].offset == 0 (start of msg1)
        Anchors anchors;
        anchors.set(offsets[0].offset, true);

        SearchIndex.Type[8] searchBuf;
        DecodedMessage!wchar parsedMsg;
        auto filter = new NeverMatchFilter();

        auto result = buildSearchIndexes(searchBuf[], parsedMsg, src, offsets, anchors, filter);
        assert(result.length == 1);
        assert(result[0] == 0);
    }

    @("buildSearchIndexes: AppId filter selects only matching messages")
    unittest
    {
        auto msgA = makeDltMsg("ECU1", "APP1");
        auto msgB = makeDltMsg("ECU1", "OAPP");
        auto msgC = makeDltMsg("ECU1", "APP1");
        ubyte[] combined = msgA.dup ~ msgB.dup ~ msgC.dup;
        auto src = new MockDltSource(combined);
        auto range = src.range();

        OffsetIndex.Type[8] offBuf;
        auto offsets = buildOffsetIndexes(offBuf[], range);

        SearchIndex.Type[8] searchBuf;
        DecodedMessage!wchar parsedMsg;
        Anchors anchors;
        auto filter = new AppIdFilter("APP1");

        auto result = buildSearchIndexes(searchBuf[], parsedMsg, src, offsets, anchors, filter);
        assert(result.length == 2);
        assert(result[0] == 0); // msgA
        assert(result[1] == 2); // msgC
    }

    @("buildSearchIndexes: empty offsetIndexes yields empty result")
    unittest
    {
        auto src = new MockDltSource([]);
        OffsetIndex.Type[] emptyOffsets = [];

        SearchIndex.Type[8] searchBuf;
        DecodedMessage!wchar parsedMsg;
        Anchors anchors;
        auto filter = new AlwaysMatchFilter();

        auto result = buildSearchIndexes(searchBuf[], parsedMsg, src, emptyOffsets, anchors, filter);
        assert(result.length == 0);
    }

    @("buildSearchIndexes: result indices are into offsetIndexes, not file offsets")
    unittest
    {
        auto msgA = makeDltMsg("ECU1", "APP1");
        auto msgB = makeDltMsg("ECU1", "SKIP");
        auto msgC = makeDltMsg("ECU1", "APP1");
        ubyte[] combined = msgA.dup ~ msgB.dup ~ msgC.dup;
        auto src = new MockDltSource(combined);
        auto range = src.range();

        OffsetIndex.Type[8] offBuf;
        auto offsets = buildOffsetIndexes(offBuf[], range);
        assert(offsets.length == 3);

        SearchIndex.Type[8] searchBuf;
        DecodedMessage!wchar parsedMsg;
        Anchors anchors;
        auto filter = new AppIdFilter("APP1");

        auto result = buildSearchIndexes(searchBuf[], parsedMsg, src, offsets, anchors, filter);
        // result[0] == 0 means offsetIndexes[0] (msgA), result[1] == 2 means offsetIndexes[2] (msgC)
        assert(result[0] == 0);
        assert(result[1] == 2);
    }
}
