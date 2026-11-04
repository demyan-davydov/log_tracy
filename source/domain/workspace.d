module domain.workspace;

import domain.document;
import domain.document_id;
import domain.document_item : DocumentItem;
import domain.index.anchors;

import log_core.log_filter : LogFilter;
import log_core.log_format : ColumnInfo, LogFormat;

import event_bus.event_bus_interface : SignalConsumer, SubscriptionToken;
import event_bus.event_bus_sync : EventBusSync;

import std.algorithm : countUntil, remove;
import std.meta : AliasSeq;
import std.array : insertInPlace;

//! Workspace is a collection of documents

/// Document event forwarded by Workspace, tagged with its source document
struct DocumentEvent(E)
{
    DocumentId docId;
    E event;
}

/// Document events that Workspace forwards as DocumentEvent!E
alias ForwardedDocumentEvents = AliasSeq!(OperationStarted, OperationProgress, OperationFinished, SourceLost);

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

    override Document.Operation operation()
    {
        return Document.Operation.None;
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

    override const(ColumnInfo)[] columns()
    {
        return null;
    }

    override const(LogFormat) format()
    {
        return null;
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

    override bool requestCancel()
    {
        return false;
    }

    override bool sourceLost()
    {
        return false;
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
    SubscriptionToken[] subscriptions; // forwarding subscriptions on document.events
    string sourcePath;
    string filterPath;
    string fibexPath;
}

final class Workspace
{
    private DocumentRecord[] _documents;
    private size_t _current; // currently displayed document
    private DocumentIdGenerator _idGenerator;
    private EventBusSync _events; // already on the UI thread: documents dispatch there

    this()
    {
        _events = new EventBusSync();
    }

    ~this()
    {
        // GC finalizer: documents may already be finalized, so don't touch them
        _documents = null;
    }

    //! @brief Subscription point for DocumentEvent!E, E in ForwardedDocumentEvents.
    //! Delivered on the UI thread from dispatchEvents().
    SignalConsumer events()
    {
        return _events;
    }

    void clear()
    {
        foreach (ref record; _documents)
            stopForwarding(record);
        _documents.length = 0;
        _current = 0;
    }

    //! @brief Stops forwarding and destroys all documents, cancelling and
    //! joining their background operations. Call on application exit:
    //! a running indexing thread would otherwise keep the process alive.
    void closeAll()
    {
        auto records = _documents;
        _documents = null;
        _current = 0;

        foreach (ref record; records)
        {
            stopForwarding(record);
            destroy(record.document);
        }
    }

    private SubscriptionToken[] startForwarding(Document document, DocumentId docId)
    {
        SubscriptionToken[] tokens;
        static foreach (E; ForwardedDocumentEvents)
        {
            tokens ~= document.events.subscribe((const E e) {
                _events.publish(DocumentEvent!E(docId, e));
            });
        }
        return tokens;
    }

    private void stopForwarding(ref DocumentRecord record)
    {
        foreach (token; record.subscriptions)
            record.document.events.unsubscribe(token);
        record.subscriptions = null;
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
        item.subscriptions = startForwarding(document, item.docId);
        _documents ~= item;
        return item.docId;
    }

    Document removeDocument(DocumentId docId)
    {
        ptrdiff_t idx = findIndexById(docId);
        if (idx != -1)
        {
            auto document = _documents[idx].document;
            stopForwarding(_documents[idx]);
            _documents = _documents.remove(idx);
            if (_current >= _documents.length && _current > 0)
                _current = _documents.length - 1;
            return document;
        }
        return null;
    }

    //! @brief Puts `document` in place of the document `docId`, keeping its id,
    //! position and path: the tab stays and shows the new document. Used to
    //! reopen a document whose file was lost.
    //! @return the replaced document (the caller destroys it), null if not found
    Document replaceDocument(DocumentId docId, Document document)
    {
        ptrdiff_t idx = findIndexById(docId);
        if (idx == -1)
            return null;

        auto old = _documents[idx].document;
        stopForwarding(_documents[idx]);
        _documents[idx].document = document;
        _documents[idx].subscriptions = startForwarding(document, docId);
        return old;
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

        const(ColumnInfo)[] columns()
        {
            return null;
        }

        const(LogFormat) format()
        {
            return null;
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

        bool requestCancel()
        {
            return false;
        }

        bool sourceLost()
        {
            return false;
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

@("Workspace forwards document events tagged with DocumentId")
unittest
{
    import event_bus.event_bus_async : EventBusAsync;

    // Document whose events are published by the test itself
    class EventSourceDocument : Document
    {
        EventBusAsync bus;
        this() { bus = new EventBusAsync(); }

        SignalConsumer events() { return bus; }
        void dispatchEvents() { bus.dispatch(); }
        DocumentView mainView() { return k_nullDocumentView; }
        DocumentView searchView() { return k_nullDocumentView; }
        const(ColumnInfo)[] columns() { return null; }
        const(LogFormat) format() { return null; }
        void applyViewFilter(LogFilter!wchar filter) {}
        void applySearchFilter(LogFilter!wchar filter) {}
        bool setAnchor(size_t index, bool value) { return false; }
        size_t[] exportAnchors() const pure { return null; }
        void importAnchors(const(size_t[]) anchors) {}
        bool requestCancel() { return false; }
        bool sourceLost() { return false; }
    }

    auto ws = new Workspace();
    auto doc1 = new EventSourceDocument();
    auto doc2 = new EventSourceDocument();
    const id1 = ws.addDocument(doc1, "doc1");
    const id2 = ws.addDocument(doc2, "doc2");

    DocumentId[] startedIds;
    float progress = -1;
    DocumentId finishedId;
    ws.events.subscribe((const DocumentEvent!OperationStarted e) { startedIds ~= e.docId; });
    ws.events.subscribe((const DocumentEvent!OperationProgress e) { progress = e.event.progress; });
    ws.events.subscribe((const DocumentEvent!OperationFinished e) { finishedId = e.docId; });

    doc1.bus.publish(OperationStarted(Document.Operation.BuildOffsetIndex));
    doc2.bus.publish(OperationStarted(Document.Operation.BuildOffsetIndex));
    doc2.bus.publish(OperationProgress(Document.Operation.BuildOffsetIndex, 0.5f));
    doc2.bus.publish(OperationFinished(Document.Operation.BuildOffsetIndex));

    assert(startedIds.length == 0, "nothing is delivered before dispatchEvents()");
    ws.dispatchEvents();

    assert(startedIds == [id1, id2]);
    assert(progress == 0.5f);
    assert(finishedId == id2);

    // A removed document is no longer forwarded
    ws.removeDocument(id1);
    doc1.bus.publish(OperationStarted(Document.Operation.BuildSearchIndex));
    doc1.dispatchEvents();
    ws.dispatchEvents();
    assert(startedIds == [id1, id2], "events of a removed document must not be forwarded");
}

@("Workspace.closeAll destroys documents and stops forwarding")
unittest
{
    static int destroyed;

    class ClosableDocument : Document
    {
        ~this() { ++destroyed; }

        SignalConsumer events() { return k_nullEvents; }
        void dispatchEvents() {}
        DocumentView mainView() { return k_nullDocumentView; }
        DocumentView searchView() { return k_nullDocumentView; }
        const(ColumnInfo)[] columns() { return null; }
        const(LogFormat) format() { return null; }
        void applyViewFilter(LogFilter!wchar filter) {}
        void applySearchFilter(LogFilter!wchar filter) {}
        bool setAnchor(size_t index, bool value) { return false; }
        size_t[] exportAnchors() const pure { return null; }
        void importAnchors(const(size_t[]) anchors) {}
        bool requestCancel() { return false; }
        bool sourceLost() { return false; }
    }

    auto ws = new Workspace();
    ws.addDocument(new ClosableDocument(), "doc1");
    ws.addDocument(new ClosableDocument(), "doc2");

    ws.closeAll();

    assert(destroyed == 2, "every document must be destroyed");
    assert(ws.length == 0);
    assert(ws.current is k_nullDocument);
}

@("Workspace.replaceDocument keeps the id and forwards the new document only")
unittest
{
    import event_bus.event_bus_async : EventBusAsync;

    class EventSourceDocument : Document
    {
        EventBusAsync bus;
        this() { bus = new EventBusAsync(); }

        SignalConsumer events() { return bus; }
        void dispatchEvents() { bus.dispatch(); }
        DocumentView mainView() { return k_nullDocumentView; }
        DocumentView searchView() { return k_nullDocumentView; }
        const(ColumnInfo)[] columns() { return null; }
        const(LogFormat) format() { return null; }
        void applyViewFilter(LogFilter!wchar filter) {}
        void applySearchFilter(LogFilter!wchar filter) {}
        bool setAnchor(size_t index, bool value) { return false; }
        size_t[] exportAnchors() const pure { return null; }
        void importAnchors(const(size_t[]) anchors) {}
        bool requestCancel() { return false; }
        bool sourceLost() { return false; }
    }

    auto ws = new Workspace();
    auto oldDoc = new EventSourceDocument();
    auto newDoc = new EventSourceDocument();
    const id = ws.addDocument(oldDoc, "file.dlt");

    DocumentId[] lost;
    ws.events.subscribe((const DocumentEvent!SourceLost e) { lost ~= e.docId; });

    assert(ws.replaceDocument(id, newDoc) is oldDoc);
    assert(ws.doc(id) is newDoc && ws.length == 1);
    assert(ws.displayName(id) == "file.dlt", "the path is kept");

    oldDoc.bus.publish(SourceLost());
    oldDoc.dispatchEvents();
    assert(lost.length == 0, "the replaced document is no longer forwarded");

    newDoc.bus.publish(SourceLost());
    ws.dispatchEvents();
    assert(lost == [id], "the new document is forwarded under the same id");
}
