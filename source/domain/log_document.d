module domain.log_document;

import domain.document;
import domain.document_item;
import domain.document_id;

import log_core.log_message;
import log_core.log_filter;

import domain.anchors;
import domain.log_index;
import formats.registry : createFormat, detectFormat;
import log_core.byte_source;
import log_core.log_format : LogFormat, ColumnInfo, FormatChoice;

import utils.lock_guard;

import utils.event_bus.event_bus_async : EventBusAsync;
import utils.event_bus.event_bus_interface : SignalConsumer;

import std.parallelism : Task, TaskPool;
import std.typecons : scoped, Unique, Proxy;

//! A log document: a log of any format with its main and search views
class LogDocument : Document
{
    private MainDocumentView _mainView;
    private SearchDocumentView _searchView;

    private LogFilter!wchar _viewFilter;
    private LogFilter!wchar _searchFilter;
    private Anchors _anchors;

    private string _sourcePath;
    private FormatChoice _formatChoice;

    private EventBusAsync _events; // must outlive _index: its worker publishes here
    private LogIndex _index;

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
    private bool _sourceLost; // SourceLost was published

    this() @disable;

    //! @brief Opens the file in the format chosen before, or detects it
    //! @param choice - the format to open with; unset: detect it
    //! @throws Exception if the file can't be opened or its format is unknown
    this(string path, FormatChoice choice = FormatChoice.init)
    {
        auto source = new FileSource(path);
        scope (failure)
            source.close();
        // A choice this build can't make (a format it doesn't know, a broken
        // variant) is detected again instead of locking the file out
        LogFormat format;
        if (choice.isSet)
        {
            try
                format = createFormat(choice, source.data);
            catch (Exception)
                format = null;
        }
        if (format is null)
            format = detectFormat(path, source.data, choice);
        this(path, source, format);
        _formatChoice = choice;
    }

    override FormatChoice formatChoice() const pure nothrow @nogc
    {
        return _formatChoice;
    }

    //! @param path - shown to the user
    //! @param source - owned by the document from now on
    this(string path, ByteSource source, LogFormat format)
    {
        _events = new EventBusAsync();
        // Subscribed before anyone else: the document is up to date before
        // external subscribers see the event
        _events.subscribe((const OperationFinished e) {
            // A cancelled or failed search left no results (its index is
            // cleared): nothing is found, and a new filter doesn't repeat it
            if (isSearchOperation(e.operation) && e.result != OperationFinished.Result.Completed)
                _searchFilter = null;
            _running = Operation.None;
            startPending();
        });
        _index = LogIndex(source, format, _events); // starts BuildOffsetIndex
        _running = Operation.BuildOffsetIndex;
        _sourcePath = path;
        _mainView = new MainDocumentView();
        _searchView = new SearchDocumentView();
    }

    override SignalConsumer events()
    {
        return _events;
    }

    override void dispatchEvents()
    {
        // A failed read is only flagged by the fault handler; report it once,
        // from here, on the UI thread
        if (!_sourceLost && _index.sourceLost)
        {
            _sourceLost = true;
            _pendingViewFilter = PendingRequest.init;
            _pendingSearch = PendingRequest.init;
            _events.publish(SourceLost());
        }
        _events.dispatch();
    }

    override bool sourceLost()
    {
        return _sourceLost || _index.sourceLost;
    }

    override DocumentView mainView()
    {
        return _mainView;
    }

    override DocumentView searchView()
    {
        return _searchView;
    }

    override const(LogFormat) format()
    {
        return _index.format;
    }

    override size_t messageCount() nothrow @nogc
    {
        return _index.messageCount;
    }

    override ulong byteSize() nothrow @nogc
    {
        return _index.byteSize;
    }

    /*override string sourcePath() const
    {
        return _sourcePath;
    }*/

    //! @brief Rebuilds the main view with `filter`. If an operation is running,
    //! the request waits for it; a running filter or search is cancelled
    //! first, since the new filter rebuilds both indexes anyway.
    //! The search runs over the main view, so the running or completed search
    //! is repeated after the filter. A search that was cancelled or failed is
    //! not, and a newer search request waiting for its turn replaces it.
    override void applyViewFilter(LogFilter!wchar filter)
    {
        if (sourceLost)
            return;
        _pendingViewFilter = PendingRequest(filter, true);
        // _searchFilter: the running or completed search (see the
        // OperationFinished handler)
        if (!_pendingSearch.requested && _searchFilter !is null)
            _pendingSearch = PendingRequest(_searchFilter, true);
        if (_running == Operation.BuildFilterIndex || _running == Operation.BuildSearchIndex)
            _index.cancelCurrentOperation();
        startPending();
    }

    //! @brief Rebuilds the search view with `filter`. If an operation is
    //! running, the request waits for it; a running search is cancelled first.
    override void applySearchFilter(LogFilter!wchar filter)
    {
        if (sourceLost)
            return;
        _pendingSearch = PendingRequest(filter, true);
        if (_running == Operation.BuildSearchIndex)
            _index.cancelCurrentOperation();
        startPending();
    }

    override const(LogFilter!wchar) searchFilter()
    {
        return _searchFilter;
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
            if (_index.runBuildFilterIndex(filter, Anchors(_anchors))) // snapshot for the worker
            {
                _viewFilter = filter;
                _running = Operation.BuildFilterIndex;
            }
        }
        else if (_pendingSearch.requested)
        {
            auto filter = _pendingSearch.filter;
            _pendingSearch = PendingRequest.init;
            if (_index.runBuildSearchIndex(filter, Anchors(_anchors))) // snapshot for the worker
            {
                _searchFilter = filter;
                _running = Operation.BuildSearchIndex;
            }
        }
    }

    //! @brief Sets or clears the anchor of a message. An anchored message is
    //! always listed in the main view and in the search results; the views are
    //! updated in place.
    //! @param index - message index in the file (DocumentItem.realIndex)
    //! @return true if done; refused (nothing changed) as busy while an
    //! operation is running, since the operation works on a snapshot of the
    //! anchors and is building the indexes, and when the source is lost or the
    //! index is out of range; as limit when there is no room for another anchor
    override AnchorChange setAnchor(size_t index, bool value)
    {
        if (_running != Operation.None || sourceLost || index >= _index.messageCount)
            return AnchorChange(AnchorRefusal.busy);
        if (_anchors.has(index) == value)
            return AnchorChange.init;
        if (!_anchors.set(index, value))
            return AnchorChange(AnchorRefusal.limit);

        _index.updateAnchor(index, value, _viewFilter, _searchFilter);
        return AnchorChange.init;
    }

    override bool anchorsFull() const
    {
        return _anchors.length == Anchors.MaxAnchors;
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

    //! @brief Whether the search found `item`, a message the search view lists:
    //! an anchored message is listed there whether it matches or not, so it is
    //! matched again (anchors are few); any other one was found
    private bool searchFound(ref const(DocumentItem) item) const
    {
        if (_searchFilter is null)
            return false; // no search, or it left no results
        return !item.anchored || _searchFilter.matches(item.message);
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
            if (!this.outer._index.fetchMainViewItem(index, item))
                return false;
            item.anchored = this.outer._anchors.has(item.realIndex);
            size_t position;
            item.found = this.outer.searchFound(item) // no lookup without a search
                && this.outer._index.searchViewPositionOf(item.realIndex, position);
            return true;
        }

        override bool positionOf(size_t realIndex, out size_t position)
        {
            return this.outer._index.mainViewPositionOf(realIndex, position);
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
            if (!this.outer._index.fetchSearchViewItem(index, item))
                return false;
            item.anchored = this.outer._anchors.has(item.realIndex);
            item.found = this.outer.searchFound(item);
            return true;
        }

        override bool positionOf(size_t realIndex, out size_t position)
        {
            return this.outer._index.searchViewPositionOf(realIndex, position);
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
    import formats.dlt.testing_utils : buildDltMessage;
    import formats.dlt.fields : ecuId;

    private string writeTestDlt(string name, size_t messageCount, const(char)[4] ecuId = "ECU1")
    {
        import std.file : write, tempDir;
        import std.path : buildPath;

        ubyte[] data;
        foreach (i; 0 .. messageCount)
            data ~= buildDltMessage(ecuId, cast(uint) i, 0, 0, cast(ubyte) i, [0xAA, 0xBB]);

        auto path = buildPath(tempDir(), name);
        write(path, data);
        return path;
    }

    /// Filter of the main view by the ECU ID of DLT messages
    private LogFilter!wchar ecuFilter(string ecuId)
    {
        import formats.dlt.format : DltFormat;
        import log_core.rule_filter : Check, Condition, FilterRule, FilterSet, RuleFilter;

        FilterSet set;
        set.rules = [FilterRule("", FilterRule.init.kind, true, "",
                [Condition("ecu", Check.Equals, ecuId)])];
        return RuleFilter.compile(new DltFormat().columns, [set]);
    }

    /// What the views of a document show, as its operation events tell (the
    /// machines of the UI see the same). Subscribed when made: make it before
    /// the events are dispatched.
    private final class Views
    {
        enum State
        {
            NotReady, // its index isn't built: loading, or the build was cancelled
            Ready,
            Building,
            Failed,
        }

        State main; // NotReady: the file is loading
        State search = State.Ready; // an empty result until a search runs

        /// @param main - what the main view shows now: Ready for a loaded document
        this(Document doc, State main = State.NotReady)
        {
            this.main = main;
            doc.events.subscribe((const OperationStarted e) { stateOf(e.operation) = State.Building; });
            doc.events.subscribe((const OperationFinished e) {
                stateOf(e.operation) = e.result == OperationFinished.Result.Completed ? State.Ready
                    : e.result == OperationFinished.Result.Cancelled ? State.NotReady : State.Failed;
            });
        }

        bool mainReady() const { return main == State.Ready; }
        bool searchReady() const { return search == State.Ready; }

        private ref State stateOf(Document.Operation operation) return
        {
            return isSearchOperation(operation) ? search : main;
        }
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

        bool matches(scope ref const(LogMessage!wchar) item) const
        {
            return _result;
        }

        Nullable!uint matchIndex(scope ref const(LogMessage!wchar) item) const
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

@("LogDocument: opening reports Started, Progress, Finished in order")
unittest
{
    import std.file : remove;

    enum messageCount = 2000;
    auto path = writeTestDlt("dlt_document_events.dlt", messageCount);
    scope (exit)
        remove(path);

    auto doc = new LogDocument(path);

    string[] log;
    float lastProgress = -1;
    OperationFinished finished;
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
        // Finished is published after the slot is idle: the index is complete
        countOnFinish = doc.mainView.itemsCount;
        log ~= "finished";
    });

    dispatchUntil(doc, () => log.length > 0 && log[$ - 1] == "finished");

    assert(log == ["started", "progress", "finished"], "unexpected event order");
    assert(finished.operation == Document.Operation.BuildOffsetIndex);
    assert(finished.result == OperationFinished.Result.Completed);
    assert(lastProgress == 1.0f, "last progress event must report completion");
    assert(countOnFinish == messageCount);
}

@("LogDocument: destroy while indexing cancels and joins the worker")
unittest
{
    import std.file : remove;
    import core.time : MonoTime, seconds;

    auto path = writeTestDlt("dlt_document_destroy.dlt", 200_000);
    scope (exit)
        remove(path);

    auto doc = new LogDocument(path);
    const start = MonoTime.currTime;
    destroy(doc); // must cancel the running BuildOffsetIndex, not wait for it or crash
    assert(MonoTime.currTime - start < 1.seconds, "destroy must not wait for indexing to complete");
}

@("LogDocument: a search requested while loading waits for the load, latest request wins")
unittest
{
    import std.file : remove;

    enum messageCount = 2000;
    auto path = writeTestDlt("dlt_document_deferred.dlt", messageCount);
    scope (exit)
        remove(path);

    auto doc = new LogDocument(path);

    auto views = new Views(doc);
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
    assert(views.searchReady);
    assert(doc.searchView.itemsCount == messageCount, "the latest (match-all) search must have run");
}

@("LogDocument: a new search cancels the running one and replaces it")
unittest
{
    import std.algorithm : count;
    import std.file : remove;

    enum messageCount = 200_000;
    auto path = writeTestDlt("dlt_document_restart.dlt", messageCount);
    scope (exit)
        remove(path);

    auto doc = new LogDocument(path);

    auto views = new Views(doc);
    string[] log;
    doc.events.subscribe((const OperationStarted e) {
        import std.conv : to;
        log ~= e.operation.to!string ~ " started";
    });
    doc.events.subscribe((const OperationFinished e) {
        import std.conv : to;
        log ~= e.operation.to!string ~ " " ~ e.result.to!string;
    });
    dispatchUntil(doc, () => views.mainReady);

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

@("LogDocument: requestCancel stops a running search")
unittest
{
    import std.file : remove;

    auto path = writeTestDlt("dlt_document_cancel.dlt", 200_000);
    scope (exit)
        remove(path);

    auto doc = new LogDocument(path);

    auto views = new Views(doc);
    OperationFinished[] finished;
    doc.events.subscribe((const OperationFinished e) { finished ~= e; });
    dispatchUntil(doc, () => views.mainReady);
    finished = null;

    doc.applySearchFilter(new ConstFilter(true));
    assert(doc.requestCancel(), "a running search must be cancellable");

    dispatchUntil(doc, () => finished.length > 0);

    assert(finished.length == 1);
    assert(finished[0].operation == Document.Operation.BuildSearchIndex);
    assert(finished[0].result == OperationFinished.Result.Cancelled,
        "search must stop at the next batch, not complete");
    assert(views.search == Views.State.NotReady, "cancelled search leaves the view not ready");
    assert(views.mainReady, "main view is not affected");
    assert(!doc.requestCancel(), "nothing left to cancel");
}

@("LogDocument: requestCancel drops pending requests but not the file load")
unittest
{
    import std.file : remove;

    enum messageCount = 2000;
    auto path = writeTestDlt("dlt_document_cancel_pending.dlt", messageCount);
    scope (exit)
        remove(path);

    auto doc = new LogDocument(path);

    auto views = new Views(doc);
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
    assert(views.mainReady && doc.mainView.itemsCount == messageCount);
}

@("LogDocument: resetFilter (null filter) clears the result instead of crashing")
unittest
{
    import std.file : remove;

    enum messageCount = 2000;
    auto path = writeTestDlt("dlt_document_reset.dlt", messageCount);
    scope (exit)
        remove(path);

    auto doc = new LogDocument(path);

    auto views = new Views(doc);
    OperationFinished[] finished;
    doc.events.subscribe((const OperationFinished e) { finished ~= e; });
    dispatchUntil(doc, () => finished.length == 1); // file loaded

    doc.applySearchFilter(new ConstFilter(true));
    dispatchUntil(doc, () => finished.length == 2);
    assert(doc.searchView.itemsCount == messageCount);

    // Before the fix the worker called matches() on a null filter and crashed
    doc.searchView.resetFilter();
    dispatchUntil(doc, () => finished.length == 3);
    assert(finished[2].operation == Document.Operation.BuildSearchIndex);
    assert(finished[2].result == OperationFinished.Result.Completed);
    assert(views.searchReady && doc.searchView.itemsCount == 0, "search result must be empty");

    doc.mainView.resetFilter();
    dispatchUntil(doc, () => finished.length == 4);
    assert(finished[3].operation == Document.Operation.BuildFilterIndex);
    assert(finished[3].result == OperationFinished.Result.Completed);
    assert(views.mainReady);
    assert(!doc.mainView.isFilterEnabled, "reset filter shows the unfiltered view");
    assert(doc.mainView.itemsCount == messageCount, "all messages are visible");
}

@("LogDocument: applyViewFilter filters the main view")
unittest
{
    import std.file : remove;

    enum messageCount = 2000;
    auto path = writeTestDlt("dlt_document_view_filter.dlt", messageCount);
    scope (exit)
        remove(path);

    auto doc = new LogDocument(path);

    auto views = new Views(doc);
    size_t finished;
    doc.events.subscribe((const OperationFinished e) { ++finished; });
    dispatchUntil(doc, () => finished == 1);

    DocumentItem item;

    doc.applyViewFilter(ecuFilter("ECU2"));
    dispatchUntil(doc, () => finished == 2);
    assert(views.mainReady && doc.mainView.isFilterEnabled, "a built filter is applied to the view");
    assert(doc.mainView.itemsCount == 0, "no message has ECU2");
    assert(!doc.mainView.fetchItem(0, item));

    doc.applyViewFilter(ecuFilter("ECU1"));
    dispatchUntil(doc, () => finished == 3);
    assert(doc.mainView.itemsCount == messageCount, "every message has ECU1");
    assert(doc.mainView.fetchItem(messageCount - 1, item) && item.realIndex == messageCount - 1);
    assert(!doc.mainView.fetchItem(messageCount, item), "position past the filtered view");

    doc.mainView.resetFilter();
    dispatchUntil(doc, () => finished == 4);
    assert(!doc.mainView.isFilterEnabled && doc.mainView.itemsCount == messageCount);
}

@("LogDocument: an ECU ID padded with spaces is found by its trimmed value")
unittest
{
    import std.file : remove;

    enum messageCount = 100;
    // Real logs pad short IDs with a space instead of '\0', e.g. "CU7 "
    auto path = writeTestDlt("dlt_document_ecu_padding.dlt", messageCount, "CU7 ");
    scope (exit)
        remove(path);

    auto doc = new LogDocument(path);

    size_t finished;
    doc.events.subscribe((const OperationFinished e) { ++finished; });
    dispatchUntil(doc, () => finished == 1);

    DocumentItem item;
    assert(doc.mainView.fetchItem(0, item));
    assert(item._message.ecuId == "CU7"w, "the padding must not be part of the ID");

    doc.applyViewFilter(ecuFilter("CU7"));
    dispatchUntil(doc, () => finished == 2);
    assert(doc.mainView.itemsCount == messageCount, "typing the visible ID must find the messages");
}

version (unittest)
{
    /// Opens a test document and waits until it is loaded
    private LogDocument openLoaded(string name, size_t messageCount, out string path)
    {
        path = writeTestDlt(name, messageCount);
        auto doc = new LogDocument(path);
        auto views = new Views(doc);
        dispatchUntil(doc, () => views.mainReady);
        return doc;
    }

    /// Runs a filter/search request and waits until the document is idle:
    /// a filter may be followed by the search it repeats
    private void runAndWait(LogDocument doc, void delegate() request)
    {
        request();
        waitIdle(doc);
    }

    /// Waits until no operation runs or waits for its turn. The next request
    /// starts from the Finished handler of the previous one, during the same
    /// dispatch, so an idle slot after a dispatch means nothing is left.
    private void waitIdle(LogDocument doc)
    {
        dispatchUntil(doc, () => doc._running == Document.Operation.None);
    }

    /// Operations started since recordStarted()
    private final class StartedLog
    {
        Document.Operation[] operations;
    }

    private StartedLog recordStarted(LogDocument doc)
    {
        auto log = new StartedLog;
        doc.events.subscribe((const OperationStarted e) { log.operations ~= e.operation; });
        return log;
    }

    private size_t[] realIndexes(DocumentView view)
    {
        size_t[] result;
        DocumentItem item;
        foreach (i; 0 .. view.itemsCount)
        {
            assert(view.fetchItem(i, item));
            result ~= item.realIndex;
        }
        return result;
    }
}

@("LogDocument anchors: listed in the empty search view and marked in rows")
unittest
{
    import std.file : remove;

    string path;
    auto doc = openLoaded("dlt_document_anchors.dlt", 100, path);
    scope (exit)
        remove(path);

    assert(doc.searchView.itemsCount == 0);
    assert(doc.setAnchor(10, true) && doc.setAnchor(5, true));
    assert(realIndexes(doc.searchView) == [5, 10], "anchors are listed in order without a search");

    DocumentItem item;
    assert(doc.searchView.fetchItem(0, item) && item.anchored);
    assert(doc.mainView.fetchItem(5, item) && item.anchored);
    assert(doc.mainView.fetchItem(6, item) && !item.anchored);

    assert(doc.setAnchor(5, false));
    assert(realIndexes(doc.searchView) == [10]);
    assert(doc.mainView.fetchItem(5, item) && !item.anchored);
}

@("LogDocument anchors: an anchored message is shown despite the filter and the search")
unittest
{
    import std.file : remove;

    enum messageCount = 100;
    string path;
    auto doc = openLoaded("dlt_document_anchors_filter.dlt", messageCount, path);
    scope (exit)
        remove(path);

    // The view filter hides every message (they all have ECU1)
    runAndWait(doc, () => doc.applyViewFilter(ecuFilter("ECU2")));
    assert(doc.mainView.itemsCount == 0);

    assert(doc.setAnchor(7, true));
    assert(realIndexes(doc.mainView) == [7], "anchored message is in the filtered view");
    assert(realIndexes(doc.searchView) == [7]);

    // A search that matches nothing still lists the anchor
    runAndWait(doc, () => doc.applySearchFilter(new ConstFilter(false)));
    assert(realIndexes(doc.searchView) == [7]);

    // Without the anchor the message matches neither the filter nor the search
    assert(doc.setAnchor(7, false));
    assert(doc.mainView.itemsCount == 0 && doc.searchView.itemsCount == 0);

    // A message that matches by itself stays when its anchor is removed
    runAndWait(doc, () => doc.mainView.resetFilter());
    runAndWait(doc, () => doc.applySearchFilter(new ConstFilter(true)));
    assert(doc.setAnchor(3, true) && doc.setAnchor(3, false));
    assert(doc.searchView.itemsCount == messageCount);
    assert(doc.mainView.itemsCount == messageCount);
}

@("LogDocument anchors: a new filter keeps the anchors in both views")
unittest
{
    import std.file : remove;

    string path;
    auto doc = openLoaded("dlt_document_anchors_refilter.dlt", 100, path);
    scope (exit)
        remove(path);

    assert(doc.setAnchor(42, true) && doc.setAnchor(8, true));
    runAndWait(doc, () => doc.applyViewFilter(ecuFilter("ECU2")));

    assert(realIndexes(doc.mainView) == [8, 42]);
    assert(realIndexes(doc.searchView) == [8, 42], "the cleared search lists the anchors");
}

@("LogDocument: a new filter repeats the completed search over the filtered view")
unittest
{
    import std.file : remove;

    enum messageCount = 2000;
    string path;
    auto doc = openLoaded("dlt_document_refilter_search.dlt", messageCount, path);
    auto views = new Views(doc, Views.State.Ready); // loaded
    scope (exit)
        remove(path);

    runAndWait(doc, () => doc.applySearchFilter(new ConstFilter(true)));
    assert(doc.searchView.itemsCount == messageCount);

    auto started = recordStarted(doc);
    runAndWait(doc, () => doc.applyViewFilter(ecuFilter("ECU2")));
    assert(started.operations == [Document.Operation.BuildFilterIndex, Document.Operation.BuildSearchIndex],
        "the search must be repeated after the filter");
    assert(views.searchReady && doc.searchView.itemsCount == 0, "the search runs over the filtered view");

    runAndWait(doc, () => doc.mainView.resetFilter());
    assert(views.searchReady && doc.searchView.itemsCount == messageCount,
        "the search follows the reset of the filter as well");
}

@("LogDocument: a search running when the filter changes is repeated after the filter")
unittest
{
    import std.algorithm : count;
    import std.file : remove;

    enum messageCount = 200_000;
    string path;
    auto doc = openLoaded("dlt_document_refilter_running.dlt", messageCount, path);
    auto views = new Views(doc, Views.State.Ready); // loaded
    scope (exit)
        remove(path);

    auto started = recordStarted(doc);
    doc.applySearchFilter(new ConstFilter(true)); // starts right away
    runAndWait(doc, () => doc.mainView.resetFilter()); // cancels it

    // Usually the first search is Cancelled; on a very fast run it completes
    // first. Either way it is repeated after the filter.
    assert(started.operations.count(Document.Operation.BuildSearchIndex) == 2, "the search must be repeated");
    assert(started.operations[$ - 1] == Document.Operation.BuildSearchIndex);
    assert(views.searchReady && doc.searchView.itemsCount == messageCount);
}

@("LogDocument: a cancelled search is not repeated by a new filter")
unittest
{
    import std.file : remove;

    string path;
    auto doc = openLoaded("dlt_document_refilter_cancelled.dlt", 200_000, path);
    auto views = new Views(doc, Views.State.Ready); // loaded
    scope (exit)
        remove(path);

    doc.applySearchFilter(new ConstFilter(true));
    assert(doc.requestCancel());
    waitIdle(doc);
    assert(views.search == Views.State.NotReady, "the search must be cancelled");

    auto started = recordStarted(doc);
    runAndWait(doc, () => doc.mainView.resetFilter());
    assert(started.operations == [Document.Operation.BuildFilterIndex], "the user cancelled the search");
}

@("LogDocument: cancelling the filter drops the search it would repeat")
unittest
{
    import std.file : remove;

    string path;
    auto doc = openLoaded("dlt_document_refilter_cancel_filter.dlt", 200_000, path);
    auto views = new Views(doc, Views.State.Ready); // loaded
    scope (exit)
        remove(path);

    runAndWait(doc, () => doc.applySearchFilter(new ConstFilter(false)));
    assert(views.searchReady);

    auto started = recordStarted(doc);
    doc.applyViewFilter(ecuFilter("ECU1"));
    assert(doc.requestCancel(), "a running filter must be cancellable");
    waitIdle(doc);
    assert(started.operations == [Document.Operation.BuildFilterIndex],
        "there is nothing to search in until the view is filtered");
}

@("LogDocument anchors: can't be changed while an operation runs")
unittest
{
    import std.file : remove;

    auto path = writeTestDlt("dlt_document_anchors_busy.dlt", 200_000);
    scope (exit)
        remove(path);

    auto doc = new LogDocument(path);

    auto views = new Views(doc);
    assert(!doc.setAnchor(1, true), "not while the file loads");
    dispatchUntil(doc, () => views.mainReady);

    bool searched;
    doc.events.subscribe((const OperationFinished e) { searched = true; });
    doc.applySearchFilter(new ConstFilter(true));
    assert(!doc.setAnchor(1, true), "not while searching");
    assert(doc.exportAnchors.length == 0, "a refused change leaves the anchors as they were");

    dispatchUntil(doc, () => searched);
    assert(doc.setAnchor(1, true), "allowed again once the search is done");
}

@("LogDocument anchors: a refusal tells why; a running operation comes before the limit")
unittest
{
    import domain.anchors : Anchors;
    import std.file : remove;

    auto path = writeTestDlt("dlt_document_anchors_reason.dlt", 200_000);
    scope (exit)
        remove(path);

    auto doc = new LogDocument(path);
    auto views = new Views(doc);
    assert(doc.setAnchor(1, true).refusal == AnchorRefusal.busy, "the file loads");
    dispatchUntil(doc, () => views.mainReady);

    foreach (i; 0 .. Anchors.MaxAnchors)
        assert(doc.setAnchor(i, true).refusal == AnchorRefusal.none);
    assert(doc.setAnchor(100, true).refusal == AnchorRefusal.limit);

    doc.applySearchFilter(new ConstFilter(true));
    assert(doc.setAnchor(100, true).refusal == AnchorRefusal.busy,
        "full and searching: the search refuses it, removing one wouldn't help");
    assert(doc.setAnchor(0, false).refusal == AnchorRefusal.busy);
    assert(doc.setAnchor(1_000_000, true).refusal == AnchorRefusal.busy, "out of range");
    assert(doc.requestCancel());
    waitIdle(doc);
}

@("LogDocument anchors: the limit is enforced silently")
unittest
{
    import domain.anchors : Anchors;
    import std.file : remove;

    string path;
    auto doc = openLoaded("dlt_document_anchors_limit.dlt", 100, path);
    auto views = new Views(doc, Views.State.Ready); // loaded
    scope (exit)
        remove(path);

    foreach (i; 0 .. Anchors.MaxAnchors)
    {
        assert(!doc.anchorsFull, "room for one more");
        assert(doc.setAnchor(i, true));
    }
    assert(doc.anchorsFull);
    assert(!doc.setAnchor(50, true), "over the limit");
    assert(doc.searchView.itemsCount == Anchors.MaxAnchors);

    assert(!doc.setAnchor(1000, true), "out of range");
    assert(doc.setAnchor(0, false) && !doc.anchorsFull, "room again after removing one");
    assert(doc.setAnchor(50, true) && doc.anchorsFull);
}

version (Posix)
{
    /// Simulates a removed disk: pages of a mapped file past its new end
    /// raise the same fault as a lost medium
    private void truncateFile(string path)
    {
        import core.sys.posix.unistd : truncate;
        import std.string : toStringz;

        assert(truncate(path.toStringz, 0) == 0);
    }

    @("LogDocument: a lost file is reported once and the document stops working")
    unittest
    {
        import std.file : remove;

        string path;
        auto doc = openLoaded("dlt_document_lost.dlt", 2000, path);
        scope (exit)
            remove(path);

        size_t lostEvents, started;
        doc.events.subscribe((const SourceLost e) { ++lostEvents; });
        doc.events.subscribe((const OperationStarted e) { ++started; });

        DocumentItem item;
        assert(doc.mainView.fetchItem(1000, item), "readable before the loss");

        truncateFile(path);
        assert(!doc.mainView.fetchItem(1000, item), "a message read as zeros is not returned");
        assert(doc.sourceLost);

        doc.dispatchEvents();
        doc.dispatchEvents();
        assert(lostEvents == 1, "reported once");

        doc.applySearchFilter(new ConstFilter(true));
        doc.dispatchEvents();
        assert(started == 0, "requests are ignored");
        assert(!doc.setAnchor(5, true));
    }

    @("LogDocument: losing the file while loading fails the load")
    unittest
    {
        import std.file : remove;

        auto path = writeTestDlt("dlt_document_lost_loading.dlt", 500_000);
        scope (exit)
            remove(path);

        auto doc = new LogDocument(path);
        auto views = new Views(doc);
        bool truncated, lost;
        OperationFinished finished;
        bool done;
        // Truncated from the first progress report: the load is surely still running
        doc.events.subscribe((const OperationProgress e) {
            if (!truncated)
            {
                truncateFile(path);
                truncated = true;
            }
        });
        doc.events.subscribe((const SourceLost e) { lost = true; });
        doc.events.subscribe((const OperationFinished e) { finished = e; done = true; });

        dispatchUntil(doc, () => done && lost);

        assert(truncated);
        assert(finished.result == OperationFinished.Result.Failed, "the load can't complete");
        assert(finished.error == LogIndex.sourceLostText());
        assert(lost, "SourceLost is published");
        assert(views.main == Views.State.Failed);
    }
}

@("LogDocument: messages after garbage are indexed at their own offset")
unittest
{
    import formats.dlt.testing_utils : buildDltMessage;
    import std.file : remove, tempDir, write;
    import std.path : buildPath;

    auto first = buildDltMessage("ECU1", 1, 0, 0, 1, [0x01]);
    auto second = buildDltMessage("ECU2", 2, 0, 0, 2, [0x02]);
    ubyte[] garbage = [0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA, 0xF9];
    auto path = buildPath(tempDir(), "dlt_document_garbage.dlt");
    write(path, first ~ garbage ~ second);
    scope (exit)
        remove(path);

    auto doc = new LogDocument(path);

    auto views = new Views(doc);
    dispatchUntil(doc, () => views.mainReady);
    assert(doc.mainView.itemsCount == 2);

    DocumentItem item;
    assert(doc.mainView.fetchItem(1, item), "the offset points at the message, not the garbage");
    assert(item._message.ecuId == "ECU2"w);
}

@("LogDocument: knows the format it was opened with")
unittest
{
    import formats.dlt.format : DltFormat;
    import std.file : remove;

    auto path = writeTestDlt("dlt_document_format.dlt", 3);
    scope (exit)
        remove(path);
    auto doc = new LogDocument(path);
    scope (exit)
        doc.destroy();

    assert(cast(const(DltFormat)) doc.format !is null);
    assert(doc.format.columns is doc.columns);
}

@("LogDocument: opens in a format chosen before, and tells which one it opened with")
unittest
{
    import formats.logcat : logcatFormatInfo;
    import formats.plain_text : PlainTextFormat, plainTextFormatInfo;
    import std.file : remove, tempDir, write;
    import std.path : buildPath;

    auto path = buildPath(tempDir(), "dlt_document_choice.log");
    write(path, "11-03 14:22:01.123  1234  1250 I Tag: text\n");
    scope (exit)
        remove(path);

    auto detected = new LogDocument(path);
    scope (exit)
        detected.destroy();
    assert(detected.formatChoice.id == logcatFormatInfo.id, "detected");

    const asText = FormatChoice(plainTextFormatInfo.id);
    auto chosen = new LogDocument(path, asText);
    scope (exit)
        chosen.destroy();
    assert(cast(const(PlainTextFormat)) chosen.format !is null, "the choice wins over detection");
    assert(chosen.formatChoice == asText);

    auto unset = new LogDocument(path, FormatChoice.init);
    scope (exit)
        unset.destroy();
    assert(unset.formatChoice.id == logcatFormatInfo.id, "no choice: detected");

    // A choice this build can't make (a newer build's format, a broken settings
    // file) must not lock the file out: it is detected instead
    foreach (bad; [FormatChoice("no-such-format"), FormatChoice(logcatFormatInfo.id, 99)])
    {
        auto fallback = new LogDocument(path, bad);
        scope (exit)
            fallback.destroy();
        assert(fallback.formatChoice.id == logcatFormatInfo.id, bad.id);
        assert(fallback.formatChoice.variant != 99, bad.id);
    }
}

@("LogDocument: opening a missing file throws instead of crashing")
unittest
{
    import std.exception : assertThrown;

    // The constructor fails before the background slot is constructed; the
    // field destructors run on the unconstructed slot and must cope with it
    assertThrown(new LogDocument("/nonexistent/dlt_document_missing.dlt"));
}

@("LogDocument: positionOf finds a message in the filtered main view")
unittest
{
    import std.file : remove, tempDir, write;
    import std.path : buildPath;

    enum messageCount = 100;
    ubyte[] data; // even messages from ECU1, odd ones from ECU2
    foreach (i; 0 .. messageCount)
        data ~= buildDltMessage(i % 2 ? "ECU2" : "ECU1", cast(uint) i, 0, 0, cast(ubyte) i, [0xAA]);
    auto path = buildPath(tempDir(), "dlt_document_position_of.dlt");
    write(path, data);
    scope (exit)
        remove(path);

    auto doc = new LogDocument(path);

    auto views = new Views(doc);
    dispatchUntil(doc, () => views.mainReady);

    size_t position;
    assert(doc.mainView.positionOf(42, position) && position == 42, "unfiltered: the message index");
    assert(!doc.mainView.positionOf(messageCount, position), "past the end of the log");

    runAndWait(doc, () => doc.applyViewFilter(ecuFilter("ECU2")));
    assert(doc.mainView.positionOf(1, position) && position == 0);
    assert(doc.mainView.positionOf(43, position) && position == 21);
    assert(!doc.mainView.positionOf(42, position), "hidden by the filter");
    assert(!doc.mainView.positionOf(messageCount + 1, position), "past the end of the log");

    runAndWait(doc, () => doc.applySearchFilter(ecuFilter("ECU2")));
    assert(doc.searchView.positionOf(43, position) && position == 21);
    assert(!doc.searchView.positionOf(42, position), "not found by the search");
}

@("LogDocument: the messages the search found are marked in both views, an anchor only if it matches")
unittest
{
    import std.algorithm : any;
    import std.file : remove, tempDir, write;
    import std.path : buildPath;

    enum messageCount = 20;
    ubyte[] data; // even messages from ECU1, odd ones from ECU2
    foreach (i; 0 .. messageCount)
        data ~= buildDltMessage(i % 2 ? "ECU2" : "ECU1", cast(uint) i, 0, 0, cast(ubyte) i, [0xAA]);
    auto path = buildPath(tempDir(), "dlt_document_found.dlt");
    write(path, data);
    scope (exit)
        remove(path);

    auto doc = new LogDocument(path);
    auto views = new Views(doc);
    dispatchUntil(doc, () => views.mainReady);

    bool[] foundIn(DocumentView view)
    {
        bool[] result;
        DocumentItem item;
        foreach (i; 0 .. view.itemsCount)
        {
            assert(view.fetchItem(i, item));
            result ~= item.found;
        }
        return result;
    }

    bool[] expected;
    foreach (i; 0 .. messageCount)
        expected ~= i % 2 == 1;

    assert(!foundIn(doc.mainView).any, "no search: nothing is found");

    assert(doc.setAnchor(4, true) && doc.setAnchor(5, true));
    runAndWait(doc, () => doc.applySearchFilter(ecuFilter("ECU2")));
    assert(foundIn(doc.mainView) == expected, "the anchored 4 doesn't match, the anchored 5 does");
    assert(realIndexes(doc.searchView)[0 .. 3] == [1, 3, 4]);
    assert(foundIn(doc.searchView)[0 .. 4] == [true, true, false, true], "4 is listed by its anchor only");

    // Over a filtered main view
    runAndWait(doc, () => doc.applyViewFilter(ecuFilter("ECU1")));
    assert(realIndexes(doc.mainView) == [0, 2, 4, 5, 6, 8, 10, 12, 14, 16, 18]);
    assert(foundIn(doc.mainView) == [false, false, false, true, false, false, false, false, false, false, false]);

    runAndWait(doc, () => doc.searchView.resetFilter());
    assert(!foundIn(doc.mainView).any && !foundIn(doc.searchView).any, "the search is cleared");
}

@("LogDocument: a new search doesn't take the results of the previous one for its own")
unittest
{
    import std.file : remove;

    string path;
    auto doc = openLoaded("dlt_document_found_new_search.dlt", 1000, path);
    scope (exit)
        remove(path);

    runAndWait(doc, () => doc.applySearchFilter(new ConstFilter(true)));
    DocumentItem item;
    assert(doc.mainView.fetchItem(1, item) && item.found);

    // Right after the request, before the worker ran: the old results are gone
    doc.applySearchFilter(new ConstFilter(false));
    assert(doc.mainView.fetchItem(1, item) && !item.found, "found by the previous search only");
    waitIdle(doc);
    assert(doc.mainView.fetchItem(1, item) && !item.found);
}

@("LogDocument: after a cancelled search nothing is found, the anchors are only listed")
unittest
{
    import std.file : remove;

    string path;
    auto doc = openLoaded("dlt_document_found_cancelled.dlt", 200_000, path);
    auto views = new Views(doc, Views.State.Ready); // loaded
    scope (exit)
        remove(path);

    assert(doc.setAnchor(7, true));
    doc.applySearchFilter(new ConstFilter(true)); // would match every message
    assert(doc.requestCancel());
    waitIdle(doc);
    assert(views.search == Views.State.NotReady, "the search must be cancelled");

    DocumentItem item;
    // An anchor set and cleared after the cancel doesn't stay as a result
    assert(doc.setAnchor(9, true) && doc.setAnchor(9, false));
    assert(doc.mainView.fetchItem(9, item) && !item.found, "the cancelled search found nothing");

    // A new filter doesn't repeat the cancelled search: the results list the anchor only
    runAndWait(doc, () => doc.mainView.resetFilter());
    assert(realIndexes(doc.searchView) == [7]);
    assert(doc.searchView.fetchItem(0, item) && item.anchored && !item.found);
    assert(doc.mainView.fetchItem(7, item) && item.anchored && !item.found);
}
