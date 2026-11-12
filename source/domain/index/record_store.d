//! RecordStore: the records of a log. The bytes of its source, the format that splits and
//! decodes them, and the offset index of the records found so far, which only grows. The
//! numbered parts of a message (PartedFormat) are one record of it (domain/index/part_joiner);
//! the files sent in the log (TransferringFormat) are cataloged (domain/index/transfers).
//!
//! Not thread-safe, but for one promise: the records below a length a reader was given
//! (Records, records()) may be read by any number of threads at once while one writer
//! appends after them. Their entries never move (utils/chunked_array) and none is removed.
//! The rest is the holder's to synchronize (LogIndex): reading length() while a record is
//! appended, appending, and release(). The holder gives a reader its Records so that the
//! reader sees the records below its length (a lock both take, or starting the thread or
//! the task that reads), and closes the store only once no reader reads it any more: the
//! bytes of a closed store are gone, and a reader of them crashes.
//!
//! A reader the holder doesn't wait for (another reader of the log, on its own thread)
//! leases the records instead (lease(), RecordsLease): the store is counted, its holder and
//! each lease, and the last of them to let it go closes it (release()). A holder that is done
//! with the store marks it closing first (markClosing()): a reader of a lease stops at its
//! next check (Records.closing) instead of being waited for.
module domain.index.record_store;

import domain.index.offset_index : OffsetIndex, OffsetIndexItem;
import domain.index.part_joiner : PartJoiner, StepKind;
import domain.index.transfers : Transfers;
import log_core.byte_source : ByteSource;
import log_core.log_format : LogFormat, MarkedFormat, PartedFormat, RecordMark, RecordPart, ScanResult,
    TransferringFormat;
import log_core.log_message : LogMessage;
import utils.chunked_array : ChunkedArray;

import std.typecons : Rebindable;

//! What RecordStore.findRecords found: the offsets of the records, at most
//! RecordStore.bunchSize, and where the next search goes on from
struct Bunch
{
    size_t[RecordStore.bunchSize] offsets;
    ScanResult found;
    bool end; // the data is over: no more bytes will come, and these were the last ones

    ubyte[RecordStore.bunchSize] marks; // of a MarkedFormat: what each record may be (RecordMark)
    ubyte anyMarks; // the marks of all the records together

    //! The offsets found
    const(size_t)[] records() const pure nothrow @nogc return
    {
        return offsets[0 .. found.count];
    }
}

//! A record that is the head of a message cut into parts: its other parts are a list of
//! fragments, RecordStore._fragments[first], then each one's next
private struct Join
{
    size_t record;
    size_t first = PartJoiner.none; // its first fragment, none: none (yet)
    size_t fragments; // in its list
}

//! A part of a message after its head: where it is, and the next part of the message
private struct Fragment
{
    size_t offset;
    size_t next = PartJoiner.none;
}

//! The records of a log: its source, the format that splits and decodes it, and the offset
//! index of the records found so far. One writer (LogIndex's worker) finds records and
//! appends them in the order of the file; readers read them from any thread through
//! Records. The numbered parts of a message (PartedFormat) are joined into one record as
//! they are appended. See the module for what is safe across threads.
final class RecordStore
{
    //! Records found and appended at a time
    enum bunchSize = 32;

    private ByteSource _source;
    private LogFormat _format;
    private const(PartedFormat) _parted; // the format, if its records may be parts
    private OffsetIndex _offsets;
    private size_t _scannedBytes; // the bytes of the source split into records

    // The heads of messages cut into parts, by their record, and the other parts. Taken
    // as the parts are found: none for a log without them. Those of an open message
    // change until it closes: no reader sees them meanwhile (see records())
    private PartJoiner _joiner;
    private ChunkedArray!Join _joins;
    private ChunkedArray!Fragment _fragments;
    private bool _broken; // an append failed half done: the joins may not match the records

    private const(TransferringFormat) _transferring; // the format, if its records may send files
    private const(MarkedFormat) _marked; // the format, if it is either: what each record may be
    private Transfers _transfers; // the files sent in the log

    private shared size_t _users = 1; // its holder and the leases: the last one closes it
    private shared bool _closing; // its holder is done with it: the readers of leases stop

    //! @param source - owned by the store from now on: released when the store is closed (release())
    this(ByteSource source, LogFormat format)
    {
        _source = source;
        _format = format;
        _parted = cast(const(PartedFormat)) format;
        _transferring = cast(const(TransferringFormat)) format;
        _marked = cast(const(MarkedFormat)) format;
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

    //! The records found so far that can be read: those before the head of a message
    //! still open (PartedFormat), whose text may grow. Not while one is being appended
    //! (see the module)
    size_t length() const pure nothrow @nogc
    {
        const open = _joiner.firstOpenRecord;
        return open == PartJoiner.none ? _offsets.length : open;
    }

    //! @returns true if records found can't be read yet: they wait for the parts of a
    //! message, see append()
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

    //! The format as a TransferringFormat, null if its records send no files
    const(TransferringFormat) transferring() const pure nothrow @nogc
    {
        return _transferring;
    }

    //! The files sent in the log found so far (TransferringFormat). Not while a record is
    //! being appended (see the module)
    ref const(Transfers) transfers() const pure nothrow @nogc return
    {
        return _transfers;
    }

    //! The records found so far, to read from any thread: see the module. Not while one is
    //! being appended
    Records records() const pure nothrow @nogc
    {
        const open = _joiner.firstOpenJoin;
        return Records(this, length, open == PartJoiner.none ? _joins.length : open);
    }

    //! @brief A lease of the records found so far (records()): they stay open while it is
    //! held, after the holder released the store too. Taken the way records() is: by the
    //! holder, not while a record is being appended
    RecordsLease lease() nothrow @nogc
    {
        return RecordsLease(this, records);
    }

    //! The holder is done with the store: the readers of its leases stop at their next
    //! check (Records.closing). Any thread
    void markClosing() nothrow @nogc
    {
        import core.atomic : atomicStore;

        atomicStore(_closing, true);
    }

    //! @brief The holder or a lease lets the store go: the last one closes it (close()).
    //! Any thread
    void release() nothrow @nogc
    {
        import core.atomic : atomicOp;

        const left = atomicOp!"-="(_users, 1);
        assert(left != size_t.max, "released more often than held");
        if (left == 0)
            close(); // no one reads it any more
    }

    private void retain() nothrow @nogc
    {
        import core.atomic : atomicOp;

        const users = atomicOp!"+="(_users, 1);
        assert(users > 1, "leased once closed");
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
        if (_marked !is null)
            foreach (i, offset; bunch.records)
            {
                bunch.marks[i] = _marked.marksOf(data, offset);
                bunch.anyMarks |= bunch.marks[i];
            }
        return bunch;
    }

    //! @brief Appends the records findRecords() found: the bytes they were found in are
    //! split into records from now on. A later part of a message of a PartedFormat is not
    //! a record but a fragment of its head; the records from the head of a message still
    //! open on can't be read (length()) until it closes: when its last part came, when it
    //! can't grow (PartJoiner), at the end of the data (Bunch.end).
    //! @return false if the index can't grow (too many records, not enough memory):
    //! nothing changes then; for a PartedFormat the store takes nothing more from then on
    bool append(ref const Bunch bunch) nothrow @nogc
    {
        if (_broken)
            return false;
        OffsetIndexItem[bunchSize] items;
        size_t count = 0;
        if (_parted is null)
        {
            foreach (i, offset; bunch.records)
                items[i].offset = offset;
            count = bunch.found.count;
        }
        else if (!appendParts(bunch, items, count))
        {
            // The joins and fragments may be written: a later append would give the
            // next records the numbers the joins have
            _broken = true;
            return false;
        }
        const first = _offsets.length;
        if (!_offsets.append(items[0 .. count]))
        {
            _broken |= _parted !is null;
            return false;
        }
        _scannedBytes = bunch.found.next;
        if (_transferring !is null && (bunch.anyMarks & RecordMark.transfer))
            addTransfers(bunch, items[0 .. count], first);
        return true;
    }

    //! Catalogs the messages of transfers among the records of a bunch appended as `items`,
    //! numbered from `first`: the records of the bunch but the fragments of a message
    private void addTransfers(ref const Bunch bunch, const(OffsetIndexItem)[] items, size_t first) nothrow @nogc
    {
        const data = _source.data;
        size_t item = 0;
        foreach (i, offset; bunch.records)
        {
            if (item == items.length || items[item].offset != offset)
                continue; // a fragment: a part of a message is not a message of a transfer
            const record = first + item++;
            if (bunch.marks[i] & RecordMark.transfer)
            {
                const message = _transferring.transferOf(data, offset);
                _transfers.add(message, record, offset);
            }
        }
    }

    //! Sorts the records of a bunch of a PartedFormat into records (`items`) and fragments
    //! @return false if the joins or the fragments can't grow
    private bool appendParts(ref const Bunch bunch, ref OffsetIndexItem[bunchSize] items, ref size_t count) nothrow @nogc
    {
        const data = _source.data;
        foreach (i, offset; bunch.records)
        {
            const mayBePart = (bunch.marks[i] & RecordMark.part) != 0;
            if (!mayBePart && !_joiner.holding)
            {
                items[count++] = OffsetIndexItem(offset); // the usual record
                continue;
            }
            const record = _offsets.length + count;
            const step = _joiner.add(mayBePart ? _parted.partOf(data, offset) : RecordPart.init,
                record, _joins.length, _fragments.length);
            final switch (step.kind)
            {
            case StepKind.record:
                items[count++] = OffsetIndexItem(offset);
                break;
            case StepKind.head:
                if (!_joins.append(Join(record)))
                    return false;
                OffsetIndexItem item;
                item.offset = offset;
                item.joined = true;
                items[count++] = item;
                break;
            case StepKind.fragment:
                // The message is open: no reader sees its join and fragments yet
                const fragment = _fragments.length;
                if (!_fragments.append(Fragment(offset)))
                    return false;
                Join join = _joins[step.join];
                if (step.previous == PartJoiner.none)
                    join.first = fragment;
                else
                {
                    Fragment previous = _fragments[step.previous];
                    previous.next = fragment;
                    _fragments[step.previous] = previous;
                }
                ++join.fragments;
                _joins[step.join] = join;
                break;
            }
        }
        if (bunch.end)
            _joiner.flush();
        return true;
    }

    //! Releases the bytes of the source and the offset index at once: the index lives in
    //! memory of its own, which the GC neither sees nor would free soon. Called by the last
    //! release() only: no reader reads them any more (see the module). No records and
    //! data() empty afterwards.
    private void close() nothrow @nogc
    {
        _source.close();
        _offsets.clear();
        _joins.clear();
        _fragments.clear();
        _transfers.clear();
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
        return _store !is null && _store.lost;
    }

    //! The holder of the records is done with them (RecordStore.markClosing): a reader of
    //! a lease stops reading, as it would for a cancel
    bool closing() const nothrow @nogc
    {
        import core.atomic : atomicLoad;

        return _store !is null && atomicLoad(_store._closing);
    }

    //! @brief Whether a reader of the records gives up: `cancelled()`, or the records are
    //! lost or closing. A scan checks it every few records and again before what it read is
    //! delivered: once true it stays true (`cancelled` too), so nothing read by a block cut
    //! short is delivered, nor a record of a lost file read as zeros
    bool givesUp(scope bool delegate() cancelled) const
    {
        return cancelled() || lost || closing;
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
        if (join.fragments == 0) // a message whose other parts never came
            return format.decode(msg, format.recordAt(data, item.offset));
        const(ubyte)[][PartJoiner.maxParts] parts;
        parts[0] = format.recordAt(data, item.offset);
        size_t next = join.first;
        foreach (i; 0 .. join.fragments)
        {
            const fragment = _store._fragments[next];
            parts[1 + i] = format.recordAt(data, fragment.offset);
            next = fragment.next;
        }
        return _store._parted.decodeParts(msg, parts[0 .. 1 + join.fragments]);
    }

    //! @brief The parts the record `record` < length is joined of (PartedFormat): 1 for a
    //! record that is not joined, nor a message whose other parts never came (its text
    //! tells which part of how many it is)
    size_t partsOf(size_t record) const pure nothrow @nogc
    {
        assert(record < _length);
        return _store._offsets[record].joined ? 1 + joinOf(record).fragments : 1;
    }

    //! The parts of the head `record`: the joins are in the order of their records
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

//! @brief A lease of the records of a RecordStore (RecordStore.lease): they stay open while
//! a copy of it lives, wherever the store's holder is. Read records() on any thread, and
//! stop once they are closing() (the holder is done with them). Empty when not given by a
//! store (RecordsLease.init): no records.
//! Let it go deterministically (a scope, destroy()): one the GC collects in an object it
//! finalizes never lets the store go, so the store and its file stay open for good (on
//! Windows the file can't be deleted or renamed then until the program exits).
struct RecordsLease
{
    private RecordStore _store; // null: empty
    private Records _records;

    private this(RecordStore store, Records records) nothrow @nogc
    {
        _store = store;
        _records = records;
        store.retain();
    }

    this(this) nothrow @nogc
    {
        if (_store !is null)
            _store.retain();
    }

    ~this() nothrow @nogc
    {
        import core.memory : GC;

        // In a finalizer the store, its source and its offsets may be finalized already
        // (their vtables gone): closing them would crash
        if (_store !is null && !GC.inFinalizer)
            _store.release();
    }

    //! The records leased, read while the lease is held
    Records records() const pure nothrow @nogc
    {
        return _records;
    }

    //! The holder of the records is done with them: stop reading (Records.closing)
    bool closing() const nothrow @nogc
    {
        return _records.closing;
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
    private class PartedText : LogFormat, PartedFormat
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

        override ubyte marksOf(const(ubyte)[] data, size_t offset) const nothrow @nogc
            => partOf(data, offset).isPart ? RecordMark.part : RecordMark.none;

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

version (unittest)
{
    import log_core.log_format : TransferKind, TransferMessage, TransferringFormat;

    //! PartedText whose lines "FL<kind> <serial> [<packet>]" are messages of a transfer:
    //! FLST of 2 packets, FLDA, FLFI
    private final class TransferText : PartedText, TransferringFormat
    {
        override ubyte marksOf(const(ubyte)[] data, size_t offset) const nothrow @nogc
            => super.marksOf(data, offset)
                | (data.length >= offset + 2 && data[offset .. offset + 2] == "FL" ? RecordMark.transfer : RecordMark.none);

        override TransferMessage transferOf(const(ubyte)[] data, size_t offset) const nothrow @nogc
        {
            TransferMessage m;
            const s = cast(const(char)[]) recordAt(data, offset);
            if (s.length < 6 || s[0 .. 2] != "FL")
                return m;
            m.hasSerial = true;
            m.serial = s[5] - '0';
            switch (s[0 .. 4])
            {
            case "FLST":
                m.kind = TransferKind.start;
                m.packets = 2;
                break;
            case "FLDA":
                m.kind = TransferKind.data;
                m.packet = s[7] - '0';
                break;
            case "FLFI":
                m.kind = TransferKind.end;
                break;
            default:
                break;
            }
            return m;
        }
    }
}

@("RecordStore: the messages of a file sent in the log are cataloged by the numbers of their records")
unittest
{
    const text = "x\nA1 1/2: he\nFLST 7\nFLDA 7 1\nA2 2/2: llo\nFLDA 7 2\nFLFI 7\n";
    auto store = new RecordStore(new TextSource(text), new TransferText());
    scanAll(store, true);
    assert(store.length == 6, "the parts are one record");
    const transfers = &store.transfers();
    assert(transfers.length == 1);
    const t = (*transfers)[0];
    assert(t.record == 2 && t.offset == 13 && t.started && t.ended && t.inTurn == 2);
    assert(transfers.inTurnOffsets(0) == [20, 41]);

    store.release();
    assert(store.transfers.length == 0, "closed with the store");
}

@("RecordStore: a format that sends no files has no transfers")
unittest
{
    auto store = new RecordStore(new TextSource("FLST 7\nFLDA 7 1\n"), new PartedText());
    scanAll(store, true);
    assert(store.length == 2 && store.transfers.length == 0);
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

@("Records.partsOf: how many parts a record is joined of, 1 for one that isn't")
unittest
{
    auto store = new RecordStore(new TextSource("x\nA1 1/3: a\nB\nA2 2/3: b\nA3 3/3: c\nC1 1/2: d\ny\n"),
        new PartedText());
    scanAll(store, true);
    const records = store.records;
    assert(records.length == 5);
    assert(payloadOf(records, 1) == "a|b|c" && payloadOf(records, 3) == "C1 1/2: d");
    assert(records.partsOf(0) == 1 && records.partsOf(2) == 1, "records that are no parts");
    assert(records.partsOf(1) == 3, "joined of three parts");
    assert(records.partsOf(3) == 1, "a first part whose other parts never came");
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

@("RecordStore: a message that can't be whole keeps the parts it got, its records stay in place")
unittest
{
    auto store = new RecordStore(new TextSource("A1 1/3: a\nx\nA2 2/3: b\nA4 3/3: c\ny\n"), new PartedText());
    scanAll(store, true);
    const records = store.records;
    assert(records.length == 4, "the part out of counter is a record of its own");
    assert(payloadOf(records, 0) == "a|b" && payloadOf(records, 1) == "x");
    assert(payloadOf(records, 2) == "A4 3/3: c" && payloadOf(records, 3) == "y");
}

@("RecordStore: the parts of two messages interleaved are linked each to its own")
unittest
{
    auto store = new RecordStore(new TextSource("A1 1/3: a\nB1 1/2: x\nA2 2/3: b\nB2 2/2: y\nA3 3/3: c\n"), new PartedText());
    scanAll(store, true);
    const records = store.records;
    assert(records.length == 2);
    assert(payloadOf(records, 0) == "a|b|c" && payloadOf(records, 1) == "x|y");
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

@("RecordStore: the last release closes the source and the offset index at once, not by the GC later")
unittest
{
    import formats.plain_text : PlainTextFormat;

    auto source = new TextSource("a\n");
    auto store = new RecordStore(source, new PlainTextFormat());
    scanAll(store, true);
    assert(store.reservedBytes > 0);
    store.release(); // its holder, the only user
    assert(source.closed);
    assert(store.reservedBytes == 0, "the offsets wait for the GC");
    assert(store.length == 0 && store.records.length == 0);
}

@("RecordStore: a lease keeps the records open after their holder, the last one closes them")
unittest
{
    import formats.plain_text : PlainTextFormat;

    auto source = new TextSource("one\ntwo\n");
    auto store = new RecordStore(source, new PlainTextFormat());
    scanAll(store, true);
    auto lease = store.lease();
    auto copy = lease;
    assert(!lease.closing);

    store.markClosing();
    store.release(); // the holder is done with it
    assert(!source.closed, "leased");
    assert(lease.closing && copy.records.closing, "a reader of a lease stops");
    assert(lease.records.length == 2 && payloadOf(lease.records, 1) == "two", "still readable");

    destroy(lease);
    assert(!source.closed, "a copy still leases it");
    destroy(copy);
    assert(source.closed, "the last lease closes it");
}

@("RecordStore: a store whose leases are gone is closed by its holder")
unittest
{
    import formats.plain_text : PlainTextFormat;

    auto source = new TextSource("one\n");
    auto store = new RecordStore(source, new PlainTextFormat());
    scanAll(store, true);
    {
        auto lease = store.lease();
    }
    assert(!source.closed, "its holder holds it");
    store.release();
    assert(source.closed);
}

@("RecordsLease: an empty lease has no records")
unittest
{
    RecordsLease lease;
    assert(lease.records.length == 0 && !lease.closing && !lease.records.lost);
    auto copy = lease; // nothing to count
}
