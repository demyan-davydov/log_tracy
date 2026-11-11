//! PartJoiner: follows the messages cut into numbered parts ("1/2: ...", "2/2: ...", as a
//! PartedFormat tells them) as their records are found in the order of the file, and says
//! where each record goes: to the offset index as it is, to the index as the head of a
//! message (its first part), or to the fragments of an open message (a later part). It
//! keeps the open messages only, not their records; the tables are the store's.
module domain.index.part_joiner;

import log_core.log_format : RecordPart;

//! Where a record goes
enum StepKind : ubyte
{
    record, // to the offset index, a record of its own
    head, // to the offset index, the first part of a message: it gets the join given
    fragment, // to the fragments of the message `join`, after the fragment `previous`
}

//! What PartJoiner.add says of a record
struct Step
{
    StepKind kind;
    size_t join; // fragment: the join of its message (PartJoiner.add's `join` of its head)
    size_t previous; // fragment: the one before it in its message, PartJoiner.none: none
}

//! Follows the open messages, record by record in the order of the file.
//!
//! A message grows while its parts come one by one from one sender: part 1 of n, then 2,
//! ... n, each with the counter the one before it said comes next. Records of other
//! senders may come between them. A message closes when its last part came, or when it
//! can't grow any more: a part out of turn or of another counter, a new part 1 of its
//! sender, maxWait records after its head, more than maxOpen messages open, the end of
//! the data (flush). A closed message keeps the parts it got.
struct PartJoiner
{
    //! No such index
    enum size_t none = size_t.max;

    //! The most parts a message is joined of: one of more is left as it is
    enum uint maxParts = 64;

    //! The most messages open at once: past them the oldest one closes
    enum size_t maxOpen = 64;

    //! The records after its head a message waits for its next part at most
    enum size_t maxWait = 256;

    //! @brief Takes the next record of the file
    //! @param record - the number the record gets if it goes to the offset index
    //! @param join - the index its join gets if it is the head of a message
    //! @param fragment - the index it gets if it is a fragment
    Step add(in RecordPart part, size_t record, size_t join, size_t fragment) pure nothrow @nogc
    {
        // Messages whose head is maxWait records back won't get their next part
        while (_open != 0 && record - _chains[0].record >= maxWait)
            close(0);

        const joinable = part.isPart && part.count >= 2 && part.count <= maxParts
            && part.number <= part.count;
        if (!joinable)
            return Step(StepKind.record);

        const open = openOf(part.sender);
        if (part.number == 1)
        {
            if (open != none)
                close(open);
            if (_open == maxOpen)
                close(0);
            _chains[_open++] = Chain(part.sender, record, join, none, 2, part.count, part.nextCounter);
            return Step(StepKind.head);
        }

        if (open != none && _chains[open].expected == part.number && _chains[open].nextCounter == part.counter)
        {
            auto chain = &_chains[open];
            const step = Step(StepKind.fragment, chain.join, chain.last);
            chain.last = fragment;
            ++chain.expected;
            chain.nextCounter = part.nextCounter;
            if (part.number == part.count)
                close(open);
            return step;
        }
        if (open != none)
            close(open);
        return Step(StepKind.record);
    }

    //! The data is over: every open message closes
    void flush() pure nothrow @nogc
    {
        _open = 0;
    }

    //! @returns true if a message is open: the records from its head on wait for it
    bool holding() const pure nothrow @nogc
    {
        return _open != 0;
    }

    //! The record of the oldest open message's head, none if no message is open: the
    //! records from it on are not to be read yet
    size_t firstOpenRecord() const pure nothrow @nogc
    {
        return _open != 0 ? _chains[0].record : none;
    }

    //! The join of the oldest open message, none if no message is open: the joins from
    //! it on are not to be read yet
    size_t firstOpenJoin() const pure nothrow @nogc
    {
        return _open != 0 ? _chains[0].join : none;
    }

private:
    //! An open message
    struct Chain
    {
        ubyte[16] sender;
        size_t record; // of its head
        size_t join; // of its head
        size_t last; // its last fragment, none: none yet
        uint expected; // the number of its next part
        uint count; // of its parts
        uint nextCounter; // the counter of its next part
    }

    // The open messages, the oldest head first: heads come in the order of the file
    Chain[maxOpen] _chains;
    size_t _open;

    //! @returns the open message of the sender, none if none
    size_t openOf(const ref ubyte[16] sender) const pure nothrow @nogc
    {
        foreach (i; 0 .. _open)
            if (_chains[i].sender == sender)
                return i;
        return none;
    }

    //! Closes the open message `i`: the order of the others stays
    void close(size_t i) pure nothrow @nogc
    {
        foreach (j; i + 1 .. _open)
            _chains[j - 1] = _chains[j];
        --_open;
    }
}

version (unittest)
{
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
    private enum none = PartJoiner.none;

    private Step fragment(size_t join, size_t previous)
    {
        return Step(StepKind.fragment, join, previous);
    }
}

@("PartJoiner: records that are not parts go to the index as they are")
unittest
{
    PartJoiner joiner;
    assert(joiner.add(whole, 0, 0, 0).kind == StepKind.record);
    assert(joiner.add(part('A', 1, 1, 0), 1, 0, 0).kind == StepKind.record, "1 of 1");
    assert(!joiner.holding && joiner.firstOpenRecord == none && joiner.firstOpenJoin == none);
}

@("PartJoiner: the first part is a head, the next ones its fragments, linked in turn")
unittest
{
    PartJoiner joiner;
    assert(joiner.add(part('A', 1, 3, 7), 5, 2, 0).kind == StepKind.head);
    assert(joiner.holding && joiner.firstOpenRecord == 5 && joiner.firstOpenJoin == 2);
    assert(joiner.add(whole, 6, 3, 0).kind == StepKind.record, "records of others between");
    assert(joiner.add(part('A', 2, 3, 8), 7, 3, 10) == fragment(2, none));
    assert(joiner.holding);
    assert(joiner.add(part('A', 3, 3, 9), 7, 3, 11) == fragment(2, 10));
    assert(!joiner.holding && joiner.firstOpenRecord == none, "the last part closes it");
}

@("PartJoiner: the messages of two senders grow each, the oldest open one is waited for")
unittest
{
    PartJoiner joiner;
    assert(joiner.add(part('A', 1, 2, 1), 0, 0, 0).kind == StepKind.head);
    assert(joiner.add(part('B', 1, 2, 255), 1, 1, 0).kind == StepKind.head);
    assert(joiner.add(part('B', 2, 2, 0), 2, 2, 0) == fragment(1, none), "the counter wraps");
    assert(joiner.firstOpenRecord == 0 && joiner.firstOpenJoin == 0, "A is still open");
    assert(joiner.add(part('A', 2, 2, 2), 2, 2, 1) == fragment(0, none));
    assert(!joiner.holding);
}

@("PartJoiner: a part of another counter or out of turn closes the message, goes as a record")
unittest
{
    PartJoiner joiner;
    joiner.add(part('A', 1, 3, 1), 0, 0, 0);
    assert(joiner.add(part('A', 2, 3, 3), 1, 1, 0).kind == StepKind.record, "a message was lost");
    assert(!joiner.holding);

    joiner.add(part('A', 1, 3, 1), 2, 1, 0);
    assert(joiner.add(part('A', 3, 3, 2), 3, 2, 0).kind == StepKind.record, "part 2 missing");
    assert(!joiner.holding);

    assert(joiner.add(part('A', 2, 2, 5), 4, 2, 0).kind == StepKind.record, "no head");
}

@("PartJoiner: a new first part of the sender closes its open message")
unittest
{
    PartJoiner joiner;
    joiner.add(part('A', 1, 3, 1), 0, 0, 0);
    joiner.add(part('A', 2, 3, 2), 1, 1, 0);
    assert(joiner.add(part('A', 1, 2, 3), 1, 1, 1).kind == StepKind.head);
    assert(joiner.firstOpenRecord == 1 && joiner.firstOpenJoin == 1, "the old one is closed");
    assert(joiner.add(part('A', 2, 2, 4), 2, 2, 1) == fragment(1, none));
}

@("PartJoiner: a message closes maxWait records after its head, and at the end of the data")
unittest
{
    PartJoiner joiner;
    joiner.add(part('A', 1, 2, 1), 10, 0, 0);
    joiner.add(whole, 10 + PartJoiner.maxWait - 1, 1, 0);
    assert(joiner.holding);
    joiner.add(whole, 10 + PartJoiner.maxWait, 1, 0);
    assert(!joiner.holding, "waited long enough");
    assert(joiner.add(part('A', 2, 2, 2), 10 + PartJoiner.maxWait + 1, 1, 0).kind == StepKind.record);

    joiner.add(part('B', 1, 2, 1), 1000, 1, 0);
    joiner.flush();
    assert(!joiner.holding);
}

@("PartJoiner: past maxOpen messages the oldest closes")
unittest
{
    PartJoiner joiner;
    foreach (i; 0 .. PartJoiner.maxOpen)
    {
        RecordPart p = part('A', 1, 2, 0);
        p.sender[1] = cast(ubyte) i;
        joiner.add(p, i, i, 0);
    }
    assert(joiner.firstOpenRecord == 0);
    RecordPart p = part('B', 1, 2, 0);
    joiner.add(p, PartJoiner.maxOpen, PartJoiner.maxOpen, 0);
    assert(joiner.firstOpenRecord == 1 && joiner.firstOpenJoin == 1);
}

@("PartJoiner: a message of more than maxParts parts is left as it is")
unittest
{
    PartJoiner joiner;
    assert(joiner.add(part('A', 1, PartJoiner.maxParts + 1, 1), 0, 0, 0).kind == StepKind.record);
    assert(!joiner.holding);
}
