//! Transfers: the catalog of the files sent in a log (TransferringFormat), kept as the
//! offset index grows (RecordStore). It keeps numbers only: of each transfer, the record
//! that opened it and what it told; of each packet that came in turn, where its record
//! is. The name and the date are read from the record when asked for, the bytes of the
//! file from the packets when it is saved. Not thread-safe: its holder synchronizes.
module domain.index.transfers;

import log_core.log_format : TransferKind, TransferMessage;
import utils.chunked_array : ChunkedArray;

//! What the catalog knows of a transfer
struct Transfer
{
    size_t record; // the record that opened it: FLST, else the first packet or the error
    size_t offset; // of that record in the data: its name and date are read there
    bool hasSerial; // all but an error of a file that could not be read
    uint serial;
    bool started; // opened by its start: the size and the packets are known
    ulong size;
    uint packets;
    bool ended; // the writer said the last packet was sent
    bool failed; // the writer said it can't send the file
    size_t received; // packets, in turn or not
    size_t inTurn; // packets 1 .. inTurn came in turn: the file up to there can be read
    private size_t firstPacket = Transfers.none, lastPacket = Transfers.none; // in turn
    private bool outOfTurn; // a packet came out of turn: no more are in turn
}

//! A packet in turn of a transfer: where its record is, the next one of the transfer
private struct Packet
{
    size_t offset;
    size_t next = Transfers.none;
}

//! The packets in turn of a transfer at a time (Transfers.inTurnOf)
struct InTurn
{
    private size_t first = Transfers.none;
    size_t count;
}

//! The transfers of a log, in the order of their first records, and their packets
struct Transfers
{
    //! No such index
    enum size_t none = size_t.max;

    //! The most transfers open at once: past them the oldest one leaves the open ones
    enum size_t maxOpen = 64;

    private ChunkedArray!(Transfer, 10) _transfers;
    private ChunkedArray!Packet _packets;
    private size_t[maxOpen] _open; // the transfers whose next messages may come, oldest first
    private size_t _openCount;
    private bool _full; // the memory ran out: no more transfers or packets are kept
    private size_t _messages; // taken: see messages()

    //! @brief Takes the message of a transfer of a record, in the order of the file
    //! @param record - the number of the record in the offset index
    //! @param offset - of the record in the data
    void add(ref const TransferMessage message, size_t record, size_t offset) nothrow @nogc
    {
        if (_full)
            return;
        final switch (message.kind)
        {
        case TransferKind.none:
            return;
        case TransferKind.start:
            ++_messages;
            const open = openOf(message.serial);
            if (open != none)
                leave(open); // sent again before its end: that one stays as it is
            Transfer t = opened(message, record, offset);
            t.started = true;
            t.size = message.size;
            t.packets = message.packets;
            begin(t);
            return;
        case TransferKind.data:
            ++_messages;
            size_t open = openOf(message.serial);
            if (open == none)
            {
                // The log began during the transfer
                if (!begin(opened(message, record, offset)))
                    return;
                open = _openCount - 1;
            }
            addPacket(_open[open], message.packet, offset);
            return;
        case TransferKind.end:
            const open = openOf(message.serial);
            if (open == none)
                return;
            ++_messages;
            Transfer t = _transfers[_open[open]];
            t.ended = true;
            _transfers[_open[open]] = t;
            leave(open);
            return;
        case TransferKind.error:
            ++_messages;
            const open = message.hasSerial ? openOf(message.serial) : none;
            if (open == none)
            {
                Transfer t = opened(message, record, offset);
                t.failed = true;
                if (begin(t))
                    leave(_openCount - 1);
                return;
            }
            Transfer t = _transfers[_open[open]];
            t.failed = true;
            _transfers[_open[open]] = t;
            leave(open);
            return;
        }
    }

    //! A transfer opened by the message of `record`
    private static Transfer opened(ref const TransferMessage message, size_t record, size_t offset) pure nothrow @nogc
    {
        Transfer t;
        t.record = record;
        t.offset = offset;
        t.hasSerial = message.hasSerial;
        t.serial = message.serial;
        return t;
    }

    //! @returns the index in _open of the open transfer of `serial`, the newest one; none
    private size_t openOf(uint serial) const pure nothrow @nogc
    {
        foreach_reverse (i; 0 .. _openCount)
            if (_transfers[_open[i]].serial == serial)
                return i;
        return none;
    }

    //! Appends the transfer `t` and opens it, the newest one
    //! @returns false if there is no memory for it: no more transfers are kept
    private bool begin(Transfer t) nothrow @nogc
    {
        if (!_transfers.append(t))
        {
            _full = true;
            return false;
        }
        if (_openCount == maxOpen)
            leave(0);
        _open[_openCount++] = _transfers.length - 1;
        return true;
    }

    //! The transfer _open[i] is not open any more: no message goes to it from now on
    private void leave(size_t i) pure nothrow @nogc
    {
        foreach (j; i + 1 .. _openCount)
            _open[j - 1] = _open[j];
        --_openCount;
    }

    //! Adds the packet `number` at `offset` to the transfer `i`
    private void addPacket(size_t i, uint number, size_t offset) nothrow @nogc
    {
        Transfer t = _transfers[i];
        ++t.received;
        if (!t.outOfTurn && number == t.inTurn + 1)
        {
            if (!_packets.append(Packet(offset)))
            {
                _full = true;
                return;
            }
            const packet = _packets.length - 1;
            if (t.lastPacket == none)
                t.firstPacket = packet;
            else
            {
                Packet last = _packets[t.lastPacket];
                last.next = packet;
                _packets[t.lastPacket] = last;
            }
            t.lastPacket = packet;
            ++t.inTurn;
        }
        else
            t.outOfTurn = true;
        _transfers[i] = t;
    }

    //! The messages of transfers taken so far: it changes whenever the catalog does
    size_t messages() const pure nothrow @nogc
    {
        return _messages;
    }

    //! The transfers found so far
    size_t length() const pure nothrow @nogc
    {
        return _transfers.length;
    }

    //! The transfer `i` < length
    Transfer opIndex(size_t i) const pure nothrow @nogc
    {
        return _transfers[i];
    }

    //! The packets 1 .. inTurn of the transfer `i` as they are now, to read by offsetsOf
    //! apart from the holder's lock: those packets and their links don't change any more,
    //! the writer only appends after them (utils/chunked_array: entries never move)
    InTurn inTurnOf(size_t i) const pure nothrow @nogc
    {
        const t = _transfers[i];
        return InTurn(t.firstPacket, t.inTurn);
    }

    //! The offsets of the records of the packets `packets`, in order: read while the
    //! catalog grows (see inTurnOf)
    size_t[] offsetsOf(InTurn packets) const pure nothrow
    {
        auto offsets = new size_t[packets.count];
        size_t packet = packets.first;
        foreach (ref offset; offsets)
        {
            const p = _packets[packet];
            offset = p.offset;
            packet = p.next;
        }
        return offsets;
    }

    //! The offsets of the records of the packets 1 .. inTurn of the transfer `i`, in order
    size_t[] inTurnOffsets(size_t i) const pure nothrow
    {
        return offsetsOf(inTurnOf(i));
    }

    //! Forgets every transfer
    void clear() nothrow @nogc
    {
        _transfers.clear();
        _packets.clear();
        _openCount = 0;
        _full = false;
        _messages = 0;
    }
}

version (unittest)
{
    private TransferMessage start(uint serial, uint packets = 3)
    {
        TransferMessage m;
        m.kind = TransferKind.start;
        m.hasSerial = true;
        m.serial = serial;
        m.size = packets * 10;
        m.packets = packets;
        return m;
    }

    private TransferMessage data(uint serial, uint packet)
    {
        TransferMessage m;
        m.kind = TransferKind.data;
        m.hasSerial = true;
        m.serial = serial;
        m.packet = packet;
        return m;
    }

    private TransferMessage end(uint serial)
    {
        TransferMessage m;
        m.kind = TransferKind.end;
        m.hasSerial = true;
        m.serial = serial;
        return m;
    }

    private TransferMessage error(uint serial)
    {
        TransferMessage m;
        m.kind = TransferKind.error;
        m.hasSerial = true;
        m.serial = serial;
        return m;
    }

    //! The records of a log, numbered from 0, at the offsets 100, 200, ...
    private struct Log
    {
        Transfers t;
        size_t records;

        void add(TransferMessage[] messages...)
        {
            foreach (m; messages)
            {
                t.add(m, records, (records + 1) * 100);
                ++records;
            }
        }

        void skip(size_t count) // records of no transfer
        {
            records += count;
        }
    }
}

@("Transfers: a start, its packets in turn and its end make one transfer that can be read whole")
unittest
{
    Log log;
    log.add(start(7), data(7, 1), data(7, 2), data(7, 3), end(7));
    auto t = &log.t;
    assert(t.length == 1);
    const x = (*t)[0];
    assert(x.record == 0 && x.offset == 100 && x.hasSerial && x.serial == 7);
    assert(x.started && x.size == 30 && x.packets == 3);
    assert(x.ended && !x.failed && x.received == 3 && x.inTurn == 3);
    assert(t.inTurnOffsets(0) == [200, 300, 400]);
}

@("Transfers: the packets of transfers sent at once go each to its own, by serial")
unittest
{
    Log log;
    log.add(start(1), start(2), data(2, 1), data(1, 1));
    log.skip(5);
    log.add(data(1, 2), data(2, 2), end(2));
    auto t = &log.t;
    assert(t.length == 2 && (*t)[0].serial == 1 && (*t)[1].serial == 2);
    assert(t.inTurnOffsets(0) == [400, 1000] && t.inTurnOffsets(1) == [300, 1100]);
    assert(!(*t)[0].ended && (*t)[1].ended);
}

@("Transfers: a file sent again with the same serial is another transfer")
unittest
{
    Log log;
    log.add(start(7, 1), data(7, 1), end(7), start(7, 1), data(7, 1));
    auto t = &log.t;
    assert(t.length == 2 && (*t)[1].record == 3);
    assert(t.inTurnOffsets(0) == [200] && t.inTurnOffsets(1) == [500]);
    assert((*t)[0].ended && !(*t)[1].ended);
}

@("Transfers: a new start of an open serial leaves the transfer before as it is")
unittest
{
    Log log;
    log.add(start(7), data(7, 1), start(7), data(7, 1));
    auto t = &log.t;
    assert(t.length == 2 && (*t)[0].received == 1 && (*t)[1].received == 1);
}

@("Transfers: packets without a start (the log began during the transfer) open one")
unittest
{
    Log log;
    log.skip(2);
    log.add(data(7, 41), data(7, 42), end(7));
    auto t = &log.t;
    assert(t.length == 1);
    const x = (*t)[0];
    assert(x.record == 2 && x.offset == 300 && x.hasSerial && x.serial == 7 && !x.started);
    assert(x.ended && x.received == 2 && x.inTurn == 0, "its first packets are missing");
    assert(t.inTurnOffsets(0).length == 0);
}

@("Transfers: a packet missing or out of turn ends the packets in turn; all are counted")
unittest
{
    Log log;
    log.add(start(7, 5), data(7, 1), data(7, 2), data(7, 4), data(7, 3), data(7, 5));
    auto t = &log.t;
    assert((*t)[0].received == 5 && (*t)[0].inTurn == 2);
    assert(t.inTurnOffsets(0) == [200, 300]);

    Log again;
    again.add(start(7, 3), data(7, 1), data(7, 1), data(7, 2));
    assert(again.t[0].received == 3 && again.t[0].inTurn == 1, "a packet twice");
}

@("Transfers: an error fails the open transfer of its serial and closes it")
unittest
{
    Log log;
    log.add(start(7), data(7, 1), error(7), data(7, 2));
    auto t = &log.t;
    assert(t.length == 2, "a packet after the error opens a transfer");
    assert((*t)[0].failed && (*t)[0].received == 1 && !(*t)[1].started);
}

@("Transfers: an error of a file that could not be read, or of no open transfer, is a failed transfer of its own")
unittest
{
    TransferMessage unread;
    unread.kind = TransferKind.error;
    Log log;
    log.skip(1);
    log.add(unread, error(9));
    auto t = &log.t;
    assert(t.length == 2);
    assert((*t)[0].failed && (*t)[0].record == 1 && !(*t)[0].hasSerial && (*t)[0].received == 0);
    assert((*t)[1].failed && (*t)[1].record == 2 && (*t)[1].serial == 9);
}

@("Transfers: an end of no open transfer is not one; a record of no transfer neither")
unittest
{
    Log log;
    log.add(end(7), TransferMessage.init);
    assert(log.t.length == 0);
}

@("Transfers: past maxOpen open transfers the oldest one is no longer open")
unittest
{
    Log log;
    foreach (uint serial; 0 .. Transfers.maxOpen + 1)
        log.add(start(serial));
    log.add(data(1, 1), data(0, 1));
    auto t = &log.t;
    assert(t.length == Transfers.maxOpen + 2, "the packet of the oldest opens a transfer of its own");
    assert((*t)[0].received == 0 && (*t)[1].received == 1);
}

@("Transfers: messages counts the messages taken: it changes whenever the catalog does")
unittest
{
    Log log;
    log.add(TransferMessage.init);
    assert(log.t.messages == 0);
    log.add(start(7), data(7, 1), data(7, 3), end(7));
    assert(log.t.messages == 4, "a packet out of turn changes what is received");
    log.add(end(7));
    assert(log.t.messages == 4, "an end of no open transfer changes nothing");
}

@("Transfers: the packets in turn taken at a time are read as they were while more come")
unittest
{
    Log log;
    log.add(start(7, 3), data(7, 1));
    const packets = log.t.inTurnOf(0);
    log.add(data(7, 2), data(7, 3));
    assert(log.t.offsetsOf(packets) == [200], "the packets of then");
    assert(log.t.inTurnOffsets(0) == [200, 300, 400]);
}

@("Transfers: clear forgets every transfer")
unittest
{
    Log log;
    log.add(start(7), data(7, 1));
    log.t.clear();
    assert(log.t.length == 0);
    log.add(data(7, 1));
    assert(log.t.length == 1 && !log.t[0].started, "nothing open is left");
}
