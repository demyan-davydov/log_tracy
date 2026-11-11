//! RecordStore: the records of a log. The bytes of its source, the format that splits and
//! decodes them, and the offset index of the records found so far, which only grows. The
//! numbered parts of a message (PartedFormat) are one record of it (domain/index/part_joiner).
//!
//! Not thread-safe, but for one promise: the records below a length a reader was given
//! (Records, records()) may be read by any number of threads at once while one writer
//! appends after them. Their entries never move (utils/chunked_array) and none is removed.
//! The rest is the holder's to synchronize (LogIndex): reading length() while a record is
//! appended, appending, and close(). The holder gives a reader its Records so that the
//! reader sees the records below its length (a lock both take, or starting the thread or
//! the task that reads), and closes the store only once no reader reads it any more: the
//! bytes of a closed store are gone, and a reader of them crashes.
module domain.index.record_store;

import domain.index.offset_index : OffsetIndex, OffsetIndexItem;
import domain.index.part_joiner : PartJoiner;
import log_core.byte_source : ByteSource;
import log_core.log_format : LogFormat, PartedFormat, RecordPart, ScanResult;
import log_core.log_message : LogMessage;
import utils.chunked_array : ChunkedArray;

import std.typecons : Rebindable;

//! What RecordStore.findRecords found: the offsets of the records, at most
//! RecordStore.bunchSize, and where the next search goes on from
struct Bunch
{
    size_t[RecordStore.bunchSize] offsets;
    RecordPart[RecordStore.bunchSize] parts; // of a PartedFormat: what each record is as a part
    ScanResult found;
    bool end; // the data is over: no more bytes will come, and these were the last ones

    //! The offsets found
    const(size_t)[] records() const pure nothrow @nogc return
    {
        return offsets[0 .. found.count];
    }
}

//! A record joined of parts: the offsets of its parts after the first one are
//! RecordStore._parts[firstPart .. firstPart + parts]
private struct Join
{
    size_t record;
    size_t firstPart;
    size_t parts;
}

final class RecordStore
{
    //! Records found and appended at a time
    enum bunchSize = 32;

    private ByteSource _source;
    private LogFormat _format;
    private const(PartedFormat) _parted; // the format, if its records may be parts
    private OffsetIndex _offsets;
    private size_t _scannedBytes; // the bytes of the source split into records

    // The records joined of parts, by their number, and the offsets of their parts.
    // Taken as the parts are found: none for a log without them
    private PartJoiner _joiner;
    private ChunkedArray!Join _joins;
    private ChunkedArray!size_t _parts;
    private bool _broken; // an append failed half done: the joins may not match the records

    //! @param source - owned by the store from now on: released by close()
    this(ByteSource source, LogFormat format)
    {
        _source = source;
        _format = format;
        _parted = cast(const(PartedFormat)) format;
    }

    //! The format the records are split and decoded by
    const(LogFormat) format() const pure nothrow @nogc
    {
        return _format;
    }

    //! The bytes of the source so far (ByteSource.data): they may grow, see ByteSource
    const(ubyte)[] data() const pure nothrow @nogc
    {
        return _source.data;
    }

    //! No more bytes will come (ByteSource.complete): asked before data(), see there
    bool complete() const nothrow @nogc
    {
        return _source.complete;
    }

    //! The bytes can't be read any more (ByteSource.lost): what was read may be zeros
    bool lost() const nothrow @nogc
    {
        return _source.lost;
    }

    //! The records found so far. Not while one is being appended (see the module)
    size_t length() const pure nothrow @nogc
    {
        return _offsets.length;
    }

    //! @returns true if records found are held, not appended yet: they wait for the
    //! parts of a message (PartedFormat), see append()
    bool holding() const pure nothrow @nogc
    {
        return _joiner.holding;
    }

    //! The bytes of the data split into records so far
    size_t scannedBytes() const pure nothrow @nogc
    {
        return _scannedBytes;
    }

    //! Memory the offset index has taken, in bytes
    size_t reservedBytes() const pure nothrow @nogc
    {
        return _offsets.reservedBytes;
    }

    //! The records found so far, to read from any thread: see the module. Not while one is
    //! being appended
    Records records() const pure nothrow @nogc
    {
        return Records(this, _offsets.length, _joins.length);
    }

    //! @brief Finds the records of `data` after scannedBytes(), bunchSize of them at most,
    //! without changing the store (LogFormat.scanRecords). Nothing found, and `next` where
    //! it started: the bytes left are the start of a record still to come (not `final_`).
    //! @param data - the bytes of the source, as data() gave them
    //! @param final_ - no more bytes will come (complete())
    Bunch findRecords(const(ubyte)[] data, bool final_) const nothrow @nogc
    {
        Bunch bunch;
        bunch.found = _format.scanRecords(data, _scannedBytes, bunch.offsets[], final_);
        bunch.end = final_ && bunch.found.next == data.length;
        // Here, not in append(): the holder calls this without its lock
        if (_parted !is null)
            foreach (i, offset; bunch.records)
                bunch.parts[i] = _parted.partOf(data, offset);
        return bunch;
    }

    //! @brief Appends the records findRecords() found: the bytes they were found in are
    //! split into records from now on. The records of a PartedFormat from a first part
    //! on may be held (holding()) until its message is whole or can't be; the end of the
    //! data (Bunch.end) lets them out.
    //! @return false if the index can't grow (too many records, not enough memory):
    //! nothing changes then; for a PartedFormat the store takes nothing more from then on
    bool append(ref const Bunch bunch) nothrow @nogc
    {
        if (_broken)
            return false;
        if (_parted is null)
        {
            OffsetIndexItem[bunchSize] items;
            foreach (i, offset; bunch.records)
                items[i].offset = offset;
            if (!_offsets.append(items[0 .. bunch.found.count]))
                return false;
            _scannedBytes = bunch.found.next;
            return true;
        }

        // The records held before and the ones of the bunch may all leave at once
        OffsetIndexItem[bunchSize + PartJoiner.maxHeld] items = void;
        size_t count = 0;
        bool failed = false;
        scope emit = (size_t offset, const(size_t)[] parts) nothrow @nogc {
            OffsetIndexItem item;
            item.offset = offset;
            if (parts.length != 0)
            {
                // Before the record: a reader of it finds its parts
                const join = Join(_offsets.length + count, _parts.length, parts.length);
                failed |= !_parts.append(parts) || !_joins.append(join);
                item.joined = true;
            }
            items[count++] = item;
        };

        foreach (i, offset; bunch.records)
        {
            if (!bunch.parts[i].isPart && !_joiner.holding)
                items[count++] = OffsetIndexItem(offset); // the usual record, at once
            else
                _joiner.add(offset, bunch.parts[i], emit);
        }
        if (bunch.end)
            _joiner.flush(emit);
        // The joiner has let its records out and the joins are written: a later append
        // would give the next records the numbers the joins already have
        if (failed || !_offsets.append(items[0 .. count]))
        {
            _broken = true;
            return false;
        }
        _scannedBytes = bunch.found.next;
        return true;
    }

    //! Releases the bytes of the source and the offset index at once: the index lives in
    //! memory of its own, which the GC neither sees nor would free soon. Only once no reader
    //! reads them (see the module). Idempotent; no records and data() empty afterwards.
    void close() nothrow @nogc
    {
        _source.close();
        _offsets.clear();
        _joins.clear();
        _parts.clear();
        _joiner = PartJoiner.init;
        _broken = false;
        _scannedBytes = 0;
    }
}

//! The records of a RecordStore below a length: read from any thread, while the store
//! grows after them (see domain.index.record_store). A copy reads the same records.
struct Records
{
    private Rebindable!(const RecordStore) _store; // a copy may be assigned another one
    private size_t _length;
    private size_t _joins; // the joined records below _length: RecordStore._joins

    private this(const RecordStore store, size_t length, size_t joins) pure nothrow @nogc
    {
        _store = store;
        _length = length;
        _joins = joins;
    }

    //! The records it reads
    size_t length() const pure nothrow @nogc
    {
        return _length;
    }

    //! The bytes can't be read any more: a record read may be zeros, see decode()
    bool lost() const nothrow @nogc
    {
        return _store.lost;
    }

    //! The offset of the record `record` < length in the data of the source
    size_t offsetOf(size_t record) const pure nothrow @nogc
    {
        assert(record < _length);
        return _store._offsets[record].offset;
    }

    //! @brief Decodes the record `record` < length into `msg`
    //! @return false if there is no valid record there: e.g. the file was lost and read
    //! as zeros (lost())
    bool decode(size_t record, ref LogMessage!wchar msg) const nothrow @nogc
    {
        assert(record < _length);
        const format = _store._format;
        const data = _store._source.data;
        const item = _store._offsets[record];
        if (!item.joined)
            return format.decode(msg, format.recordAt(data, item.offset));

        const join = joinOf(record);
        const(ubyte)[][1 + PartJoiner.maxParts] parts;
        parts[0] = format.recordAt(data, item.offset);
        foreach (i; 0 .. join.parts)
            parts[1 + i] = format.recordAt(data, _store._parts[join.firstPart + i]);
        return _store._parted.decodeParts(msg, parts[0 .. 1 + join.parts]);
    }

    //! The parts of the joined record `record`: the joins are in the order of their records
    private Join joinOf(size_t record) const pure nothrow @nogc
    {
        size_t lo = 0, hi = _joins;
        while (lo < hi)
        {
            const mid = lo + (hi - lo) / 2;
            if (_store._joins[mid].record < record)
                lo = mid + 1;
            else
                hi = mid;
        }
        assert(lo < _joins && _store._joins[lo].record == record);
        return _store._joins[lo];
    }
}

version (unittest)
{
    //! Bytes in memory that may come in parts: the bytes of before don't move
    private final class TextSource : ByteSource
    {
        private ubyte[] _room;
        private size_t _length;
        bool closed;

        this(string text, size_t room = 4096)
        {
            _room = new ubyte[room];
            add(text);
        }

        void add(string text)
        {
            _room[_length .. _length + text.length] = cast(const(ubyte)[]) text;
            _length += text.length;
        }

        override const(ubyte)[] data() const pure nothrow @nogc => _room[0 .. _length];
        override bool complete() const nothrow @nogc => false;
        override bool lost() const nothrow @nogc => false;
        override void close() nothrow @nogc { closed = true; }
    }

    //! Finds and appends the records of the bytes not split yet
    private void scanAll(RecordStore store, bool final_)
    {
        for (;;)
        {
            const bunch = store.findRecords(store.data, final_);
            assert(store.append(bunch));
            if (store.scannedBytes == store.data.length && !(final_ && store.holding))
                return;
            if (bunch.found.count == 0 && bunch.found.next == store.scannedBytes && !bunch.end)
                return;
        }
    }

    private string payloadOf(Records records, size_t record)
    {
        import std.conv : to;

        LogMessage!wchar msg;
        assert(records.decode(record, msg));
        return msg.payloadText.to!string;
    }
}

@("RecordStore: records are found in bunches and read by their number")
unittest
{
    import formats.plain_text : PlainTextFormat;

    auto store = new RecordStore(new TextSource("one\ntwo\nthree\n"), new PlainTextFormat());
    assert(store.length == 0 && store.records.length == 0);

    scanAll(store, true);
    assert(store.length == 3 && store.scannedBytes == store.data.length);
    const records = store.records;
    assert(records.offsetOf(0) == 0 && records.offsetOf(1) == 4 && records.offsetOf(2) == 8);
    assert(payloadOf(records, 0) == "one" && payloadOf(records, 2) == "three");
}

@("RecordStore: Records reads the records below its length while the store grows after them")
unittest
{
    import formats.plain_text : PlainTextFormat;

    auto source = new TextSource("one\ntwo\nthr");
    auto store = new RecordStore(source, new PlainTextFormat());
    scanAll(store, false);
    assert(store.length == 2, "the record cut by the end of the data waits");
    const before = store.records;

    source.add("ee\nfour\n");
    scanAll(store, false);
    assert(store.length == 4 && payloadOf(store.records, 2) == "three");
    assert(before.length == 2 && payloadOf(before, 1) == "two", "a copy given before reads what it read");
}

@("RecordStore: findRecords changes nothing, append takes what it found")
unittest
{
    import formats.plain_text : PlainTextFormat;

    auto store = new RecordStore(new TextSource("a\nb\n"), new PlainTextFormat());
    const bunch = store.findRecords(store.data, true);
    assert(bunch.records == [0, 2]);
    assert(store.length == 0 && store.scannedBytes == 0, "nothing appended until asked");
    assert(store.append(bunch));
    assert(store.length == 2 && store.scannedBytes == 4);
}

version (unittest)
{
    import log_core.log_format : ColumnInfo, FormatInfo, PartedFormat, RecordPart;

    //! Lines of plain text, "<sender><counter> <k>/<n>: <text>" a part of a message:
    //! its parts are decoded as their texts joined by "|"
    private final class PartedText : LogFormat, PartedFormat
    {
        import formats.plain_text : PlainTextFormat;

        private PlainTextFormat _text;

        this()
        {
            _text = new PlainTextFormat();
        }

        override FormatInfo info() const pure nothrow @nogc => _text.info;
        override const(ColumnInfo)[] columns() const pure nothrow @nogc => _text.columns;
        override ScanResult scanRecords(const(ubyte)[] data, size_t from, size_t[] offsets, bool final_) const nothrow @nogc
            => _text.scanRecords(data, from, offsets, final_);
        override const(ubyte)[] recordAt(const(ubyte)[] data, size_t offset) const nothrow @nogc
            => _text.recordAt(data, offset);
        override bool decode(ref LogMessage!wchar msg, const(ubyte)[] record) const nothrow @nogc
            => _text.decode(msg, record);

        override RecordPart partOf(const(ubyte)[] data, size_t offset) const nothrow @nogc
        {
            RecordPart part;
            const s = cast(const(char)[]) recordAt(data, offset);
            if (s.length < 7 || s[2] != ' ' || s[4] != '/' || s[6] != ':')
                return part;
            part.sender[0] = s[0];
            part.counter = s[1] - '0';
            part.nextCounter = part.counter + 1;
            part.number = s[3] - '0';
            part.count = s[5] - '0';
            return part;
        }

        override bool decodeParts(ref LogMessage!wchar msg, const(ubyte[])[] parts) const nothrow @nogc
        {
            msg.beginRecord();
            auto builder = msg.payloadBuilder();
            foreach (part; parts)
            {
                auto s = cast(const(char)[]) part;
                while (s.length && (s[$ - 1] == '\n'))
                    s = s[0 .. $ - 1];
                builder.appendAscii(s[8 .. $], false);
                if (part !is parts[$ - 1])
                    builder.appendAscii("|", false);
            }
            return true;
        }
    }
}

@("RecordStore: the numbered parts of a message are one record, where its first part is")
unittest
{
    auto store = new RecordStore(new TextSource("x\nA1 1/2: he\nB\nA2 2/2: llo\ny\n"), new PartedText());
    scanAll(store, true);
    const records = store.records;
    assert(records.length == 4);
    assert(payloadOf(records, 0) == "x" && payloadOf(records, 1) == "he|llo");
    assert(payloadOf(records, 2) == "B" && payloadOf(records, 3) == "y");
}

@("RecordStore: the records after a first part wait for its message, the end of the data lets them out")
unittest
{
    auto source = new TextSource("x\nA1 1/2: he\nB\n");
    auto store = new RecordStore(source, new PartedText());
    scanAll(store, false);
    assert(store.length == 1 && store.scannedBytes == source.data.length, "scanned, but held");

    source.add("A2 2/2: llo\n");
    scanAll(store, false);
    assert(store.length == 3 && payloadOf(store.records, 1) == "he|llo");

    source.add("C1 1/2: cut\nz\n");
    scanAll(store, false);
    assert(store.length == 3);
    scanAll(store, true);
    assert(store.length == 5, "the data is over: the message won't be whole");
    assert(payloadOf(store.records, 3) == "C1 1/2: cut" && payloadOf(store.records, 4) == "z");
}

@("RecordStore: once an append of parts failed half done, the store takes nothing more")
unittest
{
    auto store = new RecordStore(new TextSource("x\nA1 1/2: he\nB\n"), new PartedText());
    store._broken = true; // what a failed append leaves: memory can't be made to run out here
    const bunch = store.findRecords(store.data, true);
    assert(!store.append(bunch));
    assert(store.length == 0 && store.scannedBytes == 0);
}

@("RecordStore: close releases the source and the offset index at once, not by the GC later")
unittest
{
    import formats.plain_text : PlainTextFormat;

    auto source = new TextSource("a\n");
    auto store = new RecordStore(source, new PlainTextFormat());
    scanAll(store, true);
    assert(store.reservedBytes > 0);
    store.close();
    assert(source.closed);
    assert(store.reservedBytes == 0, "the offsets wait for the GC");
    assert(store.length == 0 && store.records.length == 0);
    store.close(); // idempotent
}
