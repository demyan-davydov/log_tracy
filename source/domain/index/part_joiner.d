//! PartJoiner: follows the messages cut into numbered parts ("1/2: ...", "2/2: ...") or
//! into pieces at a limit of their text (PieceKind), as a PartedFormat tells them, as
//! their records are found in the order of the file, and says
//! where each record goes: to the offset index as it is, to the index as the head of a
//! message (its first part), or to the fragments of an open message (a later part). It
//! keeps the open messages only, not their records; the tables are the store's.
module domain.index.part_joiner;

import log_core.log_format : PieceKind, RecordPart;
import log_core.log_level : LogLevel;

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
//!
//! A message cut into pieces at a limit has no numbers: it grows while the next record of
//! its sender goes on with its last piece (piecesGoOn) and that piece was cut, and closes
//! at a piece not cut, at any other record of the sender, past maxParts pieces.
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

    //! The time a piece goes on with the cut one before it at most, in ns: its writer
    //! writes them at once
    enum long maxPieceGap = 5_000_000;

    //! @brief Takes the next record of the file
    //! @param record - the number the record gets if it goes to the offset index
    //! @param join - the index its join gets if it is the head of a message
    //! @param fragment - the index it gets if it is a fragment
    Step add(in RecordPart part, size_t record, size_t join, size_t fragment) pure nothrow @nogc
    {
        // Messages whose head is maxWait records back won't get their next part
        while (_open != 0 && record - _chains[0].record >= maxWait)
            close(0);

        if (!part.isPart)
            return addPiece(part, record, join, fragment);
        const joinable = part.count >= 2 && part.count <= maxParts && part.number <= part.count;
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

        if (open != none && !_chains[open].cut && _chains[open].expected == part.number
            && _chains[open].nextCounter == part.counter)
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

    //! @brief Takes a record that is not a numbered part: a piece of a message cut at a
    //! limit, or not (piecesGoOn)
    private Step addPiece(in RecordPart part, size_t record, size_t join, size_t fragment) pure nothrow @nogc
    {
        if (part.piece == PieceKind.unknown)
            return Step(StepKind.record);

        const open = openOf(part.sender);
        if (open != none && _chains[open].cut && piecesGoOn(_chains[open], part))
        {
            auto chain = &_chains[open];
            const step = Step(StepKind.fragment, chain.join, chain.last);
            chain.last = fragment;
            ++chain.expected;
            chain.nextCounter = part.nextCounter;
            chain.time = part.time;
            chain.room = part.room;
            chain.level = part.level;
            if (part.piece != PieceKind.cut || chain.expected > maxParts)
                close(open);
            return step;
        }
        // Any other record of the writer: its message of pieces can't grow (a numbered one
        // waits for its parts as before, unless a message of pieces starts: one a writer)
        if (open != none && (_chains[open].cut || part.piece == PieceKind.cut))
            close(open);
        if (part.piece != PieceKind.cut)
            return Step(StepKind.record);
        if (_open == maxOpen)
            close(0);
        auto chain = Chain(part.sender, record, join, none, 2, 0, part.nextCounter);
        chain.cut = true;
        chain.time = part.time;
        chain.room = part.room;
        chain.level = part.level;
        _chains[_open++] = chain;
        ++_cutOpen;
        return Step(StepKind.head);
    }

    //! @brief The rule of pieces: a record of one text goes on with the piece its writer
    //! cut before it if it is the next message of the writer (its counter), of the same
    //! level (the writer cut one message), written at once (maxPieceGap, when both times
    //! are known), and starts with a character the cut piece left no room for
    private static bool piecesGoOn(const ref Chain chain, in RecordPart part) pure nothrow @nogc
    {
        if (part.piece != PieceKind.text && part.piece != PieceKind.cut)
            return false;
        if (part.counter != chain.nextCounter || part.level != chain.level)
            return false;
        if (part.time != RecordPart.noTime && chain.time != RecordPart.noTime
            && (part.time < chain.time || part.time - chain.time > maxPieceGap))
            return false;
        return chain.room == 0 || part.firstCharLength > chain.room;
    }

    //! @returns true if a message cut into pieces is open: whose the next records are is to
    //! be told (PartedFormat.partOf), any of them may go on with it
    bool followsPieces() const pure nothrow @nogc
    {
        return _cutOpen != 0;
    }

    //! The data is over: every open message closes
    void flush() pure nothrow @nogc
    {
        _open = 0;
        _cutOpen = 0;
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
        bool cut; // of pieces cut at a limit, not of numbered parts (count is 0)
        long time = RecordPart.noTime; // pieces: of its last one
        uint room; // pieces: the room its last one left under the limit
        LogLevel level; // pieces: the level of its pieces
    }

    // The open messages, the oldest head first: heads come in the order of the file
    Chain[maxOpen] _chains;
    size_t _open;
    size_t _cutOpen; // of them, messages of pieces

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
        if (_chains[i].cut)
            --_cutOpen;
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

    //! A record of one text of the sender, `ms` its time in ms (-1: unknown)
    private RecordPart piece(char sender, PieceKind kind, uint counter, long ms, uint room = 0,
        uint firstCharLength = 1)
    {
        RecordPart p;
        p.sender[0] = sender;
        p.piece = kind;
        p.counter = counter;
        p.nextCounter = (counter + 1) & 0xFF;
        p.time = ms < 0 ? RecordPart.noTime : ms * 1_000_000;
        p.room = room;
        p.firstCharLength = firstCharLength;
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

@("PartJoiner: a piece cut at the limit is a head, the next records of its writer its fragments")
unittest
{
    alias K = PieceKind;
    PartJoiner joiner;
    assert(joiner.add(piece('A', K.cut, 7, 100), 5, 2, 0).kind == StepKind.head);
    assert(joiner.holding && joiner.followsPieces && joiner.firstOpenRecord == 5);
    assert(joiner.add(piece('B', K.text, 1, 100), 6, 3, 0).kind == StepKind.record, "others between");
    assert(joiner.add(piece('A', K.cut, 8, 101), 7, 3, 10) == fragment(2, none), "cut again");
    assert(joiner.add(piece('A', K.text, 9, 101), 7, 3, 11) == fragment(2, 10));
    assert(!joiner.holding && !joiner.followsPieces, "a piece not cut is the last");
    assert(joiner.add(piece('A', K.text, 10, 101), 7, 3, 12).kind == StepKind.record);
}

@("PartJoiner: a piece goes on only with the next counter, in maxPieceGap, of its level, after the room")
unittest
{
    alias K = PieceKind;
    enum gap = PartJoiner.maxPieceGap / 1_000_000; // ms
    PartJoiner joiner;

    joiner.add(piece('A', K.cut, 1, 100), 0, 0, 0);
    assert(joiner.add(piece('A', K.text, 3, 100), 1, 1, 0).kind == StepKind.record, "a message lost");
    assert(!joiner.holding);

    joiner.add(piece('A', K.cut, 1, 100), 2, 1, 0);
    assert(joiner.add(piece('A', K.text, 2, 100 + gap + 1), 3, 2, 0).kind == StepKind.record, "too late");
    assert(!joiner.holding);
    joiner.add(piece('A', K.cut, 1, 100), 4, 2, 0);
    assert(joiner.add(piece('A', K.text, 2, 100 + gap), 5, 3, 0).kind == StepKind.fragment, "in time");
    joiner.add(piece('A', K.cut, 1, 100), 6, 3, 1);
    assert(joiner.add(piece('A', K.text, 2, 99), 7, 4, 1).kind == StepKind.record, "earlier");
    joiner.add(piece('A', K.cut, 1, -1), 8, 4, 1);
    assert(joiner.add(piece('A', K.text, 2, 5000), 9, 5, 1).kind == StepKind.fragment, "no time: not told");

    // Its writer cut the message: the pieces have its level
    auto debug_ = piece('A', K.cut, 1, 100);
    debug_.level = LogLevel.Debug;
    joiner.add(debug_, 14, 7, 3);
    auto info = piece('A', K.text, 2, 100);
    info.level = LogLevel.Info;
    assert(joiner.add(info, 15, 8, 3).kind == StepKind.record, "another level");
    joiner.add(debug_, 16, 8, 3);
    auto same = info;
    same.level = LogLevel.Debug;
    assert(joiner.add(same, 17, 9, 3).kind == StepKind.fragment);

    // The writer left 2 bytes under its limit: the next piece starts with a longer character
    joiner.add(piece('A', K.cut, 1, 100, 2), 10, 5, 2);
    assert(joiner.add(piece('A', K.text, 2, 100, 0, 2), 11, 6, 2).kind == StepKind.record, "it fit");
    joiner.add(piece('A', K.cut, 1, 100, 2), 12, 6, 2);
    assert(joiner.add(piece('A', K.text, 2, 100, 0, 3), 13, 7, 2).kind == StepKind.fragment);
}

@("PartJoiner: another record of the writer ends its cut message, records it doesn't tell don't")
unittest
{
    alias K = PieceKind;
    PartJoiner joiner;
    joiner.add(piece('A', K.cut, 1, 100), 0, 0, 0);
    assert(joiner.add(whole, 1, 1, 0).kind == StepKind.record);
    assert(joiner.holding, "whose it is, unknown");
    assert(joiner.add(piece('A', K.other, 2, 100), 2, 1, 0).kind == StepKind.record);
    assert(!joiner.holding);

    joiner.add(piece('A', K.cut, 1, 100), 3, 1, 0);
    assert(joiner.add(piece('A', K.cut, 5, 100), 4, 2, 0).kind == StepKind.head, "a new cut one");
    assert(joiner.firstOpenRecord == 4);
}

@("PartJoiner: records of one text of the writer between its numbered parts don't close the message")
unittest
{
    alias K = PieceKind;
    PartJoiner joiner;
    joiner.add(part('A', 1, 2, 1), 0, 0, 0);
    assert(joiner.add(piece('A', K.text, 2, 100), 1, 1, 0).kind == StepKind.record);
    assert(joiner.add(piece('A', K.other, 3, 100), 2, 1, 0).kind == StepKind.record);
    assert(joiner.holding && !joiner.followsPieces);
    assert(joiner.add(part('A', 2, 2, 2), 3, 1, 0) == fragment(0, none));
}

@("PartJoiner: numbered parts and pieces of one writer don't mix, a message of pieces has maxParts")
unittest
{
    alias K = PieceKind;
    PartJoiner joiner;
    joiner.add(part('A', 1, 2, 1), 0, 0, 0);
    assert(joiner.add(piece('A', K.cut, 2, 100), 1, 1, 0).kind == StepKind.head, "closes the numbered one");
    assert(joiner.firstOpenRecord == 1);
    assert(joiner.add(part('A', 2, 2, 3), 2, 2, 0).kind == StepKind.record);
    assert(!joiner.holding);

    joiner.add(piece('B', K.cut, 0, 100), 10, 2, 0);
    foreach (i; 1 .. PartJoiner.maxParts)
        assert(joiner.add(piece('B', K.cut, i, 100), 10 + i, 3, i).kind == StepKind.fragment);
    assert(!joiner.holding, "maxParts pieces: closed");
}
