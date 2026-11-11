//! The files sent in a log as the UI sees them: Attachment, what a transfer of the
//! catalog (domain/index/transfers) is to the user, and the writing of its bytes from the
//! packets that came in turn. Free of LogIndex, of its lock and of files: LogIndex gives the
//! transfer, the message that opened it and the packets.
module domain.attachments;

import domain.index.transfers : Transfer;
import log_core.log_format : TransferKind, TransferMessage;

//! Where a file sent in the log stands
enum AttachmentState : ubyte
{
    sending, // its end has not come, but the log is still loading
    complete, // every packet came in turn: the file is whole
    incomplete, // packets are missing (the log ended, a packet was lost): its start can be saved
    failed, // the writer said it can't send it
}

//! A file sent in the log
struct Attachment
{
    size_t id; // in the catalog of its document
    string name; // as the writer gave it (a path, maybe): empty if its start is not in the log
    string date; // as the writer wrote it
    ulong size; // bytes, 0 if unknown
    uint packets; // 0 if unknown
    size_t received; // packets, in turn or not
    size_t inTurn; // packets from the first one: what can be saved
    AttachmentState state;
    size_t record; // the record that opened it: its start, else its first packet or its error
    bool hasSerial;
    uint serial;
    long error, osError; // failed: what the writer told
}

//! @brief What the transfer `t` is to the user
//! @param opening - the message of its record (t.offset): its start, a packet or an error
//! @param loading - the log is still loading: more of its packets may come
Attachment attachmentOf(size_t id, in Transfer t, in TransferMessage opening, bool loading) pure
{
    Attachment a;
    a.id = id;
    a.record = t.record;
    a.hasSerial = t.hasSerial;
    a.serial = t.serial;
    a.received = t.received;
    a.inTurn = t.inTurn;
    if (opening.kind == TransferKind.start || opening.kind == TransferKind.error)
    {
        a.name = opening.name.idup;
        a.date = opening.date.idup;
    }
    if (t.started)
    {
        a.size = t.size;
        a.packets = t.packets;
    }
    if (opening.kind == TransferKind.error)
    {
        a.error = opening.error;
        a.osError = opening.osError;
    }

    const whole = t.started && t.inTurn == t.packets;
    if (t.failed)
        a.state = AttachmentState.failed;
    else if (t.ended)
        a.state = whole ? AttachmentState.complete : AttachmentState.incomplete;
    else
        a.state = loading ? AttachmentState.sending : AttachmentState.incomplete;
    return a;
}

//! @brief Writes the bytes of a file: those of its packets in turn, cut at its size when
//! it is known (the last packet may be padded)
//! @param packetAt - the message of the packet at an offset of the data
//! @param offsets - of the packets in turn
//! @param size - of the file, 0 if unknown
//! @param write - takes the bytes, in order
//! @param unreadable - set if a packet can't be read (a lost file): the bytes stop before it
//! @returns the bytes written
ulong writeAttachment(scope TransferMessage delegate(size_t offset) packetAt, const(size_t)[] offsets, ulong size,
    scope void delegate(const(ubyte)[] bytes) write, out bool unreadable)
{
    ulong written = 0;
    foreach (offset; offsets)
    {
        const packet = packetAt(offset);
        if (packet.kind != TransferKind.data)
        {
            unreadable = true;
            break;
        }
        const(ubyte)[] bytes = packet.bytes;
        if (size != 0 && written + bytes.length > size)
            bytes = bytes[0 .. cast(size_t)(size - written)];
        write(bytes);
        written += bytes.length;
        if (size != 0 && written == size)
            break;
    }
    return written;
}

version (unittest)
{
    private Transfer transfer(bool started, bool ended, bool failed, size_t inTurn, size_t received, uint packets = 3)
    {
        Transfer t;
        t.record = 5;
        t.offset = 500;
        t.hasSerial = true;
        t.serial = 7;
        t.started = started;
        t.size = started ? 25 : 0;
        t.packets = started ? packets : 0;
        t.ended = ended;
        t.failed = failed;
        t.inTurn = inTurn;
        t.received = received;
        return t;
    }

    private TransferMessage startMessage(char[] name = "a.bin".dup)
    {
        TransferMessage m;
        m.kind = TransferKind.start;
        m.hasSerial = true;
        m.serial = 7;
        m.name = name;
        m.date = "today";
        return m;
    }
}

@("attachmentOf: a transfer that ended with every packet in turn is complete, named by its start")
unittest
{
    char[] name = "a.bin".dup;
    const opening = startMessage(name);
    const a = attachmentOf(2, transfer(true, true, false, 3, 3), opening, false);
    assert(a.id == 2 && a.name == "a.bin" && a.date == "today" && a.size == 25 && a.packets == 3);
    assert(a.received == 3 && a.inTurn == 3 && a.state == AttachmentState.complete);
    assert(a.record == 5 && a.hasSerial && a.serial == 7);
    name[0] = 'X';
    assert(a.name == "a.bin", "a copy: the message is a slice of the log");
}

@("attachmentOf: without its end, it is sending while the log loads and incomplete after")
unittest
{
    const opening = startMessage();
    assert(attachmentOf(0, transfer(true, false, false, 2, 2), opening, true).state == AttachmentState.sending);
    assert(attachmentOf(0, transfer(true, false, false, 2, 2), opening, false).state == AttachmentState.incomplete);
    assert(attachmentOf(0, transfer(true, false, false, 3, 3), opening, false).state == AttachmentState.incomplete,
        "every packet, but no end");
}

@("attachmentOf: an end with packets missing is incomplete, an error failed")
unittest
{
    const opening = startMessage();
    assert(attachmentOf(0, transfer(true, true, false, 1, 3), opening, false).state == AttachmentState.incomplete);
    assert(attachmentOf(0, transfer(true, false, true, 1, 1), opening, true).state == AttachmentState.failed);
}

@("attachmentOf: a transfer opened by a packet has no name; by an error, the name and codes of the error")
unittest
{
    TransferMessage packet;
    packet.kind = TransferKind.data;
    const a = attachmentOf(0, transfer(false, true, false, 0, 4), packet, false);
    assert(a.name.length == 0 && a.size == 0 && a.packets == 0 && a.state == AttachmentState.incomplete);

    TransferMessage error;
    error.kind = TransferKind.error;
    error.name = "/no/such";
    error.error = -400;
    error.osError = -2;
    const e = attachmentOf(0, transfer(false, false, true, 0, 0), error, false);
    assert(e.name == "/no/such" && e.state == AttachmentState.failed && e.error == -400 && e.osError == -2);
}

@("writeAttachment: the bytes of the packets in order, cut at the size")
unittest
{
    TransferMessage packetAt(size_t offset)
    {
        TransferMessage m;
        if (offset == 666)
            return m; // read as zeros: no packet
        m.kind = TransferKind.data;
        m.bytes = offset == 100 ? [1, 2, 3] : offset == 200 ? [4, 5, 6] : [7, 0, 0];
        return m;
    }

    bool unreadable;
    ubyte[] written;
    void write(const(ubyte)[] bytes)
    {
        written ~= bytes;
    }

    assert(writeAttachment(&packetAt, [100, 200, 300], 7, &write, unreadable) == 7);
    assert(written == [1, 2, 3, 4, 5, 6, 7], "the padding of the last packet is cut");

    written = null;
    assert(writeAttachment(&packetAt, [100, 200], 0, &write, unreadable) == 6 && written == [1, 2, 3, 4, 5, 6], "no size known");

    written = null;
    assert(writeAttachment(&packetAt, [100, 200], 100, &write, unreadable) == 6, "an incomplete file: what came");

    written = null;
    assert(!unreadable);
    assert(writeAttachment(&packetAt, [100, 666, 300], 0, &write, unreadable) == 3 && written == [1, 2, 3],
        "a packet that can't be read stops it");
    assert(unreadable, "and is told");
}
