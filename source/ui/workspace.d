module ui.workspace;

import ui.document;
import ui.document_id;

import dlt_core.search : LogItem, FilterConfig;

import std.algorithm : countUntil, remove;
import std.array : insertInPlace;

//! Workspace is a collection of documents

private class NullDocument : Document
{
    string sourcePath() const
    {
        return "";
    }

    string fibexPath() const
    {
        return "";
    }

    size_t length() const
    {
        return 0;
    }

    LogItem logItem(ulong index)
    {
        return LogItem.init;
    }

    void openFibex(string path)
    {
    }

    void applyFilter(FilterConfig config)
    {
    }

    int progress() const
    {
        return 100;
    }
}

__gshared NullDocument k_nullDocument = new NullDocument();

private struct DocumentItem
{
    Document document;
    DocumentId docId;
}

final class Workspace
{
    private DocumentItem[] _documents;
    private size_t _current; // currently displayed document
    private DocumentIdGenerator _idGenerator;

    this()
    {
    }

    ~this()
    {
        clear();
    }

    void clear()
    {
        _documents.length = 0;
        _current = 0;
    }

    // returns -1 if not found
    private ptrdiff_t findIndexById(DocumentId docId) const pure nothrow @nogc
    {
        return _documents.countUntil!((item) => item.docId == docId);
    }

    void setCurrent(DocumentId docId)
    {
        ptrdiff_t idx = findIndexById(docId);
        if (idx != -1)
        {
            _current = idx;
        }
    }

    DocumentId addDocument(Document document)
    {
        auto item = DocumentItem(document, _idGenerator.popId());
        _documents ~= item;
        return item.docId;
    }

    Document removeDocument(DocumentId docId)
    {
        ptrdiff_t idx = findIndexById(docId);
        if (idx != -1)
        {
            auto document = _documents[idx].document;
            _documents = _documents.remove(idx);
            if (_current >= _documents.length && _current > 0)
                _current = _documents.length - 1;
            return document;
        }
        return null;
    }

    bool moveDocumentBefore(DocumentId docId, size_t index)
    {
        ptrdiff_t idx = findIndexById(docId);
        if (idx != -1 && index < _documents.length)
        {
            auto item = _documents[idx];
            _documents = _documents.remove(idx);
            _documents.insertInPlace(index, item);
            return true;
        }

        return false;
    }

    bool hasCurrent() const pure nothrow @nogc @property
    {
        return _current < _documents.length;
    }

    inout(Document) current() inout @property
    {
        if (_current < _documents.length)
        {
            return _documents[_current].document;
        }
        else
        {
            return cast(inout(Document)) k_nullDocument;
        }
    }

    inout(DocumentId) currentId() inout @property
    {
        if (_current < _documents.length)
        {
            return _documents[_current].docId;
        }
        else
        {
            return DocumentId();
        }
    }

    size_t length() const pure nothrow @nogc @property
    {
        return _documents.length;
    }

    const(DocumentItem)[] documents() const pure nothrow @nogc @property
    {
        return _documents;
    }

    string displayName(DocumentId docId)
    {
        ptrdiff_t idx = findIndexById(docId);
        if (idx != -1)
        {
            return _documents[idx].document.sourcePath;
        }
        return "";
    }

    string displayName(size_t idx)
    {
        if (idx < _documents.length)
        {
            return _documents[idx].document.sourcePath;
        }
        return "";
    }
}

@("Workspace operations")
unittest
{
    import dlt_core.search : LogItem;

    // Minimal implementation of Document for testing
    class MockDocument : Document
    {
        string name;
        this(string n)
        {
            name = n;
        }

        string sourcePath() const
        {
            return name;
        }

        string fibexPath() const
        {
            return "";
        }

        size_t length() const
        {
            return 0;
        }

        LogItem logItem(ulong index)
        {
            return LogItem.init;
        }

        void openFibex(string path)
        {
        }

        void applyFilter(FilterConfig config)
        {
        }

        int progress() const
        {
            return 100;
        }
    }

    auto ws = new Workspace();
    assert(ws.length == 0);

    auto doc1 = new MockDocument("doc1");
    auto doc2 = new MockDocument("doc2");

    // Test adding
    ws.addDocument(doc1);
    ws.addDocument(doc2);
    assert(ws.length == 2);

    auto docs = ws.documents;
    auto id1 = docs[0].docId;
    auto id2 = docs[1].docId;

    // Test current document
    assert(ws.current is doc1);
    ws.setCurrent(id2);
    assert(ws.current is doc2);

    // Test move
    ws.moveDocumentBefore(id2, 0);
    assert(ws.documents[0].docId == id2);
    assert(ws.documents[1].docId == id1);

    // Test removal
    auto removed = ws.removeDocument(id2);
    assert(removed is doc2);
    assert(ws.length == 1);
    assert(ws.current is doc1);

    // Test clear
    ws.clear();
    assert(ws.length == 0);
    assert(ws.current is k_nullDocument);
    assert(!ws.currentId.isValid);
}
