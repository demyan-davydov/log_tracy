module ui.document_id;

private alias Id = size_t;

import std.conv : to;

struct DocumentId
{
    private Id _id;

    this(Id newId) pure nothrow @nogc
    {
        _id = newId;
    }

    bool opEquals(DocumentId other) const pure nothrow @nogc
    {
        return _id == other._id;
    }

    size_t toHash() const pure nothrow @nogc
    {
        return _id;
    }

    bool isValid() const pure nothrow @nogc
    {
        return _id != 0;
    }

    string toString() const
    {
        return _id.to!string;
    }
}

struct DocumentIdGenerator
{
    private size_t _nextId = 0;

    DocumentId popId() pure nothrow @nogc
    {
        return DocumentId(++_nextId);
    }
}

@("DocumentId properties and operations")
unittest
{
    DocumentId id0 = DocumentId(0);
    assert(!id0.isValid());
    assert(id0.toHash() == 0);
    assert(id0.toString() == "0");

    DocumentId id1 = DocumentId(1);
    assert(id1.isValid());
    assert(id1.toHash() == 1);
    assert(id1.toString() == "1");

    DocumentId id1_copy = DocumentId(1);
    assert(id1 == id1_copy);
    assert(id1 != id0);
}

@("DocumentIdGenerator behavior")
unittest
{
    DocumentIdGenerator gen;
    DocumentId id1 = gen.popId();
    DocumentId id2 = gen.popId();
    DocumentId id3 = gen.popId();

    assert(id1.toString() == "1");
    assert(id2.toString() == "2");
    assert(id3.toString() == "3");
    assert(id1 != id2);
    assert(id2 != id3);
}
