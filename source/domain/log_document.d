//! LogDocument: a log file opened in a format (chosen before or detected) with the
//! descriptions of the choice if it takes them, its main and search views over its
//! indexes, the filter, search and format requests given to the passes of the index (a
//! format replaced keeps the records and builds the views again), the operations they
//! run as its events tell them, and its anchors.
module domain.log_document;

import domain.document;
import domain.document_item;
import domain.document_id;

import log_core.log_message;
import log_core.log_filter;

import domain.anchors;
import domain.attachments : Attachment, AttachmentState;
import domain.log_index;
import domain.index.record_store : RecordsLease;
import formats.registry : createFormat, detectFormat, takesDescriptions, withDescriptions;
import log_core.byte_source;
import log_core.log_format : ColumnInfo, FormatChoice, LogFormat;

import utils.lock_guard;

import utils.event_bus.event_bus_async : EventBusAsync;
import utils.event_bus.event_bus_interface : SignalConsumer;
import utils.ui_text : UiText, uiTextOf;

//! A log document: a log of any format with its main and search views
class LogDocument : Document
{
    private MainDocumentView _mainView;
    private SearchDocumentView _searchView;

    private LogFilter!wchar _viewFilter;
    private LogFilter!wchar _searchFilter;
    private Anchors _anchors;

    private FormatChoice _formatChoice;
    private UiText _descriptionsProblem; // why the descriptions of the choice weren't taken
    // A format asked for (replaceFormat), given to the index once no pass runs: a request of
    // its own, which a cancel of the filter or the search doesn't drop
    private LogFormat _pendingFormat;
    private FormatChoice _pendingChoice; // of the format asked for: told with it

    private EventBusAsync _events; // must outlive _index: its worker publishes here
    private LogIndex _index;

    //! A filter request waiting for the running pass to stop. Only the
    //! latest request of each kind is kept; `filter` may be null (reset).
    private struct PendingRequest
    {
        LogFilter!wchar filter;
        bool requested;
    }

    private PendingRequest _pendingViewFilter;
    private PendingRequest _pendingSearch;
    // A pass of the index runs, as seen from the UI thread: cleared when its
    // PassFinished is dispatched (the slot is idle by then)
    private bool _passRunning;
    // The operations started and not finished yet: they overlap, see the
    // events in domain.document
    private bool _loading = true;
    private bool _filtering;
    private bool _searching;
    private bool _failed; // the index can't be brought up to date: nothing more is asked of it
    private bool _loadCompleted; // the load reached the end of the source once
    private UiText _failure; // why the document is done for: its load or a later pass failed
    // The user asked to stop it: told when the pass it stopped ends
    private bool _cancelFilter;
    private bool _cancelSearch;
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
        const descriptions = choice.descriptions;
        if (format is null)
            format = detectFormat(path, source.data, choice);
        choice.descriptions = descriptions; // not detected: kept for the format detected too
        // Descriptions a format takes but that can't be read leave the log decoded without
        // them, the choice keeps them so the next open tries again; a format that takes none
        // (a log detected anew) isn't named descriptions
        UiText problem;
        if (descriptions.length && !takesDescriptions(format))
            choice.descriptions = null;
        else if (descriptions.length)
        {
            try
                format = withDescriptions(format, descriptions);
            catch (Exception e)
                problem = uiTextOf(e);
        }
        this(source, format);
        _formatChoice = choice;
        _descriptionsProblem = problem;
    }

    override FormatChoice formatChoice() const pure nothrow @nogc
    {
        return _formatChoice;
    }

    override UiText descriptionsProblem() const
    {
        return _descriptionsProblem;
    }

    override void replaceFormat(LogFormat format, string descriptions)
    {
        FormatChoice choice = _formatChoice;
        choice.descriptions = descriptions;
        if (sourceLost || _failed)
        {
            // Nothing to decode: a Retry opens the file by the choice
            _formatChoice = choice;
            _descriptionsProblem = UiText.init;
            _events.publish(FormatReplaced(false));
            return;
        }
        // The choice goes with the format, once it is replaced: formatChoice never names
        // descriptions the records aren't decoded by
        _pendingFormat = format;
        _pendingChoice = choice;
        applyPending();
    }

    //! @param source - owned by the document from now on
    this(ByteSource source, LogFormat format)
    {
        _events = new EventBusAsync();
        // Subscribed before anyone else: the document is up to date before
        // external subscribers see the events that follow
        _events.subscribe((const PassFinished e) { passFinished(e); });
        // The file is loaded, or filtered, while the pass goes on with a search
        _events.subscribe((const StageFinished e) { finish(e.operation, OperationFinished.Result.Completed); });
        // Before the index starts its first pass, so it precedes any progress event
        _events.publish(OperationStarted(Operation.BuildOffsetIndex));
        _index = LogIndex(source, format, _events); // starts the pass that loads the file
        _passRunning = true;
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
            dropPendingFormat();
            _events.publish(SourceLost());
        }
        _events.dispatch();
        // A source that got more bytes since the last pass (a file being
        // written, a stream): the next pass takes them
        startPassIfBehind();
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

    override RecordsLease leaseRecords()
    {
        return _index.leaseRecords;
    }

    override DocumentState state()
    {
        auto state = _index.state;
        state.loaded = _loadCompleted;
        state.sourceLost = sourceLost;
        state.error = _failure;
        return state;
    }

    override Attachment[] attachments()
    {
        return _index.attachments;
    }

    override ulong writeAttachment(size_t id, scope void delegate() begin, scope void delegate(const(ubyte)[] bytes) write)
    {
        return _index.writeAttachment(id, begin, write);
    }

    //! @brief Rebuilds the main view with `filter`. A pass that runs is stopped
    //! first and goes on with the request: the file goes on loading, with the
    //! filter over what is loaded and then over every part loaded after.
    //! The search runs over the main view, so the running or completed search
    //! is repeated with the filter. A search that was cancelled or failed is
    //! not, and a newer search request waiting for its turn replaces it.
    override void applyViewFilter(LogFilter!wchar filter)
    {
        if (sourceLost || _failed)
            return;
        _pendingViewFilter = PendingRequest(filter, true);
        applyPending();
    }

    //! @brief Rebuilds the search view with `filter`, over what the main view
    //! shows and then over every row it gets after. A pass that runs is
    //! stopped first and goes on with the request.
    override void applySearchFilter(LogFilter!wchar filter)
    {
        if (sourceLost || _failed)
            return;
        _pendingSearch = PendingRequest(filter, true);
        applyPending();
    }

    override const(LogFilter!wchar) searchFilter()
    {
        return _searchFilter;
    }

    //! @brief Gives the pending requests to the index and starts a pass: the
    //! view filter first, since the search runs over the (filtered) main view.
    //! While a pass runs it is only asked to stop: its PassFinished comes here.
    private void applyPending()
    {
        if (!_pendingViewFilter.requested && !_pendingSearch.requested && _pendingFormat is null)
            return;
        if (_passRunning)
        {
            _index.cancelCurrentOperation();
            return;
        }

        // The format first: the views are built again by it, in this same call, so that no
        // cancel of the filter comes between and leaves them built by the format of before
        if (_pendingFormat !is null)
        {
            _index.replaceFormat(_pendingFormat);
            _pendingFormat = null;
            _formatChoice = _pendingChoice;
            _descriptionsProblem = UiText.init; // asked for: not those of the open any more
            rebuildViews(true);
            _events.publish(FormatReplaced(true));
        }

        if (_pendingViewFilter.requested)
        {
            auto filter = _pendingViewFilter.filter;
            _pendingViewFilter = PendingRequest.init;
            // _searchFilter: the running or completed search. Its results go
            // with the view it ran over
            if (!_pendingSearch.requested && _searchFilter !is null)
                _pendingSearch = PendingRequest(_searchFilter, true);
            finish(Operation.BuildSearchIndex, OperationFinished.Result.Cancelled);
            finish(Operation.BuildFilterIndex, OperationFinished.Result.Cancelled); // replaced before its end
            _index.setViewFilter(filter, Anchors(_anchors)); // a snapshot for the worker
            _viewFilter = filter;
            _searchFilter = null;
            start(Operation.BuildFilterIndex);
        }
        if (_pendingSearch.requested)
        {
            auto filter = _pendingSearch.filter;
            _pendingSearch = PendingRequest.init;
            finish(Operation.BuildSearchIndex, OperationFinished.Result.Cancelled); // replaced before its end
            _index.setSearchFilter(filter, Anchors(_anchors));
            _searchFilter = filter;
            start(Operation.BuildSearchIndex);
        }
        startPassIfBehind();
        // Nothing to bring up to date (no record, no row to search): no pass
        // would tell their end
        if (!_passRunning)
        {
            finish(Operation.BuildFilterIndex, OperationFinished.Result.Completed);
            finish(Operation.BuildSearchIndex, OperationFinished.Result.Completed);
        }
    }

    //! Starts a pass of the index if it has something to bring up to date
    private void startPassIfBehind()
    {
        if (_passRunning || _failed || sourceLost || !_index.behind)
            return;
        _passRunning = _index.runPass();
    }

    private ref bool running(Operation operation) return
    {
        final switch (operation)
        {
        case Operation.BuildOffsetIndex:
            return _loading;
        case Operation.BuildFilterIndex:
            return _filtering;
        case Operation.BuildSearchIndex:
            return _searching;
        case Operation.None:
            assert(false);
        }
    }

    private void start(Operation operation)
    {
        running(operation) = true;
        _events.publish(OperationStarted(operation));
    }

    //! Reports the end of `operation`, if it runs
    private void finish(Operation operation, OperationFinished.Result result, UiText error = UiText.init)
    {
        if (!running(operation))
            return;
        running(operation) = false;
        _loadCompleted |= operation == Operation.BuildOffsetIndex && result == OperationFinished.Result.Completed;
        _events.publish(OperationFinished(operation, result, error));
    }

    //! A search that didn't complete leaves no results: nothing is found, and
    //! a new filter doesn't repeat it
    private void dropSearch(OperationFinished.Result result, UiText error = UiText.init)
    {
        if (!_searching)
            return;
        _index.stopSearch();
        _searchFilter = null;
        finish(Operation.BuildSearchIndex, result, error);
    }

    //! @brief A pass of the index ended: tells the end of the operations it
    //! ran, then goes on with what waits. A pass stopped for a request reports
    //! nothing: its operations go on in the next one.
    private void passFinished(const PassFinished e)
    {
        alias Result = OperationFinished.Result;

        _passRunning = false;
        const bool cancelFilter = _cancelFilter, cancelSearch = _cancelSearch;
        _cancelFilter = false;
        _cancelSearch = false;

        final switch (e.result)
        {
        case Result.Completed:
            // The file first: the views are told it is whole before their own end
            finish(Operation.BuildOffsetIndex, Result.Completed);
            finish(Operation.BuildFilterIndex, Result.Completed);
            finish(Operation.BuildSearchIndex, Result.Completed);
            break;
        case Result.Cancelled:
            if (cancelFilter && _filtering)
            {
                dropSearch(Result.Cancelled);
                _index.stopViewFilter(); // the view keeps what was found, incomplete
                finish(Operation.BuildFilterIndex, Result.Cancelled);
            }
            else if (cancelSearch)
                dropSearch(Result.Cancelled);
            break;
        case Result.Failed:
            UiText error = e.error;
            // A search that failed leaves the file and the main view as they
            // are; a filter that failed stops the search over its view too.
            // Whatever else is running goes on with the next pass
            if (e.failed == Operation.BuildSearchIndex)
            {
                dropSearch(Result.Failed, error);
                break;
            }
            if (e.failed == Operation.BuildFilterIndex)
            {
                dropSearch(Result.Failed, error);
                _index.stopViewFilter(); // the view keeps what was found, incomplete
                finish(Operation.BuildFilterIndex, Result.Failed, error);
                break;
            }
            // The source can't be taken to its end (the load, or what it got
            // later): the document is done for
            _failed = true;
            _failure = error;
            _pendingViewFilter = PendingRequest.init;
            _pendingSearch = PendingRequest.init;
            dropPendingFormat();
            finish(Operation.BuildOffsetIndex, Result.Failed, error);
            dropSearch(Result.Failed, error);
            if (_filtering)
            {
                _index.stopViewFilter();
                finish(Operation.BuildFilterIndex, Result.Failed, error);
            }
            break;
        }

        applyPending();
        startPassIfBehind(); // a pass stopped for a request, or to drop the search, goes on
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
        if (_passRunning || sourceLost || index >= _index.messageCount)
            return AnchorChange(AnchorRefusal.busy);
        if (_anchors.has(index) == value)
            return AnchorChange.init;
        if (!_anchors.set(index, value))
            return AnchorChange(AnchorRefusal.limit);

        _index.updateAnchor(index, value, Anchors(_anchors));
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

    //! The views list the anchored messages: they are built again with them
    void importAnchors(const(size_t[]) anchors)
    {
        _anchors.importAnchors(anchors);
        if (sourceLost || _failed)
            return;
        rebuildViews(false);
        applyPending();
    }

    //! The file can't be read any more: a format asked for has nothing to decode, its choice
    //! is taken at once, as replaceFormat does for a document lost before, so a Retry opens
    //! the file by it
    private void dropPendingFormat()
    {
        if (_pendingFormat is null)
            return;
        _pendingFormat = null;
        _formatChoice = _pendingChoice;
        _descriptionsProblem = UiText.init;
        _events.publish(FormatReplaced(false));
    }

    //! @brief Asks for the views to be built again as they are: the filter (and the search it
    //! repeats), or the search only. A filter asked for already builds both
    //! @param main - the main view too when it has no filter: its rows are read anew
    private void rebuildViews(bool main)
    {
        if (_pendingViewFilter.requested)
            return;
        if (main || _viewFilter !is null)
            _pendingViewFilter = PendingRequest(_viewFilter, true);
        else if (!_pendingSearch.requested)
            _pendingSearch = PendingRequest(_searchFilter, true);
    }

    override bool requestCancel(Operation operation)
    {
        const bool filter = operation == Operation.BuildFilterIndex;
        if (!filter && operation != Operation.BuildSearchIndex)
            return false; // the load is not cancelled

        _pendingSearch = PendingRequest.init; // a search goes with the view it would run over
        if (filter)
        {
            _pendingViewFilter = PendingRequest.init;
            // A filter that runs with the load isn't stopped: the main view
            // would be left incomplete while the file still loads
            if (!_filtering || _loading)
                return false;
            _cancelFilter = true;
        }
        else
        {
            if (!_searching)
                return false;
            _cancelSearch = true;
        }
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

        override bool nearestPositionOf(size_t realIndex, out size_t position)
        {
            return this.outer._index.mainViewNearestPositionOf(realIndex, position);
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

        override bool nearestPositionOf(size_t realIndex, out size_t position)
        {
            return this.outer._index.searchViewNearestPositionOf(realIndex, position);
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

    /// DLT messages whose seconds are their index
    private ubyte[] testDlt(size_t messageCount, const(char)[4] ecuId = "ECU1")
    {
        ubyte[] data;
        foreach (i; 0 .. messageCount)
            data ~= buildDltMessage(ecuId, cast(uint) i, 0, 0, cast(ubyte) i, [0xAA, 0xBB]);
        return data;
    }

    private string writeTestDlt(string name, size_t messageCount, const(char)[4] ecuId = "ECU1")
    {
        import std.file : write, tempDir;
        import std.path : buildPath;

        auto path = buildPath(tempDir(), name);
        write(path, testDlt(messageCount, ecuId));
        return path;
    }

    /// Bytes in memory: all of them at once, or written in parts (a source being written).
    /// Tells when it is closed; lost when the test says so
    private final class MemorySource : ByteSource
    {
        private ubyte[] _room;
        private shared size_t _length;
        private bool _complete;
        private shared bool _closed;
        shared bool isLost;

        /// All the bytes there will be
        this(const(ubyte)[] data)
        {
            _room = data.dup;
            _length = data.length;
            _complete = true;
        }

        /// None yet, `room` of them at most: write() gives them
        this(size_t room)
        {
            _room = new ubyte[room];
        }

        void write(string text)
        {
            import core.atomic : atomicLoad, atomicStore;

            assert(!_complete);
            const length = atomicLoad(_length);
            _room[length .. length + text.length] = cast(const(ubyte)[]) text;
            atomicStore(_length, length + text.length);
        }

        bool closed() const
        {
            import core.atomic : atomicLoad;

            return atomicLoad(_closed);
        }

        override const(ubyte)[] data() const pure nothrow @nogc
        {
            import core.atomic : atomicLoad;

            return _room[0 .. atomicLoad(_length)];
        }

        override bool complete() const nothrow @nogc { return _complete; }

        override bool lost() const nothrow @nogc
        {
            import core.atomic : atomicLoad;

            return atomicLoad(isLost);
        }

        override void close() nothrow @nogc
        {
            import core.atomic : atomicStore;

            atomicStore(_closed, true);
        }
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

    /// Accepts every message; holds the threads that ask it about the messages
    /// from `held` on (of writeTestDlt: its seconds are its index) until it is
    /// opened: what is being built with it stays unfinished meanwhile, with
    /// the blocks before that message done. It opens itself after 10 seconds: a
    /// test that never opens it fails instead of hanging
    private final class GateFilter : LogFilter!wchar
    {
        import std.typecons : Nullable;

        private size_t _held;
        private shared bool _open;
        private shared bool _reached;

        this(size_t held)
        {
            _held = held;
        }

        void open()
        {
            import core.atomic : atomicStore;

            atomicStore(_open, true);
        }

        /// A thread was held by it
        bool reached() const
        {
            import core.atomic : atomicLoad;

            return atomicLoad(_reached);
        }

        bool matches(scope ref const(LogMessage!wchar) item) const
        {
            import core.atomic : atomicLoad, atomicStore;
            import core.thread : Thread;
            import core.time : MonoTime, msecs, seconds;
            import formats.dlt.fields : timestampSeconds;

            if (item.timestampSeconds < _held)
                return true;
            atomicStore(*cast(shared(bool)*) &_reached, true);
            const deadline = MonoTime.currTime + 10.seconds;
            while (!atomicLoad(_open) && MonoTime.currTime < deadline)
                Thread.sleep(1.msecs);
            return true;
        }

        Nullable!uint matchIndex(scope ref const(LogMessage!wchar) item) const
        {
            return Nullable!uint(0);
        }

        immutable(LogFilter!wchar) idup() const pure
        {
            assert(false);
        }

        LogFilter!wchar dup() const pure
        {
            assert(false);
        }
    }

    /// Fails on the first message it is asked about
    private final class FailingFilter : LogFilter!wchar
    {
        import std.typecons : Nullable;

        bool matches(scope ref const(LogMessage!wchar) item) const
        {
            throw new Exception("the filter is broken");
        }

        Nullable!uint matchIndex(scope ref const(LogMessage!wchar) item) const
        {
            return Nullable!uint.init;
        }

        immutable(LogFilter!wchar) idup() const pure
        {
            assert(false);
        }

        LogFilter!wchar dup() const pure
        {
            assert(false);
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
        const progress = e.of(Document.Operation.BuildOffsetIndex);
        assert(progress >= lastProgress, "progress must not go backwards");
        lastProgress = progress;
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

@("LogDocument: records leased are read on another thread after the document is closed, a scan of them stops")
unittest
{
    import core.atomic : atomicLoad, atomicStore;
    import core.thread : Thread;
    import core.time : MonoTime, seconds;
    import domain.index.match_scan : scanMatches;
    import formats.dlt.format : DltFormat;

    enum messageCount = 200_000;
    auto source = new MemorySource(testDlt(messageCount));
    auto doc = new LogDocument(source, new DltFormat());
    auto views = new Views(doc);
    dispatchUntil(doc, () => views.mainReady);
    assert(views.mainReady);

    auto lease = doc.leaseRecords();
    assert(lease.records.length == messageCount);
    // The scan reads a few blocks, then its threads wait at message 50000 until the
    // document is closed; they read on to their next check after it
    auto gate = new GateFilter(50_000);
    size_t delivered;
    shared bool completed = true;
    auto reader = new Thread({
        Anchors anchors;
        const all = scanMatches!uint(lease.records, 0, lease.records.length, (size_t p) => p, gate, anchors,
            () => false,
            (size_t done, const(uint)[] found) { delivered = done; return true; });
        atomicStore(completed, all);
    });
    reader.start();
    const held = MonoTime.currTime + 10.seconds;
    while (!gate.reached && MonoTime.currTime < held)
        Thread.yield();
    assert(gate.reached, "the scan never got to the gate");

    const start = MonoTime.currTime;
    destroy(doc); // the reader waits at the gate meanwhile: closing must not wait for it
    assert(MonoTime.currTime - start < 1.seconds, "closing the document waited for the lease");
    assert(!source.closed, "the records are leased");
    assert(lease.closing);

    gate.open(); // the held blocks read records of the closed document
    reader.join();
    assert(!atomicLoad(completed) && delivered < messageCount, "the scan went on after the document closed");
    assert(!source.closed, "the lease is still held");
    destroy(lease);
    assert(source.closed, "the last lease closes the records");
}

@("LogDocument: its state tells what was loaded, the end of the load and its failure")
unittest
{
    import formats.dlt.format : DltFormat;

    enum messageCount = 1000;
    const data = testDlt(messageCount);
    auto doc = new LogDocument(new MemorySource(data), new DltFormat());
    scope (exit)
        destroy(doc);
    auto views = new Views(doc);
    dispatchUntil(doc, () => views.mainReady);
    const loaded = doc.state;
    assert(loaded.loaded && loaded.error.empty && !loaded.sourceLost);
    assert(loaded.records == messageCount && loaded.records == doc.leaseRecords.records.length);
    assert(loaded.loadedBytes == data.length && loaded.totalBytes == data.length);

    // A pass after the load fails: the file is lost while a filter runs
    auto laterSource = new MemorySource(data);
    auto later = new LogDocument(laterSource, new DltFormat());
    scope (exit)
        destroy(later);
    auto laterViews = new Views(later);
    dispatchUntil(later, () => laterViews.mainReady);
    auto gate = new GateFilter(0);
    later.applyViewFilter(gate);
    dispatchUntil(later, () => gate.reached);
    laterSource.isLost = true;
    gate.open();
    dispatchUntil(later, () => laterViews.main == Views.State.Failed);
    const failedLater = later.state;
    assert(failedLater.loaded, "the load was over before");
    assert(failedLater.sourceLost && !failedLater.error.empty, "the document is done for");

    auto source = new MemorySource(data);
    source.isLost = true; // its disk is gone before the load
    auto lost = new LogDocument(source, new DltFormat());
    scope (exit)
        destroy(lost);
    auto lostViews = new Views(lost);
    dispatchUntil(lost, () => lostViews.main == Views.State.Failed);
    const failed = lost.state;
    assert(!failed.loaded && failed.sourceLost && !failed.error.empty);
    assert(failed.records == 0 && failed.loadedBytes == 0);
}

@("LogDocument: a search and a filter requested while loading run with the load, latest request wins")
unittest
{
    import std.algorithm : count, countUntil;
    import std.file : remove;

    enum messageCount = 200_000;
    auto path = writeTestDlt("dlt_document_with_load.dlt", messageCount);
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

    // They arrive while the file loads: the load goes on with them, only the
    // latest of each kind runs
    doc.applySearchFilter(new ConstFilter(false));
    doc.applySearchFilter(new ConstFilter(true));
    doc.applyViewFilter(ecuFilter("ECU1"));

    dispatchUntil(doc, () => log.length > 0 && log[$ - 1] == "BuildSearchIndex Completed");

    assert(log == [
        "BuildOffsetIndex started", "BuildFilterIndex started", "BuildSearchIndex started",
        "BuildOffsetIndex Completed", "BuildFilterIndex Completed", "BuildSearchIndex Completed"
    ], "unexpected operations order");
    assert(views.mainReady && views.searchReady);
    assert(doc.mainView.itemsCount == messageCount, "every message has ECU1");
    assert(doc.searchView.itemsCount == messageCount, "the latest (match-all) search must have run");
}

@("LogDocument: a view gets its rows while the file loads, a search over them too")
unittest
{
    import std.file : remove;

    enum messageCount = 400_000;
    auto path = writeTestDlt("dlt_document_rows_with_load.dlt", messageCount);
    scope (exit)
        remove(path);

    auto doc = new LogDocument(path);
    auto views = new Views(doc);
    // Held after the first part of the file: the load can't end meanwhile
    auto search = new GateFilter(100_000);
    scope (exit)
        search.open(); // a failed test must not leave the worker held
    doc.applySearchFilter(search);

    dispatchUntil(doc, () => doc.searchView.itemsCount > 0);
    const mainRows = doc.mainView.itemsCount, foundRows = doc.searchView.itemsCount;
    doc.dispatchEvents();
    assert(!views.mainReady, "the file is still loading");
    assert(mainRows > 0 && mainRows < messageCount, "the main view shows nothing until the file is loaded");
    assert(foundRows > 0 && foundRows < messageCount, "the search waits for the end of the load");

    search.open();
    dispatchUntil(doc, () => views.mainReady && views.searchReady);
    assert(doc.searchView.itemsCount == messageCount);
}

@("LogDocument: a filter that runs with the load of the file can't be cancelled, a search can")
unittest
{
    import std.file : remove;

    enum messageCount = 400_000;
    auto path = writeTestDlt("dlt_document_cancel_with_load.dlt", messageCount);
    scope (exit)
        remove(path);

    auto doc = new LogDocument(path);
    auto views = new Views(doc);
    auto started = recordStarted(doc);
    auto filter = new GateFilter(1000); // held in the first part of the file
    scope (exit)
        filter.open();
    doc.applyViewFilter(filter);
    doc.applySearchFilter(new ConstFilter(true));
    dispatchUntil(doc, () => started.operations.length == 3);

    assert(!doc.requestCancel(Document.Operation.BuildOffsetIndex), "the load is not cancelled");
    assert(!doc.requestCancel(Document.Operation.BuildFilterIndex),
        "the main view would be left incomplete while the file loads");
    assert(doc.requestCancel(Document.Operation.BuildSearchIndex));
    filter.open();
    dispatchUntil(doc, () => views.mainReady);
    waitIdle(doc);
    assert(doc.mainView.itemsCount == messageCount, "the load and the filter went on");
    assert(views.search == Views.State.NotReady && doc.searchFilter is null, "the search alone was cancelled");
}

@("LogDocument: a search cancelled while a filter runs leaves the filter running")
unittest
{
    import std.file : remove;

    enum messageCount = 200_000;
    string path;
    auto doc = openLoaded("dlt_document_cancel_search_only.dlt", messageCount, path);
    auto views = new Views(doc, Views.State.Ready); // loaded
    scope (exit)
        remove(path);

    auto started = recordStarted(doc);
    auto filter = new GateFilter(1000);
    scope (exit)
        filter.open();
    doc.applyViewFilter(filter);
    doc.applySearchFilter(new ConstFilter(true));
    dispatchUntil(doc, () => started.operations.length == 2);

    assert(doc.requestCancel(Document.Operation.BuildSearchIndex));
    filter.open();
    waitIdle(doc);
    assert(views.mainReady && doc.mainView.itemsCount == messageCount, "the filter must complete");
    assert(views.search == Views.State.NotReady && doc.searchView.itemsCount == 0);
}

@("LogDocument: a filter or a search that fails leaves the file as it is")
unittest
{
    import std.file : remove;

    enum messageCount = 2000;
    string path;
    auto doc = openLoaded("dlt_document_stage_failed.dlt", messageCount, path);
    auto views = new Views(doc, Views.State.Ready); // loaded
    scope (exit)
        remove(path);

    runAndWait(doc, () => doc.applySearchFilter(new FailingFilter()));
    assert(views.search == Views.State.Failed && views.mainReady);
    assert(doc.searchView.itemsCount == 0 && doc.searchFilter is null, "a failed search leaves no results");

    runAndWait(doc, () => doc.applyViewFilter(new FailingFilter()));
    assert(views.main == Views.State.Failed);

    // The document goes on working
    runAndWait(doc, () => doc.applyViewFilter(null));
    runAndWait(doc, () => doc.applySearchFilter(new ConstFilter(true)));
    assert(views.mainReady && views.searchReady);
    assert(doc.mainView.itemsCount == messageCount && doc.searchView.itemsCount == messageCount);
}

@("LogDocument: a filter that fails while the file loads doesn't stop the load")
unittest
{
    import std.algorithm : canFind;
    import std.file : remove;

    enum messageCount = 400_000;
    auto path = writeTestDlt("dlt_document_filter_failed_with_load.dlt", messageCount);
    scope (exit)
        remove(path);

    auto doc = new LogDocument(path);
    string[] log;
    doc.events.subscribe((const OperationFinished e) {
        import std.conv : to;
        log ~= e.operation.to!string ~ " " ~ e.result.to!string;
    });
    doc.applyViewFilter(new FailingFilter());

    dispatchUntil(doc, () => log.canFind("BuildOffsetIndex Completed") || log.canFind("BuildOffsetIndex Failed"));
    assert(log.canFind("BuildFilterIndex Failed"), "the filter must fail");
    assert(log.canFind("BuildOffsetIndex Completed"), "the file must load: the user can change the filters");
    assert(doc.messageCount == messageCount);

    runAndWait(doc, () => doc.applyViewFilter(null));
    assert(doc.mainView.itemsCount == messageCount);
}

@("LogDocument: a source that gets more is followed: the views grow, a growth is told")
unittest
{
    import formats.plain_text : PlainTextFormat;
    import log_core.search_filter : SearchChip, SearchFilter;

    auto source = new MemorySource(1024);
    source.write("one seven\ntwo\n");
    auto doc = new LogDocument(source, new PlainTextFormat());
    auto views = new Views(doc);
    size_t grown;
    doc.events.subscribe((const ContentGrown e) { ++grown; });
    dispatchUntil(doc, () => views.mainReady);

    doc.applyViewFilter(SearchFilter.fromChips([SearchChip("seven")]));
    waitIdle(doc);
    doc.applySearchFilter(SearchFilter.fromChips([SearchChip("five")]));
    waitIdle(doc);
    assert(doc.messageCount == 2 && doc.mainView.itemsCount == 1 && doc.searchView.itemsCount == 0);

    Document.Operation[] started;
    doc.events.subscribe((const OperationStarted e) { started ~= e.operation; });
    source.write("three seven five\nfour five\n");
    dispatchUntil(doc, () => doc.messageCount == 4 && !doc._passRunning);
    doc.dispatchEvents();
    assert(realIndexes(doc.mainView) == [0, 2] && realIndexes(doc.searchView) == [2]);
    assert(grown >= 1, "the views are told to count their rows");
    assert(started.length == 0, "no operation: the views stay ready");
    assert(views.mainReady && views.searchReady);
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
    assert(doc.requestCancel(Document.Operation.BuildSearchIndex), "a running search must be cancellable");

    dispatchUntil(doc, () => finished.length > 0);

    assert(finished.length == 1);
    assert(finished[0].operation == Document.Operation.BuildSearchIndex);
    assert(finished[0].result == OperationFinished.Result.Cancelled,
        "search must stop at the next batch, not complete");
    assert(views.search == Views.State.NotReady, "cancelled search leaves the view not ready");
    assert(views.mainReady, "main view is not affected");
    assert(!doc.requestCancel(Document.Operation.BuildSearchIndex), "nothing left to cancel");
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

    doc.applySearchFilter(new ConstFilter(true)); // waits for the pass that loads to stop
    assert(!doc.requestCancel(Document.Operation.BuildSearchIndex), "loading the file is not cancellable");

    dispatchUntil(doc, () => finished.length > 0);
    // A pending search would start when the pass ends (passFinished); its
    // Started is delivered by the next dispatch
    doc.dispatchEvents();

    assert(finished.length == 1 && finished[0].result == OperationFinished.Result.Completed,
        "the load must complete");
    assert(started == [Document.Operation.BuildOffsetIndex], "the pending search must be dropped");
    assert(views.mainReady && doc.mainView.itemsCount == messageCount);
}

@("LogDocument: a null filter clears the result instead of crashing")
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
    doc.applySearchFilter(null);
    dispatchUntil(doc, () => finished.length == 3);
    assert(finished[2].operation == Document.Operation.BuildSearchIndex);
    assert(finished[2].result == OperationFinished.Result.Completed);
    assert(views.searchReady && doc.searchView.itemsCount == 0, "search result must be empty");

    doc.applyViewFilter(ecuFilter("ECU2")); // hides every message
    dispatchUntil(doc, () => finished.length == 4);
    assert(doc.mainView.itemsCount == 0);

    doc.applyViewFilter(null);
    dispatchUntil(doc, () => finished.length == 5);
    assert(finished[4].operation == Document.Operation.BuildFilterIndex);
    assert(finished[4].result == OperationFinished.Result.Completed);
    assert(views.mainReady);
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

    doc.applyViewFilter(ecuFilter("ECU1"));
    dispatchUntil(doc, () => finished == 2);
    assert(doc.mainView.itemsCount == messageCount, "every message has ECU1");
    assert(doc.mainView.fetchItem(messageCount - 1, item) && item.realIndex == messageCount - 1);
    assert(!doc.mainView.fetchItem(messageCount, item), "position past the filtered view");

    doc.applyViewFilter(ecuFilter("ECU2"));
    dispatchUntil(doc, () => finished == 3);
    assert(views.mainReady, "a built filter is applied to the view");
    assert(doc.mainView.itemsCount == 0, "no message has ECU2");
    assert(!doc.mainView.fetchItem(0, item));

    // From a view that shows nothing: the reset shows every message again
    doc.applyViewFilter(null);
    dispatchUntil(doc, () => finished == 4);
    assert(doc.mainView.itemsCount == messageCount, "the unfiltered view");
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

    /// Waits until no pass runs and the end of its operations was told
    private void waitIdle(LogDocument doc)
    {
        dispatchUntil(doc, () => !doc._passRunning);
        // The end of a pass is told by the document: delivered by the next
        // dispatch, where a pass that goes on may start
        doc.dispatchEvents();
        dispatchUntil(doc, () => !doc._passRunning);
        doc.dispatchEvents();
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
    runAndWait(doc, () => doc.applyViewFilter(null));
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

    runAndWait(doc, () => doc.applyViewFilter(null));
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
    runAndWait(doc, () => doc.applyViewFilter(null)); // cancels it

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
    assert(doc.requestCancel(Document.Operation.BuildSearchIndex));
    waitIdle(doc);
    assert(views.search == Views.State.NotReady, "the search must be cancelled");

    auto started = recordStarted(doc);
    runAndWait(doc, () => doc.applyViewFilter(null));
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
    assert(doc.requestCancel(Document.Operation.BuildFilterIndex), "a running filter must be cancellable");
    waitIdle(doc);
    assert(started.operations == [Document.Operation.BuildFilterIndex, Document.Operation.BuildSearchIndex],
        "the search runs with the filter");
    assert(views.main == Views.State.NotReady && views.search == Views.State.NotReady, "both are cancelled");
    assert(doc.searchFilter is null, "the search is not repeated by the next filter");
}

@("LogDocument: a search asked for after a cancelled filter runs over what the view has")
unittest
{
    import std.file : remove;

    string path;
    auto doc = openLoaded("dlt_document_search_after_cancel.dlt", 200_000, path);
    auto views = new Views(doc, Views.State.Ready); // loaded
    scope (exit)
        remove(path);

    doc.applyViewFilter(ecuFilter("ECU1"));
    assert(doc.requestCancel(Document.Operation.BuildFilterIndex));
    waitIdle(doc);
    assert(views.main == Views.State.NotReady, "the filter must be cancelled");

    runAndWait(doc, () => doc.applySearchFilter(new ConstFilter(true)));
    assert(views.searchReady, "the search never ends");
    assert(doc.searchView.itemsCount == doc.mainView.itemsCount);
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
    assert(doc.requestCancel(Document.Operation.BuildSearchIndex));
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

@("LogDocument: a document of a source knows its format by the format, without a choice")
unittest
{
    import formats.plain_text : PlainTextFormat, plainTextFormatInfo;

    auto doc = new LogDocument(new MemorySource(16), new PlainTextFormat());
    scope (exit)
        doc.destroy();
    assert(!doc.formatChoice.isSet, "not opened from a file");
    assert(doc.formatInfo == plainTextFormatInfo, "its column layouts and filter files are those of text");
}

@("LogDocument: opening a missing file throws instead of crashing")
unittest
{
    import std.exception : assertThrown;

    // The constructor fails before the background slot is constructed; the
    // field destructors run on the unconstructed slot and must cope with it
    assertThrown(new LogDocument("/nonexistent/dlt_document_missing.dlt"));
}

@("LogDocument: positionOf and nearestPositionOf find a message in the filtered main view")
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

    // The nearest row: of the message, or of the first one shown after it, else the last
    assert(doc.mainView.nearestPositionOf(43, position) && position == 21, "shown: its own row");
    assert(doc.mainView.nearestPositionOf(42, position) && position == 21, "hidden: the next one shown");
    assert(doc.mainView.nearestPositionOf(0, position) && position == 0);
    assert(doc.mainView.nearestPositionOf(messageCount + 5, position) && position == messageCount / 2 - 1,
        "past the end: the last row");

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

    runAndWait(doc, () => doc.applySearchFilter(null));
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
    assert(doc.requestCancel(Document.Operation.BuildSearchIndex));
    waitIdle(doc);
    assert(views.search == Views.State.NotReady, "the search must be cancelled");

    DocumentItem item;
    // An anchor set and cleared after the cancel doesn't stay as a result
    assert(doc.setAnchor(9, true) && doc.setAnchor(9, false));
    assert(doc.mainView.fetchItem(9, item) && !item.found, "the cancelled search found nothing");

    // A new filter doesn't repeat the cancelled search: the results list the anchor only
    runAndWait(doc, () => doc.applyViewFilter(null));
    assert(realIndexes(doc.searchView) == [7]);
    assert(doc.searchView.fetchItem(0, item) && item.anchored && !item.found);
    assert(doc.mainView.fetchItem(7, item) && item.anchored && !item.found);
}

@("LogDocument: the files sent in the log are listed by their start and written from their packets")
unittest
{
    import formats.dlt.testing_utils : VerboseArgs;
    import std.file : remove, tempDir, write;
    import std.path : buildPath;
    import utils.ui_text : UiTextException;

    ubyte[] data = buildDltMessage();
    data ~= VerboseArgs().str("FLST").u32(7).str("a.bin").u32(7).str("today").u32(3).u32(3).str("FLST").record();
    data ~= VerboseArgs().str("FLDA").u32(7).u32(1).raw([1, 2, 3]).str("FLDA").record();
    data ~= buildDltMessage();
    data ~= VerboseArgs().str("FLDA").u32(7).u32(2).raw([4, 5, 6]).str("FLDA").record();
    data ~= VerboseArgs().str("FLDA").u32(7).u32(3).raw([7, 0, 0]).str("FLDA").record();
    data ~= VerboseArgs().str("FLFI").u32(7).str("FLFI").record();
    data ~= VerboseArgs(false).str("FLDA").u32(9).u32(5).raw([1]).str("FLDA").record(); // its start is not in the log
    data ~= VerboseArgs().str("FLST").u32(8).str("empty").u32(0).str("today").u32(0).u32(3).str("FLST").record();
    data ~= VerboseArgs().str("FLFI").u32(8).str("FLFI").record();
    const path = buildPath(tempDir(), "dlt_document_attachments.dlt");
    write(path, data);
    scope (exit)
        remove(path);

    auto doc = new LogDocument(path);
    auto views = new Views(doc);
    size_t changed;
    doc.events.subscribe((const AttachmentsChanged e) { ++changed; });
    dispatchUntil(doc, () => views.mainReady);
    assert(changed > 0, "the files were told");

    const list = doc.attachments();
    assert(list.length == 3);
    assert(list[0].id == 0 && list[0].name == "a.bin" && list[0].date == "today" && list[0].size == 7);
    assert(list[0].packets == 3 && list[0].inTurn == 3 && list[0].record == 1);
    assert(list[0].state == AttachmentState.complete);
    assert(list[1].name.length == 0 && list[1].serial == 9 && list[1].state == AttachmentState.incomplete);
    assert(list[2].name == "empty" && list[2].state == AttachmentState.complete);

    ubyte[] written;
    size_t begun;
    ulong writeOf(size_t id)
    {
        written = null;
        begun = 0;
        return doc.writeAttachment(id, () { ++begun; }, (const(ubyte)[] bytes) { written ~= bytes; });
    }

    assert(writeOf(0) == 7 && begun == 1);
    assert(written == [1, 2, 3, 4, 5, 6, 7], "cut at its size");
    assert(writeOf(2) == 0 && begun == 1, "a whole file of no bytes");

    bool refused(size_t id)
    {
        try
            writeOf(id);
        catch (UiTextException)
            return begun == 0;
        return false;
    }

    assert(refused(1), "nothing of it from its first packet");
    assert(refused(3), "no such attachment");
}

@("LogDocument: a log that sends no files tells no change of them")
unittest
{
    import std.file : remove;

    const path = writeTestDlt("dlt_document_no_attachments.dlt", 100);
    scope (exit)
        remove(path);
    auto doc = new LogDocument(path);
    auto views = new Views(doc);
    size_t changed;
    doc.events.subscribe((const AttachmentsChanged e) { ++changed; });
    dispatchUntil(doc, () => views.mainReady);
    waitIdle(doc);
    assert(changed == 0 && doc.attachments.length == 0);
}

@("LogDocument: decodes by the descriptions of its format choice, opens without them if they can't be read")
unittest
{
    import formats.dlt.fibex : Fibex, fibexOf, logFrame, textPdu;
    import formats.dlt.format : DltFormat, dltFormatInfo;
    import log_core.text_encoding : TextEncoding;
    import std.file : remove, tempDir, write;
    import std.path : buildPath;

    auto path = writeTestDlt("dlt_document_descriptions.dlt", 3);
    scope (exit)
        remove(path);
    const fibexPath = buildPath(tempDir(), "dlt_document_descriptions.xml");
    write(fibexPath, fibexOf(textPdu("P_T", "x"), logFrame("ID_1", "APP1", "CON1", "P_T")));
    scope (exit)
        remove(fibexPath);

    const choice = FormatChoice(dltFormatInfo.id, 0, TextEncoding.utf8, fibexPath);
    auto described = new LogDocument(path, choice);
    scope (exit)
        described.destroy();
    assert((cast(const(DltFormat)) described.format).fibex !is null, "decoded by the FIBEX");
    assert(described.formatChoice == choice && described.descriptionsProblem.empty);

    const missing = FormatChoice(dltFormatInfo.id, 0, TextEncoding.utf8, fibexPath ~ ".missing");
    auto without = new LogDocument(path, missing);
    scope (exit)
        without.destroy();
    assert((cast(const(DltFormat)) without.format).fibex is null, "opened without it");
    assert(without.formatChoice == missing, "kept: the next open tries again");
    assert(!without.descriptionsProblem.empty, "told why");

    // A choice this build can't make is detected again, its descriptions kept
    const unknown = FormatChoice("no-such-format", 0, TextEncoding.utf8, fibexPath);
    auto detected = new LogDocument(path, unknown);
    scope (exit)
        detected.destroy();
    assert((cast(const(DltFormat)) detected.format).fibex !is null);
    assert(detected.formatChoice.descriptions == fibexPath);
}

version (unittest)
{
    //! A DLT log of `count` non-verbose messages of ID 3 without extended header, written
    private string writeNonVerboseDlt(string name, size_t count)
    {
        import formats.dlt.testing_utils : BuildV1, bytesOf;
        import std.file : tempDir, write;
        import std.path : buildPath;

        BuildV1 r;
        r.extended = false;
        r.payload = bytesOf(3u);
        ubyte[] data;
        foreach (_; 0 .. count)
            data ~= r.bytes();
        auto path = buildPath(tempDir(), name);
        write(path, data);
        return path;
    }

    //! Filter of the main view by the AppId of DLT messages
    private LogFilter!wchar appFilter(string appId)
    {
        import formats.dlt.format : DltFormat;
        import log_core.rule_filter : Check, Condition, FilterRule, FilterSet, RuleFilter;

        FilterSet set;
        set.rules = [FilterRule("", FilterRule.init.kind, true, "", [Condition("app", Check.Equals, appId)])];
        return RuleFilter.compile(new DltFormat().columns, [set]);
    }

    //! The format of `doc` decoding by a FIBEX that describes message 3 as "Started" of APP1
    private LogFormat describedFormat(LogDocument doc)
    {
        import formats.dlt.fibex : fibexOf, logFrame, parseFibex, textPdu;
        import formats.dlt.format : withFibex;

        return withFibex(doc.format, parseFibex(fibexOf(textPdu("P_T", "Started"),
                logFrame("ID_3", "APP1", "CON1", "P_T"))));
    }
}

@("LogDocument.replaceFormat: the records decoded by the new format, the filter built again, the records kept")
unittest
{
    import std.file : remove;

    auto path = writeNonVerboseDlt("dlt_document_replace_format.dlt", 4);
    scope (exit)
        remove(path);
    auto doc = new LogDocument(path);
    scope (exit)
        doc.destroy();
    auto views = new Views(doc);
    dispatchUntil(doc, () => views.mainReady);
    runAndWait(doc, () => doc.applyViewFilter(appFilter("APP1")));
    assert(doc.mainView.itemsCount == 0, "no AppId before the FIBEX");

    FormatReplaced[] replaced;
    doc.events.subscribe((const FormatReplaced e) { replaced ~= e; });
    auto choice = doc.formatChoice;
    choice.descriptions = "/fibex/ecu.xml";
    auto described = describedFormat(doc);
    runAndWait(doc, () => doc.replaceFormat(described, choice.descriptions));

    assert(replaced == [FormatReplaced(true)], "told once, the records decoded anew");
    assert(doc.format is described && doc.formatChoice == choice, "the rest of the choice kept");
    assert(doc.messageCount == 4, "the records stay");
    assert(doc.mainView.itemsCount == 4, "the filter built again by the new decoding");
    DocumentItem item;
    assert(doc.mainView.fetchItem(0, item) && item._message.payloadText == "Started"w);
}

@("LogDocument.replaceFormat: asked while a filter runs and then cancelled, the format is replaced and the views built again")
unittest
{
    import std.file : remove;

    auto path = writeNonVerboseDlt("dlt_document_replace_running.dlt", 4);
    scope (exit)
        remove(path);
    auto doc = new LogDocument(path);
    scope (exit)
        doc.destroy();
    auto views = new Views(doc);
    dispatchUntil(doc, () => views.mainReady);

    auto gate = new GateFilter(0);
    doc.applyViewFilter(gate);
    dispatchUntil(doc, () => gate.reached);
    auto described = describedFormat(doc);
    auto choice = doc.formatChoice;
    choice.descriptions = "/fibex/ecu.xml";
    doc.replaceFormat(described, choice.descriptions); // waits for the pass
    assert(doc.formatChoice.descriptions.length == 0 && doc.format !is described,
        "the choice goes with the format: not before it is replaced");
    doc.requestCancel(Document.Operation.BuildFilterIndex);
    gate.open();
    waitIdle(doc);

    assert(doc.format is described && doc.formatChoice == choice, "the format is replaced all the same");
    DocumentItem item;
    assert(doc.mainView.fetchItem(0, item) && item._message.payloadText == "Started"w,
        "the rows are those of the new format");
}

@("LogDocument.replaceFormat: a document whose file is lost keeps its format, takes the choice")
unittest
{
    import formats.dlt.format : DltFormat;

    auto source = new MemorySource(testDlt(3));
    source.isLost = true;
    auto lost = new LogDocument(source, new DltFormat());
    scope (exit)
        destroy(lost);
    auto views = new Views(lost);
    dispatchUntil(lost, () => views.main == Views.State.Failed);

    FormatReplaced[] replaced;
    lost.events.subscribe((const FormatReplaced e) { replaced ~= e; });
    const before = lost.format;
    lost.replaceFormat(describedFormat(lost), "/fibex/ecu.xml");
    lost.dispatchEvents();
    assert(lost.format is before, "can't be read: nothing to decode");
    assert(lost.formatChoice.descriptions == "/fibex/ecu.xml", "a Retry opens it so");
    assert(replaced == [FormatReplaced(false)], "told: the choice changed, the records not decoded anew");
}

@("LogDocument.replaceFormat: with no filter the main view is read anew, a search is repeated by the new format")
unittest
{
    import formats.dlt.format : DltFormat;
    import log_core.rule_filter : Check, Condition, FilterRule, FilterSet, RuleFilter;
    import std.algorithm : canFind;
    import std.file : remove;

    auto path = writeNonVerboseDlt("dlt_document_replace_search.dlt", 4);
    scope (exit)
        remove(path);
    auto doc = new LogDocument(path);
    scope (exit)
        doc.destroy();
    auto views = new Views(doc);
    dispatchUntil(doc, () => views.mainReady);
    FilterSet set;
    set.rules = [FilterRule("", FilterRule.init.kind, true, "", [Condition("payload", Check.Contains, "Started")])];
    runAndWait(doc, () => doc.applySearchFilter(RuleFilter.compile(new DltFormat().columns, [set])));
    assert(doc.searchView.itemsCount == 0, "nothing found before the FIBEX");

    auto started = recordStarted(doc);
    runAndWait(doc, () => doc.replaceFormat(describedFormat(doc), "/fibex/ecu.xml"));
    assert(started.operations.canFind(Document.Operation.BuildFilterIndex),
        "the main view without a filter is built again: its rows, and those of the search view, read anew");
    assert(doc.searchView.itemsCount == 4, "the search repeated by the new decoding");
}

@("LogDocument.replaceFormat: a file lost while the format waits for the pass keeps the choice for a Retry")
unittest
{
    import formats.dlt.format : DltFormat;

    auto source = new MemorySource(testDlt(3));
    auto doc = new LogDocument(source, new DltFormat());
    scope (exit)
        destroy(doc);
    auto views = new Views(doc);
    dispatchUntil(doc, () => views.mainReady);
    auto gate = new GateFilter(0);
    doc.applyViewFilter(gate);
    dispatchUntil(doc, () => gate.reached);

    FormatReplaced[] replaced;
    doc.events.subscribe((const FormatReplaced e) { replaced ~= e; });
    const before = doc.format;
    doc.replaceFormat(describedFormat(doc), "/fibex/ecu.xml"); // waits for the pass
    source.isLost = true;
    gate.open();
    dispatchUntil(doc, () => views.main == Views.State.Failed);
    doc.dispatchEvents();
    assert(doc.format is before, "lost: nothing to decode");
    assert(doc.formatChoice.descriptions == "/fibex/ecu.xml", "a Retry opens it with the FIBEX");
    assert(replaced == [FormatReplaced(false)], "told: the choice changed, the records not decoded anew");
}

@("LogDocument: descriptions of a choice whose format takes none are dropped")
unittest
{
    import formats.plain_text : plainTextFormatInfo;
    import std.file : remove, tempDir, write;
    import std.path : buildPath;

    auto path = buildPath(tempDir(), "dlt_document_foreign_descriptions.log");
    write(path, "one\ntwo\n");
    scope (exit)
        remove(path);
    auto choice = FormatChoice(plainTextFormatInfo.id);
    choice.descriptions = "/fibex/ecu.xml";
    auto doc = new LogDocument(path, choice);
    scope (exit)
        doc.destroy();
    assert(doc.formatChoice.descriptions.length == 0, "a text log takes no FIBEX: not named for it");
    assert(doc.descriptionsProblem.empty);
}
