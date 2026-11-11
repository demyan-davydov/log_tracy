//! PartJoiner: joins the records that are numbered parts of one message ("1/2: ...",
//! "2/2: ...", as a PartedFormat tells them) into one record of the offset index. It
//! holds the records from a first part on until the message is whole or can't be, so
//! the records still leave in the order of the file, the joined one where its first
//! part is.
module domain.index.part_joiner;

import log_core.log_format : RecordPart;

//! Takes a record that leaves the joiner, in the order of the file: its offset and the
//! offsets of the parts joined to it after the first (none for a record of its own)
alias EmitRecord = void delegate(size_t offset, const(size_t)[] parts) nothrow @nogc;

//! Joins numbered parts of a message, record by record in the order of the file.
//!
//! A message is joined when its parts come one by one from one sender: part 1 of n,
//! then 2, ... n, each with the counter the one before it said comes next. Records of
//! other senders may come between them. A message that can't be whole leaves as the
//! records it is: a part out of turn or of another counter, a new part 1 of its sender,
//! more than maxHeld records held, the end of the data (flush).
struct PartJoiner
{
    //! The most records held while the parts of a message are awaited: past them the
    //! oldest message waited for leaves unjoined
    enum size_t maxHeld = 256;

    //! The most parts a message is joined of: one of more is left as it is
    enum size_t maxParts = 64;

    //! @brief Takes the next record of the file: it leaves, with the records held
    //! before it that may, through `emit`, at once or later
    void add(size_t offset, in RecordPart part, scope EmitRecord emit) nothrow @nogc
    {
        const joinable = part.isPart && part.count >= 2 && part.count <= maxParts
            && part.number <= part.count;
        if (!joinable)
        {
            if (!holding)
                return emit(offset, null); // the usual record: nothing held before it
            push(Entry(offset, State.record));
        }
        else if (part.number == 1)
        {
            const open = openHeadOf(part.sender);
            if (open != none)
                breakUp(open);
            push(Entry(offset, State.openHead, part.sender, 2, part.count, part.nextCounter));
        }
        else
        {
            const open = openHeadOf(part.sender);
            if (open == none)
                push(Entry(offset, State.record));
            else
            {
                auto head = &at(open);
                if (head.expected != part.number || head.nextCounter != part.counter)
                {
                    breakUp(open);
                    push(Entry(offset, State.record));
                }
                else
                {
                    ++head.expected;
                    head.nextCounter = part.nextCounter;
                    if (part.number == part.count)
                        head.state = State.wholeHead;
                    push(Entry(offset, State.part, part.sender, 0, 0, 0, open));
                }
            }
        }
        drain(emit);
        if (_end - _first == maxHeld)
        {
            breakUp(_first); // drain stopped at it: an open head
            drain(emit);
        }
    }

    //! The data is over: every record held leaves, the messages not whole unjoined
    void flush(scope EmitRecord emit) nothrow @nogc
    {
        foreach (seq; _first .. _end)
            if (at(seq).state == State.openHead)
                breakUp(seq);
        drain(emit);
    }

    //! @returns true if records are held, waiting for the parts of a message
    bool holding() const pure nothrow @nogc
    {
        return _end != _first;
    }

private:
    enum State : ubyte
    {
        record, // a record of its own
        openHead, // the first part of a message waiting for its next part
        wholeHead, // the first part of a message whose parts all came
        part, // a part after the first one of a message, joined to its head
    }

    struct Entry
    {
        size_t offset;
        State state;
        ubyte[16] sender; // of a head
        uint expected; // of a head: the number of the next part
        uint count; // of a head: of the parts of the message
        uint nextCounter; // of a head: the counter of the next part
        size_t head; // of a part: the sequence number of its head
    }

    enum size_t none = size_t.max;

    // The records held, in the order of the file: a ring of maxHeld entries addressed by
    // a sequence number, _first the oldest one held, _end the one after the newest
    Entry[maxHeld] _ring;
    size_t _first;
    size_t _end;

    ref Entry at(size_t seq) return pure nothrow @nogc
    {
        return _ring[seq % maxHeld];
    }

    void push(Entry entry) pure nothrow @nogc
    {
        assert(_end - _first < maxHeld);
        at(_end++) = entry;
    }

    //! @returns the sequence number of the open head of the sender, none if none
    size_t openHeadOf(const ref ubyte[16] sender) pure nothrow @nogc
    {
        foreach (seq; _first .. _end)
            if (at(seq).state == State.openHead && at(seq).sender == sender)
                return seq;
        return none;
    }

    //! The open message of the head `seq` won't be whole: its parts so far become records
    void breakUp(size_t seq) pure nothrow @nogc
    {
        at(seq).state = State.record;
        foreach (s; seq + 1 .. _end)
            if (at(s).state == State.part && at(s).head == seq)
                at(s).state = State.record;
    }

    //! Lets out the records held up to the first open head
    void drain(scope EmitRecord emit) nothrow @nogc
    {
        size_t[maxParts] parts;
        while (_first != _end)
        {
            const entry = at(_first);
            final switch (entry.state)
            {
            case State.openHead:
                return;
            case State.record:
                emit(entry.offset, null);
                break;
            case State.wholeHead:
                size_t count = 0;
                foreach (s; _first + 1 .. _end)
                    if (at(s).state == State.part && at(s).head == _first)
                        parts[count++] = at(s).offset;
                emit(entry.offset, parts[0 .. count]);
                break;
            case State.part:
                break; // left with its head, which comes before it
            }
            ++_first;
        }
    }
}

version (unittest)
{
    import std.conv : to;

    //! What left the joiner: "offset" for a record, "offset+part+part" for a joined one
    private struct Sink
    {
        string[] records;

        //! Allocates, though EmitRecord is @nogc: tests only
        EmitRecord emit() return
        {
            return cast(EmitRecord)(size_t offset, const(size_t)[] parts) nothrow {
                try
                {
                    string s = offset.to!string;
                    foreach (p; parts)
                        s ~= "+" ~ p.to!string;
                    records ~= s;
                }
                catch (Exception)
                    assert(false);
            };
        }
    }

    private RecordPart part(char sender, uint number, uint count, uint counter)
    {
        RecordPart p;
        p.sender[0] = sender;
        p.number = number;
        p.count = count;
        p.counter = counter;
        p.nextCounter = (counter + 1) & 0xFF;
        return p;
    }

    private enum RecordPart whole = RecordPart.init;
}

@("PartJoiner: records that are not parts leave at once")
unittest
{
    PartJoiner joiner;
    Sink sink;
    joiner.add(0, whole, sink.emit);
    joiner.add(10, whole, sink.emit);
    assert(sink.records == ["0", "10"] && !joiner.holding);
}

@("PartJoiner: the parts of a message leave as one record once the last one comes")
unittest
{
    PartJoiner joiner;
    Sink sink;
    joiner.add(0, part('A', 1, 3, 7), sink.emit);
    joiner.add(10, part('A', 2, 3, 8), sink.emit);
    assert(sink.records.length == 0 && joiner.holding, "held until the message is whole");
    joiner.add(20, part('A', 3, 3, 9), sink.emit);
    assert(sink.records == ["0+10+20"] && !joiner.holding);
}

@("PartJoiner: records between the parts leave after the joined one, in their order")
unittest
{
    PartJoiner joiner;
    Sink sink;
    joiner.add(0, whole, sink.emit);
    joiner.add(10, part('A', 1, 2, 255), sink.emit);
    joiner.add(20, whole, sink.emit);
    joiner.add(30, part('B', 1, 1, 0), sink.emit); // 1 of 1: a record of its own
    assert(sink.records == ["0"]);
    joiner.add(40, part('A', 2, 2, 0), sink.emit); // the counter wraps
    assert(sink.records == ["0", "10+40", "20", "30"]);
}

@("PartJoiner: the messages of two senders are joined each, whatever their parts' order")
unittest
{
    PartJoiner joiner;
    Sink sink;
    joiner.add(0, part('A', 1, 2, 1), sink.emit);
    joiner.add(10, part('B', 1, 2, 5), sink.emit);
    joiner.add(20, part('A', 2, 2, 2), sink.emit);
    assert(sink.records == ["0+20"], "A leaves, B still waits");
    joiner.add(30, part('B', 2, 2, 6), sink.emit);
    assert(sink.records == ["0+20", "10+30"]);
}

@("PartJoiner: a part of another counter or out of turn leaves the message unjoined")
unittest
{
    PartJoiner joiner;
    Sink sink;
    joiner.add(0, part('A', 1, 2, 1), sink.emit);
    joiner.add(10, part('A', 2, 2, 3), sink.emit); // a message of the sender was lost between
    assert(sink.records == ["0", "10"] && !joiner.holding);

    sink.records = null;
    joiner.add(20, part('A', 1, 3, 1), sink.emit);
    joiner.add(30, part('A', 3, 3, 2), sink.emit); // part 2 missing
    assert(sink.records == ["20", "30"] && !joiner.holding);
}

@("PartJoiner: a new first part of the sender leaves the message before it unjoined")
unittest
{
    PartJoiner joiner;
    Sink sink;
    joiner.add(0, part('A', 1, 3, 1), sink.emit);
    joiner.add(10, part('A', 2, 3, 2), sink.emit);
    joiner.add(20, part('A', 1, 2, 3), sink.emit);
    assert(sink.records == ["0", "10"], "the parts so far leave as records");
    joiner.add(30, part('A', 2, 2, 4), sink.emit);
    assert(sink.records == ["0", "10", "20+30"]);
}

@("PartJoiner: the end of the data lets the records held out, the message unjoined")
unittest
{
    PartJoiner joiner;
    Sink sink;
    joiner.add(0, part('A', 1, 2, 1), sink.emit);
    joiner.add(10, whole, sink.emit);
    joiner.flush(sink.emit);
    assert(sink.records == ["0", "10"] && !joiner.holding);
}

@("PartJoiner: past maxHeld records held the oldest message waited for leaves unjoined")
unittest
{
    PartJoiner joiner;
    Sink sink;
    joiner.add(0, part('A', 1, 2, 1), sink.emit);
    foreach (i; 1 .. PartJoiner.maxHeld)
        joiner.add(i, whole, sink.emit);
    assert(sink.records.length == PartJoiner.maxHeld && sink.records[0] == "0");
    assert(!joiner.holding);
    joiner.add(1000, part('A', 2, 2, 2), sink.emit);
    assert(sink.records[$ - 1] == "1000", "too late to be joined");
}

@("PartJoiner: a message of more than maxParts parts is left as it is")
unittest
{
    PartJoiner joiner;
    Sink sink;
    enum n = cast(uint) PartJoiner.maxParts + 1;
    joiner.add(0, part('A', 1, n, 1), sink.emit);
    joiner.add(10, part('A', 2, n, 2), sink.emit);
    assert(sink.records == ["0", "10"] && !joiner.holding);
}
