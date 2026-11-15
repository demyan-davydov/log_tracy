//! DocumentStore: the open documents and who holds them (a tab of the window, later an AI
//! session), each closed when its last holder lets it go; their events forwarded with the id
//! of their document; the null document of an id that isn't open. The order of the tabs and
//! the active one are the window's (`ui/document_tabs`).
module domain.document_store;

import domain.attachments : Attachment;
import domain.document;
import domain.document_id;
import domain.document_item : DocumentItem;
import domain.index.record_store : RecordsLease;
import domain.anchors;

import log_core.log_filter : LogFilter;
import log_core.log_format : FormatChoice, LogFormat;

import utils.event_bus.event_bus_interface : SignalConsumer, SubscriptionToken;
import utils.event_bus.event_bus_sync : EventBusSync;
import utils.ui_text : uiText, UiText, UiTextException;

import std.algorithm : countUntil, remove;
import std.meta : AliasSeq;

/// Document event forwarded by DocumentStore, tagged with its source document
struct DocumentEvent(E)
{
    DocumentId docId;
    E event;
}

/// Document events that DocumentStore forwards as DocumentEvent!E
alias ForwardedDocumentEvents = AliasSeq!(OperationStarted, OperationProgress, OperationFinished, ContentGrown,
    SourceLost, AttachmentsChanged, FormatReplaced, DescriptionsChanged, AnchorApplied);

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

    override bool positionOf(size_t realIndex, out size_t position)
    {
        return false;
    }

    override bool nearestPositionOf(size_t realIndex, out size_t position)
    {
        return false;
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

    override const(LogFormat) format()
    {
        return null;
    }

    override FormatChoice formatChoice() const
    {
        return FormatChoice.init;
    }

    override DescriptionsState descriptions() const
    {
        return DescriptionsState.init;
    }

    override void loadDescriptions(string path)
    {
    }

    override size_t messageCount() nothrow @nogc
    {
        return 0;
    }

    override ulong byteSize() nothrow @nogc
    {
        return 0;
    }

    override RecordsLease leaseRecords()
    {
        return RecordsLease.init;
    }

    override DocumentState state()
    {
        return DocumentState.init;
    }

    override Attachment[] attachments()
    {
        return null;
    }

    override ulong writeAttachment(size_t id, scope void delegate() begin, scope void delegate(const(ubyte)[] bytes) write)
    {
        throw new UiTextException(uiText("no such file in the log"));
    }

    override void applyViewFilter(LogFilter!wchar filter)
    {
    }

    override void applySearchFilter(LogFilter!wchar filter)
    {
    }

    override const(LogFilter!wchar) searchFilter()
    {
        return null;
    }

    override AnchorChange setAnchor(size_t index, bool value)
    {
        return AnchorChange(AnchorRefusal.unavailable);
    }

    override bool anchorsFull() const
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

    override bool requestCancel(Operation operation)
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

//! A hold of an open document (DocumentStore.add, hold): what its holder lets it go by
//! (DocumentStore.release). A hold is released once: a second release of it does nothing,
//! so a holder can't take away the hold of another.
struct DocumentHold
{
    DocumentId docId;
    private uint _token; // unique in its store; 0: no hold

    //! false for the hold of a document that wasn't open
    bool isValid() const pure nothrow @nogc @safe
    {
        return _token != 0;
    }
}

private struct DocumentRecord
{
    DocumentId docId;
    Document document;
    string sourcePath;
    uint[] holds; // the tokens of who uses the document: it is closed when none is left
    uint generation = 1; // one more after each replace: the records are numbered anew
    SubscriptionToken[] subscriptions; // forwarding subscriptions on document.events
}

/// The open documents. Used on the UI thread: the documents dispatch their events there.
final class DocumentStore
{
    private DocumentRecord[] _documents; // in the order they were opened
    private DocumentIdGenerator _idGenerator;
    private uint _lastHold; // the token of the last hold given
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

    //! @brief Adds the document opened from `sourcePath`, held by the caller (release()
    //! lets it go)
    //! @return the caller's hold, with the id of the document
    DocumentHold add(Document document, string sourcePath)
    {
        auto record = DocumentRecord(_idGenerator.popId(), document, sourcePath);
        const hold = DocumentHold(record.docId, ++_lastHold);
        record.holds = [hold._token];
        record.subscriptions = startForwarding(document, record.docId);
        _documents ~= record;
        return hold;
    }

    //! @brief One more holder of the document `docId`: it stays open until each holder
    //! released its hold
    //! @return the new hold, invalid if the document isn't open
    DocumentHold hold(DocumentId docId)
    {
        const idx = findIndexById(docId);
        if (idx == -1)
            return DocumentHold.init;
        const hold = DocumentHold(docId, ++_lastHold);
        _documents[idx].holds ~= hold._token;
        return hold;
    }

    //! @brief A holder lets its document go: the last one closes it (stops its background
    //! operations and frees its file). Nothing if the hold was released before or the
    //! document isn't open.
    void release(DocumentHold hold)
    {
        const idx = findIndexById(hold.docId);
        if (idx == -1)
            return;
        auto holds = &_documents[idx].holds;
        const at = (*holds).countUntil(hold._token);
        if (at == -1)
            return; // released before
        *holds = (*holds).remove(at);
        if ((*holds).length > 0)
            return;
        auto record = _documents[idx];
        _documents = _documents.remove(idx);
        stopForwarding(record);
        destroy(record.document);
    }

    //! @return how many hold the document `docId`, 0 if it isn't open
    size_t holders(DocumentId docId) const pure nothrow @nogc
    {
        const idx = findIndexById(docId);
        return idx == -1 ? 0 : _documents[idx].holds.length;
    }

    //! @brief The generation of the document `docId`: one more after each replace(), where
    //! its records are numbered anew. A holder that keeps numbers of records compares it
    //! with the one they were taken in.
    //! @return 0 if it isn't open
    uint generation(DocumentId docId) const pure nothrow @nogc
    {
        const idx = findIndexById(docId);
        return idx == -1 ? 0 : _documents[idx].generation;
    }

    //! @brief Puts `document` in place of the document `docId`, keeping its id, path and
    //! holders: they see the new document, of the next generation(). Used to reopen a
    //! document whose file was lost.
    //! @return the replaced document (the caller destroys it), null if not found
    Document replace(DocumentId docId, Document document)
    {
        const idx = findIndexById(docId);
        if (idx == -1)
            return null;

        auto old = _documents[idx].document;
        stopForwarding(_documents[idx]);
        _documents[idx].document = document;
        _documents[idx].generation++;
        _documents[idx].subscriptions = startForwarding(document, docId);
        return old;
    }

    //! @brief Closes every document whatever holds it, cancelling and joining their
    //! background operations. Call on application exit: a running indexing thread would
    //! otherwise keep the process alive.
    void closeAll()
    {
        auto records = _documents;
        _documents = null;
        foreach (ref record; records)
        {
            stopForwarding(record);
            destroy(record.document);
        }
    }

    //! @brief Delivers queued events of all documents to their subscribers.
    //! Must be called from the UI thread. Every document is dispatched even if
    //! a subscriber throws; exceptions are chained via Throwable.next.
    //! A subscriber may add, release or replace documents meanwhile: one released
    //! is destroyed (its vtable gone), so it is skipped, not called.
    void dispatchEvents()
    {
        Throwable head, tail;
        foreach (record; _documents.dup) // the list may change under the subscribers
        {
            if (doc(record.docId) !is record.document)
                continue; // released or replaced since the copy
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

    //! @return the document `docId`, the null document (no rows) if it isn't open
    inout(Document) doc(DocumentId docId) inout
    {
        const idx = findIndexById(docId);
        return idx == -1 ? cast(inout(Document)) k_nullDocument : _documents[idx].document;
    }

    //! @return true if the document `docId` is open
    bool isOpen(DocumentId docId) const pure nothrow @nogc
    {
        return findIndexById(docId) != -1;
    }

    //! @return the file of the document `docId`, null if it isn't open
    string sourcePath(DocumentId docId) const pure nothrow @nogc
    {
        const idx = findIndexById(docId);
        return idx == -1 ? null : _documents[idx].sourcePath;
    }

    //! @return the number of open documents
    size_t length() const pure nothrow @nogc
    {
        return _documents.length;
    }

    //! @brief Finds the document opened from the file `path`
    //! @details Paths are compared absolute and normalized, ignoring case where
    //! the OS does
    //! @return Its id, or an invalid one if the file isn't open
    DocumentId findBySourcePath(string path) const
    {
        import std.path : absolutePath, buildNormalizedPath, filenameCmp;

        const key = buildNormalizedPath(absolutePath(path));
        foreach (record; _documents)
            if (filenameCmp(buildNormalizedPath(absolutePath(record.sourcePath)), key) == 0)
                return record.docId;
        return DocumentId.init;
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

    // -1 if not found
    private ptrdiff_t findIndexById(DocumentId docId) const pure nothrow @nogc
    {
        return _documents.countUntil!((item) => item.docId == docId);
    }
}

version (unittest)
{
    import utils.event_bus.event_bus_async : EventBusAsync;

    // A document whose events the test publishes, counting its destructions. One given
    // `destroyed` (a local of the test) must be destroyed before the test returns: left to
    // the GC, its destructor writes into a stack frame that is someone else's by then (it
    // spoiled a return address and crashed the unittests at exit, on Windows)
    private class EventSourceDocument : NullDocument
    {
        EventBusAsync bus;
        int* destroyed;
        this(int* destroyed = null) { bus = new EventBusAsync(); this.destroyed = destroyed; }
        ~this() { if (destroyed !is null) ++*destroyed; }

        override SignalConsumer events() { return bus; }
        override void dispatchEvents() { bus.dispatch(); }
    }
}

@("DocumentStore: a document is open until its last holder releases it")
unittest
{
    int destroyed;
    auto store = new DocumentStore();
    const tab = store.add(new EventSourceDocument(&destroyed), "a.dlt");
    const id = tab.docId;
    assert(tab.isValid && store.isOpen(id) && store.holders(id) == 1, "the caller of add() holds it");

    const agent = store.hold(id); // an AI session, say
    assert(agent.isValid && agent.docId == id);
    store.release(tab); // the tab closes
    assert(store.isOpen(id) && destroyed == 0, "still held");
    assert(store.sourcePath(id) == "a.dlt");

    store.release(agent);
    assert(!store.isOpen(id) && destroyed == 1, "the last holder closes it");
    assert(store.doc(id) is k_nullDocument);
    assert(store.length == 0);

    assert(!store.hold(id).isValid, "a closed document can't be held");
    store.release(agent); // nothing
    assert(destroyed == 1);
}

@("DocumentStore: a hold is released once, a second release takes no other holder's")
unittest
{
    int destroyed;
    auto store = new DocumentStore();
    const tab = store.add(new EventSourceDocument(&destroyed), "a.dlt");
    const agent = store.hold(tab.docId);

    store.release(agent);
    store.release(agent); // by mistake: the hold of the tab stays
    assert(store.isOpen(tab.docId) && store.holders(tab.docId) == 1 && destroyed == 0);

    const again = store.hold(tab.docId);
    assert(again != agent, "a new hold is another one");
    store.release(tab);
    store.release(tab);
    assert(store.isOpen(tab.docId) && destroyed == 0, "held by the new hold");
    store.release(again);
    assert(!store.isOpen(tab.docId) && destroyed == 1);
}

@("DocumentStore: a released document is no longer forwarded")
unittest
{
    auto store = new DocumentStore();
    auto doc1 = new EventSourceDocument();
    auto doc2 = new EventSourceDocument();
    const hold1 = store.add(doc1, "doc1");
    const id1 = hold1.docId, id2 = store.add(doc2, "doc2").docId;

    DocumentId[] startedIds;
    float progress = -1;
    DocumentId finishedId;
    store.events.subscribe((const DocumentEvent!OperationStarted e) { startedIds ~= e.docId; });
    store.events.subscribe((const DocumentEvent!OperationProgress e) { progress = e.event.of(Document.Operation.BuildOffsetIndex); });
    store.events.subscribe((const DocumentEvent!OperationFinished e) { finishedId = e.docId; });

    doc1.bus.publish(OperationStarted(Document.Operation.BuildOffsetIndex));
    doc2.bus.publish(OperationStarted(Document.Operation.BuildOffsetIndex));
    doc2.bus.publish(OperationProgress(Document.Operation.BuildOffsetIndex, 0.5f));
    doc2.bus.publish(OperationFinished(Document.Operation.BuildOffsetIndex));

    assert(startedIds.length == 0, "nothing is delivered before dispatchEvents()");
    store.dispatchEvents();

    assert(startedIds == [id1, id2]);
    assert(progress == 0.5f);
    assert(finishedId == id2);

    // Kept alive by the test after the store closed it: its events go nowhere
    auto bus1 = doc1.bus;
    store.release(hold1);
    bus1.publish(OperationStarted(Document.Operation.BuildSearchIndex));
    bus1.dispatch();
    store.dispatchEvents();
    assert(startedIds == [id1, id2], "events of a released document must not be forwarded");
}

@("DocumentStore: a document released by a subscriber during dispatchEvents is not dispatched")
unittest
{
    int destroyed;
    auto store = new DocumentStore();
    auto doc1 = new EventSourceDocument(&destroyed);
    const id1 = store.add(doc1, "doc1").docId;
    const hold2 = store.add(new EventSourceDocument(&destroyed), "doc2");
    const id2 = hold2.docId;

    // A holder letting the next document go in answer to an event of the first one
    store.events.subscribe((const DocumentEvent!SourceLost e) { store.release(hold2); });
    doc1.bus.publish(SourceLost());
    store.dispatchEvents(); // doc2, destroyed by then, must not be called

    assert(destroyed == 1 && store.isOpen(id1) && !store.isOpen(id2));
    store.closeAll(); // doc1 too, while `destroyed` lives
    assert(destroyed == 2);
}

@("DocumentStore.closeAll closes every document, however many hold it")
unittest
{
    int destroyed;
    auto store = new DocumentStore();
    const a = store.add(new EventSourceDocument(&destroyed), "doc1").docId;
    store.add(new EventSourceDocument(&destroyed), "doc2");
    store.hold(a);

    store.closeAll();

    assert(destroyed == 2, "every document must be destroyed");
    assert(store.length == 0);
    assert(!store.isOpen(a));
}

@("DocumentStore.replace keeps the id, the path and the holders, forwards the new document only")
unittest
{
    auto store = new DocumentStore();
    auto oldDoc = new EventSourceDocument();
    auto newDoc = new EventSourceDocument();
    const id = store.add(oldDoc, "file.dlt").docId;
    store.hold(id);

    DocumentId[] lost;
    store.events.subscribe((const DocumentEvent!SourceLost e) { lost ~= e.docId; });

    assert(store.replace(id, newDoc) is oldDoc);
    assert(store.doc(id) is newDoc && store.length == 1);
    assert(store.sourcePath(id) == "file.dlt", "the path is kept");
    assert(store.holders(id) == 2, "the holders are kept");

    oldDoc.bus.publish(SourceLost());
    oldDoc.dispatchEvents();
    assert(lost.length == 0, "the replaced document is no longer forwarded");

    newDoc.bus.publish(SourceLost());
    store.dispatchEvents();
    assert(lost == [id], "the new document is forwarded under the same id");
}

@("DocumentStore: a replaced document is of the next generation, the generation of each is its own")
unittest
{
    auto store = new DocumentStore();
    const id = store.add(new NullDocument(), "a.dlt").docId;
    const other = store.add(new NullDocument(), "b.dlt").docId;
    const first = store.generation(id);
    assert(first != 0 && store.generation(other) == first, "an open document has a generation");

    store.replace(id, new NullDocument());
    assert(store.generation(id) == first + 1, "its records are numbered anew");
    assert(store.generation(other) == first, "another document is as it was");
    assert(store.generation(DocumentId.init) == 0, "no generation without a document");
}

@("DocumentStore: the null document has no format, no columns and no records")
unittest
{
    auto store = new DocumentStore();
    assert(store.doc(DocumentId.init).format is null);
    assert(store.doc(DocumentId.init).columns is null);
    assert(store.doc(DocumentId.init).leaseRecords.records.length == 0);
    assert(store.doc(DocumentId.init).state == DocumentState.init);
}

@("DocumentStore.findBySourcePath finds the document of a file, however it is spelled")
unittest
{
    import std.path : absolutePath, buildPath;

    auto store = new DocumentStore();
    const holdA = store.add(new NullDocument(), "/logs/a.dlt");
    const a = holdA.docId;
    const b = store.add(new NullDocument(), absolutePath("b.dlt")).docId;

    assert(store.findBySourcePath("/logs/a.dlt") == a);
    assert(store.findBySourcePath("/logs/./x/../a.dlt") == a);
    assert(store.findBySourcePath("b.dlt") == b, "relative to the current directory");
    assert(!store.findBySourcePath("/logs/c.dlt").isValid);
    version (Windows)
    {
        const w = store.add(new NullDocument(), `C:\Logs\W.dlt`).docId;
        assert(store.findBySourcePath(`c:/logs/w.dlt`) == w, "case and separators don't matter");
    }

    store.release(holdA);
    assert(!store.findBySourcePath("/logs/a.dlt").isValid, "a closed file can be opened again");
}
