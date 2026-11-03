module domain.document;

import dlt_core.dlt_source;
import dlt_core.decoded_message;
import dlt_core.fibex;
import dlt_core.indexer;
import dlt_core.log_filter : LogFilter;
import dlt_core.dlt_protocol : LogLevel, MessageType;

import domain.document_id;
import domain.document_item;
import domain.index.anchors;

import event_bus.event_bus_interface : SignalConsumer;

interface DocumentView
{
    enum State
    {
        NotReady, // corresponded index not yet builded
        Ready, // corresponded index is builded
        BuildingIndex, // corresponded index is building
        Error,
    }

    size_t itemsCount() nothrow @nogc;

    bool fetchItem(size_t index, scope ref DocumentItem item);

    State state();

    float progress(); // return 1.0 if ready

    /// Operation that brought the view to its current state: the running one
    /// while BuildingIndex, the last one afterwards (None if there was none).
    Document.Operation operation();

    void enableFilter(bool enable);

    bool isFilterEnabled() const;

    void applyFilter(LogFilter!wchar filter);

    void resetFilter();

    final bool ready()
    {
        return state() == State.Ready;
    }
}

interface Document
{
    enum Operation
    {
        None,
        BuildOffsetIndex, // can not be cancelled by user
        BuildFilterIndex,
        BuildSearchIndex,
    }

    /// Subscription point for OperationStarted / OperationProgress / OperationFinished.
    SignalConsumer events();

    /// Delivers queued events to subscribers. Must be called from the UI thread.
    void dispatchEvents();

    DocumentView mainView();

    DocumentView searchView();

    //string sourcePath() const nothrow @nogc;

    //string fibexPath() const nothrow @nogc;

    //string filterPath() const nothrow @nogc;

    void applyViewFilter(LogFilter!wchar filter);

    void applySearchFilter(LogFilter!wchar filter);

    bool setAnchor(size_t index, bool value);

    size_t[] exportAnchors() const pure;

    void importAnchors(const(size_t[]) anchors);

    //! @brief Cancels the running filter or search and drops pending requests.
    //! Loading the file (BuildOffsetIndex) is not cancelled.
    //! The cancelled operation reports OperationFinished(Cancelled).
    //! @return true if a running operation was asked to stop
    bool requestCancel();
}

/// The view whose content an operation builds: search operations build the
/// search view, all others the main view.
bool isSearchOperation(Document.Operation operation) pure nothrow @nogc @safe
{
    return operation == Document.Operation.BuildSearchIndex;
}

// ─── Document events ───────────────────────────────────────────────────────
// Published from the indexing thread, delivered on the UI thread by
// Document.dispatchEvents(). Order per operation: Started, Progress*, Finished.

struct OperationStarted
{
    Document.Operation operation;
}

struct OperationProgress
{
    enum isOverridable = true; // only the latest progress matters

    Document.Operation operation;
    float progress = 0; // 0..1
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
    string error; // set when result == Failed
}
