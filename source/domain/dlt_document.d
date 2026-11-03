module domain.dlt_document;

import domain.document;
import domain.document_item;
import domain.document_id;

import dlt_core.dlt_source;
import dlt_core.dlt_log_filter;
import dlt_core.decoded_message;
import dlt_core.log_filter;

import domain.index.anchors;
import domain.dlt_index;
import domain.view_status;

import utils.lock_guard;

import event_bus.event_bus_async : EventBusAsync;
import event_bus.event_bus_interface : SignalConsumer;

import std.parallelism : Task, TaskPool;
import std.typecons : scoped, Unique, Proxy;
import std.meta : AliasSeq;

class DltDocument : Document
{
    private MainDocumentView _mainView;
    private SearchDocumentView _searchView;

    private LogFilter!wchar _viewFilter;
    private LogFilter!wchar _searchFilter;
    private Anchors _anchors;

    private string _sourcePath;

    private EventBusAsync _events; // must outlive _index: its worker publishes here
    private ViewStatus _mainStatus = ViewStatus(ViewStatus.State.NotReady); // offset index not built yet
    private ViewStatus _searchStatus; // Ready: empty search result until a search runs
    private DltIndex _index;

    //! A filter request waiting for the background slot. Only the latest
    //! request of each kind is kept; `filter` may be null (reset).
    private struct PendingRequest
    {
        LogFilter!wchar filter;
        bool requested;
    }

    private PendingRequest _pendingViewFilter;
    private PendingRequest _pendingSearch;
    // Operation started and not yet finished, as seen from the UI thread:
    // cleared when its OperationFinished is dispatched (the slot is idle by then).
    private Operation _running = Operation.None;

    this() @disable;

    this(string path)
    {
        _events = new EventBusAsync();
        // Subscribed before anyone else: views are updated before external
        // subscribers see the event, so they can read the new state right away.
        static foreach (E; AliasSeq!(OperationStarted, OperationProgress, OperationFinished))
        {
            _events.subscribe((const E e) { statusOf(e.operation).on(e); });
        }
        _events.subscribe((const OperationFinished e) {
            _running = Operation.None;
            startPending();
        });
        _index = DltIndex(path, _events); // starts BuildOffsetIndex
        _running = Operation.BuildOffsetIndex;
        _sourcePath = path;
        _mainView = new MainDocumentView();
        _searchView = new SearchDocumentView();
    }

    private ref ViewStatus statusOf(Operation operation) return
    {
        return isSearchOperation(operation) ? _searchStatus : _mainStatus;
    }

    override SignalConsumer events()
    {
        return _events;
    }

    override void dispatchEvents()
    {
        _events.dispatch();
    }

    override DocumentView mainView()
    {
        return _mainView;
    }

    override DocumentView searchView()
    {
        return _searchView;
    }

    /*override string sourcePath() const
    {
        return _sourcePath;
    }*/

    //! @brief Rebuilds the main view with `filter`. If an operation is running,
    //! the request waits for it; a running filter or search is cancelled
    //! first, since the new filter rebuilds both indexes anyway.
    override void applyViewFilter(LogFilter!wchar filter)
    {
        _pendingViewFilter = PendingRequest(filter, true);
        if (_running == Operation.BuildFilterIndex || _running == Operation.BuildSearchIndex)
            _index.cancelCurrentOperation();
        startPending();
    }

    //! @brief Rebuilds the search view with `filter`. If an operation is
    //! running, the request waits for it; a running search is cancelled first.
    override void applySearchFilter(LogFilter!wchar filter)
    {
        _pendingSearch = PendingRequest(filter, true);
        if (_running == Operation.BuildSearchIndex)
            _index.cancelCurrentOperation();
        startPending();
    }

    //! @brief Starts the next pending request if the slot is free: the view
    //! filter first, since the search runs over the (filtered) main view.
    private void startPending()
    {
        if (_running != Operation.None)
            return;

        if (_pendingViewFilter.requested)
        {
            auto filter = _pendingViewFilter.filter;
            _pendingViewFilter = PendingRequest.init;
            if (_index.runBuildFilterIndex(filter, _anchors))
            {
                _viewFilter = filter;
                _running = Operation.BuildFilterIndex;
            }
        }
        else if (_pendingSearch.requested)
        {
            auto filter = _pendingSearch.filter;
            _pendingSearch = PendingRequest.init;
            if (_index.runBuildSearchIndex(filter, _anchors))
            {
                _searchFilter = filter;
                _running = Operation.BuildSearchIndex;
            }
        }
    }

    bool setAnchor(size_t index, bool value)
    {
        return _anchors.set(index, value);
    }

    size_t[] exportAnchors() const pure
    {
        return _anchors.exportAnchors();
    }

    void importAnchors(const(size_t[]) anchors)
    {
        _anchors.importAnchors(anchors);
    }

    override bool requestCancel()
    {
        _pendingViewFilter = PendingRequest.init;
        _pendingSearch = PendingRequest.init;

        if (_running != Operation.BuildFilterIndex && _running != Operation.BuildSearchIndex)
            return false;

        _index.cancelCurrentOperation();
        return true;
    }

    /// Views

    private class MainDocumentView : DocumentView
    {
        override size_t itemsCount() nothrow @nogc
        {
            return this.outer._index.mainViewItemsCount();
        }

        override bool fetchItem(size_t index, scope ref DocumentItem item)
        {
            return this.outer._index.fetchMainViewItem(index, item);
        }

        override DocumentView.State state()
        {
            return this.outer._mainStatus.state;
        }

        override float progress()
        {
            return this.outer._mainStatus.progress;
        }

        override void enableFilter(bool enable)
        {
            this.outer._index.enableFilter(enable);
        }

        override bool isFilterEnabled() const
        {
            return this.outer._index.isMainViewFilterEnabled();
        }

        override void applyFilter(LogFilter!wchar filter)
        {
            this.outer.applyViewFilter(filter);
        }

        override void resetFilter()
        {
            this.outer.applyViewFilter(null);
        }
    }

    private class SearchDocumentView : DocumentView
    {
        override size_t itemsCount() nothrow @nogc
        {
            return this.outer._index.searchViewItemsCount();
        }

        override bool fetchItem(size_t index, scope ref DocumentItem item)
        {
            return this.outer._index.fetchSearchViewItem(index, item);
        }

        override DocumentView.State state()
        {
            return this.outer._searchStatus.state;
        }

        override float progress()
        {
            return this.outer._searchStatus.progress;
        }

        override void enableFilter(bool enable)
        {
            this.outer._index.enableFilter(enable);
        }

        override bool isFilterEnabled() const
        {
            return true;
        }

        override void applyFilter(LogFilter!wchar filter)
        {
            this.outer.applySearchFilter(filter);
        }

        override void resetFilter()
        {
            this.outer.applySearchFilter(null);
        }
    }
}

// =============================================================================
// Unit tests
// =============================================================================

version (unittest)
{
    import dlt_core.dlt_source : buildDltMessage;

    private string writeTestDlt(string name, size_t messageCount)
    {
        import std.file : write, tempDir;
        import std.path : buildPath;

        ubyte[] data;
        foreach (i; 0 .. messageCount)
            data ~= buildDltMessage("ECU1", cast(uint) i, 0, 0, cast(ubyte) i, [0xAA, 0xBB]);

        auto path = buildPath(tempDir(), name);
        write(path, data);
        return path;
    }

    /// Test filter that accepts all or no messages
    private final class ConstFilter : LogFilter!wchar
    {
        import std.typecons : Nullable;

        private bool _result;

        this(bool result) pure
        {
            _result = result;
        }

        bool matches(scope ref const(DecodedMessage!wchar) item) const
        {
            return _result;
        }

        Nullable!uint matchIndex(scope ref const(DecodedMessage!wchar) item) const
        {
            return _result ? Nullable!uint(0) : Nullable!uint.init;
        }

        immutable(LogFilter!wchar) idup() const pure
        {
            return cast(immutable) new ConstFilter(_result);
        }

        LogFilter!wchar dup() const pure
        {
            return new ConstFilter(_result);
        }
    }

    /// Pumps document events like MainWindow.onIdle() until `done` or timeout
    private void dispatchUntil(Document doc, scope bool delegate() done)
    {
        import core.thread : Thread;
        import core.time : msecs, MonoTime;

        const deadline = MonoTime.currTime + 3000.msecs;
        while (!done() && MonoTime.currTime < deadline)
        {
            doc.dispatchEvents();
            Thread.sleep(1.msecs);
        }
    }
}

@("DltDocument: opening reports Started, Progress, Finished in order")
unittest
{
    import std.file : remove;

    enum messageCount = 2000;
    auto path = writeTestDlt("dlt_document_events.dlt", messageCount);
    scope (exit)
        remove(path);

    auto doc = new DltDocument(path);

    string[] log;
    float lastProgress = -1;
    OperationFinished finished;
    bool readyOnFinish;
    size_t countOnFinish;

    // Subscribing after construction is fine: nothing is delivered before dispatchEvents()
    doc.events.subscribe((const OperationStarted e) {
        assert(e.operation == Document.Operation.BuildOffsetIndex);
        log ~= "started";
    });
    doc.events.subscribe((const OperationProgress e) {
        assert(e.progress >= lastProgress, "progress must not go backwards");
        lastProgress = e.progress;
        if (log.length == 0 || log[$ - 1] != "progress")
            log ~= "progress";
    });
    doc.events.subscribe((const OperationFinished e) {
        finished = e;
        // Finished is published after the slot is idle: views are already updated
        readyOnFinish = doc.mainView.ready;
        countOnFinish = doc.mainView.itemsCount;
        log ~= "finished";
    });

    dispatchUntil(doc, () => log.length > 0 && log[$ - 1] == "finished");

    assert(log == ["started", "progress", "finished"], "unexpected event order");
    assert(finished.operation == Document.Operation.BuildOffsetIndex);
    assert(finished.result == OperationFinished.Result.Completed);
    assert(lastProgress == 1.0f, "last progress event must report completion");
    assert(readyOnFinish, "main view must be ready when OperationFinished is delivered");
    assert(countOnFinish == messageCount);
}

@("DltDocument: destroy while indexing cancels and joins the worker")
unittest
{
    import std.file : remove;
    import core.time : MonoTime, seconds;

    auto path = writeTestDlt("dlt_document_destroy.dlt", 200_000);
    scope (exit)
        remove(path);

    auto doc = new DltDocument(path);
    const start = MonoTime.currTime;
    destroy(doc); // must cancel the running BuildOffsetIndex, not wait for it or crash
    assert(MonoTime.currTime - start < 1.seconds, "destroy must not wait for indexing to complete");
}

@("DltDocument: each view has its own state and progress")
unittest
{
    import std.file : remove;

    auto path = writeTestDlt("dlt_document_views.dlt", 500);
    scope (exit)
        remove(path);

    auto doc = new DltDocument(path);
    assert(doc.mainView.state == DocumentView.State.NotReady, "nothing delivered yet");
    assert(doc.searchView.ready, "search view starts Ready with an empty result");

    bool loaded;
    doc.events.subscribe((const OperationFinished e) { loaded = true; });
    dispatchUntil(doc, () => loaded);
    assert(doc.mainView.ready && doc.mainView.progress == 1.0f);

    // A search operation moves only the search view
    enum search = Document.Operation.BuildSearchIndex;
    doc._events.publish(OperationStarted(search));
    doc._events.publish(OperationProgress(search, 0.3f));
    doc.dispatchEvents();

    assert(doc.searchView.state == DocumentView.State.BuildingIndex);
    assert(doc.searchView.progress == 0.3f);
    assert(doc.mainView.ready && doc.mainView.progress == 1.0f, "main view must not change");
}

@("DltDocument: a search requested while loading waits for the load, latest request wins")
unittest
{
    import std.file : remove;

    enum messageCount = 2000;
    auto path = writeTestDlt("dlt_document_deferred.dlt", messageCount);
    scope (exit)
        remove(path);

    auto doc = new DltDocument(path);
    string[] log;
    doc.events.subscribe((const OperationStarted e) {
        import std.conv : to;
        log ~= e.operation.to!string ~ " started";
    });
    doc.events.subscribe((const OperationFinished e) {
        import std.conv : to;
        log ~= e.operation.to!string ~ " " ~ e.result.to!string;
    });

    // Both arrive while BuildOffsetIndex runs: neither is lost, only the latest runs
    doc.applySearchFilter(new ConstFilter(false));
    doc.applySearchFilter(new ConstFilter(true));

    dispatchUntil(doc, () => log.length > 0 && log[$ - 1] == "BuildSearchIndex Completed");

    assert(log == [
        "BuildOffsetIndex started", "BuildOffsetIndex Completed",
        "BuildSearchIndex started", "BuildSearchIndex Completed"
    ], "unexpected operations order");
    assert(doc.searchView.ready);
    assert(doc.searchView.itemsCount == messageCount, "the latest (match-all) search must have run");
}

@("DltDocument: a new search cancels the running one and replaces it")
unittest
{
    import std.algorithm : count;
    import std.file : remove;

    enum messageCount = 200_000;
    auto path = writeTestDlt("dlt_document_restart.dlt", messageCount);
    scope (exit)
        remove(path);

    auto doc = new DltDocument(path);
    string[] log;
    doc.events.subscribe((const OperationStarted e) {
        import std.conv : to;
        log ~= e.operation.to!string ~ " started";
    });
    doc.events.subscribe((const OperationFinished e) {
        import std.conv : to;
        log ~= e.operation.to!string ~ " " ~ e.result.to!string;
    });
    dispatchUntil(doc, () => doc.mainView.ready);

    doc.applySearchFilter(new ConstFilter(false)); // starts right away
    doc.applySearchFilter(new ConstFilter(true)); // cancels it and waits for its Finished

    dispatchUntil(doc, () => log.length > 0 && log[$ - 1] == "BuildSearchIndex Completed"
            && log.count("BuildSearchIndex started") == 2);

    // Usually the first search is Cancelled; on a very fast run it may complete first.
    // Either way both run, in order, and the result is the latest request's.
    assert(log.count("BuildSearchIndex started") == 2, "both searches must start");
    assert(log[$ - 1] == "BuildSearchIndex Completed");
    assert(doc.searchView.itemsCount == messageCount, "the result must be the latest search's");
}

@("DltDocument: requestCancel stops a running search")
unittest
{
    import std.file : remove;

    auto path = writeTestDlt("dlt_document_cancel.dlt", 200_000);
    scope (exit)
        remove(path);

    auto doc = new DltDocument(path);
    OperationFinished[] finished;
    doc.events.subscribe((const OperationFinished e) { finished ~= e; });
    dispatchUntil(doc, () => doc.mainView.ready);
    finished = null;

    doc.applySearchFilter(new ConstFilter(true));
    assert(doc.requestCancel(), "a running search must be cancellable");

    dispatchUntil(doc, () => finished.length > 0);

    assert(finished.length == 1);
    assert(finished[0].operation == Document.Operation.BuildSearchIndex);
    assert(finished[0].result == OperationFinished.Result.Cancelled,
        "search must stop at the next batch, not complete");
    assert(doc.searchView.state == DocumentView.State.NotReady, "cancelled search leaves the view not ready");
    assert(doc.mainView.ready, "main view is not affected");
    assert(!doc.requestCancel(), "nothing left to cancel");
}

@("DltDocument: requestCancel drops pending requests but not the file load")
unittest
{
    import std.file : remove;

    enum messageCount = 2000;
    auto path = writeTestDlt("dlt_document_cancel_pending.dlt", messageCount);
    scope (exit)
        remove(path);

    auto doc = new DltDocument(path);
    Document.Operation[] started;
    OperationFinished[] finished;
    doc.events.subscribe((const OperationStarted e) { started ~= e.operation; });
    doc.events.subscribe((const OperationFinished e) { finished ~= e; });

    doc.applySearchFilter(new ConstFilter(true)); // waits for BuildOffsetIndex
    assert(!doc.requestCancel(), "loading the file is not cancellable");

    dispatchUntil(doc, () => finished.length > 0);
    // A pending search would start from the Finished handler; its Started
    // is delivered by the next dispatch
    doc.dispatchEvents();

    assert(finished.length == 1 && finished[0].result == OperationFinished.Result.Completed,
        "the load must complete");
    assert(started == [Document.Operation.BuildOffsetIndex], "the pending search must be dropped");
    assert(doc.mainView.ready && doc.mainView.itemsCount == messageCount);
}
