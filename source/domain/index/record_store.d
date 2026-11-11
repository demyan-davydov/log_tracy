//! RecordStore: the records of a log. The bytes of its source, the format that splits and
//! decodes them, and the offset index of the records found so far, which only grows.
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
import log_core.byte_source : ByteSource;
import log_core.log_format : LogFormat, ScanResult;
import log_core.log_message : LogMessage;

import std.typecons : Rebindable;

//! What RecordStore.findRecords found: the offsets of the records, at most
//! RecordStore.bunchSize, and where the next search goes on from
struct Bunch
{
    size_t[RecordStore.bunchSize] offsets;
    ScanResult found;

    //! The offsets found
    const(size_t)[] records() const pure nothrow @nogc return
    {
        return offsets[0 .. found.count];
    }
}

final class RecordStore
{
    //! Records found and appended at a time
    enum bunchSize = 32;

    private ByteSource _source;
    private LogFormat _format;
    private OffsetIndex _offsets;
    private size_t _scannedBytes; // the bytes of the source split into records

    //! @param source - owned by the store from now on: released by close()
    this(ByteSource source, LogFormat format)
    {
        _source = source;
        _format = format;
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
        return Records(this, _offsets.length);
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
        return bunch;
    }

    //! @brief Appends the records findRecords() found: the bytes they were found in are
    //! split into records from now on
    //! @return false if the index can't grow (too many records, not enough memory):
    //! nothing changes then
    bool append(ref const Bunch bunch) nothrow @nogc
    {
        OffsetIndexItem[bunchSize] items;
        foreach (i, offset; bunch.records)
            items[i].offset = offset;
        if (!_offsets.append(items[0 .. bunch.found.count]))
            return false;
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
        _scannedBytes = 0;
    }
}

//! The records of a RecordStore below a length: read from any thread, while the store
//! grows after them (see domain.index.record_store). A copy reads the same records.
struct Records
{
    private Rebindable!(const RecordStore) _store; // a copy may be assigned another one
    private size_t _length;

    private this(const RecordStore store, size_t length) pure nothrow @nogc
    {
        _store = store;
        _length = length;
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
        const format = _store._format;
        return format.decode(msg, format.recordAt(_store._source.data, offsetOf(record)));
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
            if (bunch.found.count == 0 && bunch.found.next == store.scannedBytes)
                return;
            assert(store.append(bunch));
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
