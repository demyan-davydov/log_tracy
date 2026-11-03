module domain.workspace;

import domain.document;
import domain.document_id;
import domain.document_item : DocumentItem;
import domain.index.anchors;

import dlt_core.log_item : LogItem;
import dlt_core.log_filter : LogFilter;

import event_bus.event_bus_interface : SignalConsumer;
import event_bus.event_bus_sync : EventBusSync;

import std.algorithm : countUntil, remove;
import std.array : insertInPlace;

//! Workspace is a collection of documents

private class NullDocumentView : DocumentView
{
    override size_t itemsCount() nothrow @nogc
    {
        return 0;
    }

    override bool fetchItem(size_t index, scope ref DocumentItem item)
    {
        return false;
    }

    override State state()
    {
        return State.Ready;
    }

    override float progress()
    {
        return 1.0f;
    }

    override void enableFilter(bool enable)
    {
    }

    override bool isFilterEnabled() const
    {
        return false;
    }

    override void applyFilter(LogFilter!wchar filter)
    {
    }

    override void resetFilter()
    {
    }
}

private class NullDocument : Document
{
    override SignalConsumer events()
    {
        return k_nullEvents; // never publishes
    }

    override void dispatchEvents()
    {
    }

    override DocumentView mainView()
    {
        return k_nullDocumentView;
    }

    override DocumentView searchView()
    {
        return k_nullDocumentView;
    }

    override void applyViewFilter(LogFilter!wchar filter)
    {
    }

    override void applySearchFilter(LogFilter!wchar filter)
    {
    }

    override bool setAnchor(size_t index, bool value)
    {
        return false;
    }

    override size_t[] exportAnchors() const pure
    {
        return null;
    }

    override void importAnchors(const(size_t[]) anchors)
    {
    }
}

__gshared NullDocumentView k_nullDocumentView = new NullDocumentView();
__gshared NullDocument k_nullDocument = new NullDocument();
__gshared EventBusSync k_nullEvents;

shared static this()
{
    k_nullEvents = new EventBusSync(); // owns a Mutex: cannot be built at compile time
}

private struct DocumentRecord
{
    this(DocumentId docId)
    {
        this.docId = docId;
    }

    this(DocumentId docId, string sourcePath)
    {
        this.docId = docId;
        this.sourcePath = sourcePath;
    }

    DocumentId docId;
    Document document;
    string sourcePath;
    string filterPath;
    string fibexPath;
}

final class Workspace
{
    private DocumentRecord[] _documents;
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

    bool setCurrent(DocumentId docId)
    {
        ptrdiff_t idx = findIndexById(docId);
        if (idx != -1)
        {
            _current = idx;
            return true;
        }
        return false;
    }

    DocumentId addDocument(Document document, string sourcePath)
    {
        auto item = DocumentRecord(_idGenerator.popId(), sourcePath);
        item.document = document;
        item.sourcePath = sourcePath;
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

    //! @brief Moves document before another document
    //! @param docId Document id to move
    //! @param index Index to move document to
    //! @return True if document was moved, false otherwise
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

    //! @brief Delivers queued events of all documents to their subscribers.
    //! Must be called from the UI thread. Every document is dispatched even if
    //! a subscriber throws; exceptions are chained via Throwable.next.
    void dispatchEvents()
    {
        Throwable head, tail;
        foreach (record; _documents.dup) // subscribers may add/remove documents
        {
            try
                record.document.dispatchEvents();
            catch (Exception e)
            {
                if (head is null)
                    head = e;
                else
                    tail.next = e;
                tail = e;
                while (tail.next !is null)
                    tail = tail.next;
            }
        }
        if (head !is null)
            throw head;
    }

    //! @brief Checks if there is a current document
    //! @return True if there is a current document, false otherwise
    bool hasCurrent() const pure nothrow @nogc @property
    {
        return _current < _documents.length;
    }

    //! @brief Gets document by id
    //! @param docId Document id to get
    //! @return Document with the given id
    inout(Document) doc(DocumentId docId) inout @property
    {
        ptrdiff_t idx = findIndexById(docId);
        if (idx != -1)
        {
            return _documents[idx].document;
        }
        else
        {
            return cast(inout(Document)) k_nullDocument;
        }
    }

    //! @brief Gets current document
    //! @return Current document
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

    //! @return The number of documents in the workspace
    size_t length() const pure nothrow @nogc @property
    {
        return _documents.length;
    }

    //! @return Array of documents
    const(DocumentRecord)[] documents() const pure nothrow @nogc @property
    {
        return _documents;
    }

    //! @brief Gets display name of document
    string displayName(DocumentId docId)
    {
        ptrdiff_t idx = findIndexById(docId);
        if (idx != -1)
        {
            return _documents[idx].sourcePath;
        }
        return "";
    }

    //! @brief Gets display name of document
    string displayNameByIndex(size_t idx)
    {
        if (idx < _documents.length)
        {
            return _documents[idx].sourcePath;
        }
        return "";
    }
}

@("Workspace operations")
unittest
{
    import dlt_core.log_item : LogItem;

    // Minimal implementation of Document for testing
    class MockDocument : Document
    {
        string name;
        this(string n)
        {
            name = n;
        }

        SignalConsumer events()
        {
            return k_nullEvents;
        }

        void dispatchEvents()
        {
        }

        DocumentView mainView()
        {
            return k_nullDocumentView;
        }

        DocumentView searchView()
        {
            return k_nullDocumentView;
        }

        void applyViewFilter(LogFilter!wchar filter)
        {
        }

        void applySearchFilter(LogFilter!wchar filter)
        {
        }

        bool setAnchor(size_t index, bool value)
        {
            return false;
        }

        size_t[] exportAnchors() const pure
        {
            return null;
        }

        void importAnchors(const(size_t[]) anchors)
        {
        }
    }

    auto ws = new Workspace();
    assert(ws.length == 0);

    auto doc1 = new MockDocument("doc1");
    auto doc2 = new MockDocument("doc2");

    // Test adding
    ws.addDocument(doc1, "doc1");
    ws.addDocument(doc2, "doc2");
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
