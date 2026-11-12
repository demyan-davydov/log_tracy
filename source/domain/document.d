//! What the UI knows of an open log: the Document (its views, filter,
//! search, anchors, the format it was opened with, the files sent in it), the
//! DocumentView (the rows of one view) and the operation events a document publishes.
module domain.document;

import log_core.log_message;
import log_core.log_filter : LogFilter;
import utils.ui_text : UiText;

import domain.attachments : Attachment;
import domain.index.record_store : RecordsLease;
import domain.document_id;
import log_core.log_format : ColumnInfo, FormatChoice, FormatInfo, LogFormat;
import domain.document_item;
import domain.anchors;

import utils.event_bus.event_bus_interface : SignalConsumer;

//! Why Document.setAnchor changed nothing
enum AnchorRefusal
{
    none, /// not refused: the anchor is as asked
    busy, /// an operation is running (or the document can't change: its source is lost, no such message)
    limit, /// no room for another anchor (Anchors.MaxAnchors)
}

//! What Document.setAnchor did: true if the anchor is as asked now
struct AnchorChange
{
    AnchorRefusal refusal;

    bool opCast(T : bool)() const pure nothrow @nogc @safe
    {
        return refusal == AnchorRefusal.none;
    }
}

//! The rows of one view of a document. What the view shows (loading, ready,
//! failed...) is told by the operation events of the document, see
//! ui.main_view_fsm and ui.search_view_fsm.
interface DocumentView
{
    size_t itemsCount() nothrow @nogc;

    bool fetchItem(size_t index, scope ref DocumentItem item);

    //! @brief The position in the view of the message with index `realIndex`
    //! @return false if the view doesn't show that message
    bool positionOf(size_t realIndex, out size_t position);

    //! @brief The position in the view of the message `realIndex`, or of the first
    //! message after it the view shows, else of its last row (Go to Message)
    //! @return false if the view is empty
    bool nearestPositionOf(size_t realIndex, out size_t position);
}

//! How far a document has got with its log, at one moment (Document.state)
struct DocumentState
{
    ulong loadedBytes; /// the bytes split into records so far
    ulong totalBytes; /// the bytes of the log (Document.byteSize)
    //! The records that can be read (the length of Records): those before a message
    //! still open stay out until it closes (PartedFormat)
    size_t records;
    bool loaded; /// the load is over: every byte there was split (a source may grow after)
    bool sourceLost; /// its file can't be read any more (Document.sourceLost)
    UiText error; /// why the load failed, the document is done for; empty if it didn't
}

interface Document
{
    enum Operation
    {
        None,
        BuildOffsetIndex, // the load of the file: can not be cancelled by user
        BuildFilterIndex,
        BuildSearchIndex,
    }

    /// Subscription point for OperationStarted / OperationProgress / OperationFinished.
    SignalConsumer events();

    /// Delivers queued events to subscribers. Must be called from the UI thread.
    void dispatchEvents();

    DocumentView mainView();

    DocumentView searchView();

    //! The format of the document, null if there is none
    const(LogFormat) format();

    //! The format the document was opened with, to open its file the same
    //! way again; unset for a document without one
    FormatChoice formatChoice() const;

    //! The number of records of the log found so far: grows while the file
    //! loads, all of them once it is loaded
    size_t messageCount() nothrow @nogc;

    //! The size of the log in bytes; kept once its file is lost
    ulong byteSize() nothrow @nogc;

    //! @brief The records of the log found so far, for a reader of its own on any thread
    //! (another holder of the document): they stay readable while the lease is held, the
    //! document closed too. Closing the document doesn't wait for the leases: their
    //! reader stops once they are closing (RecordsLease.closing), as for a cancel. Taken
    //! on the thread of the document's store; empty for a document without records
    RecordsLease leaseRecords();

    //! How far the document has got with its log now: what was loaded, whether the load
    //! is over or failed. Cheap: taken on the thread of the document's store
    DocumentState state();

    //! The files sent in the log found so far (domain/attachments): the list grows and
    //! changes while the file loads, AttachmentsChanged tells it
    Attachment[] attachments();

    //! @brief Writes the bytes of the attachment `id` that can be read: those of its
    //! packets from the first one in turn, cut at its size. Throws UiTextException: no
    //! such attachment, the log doesn't have its start, the log was lost or a packet
    //! can't be read meanwhile
    //! @param begin - called once the attachment can be written, before its bytes: where
    //!   they go is made there, not for an attachment refused
    //! @param write - takes the bytes, in order
    //! @returns the bytes written
    ulong writeAttachment(size_t id, scope void delegate() begin, scope void delegate(const(ubyte)[] bytes) write);

    //! Columns of the log table, as declared by the format of the document
    final const(ColumnInfo)[] columns()
    {
        const f = format();
        return f is null ? null : f.columns;
    }

    //! What the user and the settings know the format of the document by (its id keys the
    //! column layouts and the filter files); empty without a format
    final FormatInfo formatInfo()
    {
        const f = format();
        return f is null ? FormatInfo.init : f.info;
    }

    void applyViewFilter(LogFilter!wchar filter);

    void applySearchFilter(LogFilter!wchar filter);

    //! The search the results of the search view were found by (the running
    //! search too, while it finds them); null without one, or after a search
    //! that was cancelled or failed and left no results
    const(LogFilter!wchar) searchFilter();

    AnchorChange setAnchor(size_t index, bool value);

    //! No room for another anchor: setting one is refused (Anchors.MaxAnchors)
    bool anchorsFull() const;

    size_t[] exportAnchors() const pure;

    void importAnchors(const(size_t[]) anchors);

    //! @brief Cancels `operation` and drops the requests waiting for it:
    //! BuildFilterIndex — the running filter with the search over its view (a
    //! filter that runs with the load of the file is not cancelled);
    //! BuildSearchIndex — the running search alone, a filter running with it
    //! goes on. Loading the file is not cancelled.
    //! A cancelled operation reports OperationFinished(Cancelled).
    //! @return true if a running operation was asked to stop
    bool requestCancel(Operation operation);

    //! @return true once the file can't be read any more (its disk was removed,
    //! a read failed). The document is unusable then: its views are empty and
    //! requests are ignored. Reported once by the SourceLost event.
    bool sourceLost();
}

/// The view whose content an operation builds: search operations build the
/// search view, all others the main view.
bool isSearchOperation(Document.Operation operation) pure nothrow @nogc @safe
{
    return operation == Document.Operation.BuildSearchIndex;
}

// ─── Document events ───────────────────────────────────────────────────────
// Delivered on the UI thread by Document.dispatchEvents(). Order per
// operation: Started, Progress*, Finished. Operations overlap: a filter and a
// search asked for while the file loads run with the load, each over what the
// one before it has found so far; a search runs with a filter likewise.

struct OperationStarted
{
    Document.Operation operation;
}

//! How far the operations running are, all of them in one event: only the
//! latest matters, and events of one type override each other in the queue
struct OperationProgress
{
    enum isOverridable = true; // only the latest progress matters

    /// By operation, 0..1; NaN for one that isn't running
    float[Document.Operation.max + 1] values;

    this(float[Document.Operation.max + 1] values) pure nothrow @nogc @safe
    {
        this.values = values;
    }

    /// The progress of one operation
    this(Document.Operation operation, float progress) pure nothrow @nogc @safe
    {
        values[operation] = progress;
    }

    /// True if the event tells the progress of `operation`
    bool has(Document.Operation operation) const pure nothrow @nogc @safe
    {
        return values[operation] == values[operation];
    }

    /// The progress of `operation`, 0..1; NaN if it isn't running
    float of(Document.Operation operation) const pure nothrow @nogc @safe
    {
        return values[operation];
    }
}

//! A document that was loaded got more records (its source grows: a file
//! being written, a stream): its views show more rows of the same content.
//! Rows that no operation running tells of: a view an operation fills counts
//! its rows by the progress of that operation.
struct ContentGrown
{
    enum isOverridable = true;
}

//! The files sent in the log (Document.attachments) are other than told before: more
//! of them, more of their packets, their end, or the log loaded to its end (a file
//! without its end is incomplete then). Not published for a log without any.
struct AttachmentsChanged
{
    enum isOverridable = true;
}

//! The file of the document can't be read any more (its disk was removed, a
//! read failed). Published once; the document stays unusable afterwards.
struct SourceLost
{
}

struct OperationFinished
{
    enum Result
    {
        Completed,
        Cancelled,
        Failed,
    }

    Document.Operation operation;
    Result result;
    UiText error; // set when result == Failed: for the user, translated where it is shown
}
