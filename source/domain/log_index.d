module domain.log_index;

import log_core.log_message;
import log_core.log_filter;
import log_core.log_format;
import log_core.byte_source;

import domain.index.offset_index;
import domain.index.filter_index;
import domain.index.search_index;
import domain.index.anchors;
import utils.background_slot;
import domain.document_item;
import domain.document : Document, OperationStarted, OperationProgress, OperationFinished;

import utils.event_bus.event_bus_interface : SignalProducer;

import utils.lock_guard;

import std.typecons;
import std.parallelism;
import std.algorithm.comparison : min;

import core.atomic : atomicLoad, atomicStore;
import core.stdc.stdint : uint16_t, uint32_t;
import core.sync.mutex : Mutex;

//import std.parallelism : Task;

// todo: better naming

alias Filter = LogFilter!wchar;
alias Message = LogMessage!wchar;

//! @brief Holds the data of a log and its indexes.
//! Responsible for:
//!   * Creating and maintaining indexes,
//!   * Updating indexes in the background and
//!     providing safe concurrent access to them from the GUI thread and the indexing thread.
//!
//! @brief This struct is not thread-safe. It is assumed that all access occurs
//! from the GUI thread only. It does, however, provide safe background index updates
//! and concurrent read access to the log content.
struct LogIndex
{
    private alias ScopedMutex = typeof(scoped!Mutex());

    private ByteSource _source; // log data, owned: closed by the destructor
    private LogFormat _format; // splits the data into records and decodes them
    private OffsetIndex _offsetIndex; // indecies of messages in the source file
    private FilterIndex _filterIndex; // indecies of messages that match the filter
    private SearchIndex _searchIndex; // indecies of messages that match the search
    private bool _viewIsFiltered = false; // filtered view is enabled

    //private Anchors _anchors; // anchors
    //private Filter _filter; // filter for filtered view
    //private Filter _searchFilter; // filter for search view

    //private shared bool _cancelFlag = false; // cancel current operation
    //private shared float _progress = 0.0f; // building index

    enum bunchSize = 32; // number of messages to process in one bunch

    alias Operation = Document.Operation;

    enum progressStep = 0.01f; // minimal progress change worth an event

    private BackgroundSlot _backgroundSlot;
    private ScopedMutex _mutex; // mutex for building indexes
    private SignalProducer _events; // operation events, published from the worker thread

    //! @brief Publishes throttled progress of the running operation
    private struct ProgressReporter
    {
        SignalProducer events;
        Operation operation;
        BackgroundSlot.Ctx* ctx;
        float lastPublished = -1;

        void report(float value)
        {
            ctx.progress = value;
            if (value >= 1.0f || value - lastPublished >= progressStep)
            {
                events.publish(OperationProgress(operation, value));
                lastPublished = value;
            }
        }
    }

    private alias Work = bool delegate(ref ProgressReporter progress);

    @disable this(this); // copy constructor is disabled

    this(ByteSource source, LogFormat format, SignalProducer events)
    {
        _events = events;
        _source = source;
        _format = format;

        _backgroundSlot = BackgroundSlot(null);

        _mutex = scoped!Mutex();

        runBuildOffsetIndex();
    }

    ~this()
    {
        // Fields are destroyed in reverse declaration order, so _mutex and
        // _source would go before _backgroundSlot joins the worker that uses
        // them. Stop the worker explicitly first.
        _backgroundSlot.shutdown();
        if (_source !is null) // null if the owner failed before constructing it
            _source.close();
    }

    //! The format of the log
    const(LogFormat) format() const pure nothrow @nogc
    {
        return _format;
    }

    void cancelCurrentOperation()
    {
        _backgroundSlot.cancel();
    }

    bool runBuildOffsetIndex()
    {
        return runOperation(Operation.BuildOffsetIndex,
            (ref ProgressReporter progress) => buildOffsetIndex(progress));
    }

    bool runBuildFilterIndex(Filter filter, Anchors anchors)
    {
        return runOperation(Operation.BuildFilterIndex,
            (ref ProgressReporter progress) => buildFilterIndex(progress, filter, anchors));
    }

    bool runBuildSearchIndex(Filter filter, Anchors anchors)
    {
        return runOperation(Operation.BuildSearchIndex,
            (ref ProgressReporter progress) => buildSearchIndex(progress, filter, anchors));
    }

    //! @brief Starts `work` in the background slot and reports its lifecycle:
    //! OperationStarted (before the thread starts), OperationProgress*,
    //! OperationFinished (after the slot is idle, so state() is already updated).
    //! @return false if another operation is running
    private bool runOperation(Operation op, Work work)
    {
        // Called from the UI thread only, so the slot can't become busy
        // between this check and runTask() below.
        if (_backgroundSlot.busy())
            return false;

        // Published before the thread starts, so it precedes any progress event
        _events.publish(OperationStarted(op));

        // Stays Failed unless work returns normally: a worker killed by an
        // Error must not report success.
        auto finished = OperationFinished(op, OperationFinished.Result.Failed,
            "operation terminated unexpectedly");
        auto events = _events;

        const bool started = _backgroundSlot.runTask((BackgroundSlot.Ctx* ctx) {
            auto progress = ProgressReporter(events, op, ctx);
            try
            {
                finished.result = work(progress)
                    ? OperationFinished.Result.Completed : OperationFinished.Result.Cancelled;
                finished.error = null;
            }
            catch (Exception e)
            {
                finished.result = OperationFinished.Result.Failed;
                finished.error = e.msg;
            }
        }, () { events.publish(finished); });

        if (!started) // slot is shutting down
        {
            _events.publish(OperationFinished(op, OperationFinished.Result.Cancelled));
            return false;
        }
        return true;
    }

    //! @brief Puts the anchored messages into the cleared search index, in order.
    //! Must be called under _mutex.
    private void appendAnchorsToSearch(ref const(Anchors) anchors)
    {
        import std.algorithm : map, sort;
        import std.array : array;

        auto sorted = anchors.exportAnchors.map!(i => cast(SearchIndex.Type) i).array;
        sort(sorted);
        if (!_searchIndex.append(sorted))
            throw new Exception("the search index can't grow: too many records or not enough memory");
    }

    //! @return true once the file can't be read any more (e.g. its disk was
    //! removed). Nothing read from it can be trusted from then on.
    bool sourceLost() nothrow @nogc
    {
        return _source.lost;
    }

    //! @throws Exception if the file is lost: fails the running operation
    private void enforceSourceAvailable()
    {
        if (_source.lost)
            throw new Exception(sourceLostMessage);
    }

    enum sourceLostMessage = "the file is no longer available";

    //! @return the number of messages in the file (the offset index)
    size_t messageCount() nothrow @nogc
    {
        auto lock = LockGuard(cast(Mutex)_mutex);
        return _offsetIndex.length;
    }

    //! @brief Updates the filter and search indexes in place after an anchor
    //! change, without rebuilding them. An anchored message is listed in both;
    //! an un-anchored one stays only where it matches by itself.
    //! Must be called from the UI thread while no operation is running.
    //! @param viewFilter - filter of the main view, used if the view is filtered
    //! @param searchFilter - current search, null if there is none
    void updateAnchor(size_t msgIndex, bool anchored, const(Filter) viewFilter, const(Filter) searchFilter)
    {
        assert(!_backgroundSlot.busy(), "indexes are being built");

        const value = cast(SearchIndex.Type) msgIndex;
        if (anchored)
        {
            synchronized (cast(Mutex)_mutex)
            {
                if (_viewIsFiltered)
                    _filterIndex.insertSorted(value);
                _searchIndex.insertSorted(value);
            }
            return;
        }

        // The search runs over the main view: a message hidden by the view filter
        // is not a search result either
        const bool inView = !_viewIsFiltered
            || (viewFilter !is null && messageMatches(viewFilter, msgIndex));
        const bool inSearch = inView && searchFilter !is null && messageMatches(searchFilter, msgIndex);

        synchronized (cast(Mutex)_mutex)
        {
            if (!inView)
                _filterIndex.removeSorted(value);
            if (!inSearch)
                _searchIndex.removeSorted(value);
        }
    }

    private bool messageMatches(const(Filter) filter, size_t msgIndex)
    {
        OffsetIndexItem fileOffset;
        {
            auto lock = LockGuard(cast(Mutex)_mutex);
            fileOffset = _offsetIndex[msgIndex];
        }
        Message msg;
        if (!decodeAt(msg, fileOffset.offset))
            return false;
        return filter.matches(msg);
    }

    //! @brief Decodes the record at `offset` of the data
    //! @return false if there is no valid record there
    private bool decodeAt(ref Message msg, size_t offset) nothrow @nogc
    {
        const data = _source.data;
        return _format.decode(msg, _format.recordAt(data, offset));
    }

    void enableFilter(bool enable)
    {
        synchronized (cast(Mutex)_mutex)
        {
            //if (_filterIndex.isReady)
            _viewIsFiltered = enable;
        }
    }

    //! @brief build file index, also rebuild filter and search indexes
    //! @param progress - progress reporter, also gives access to the cancel flag
    //! @return true if the build process was completed successfully, false otherwise
    private bool buildOffsetIndex(ref ProgressReporter progress)
    {
        auto ctx = progress.ctx;
        synchronized (cast(Mutex)_mutex)
        {
            _offsetIndex.clear();
            _filterIndex.clear();
            _searchIndex.clear();
            _offsetIndex.isReady = false;
            _filterIndex.isReady = false;
            _searchIndex.isReady = false;
        }

        const data = _source.data;
        size_t pos = 0;

        while (pos < data.length)
        {
            if (ctx.cancelled)
                return false;
            enforceSourceAvailable();

            size_t[bunchSize] offsets;
            const found = _format.scanRecords(data, pos, offsets[], true);
            assert(found.next > pos || found.count > 0, "scanning must make progress");
            pos = found.next;

            OffsetIndex.Type[bunchSize] tempIndex;
            foreach (i; 0 .. found.count)
                tempIndex[i].offset = offsets[i];

            synchronized (cast(Mutex)_mutex)
            {
                if (!_offsetIndex.append(tempIndex[0 .. found.count]))
                    throw new Exception("the offset index can't grow: too many records or not enough memory");
                progress.report(cast(float) pos / data.length);
            }
        }

        enforceSourceAvailable(); // the last batch may have read zeros
        synchronized (cast(Mutex)_mutex)
        {
            _offsetIndex.isReady = true;
            progress.report(1.0f);
        }

        return true;
    }

    //! @brief build filter index, also rebuild search index
    //! @param progress - progress reporter, also gives access to the cancel flag
    //! @param filter - null resets the filter: the main view shows all messages
    //! @return true if the build process was completed successfully, false otherwise
    private bool buildFilterIndex(ref ProgressReporter progress, Filter filter, Anchors anchors)
    {
        auto ctx = progress.ctx;
        if (filter is null)
        {
            synchronized (cast(Mutex)_mutex)
            {
                _viewIsFiltered = false;
                _filterIndex.clear();
                _searchIndex.clear(); // was built over the filtered view
                appendAnchorsToSearch(anchors);
                _filterIndex.isReady = false;
                _searchIndex.isReady = false;
                progress.report(1.0f);
            }
            return true;
        }

        synchronized (cast(Mutex)_mutex)
        {
            _viewIsFiltered = true; // the main view shows the filter index from now on
            _filterIndex.clear();
            _searchIndex.clear();
            appendAnchorsToSearch(anchors); // anchors are in the filtered view too
            _filterIndex.isReady = false;
            _searchIndex.isReady = false;
        }

        auto isMatched = (ref const(Message) msg, size_t fileIndex) {
            const bool isAnchoredMsg = anchors.has(fileIndex);
            return isAnchoredMsg || filter.matches(msg);
        };

        // The offset index is complete and doesn't change while this runs
        const size_t indexLen = _offsetIndex.length;
        Message parsedMsg;
        size_t pos = 0;

        while (pos < indexLen)
        {
            if (ctx.cancelled)
            {
                return false;
            }
            enforceSourceAvailable();

            const size_t batchEnd = min(pos + bunchSize, indexLen);
            FilterIndex.Type[bunchSize] tempIndex;
            size_t n = 0; // items written into tempIndex this batch

            for (size_t i = pos; i < batchEnd; ++i)
            {
                if (!decodeAt(parsedMsg, _offsetIndex[i].offset))
                    continue;

                if (isMatched(parsedMsg, i))
                    tempIndex[n++] = cast(FilterIndex.Type) i;
            }

            synchronized (cast(Mutex)_mutex)
            {
                if (!_filterIndex.append(tempIndex[0 .. n])) // only matched entries
                    throw new Exception("the filter index can't grow: too many records or not enough memory");
                progress.report(cast(float) batchEnd / indexLen);
            }

            pos = batchEnd;
        }

        enforceSourceAvailable(); // the last batch may have read zeros
        synchronized (cast(Mutex)_mutex)
        {
            _filterIndex.isReady = true;
            progress.report(1.0f);
        }

        return true;
    }

    //! @brief build search index
    //! @param progress - progress reporter, also gives access to the cancel flag
    //! @param filter - null resets the search: the search view shows the anchors only
    //! @return true if the build process was completed successfully, false otherwise
    private bool buildSearchIndex(ref ProgressReporter progress, Filter filter, Anchors anchors)
    {
        auto ctx = progress.ctx;
        if (filter is null)
        {
            synchronized (cast(Mutex)_mutex)
            {
                _searchIndex.clear();
                appendAnchorsToSearch(anchors); // anchored messages are always listed
                _searchIndex.isReady = true;
                progress.report(1.0f);
            }
            return true;
        }

        synchronized (cast(Mutex)_mutex)
        {
            _searchIndex.clear();
            _searchIndex.isReady = false;
        }

        auto isMatched = (ref const(Message) msg, size_t fileIndex) {
            const bool isAnchoredMsg = anchors.has(fileIndex);
            return isAnchoredMsg || filter.matches(msg);
        };

        // Build a read-only list of file offsets to iterate over
        const size_t indexLen = _viewIsFiltered ? _filterIndex.length : _offsetIndex.length;

        Message parsedMsg;
        SearchIndex.Type[bunchSize] tempIndex;
        size_t pos = 0;

        while (pos < indexLen)
        {
            if (ctx.cancelled)
            {
                _searchIndex.clear();
                return false;
            }
            enforceSourceAvailable();

            size_t batchEnd = pos + bunchSize;
            if (batchEnd > indexLen)
                batchEnd = indexLen;

            size_t tempLen = 0;
            for (size_t i = pos; i < batchEnd; ++i)
            {
                const uint32_t globalIndex = _viewIsFiltered ? _filterIndex[i] : cast(uint32_t) i;
                if (!decodeAt(parsedMsg, _offsetIndex[globalIndex].offset))
                    continue;

                if (isMatched(parsedMsg, globalIndex))
                {
                    tempIndex[tempLen++] = globalIndex;
                }
            }

            synchronized (cast(Mutex)_mutex)
            {
                if (!_searchIndex.append(tempIndex[0 .. tempLen]))
                    throw new Exception("the search index can't grow: too many records or not enough memory");
                progress.report(cast(float) batchEnd / indexLen);
            }

            pos = batchEnd;
        }

        enforceSourceAvailable(); // the last batch may have read zeros
        synchronized (cast(Mutex)_mutex)
        {
            _searchIndex.isReady = true;
            progress.report(1.0f);
        }

        return true;
    }

    /// 
    /// Views utils
    ///

    size_t mainViewItemsCount() nothrow @nogc
    {
        auto lock = LockGuard(cast(Mutex)_mutex);
        return _viewIsFiltered ? _filterIndex.length : _offsetIndex.length;
    }

    bool fetchMainViewItem(size_t index, scope ref DocumentItem item)
    {
        OffsetIndexItem fileOffset;

        {
            auto lock = LockGuard(cast(Mutex)_mutex);

            if (_viewIsFiltered)
            {
                if (index >= _filterIndex.length)
                    return false;

                index = cast(size_t) _filterIndex[index]; // position in the view -> message index
            }
            else
            {
                if (index >= _offsetIndex.length)
                    return false;
            }

            fileOffset = _offsetIndex[index];
        }

        const bool decoded = decodeAt(item._message, fileOffset.offset);
        if (!decoded || _source.lost)
            return false; // no record there: e.g. the file was read as zeros
        item.realIndex = index;
        item.filterMask = fileOffset.filterMask;
        item.searchMask = 0;
        item.anchored = false;
        item.selected = false;
        return true;
    }

    bool isMainViewFilterEnabled() const
    {
        synchronized (cast(Mutex)_mutex)
        {
            return _viewIsFiltered;
        }
    }

    // search view

    size_t searchViewItemsCount() nothrow @nogc
    {
        auto lock = LockGuard(cast(Mutex)_mutex);
        return _searchIndex.length;
    }

    bool fetchSearchViewItem(size_t index, scope ref DocumentItem item)
    {
        OffsetIndexItem fileOffset;
        uint32_t globalIndex;

        {
            auto lock = LockGuard(cast(Mutex)_mutex);
            if (index >= _searchIndex.length)
                return false;

            globalIndex = _searchIndex[index];
            fileOffset = _offsetIndex[globalIndex];
        }

        const bool decoded = decodeAt(item._message, fileOffset.offset);
        if (!decoded || _source.lost)
            return false; // no record there: e.g. the file was read as zeros
        item.realIndex = globalIndex;
        item.filterMask = fileOffset.filterMask;
        item.searchMask = 0;
        item.anchored = false;
        item.selected = false;
        return true;
    }

    /// 
    /// Views
    ///
}

@("LogIndex: the indexes take memory as they fill, not for the whole file")
unittest
{
    import core.thread : Thread;
    import core.time : msecs, MonoTime;
    import utils.event_bus.event_bus_async : EventBusAsync;
    import formats.plain_text : PlainTextFormat;
    import std.array : replicate;
    import std.file : remove, tempDir, write;
    import std.path : buildPath;

    // 16 MB of text in 1600 lines: a reserve for a record per byte would be
    // 16M entries per index
    const path = buildPath(tempDir(), "log_index_memory.log");
    write(path, ("x".replicate(10 * 1024 - 1) ~ "\n").replicate(1600));
    scope (exit)
        remove(path);

    auto events = new EventBusAsync();
    auto index = LogIndex(new FileSource(path), new PlainTextFormat(), events);
    const deadline = MonoTime.currTime + 10_000.msecs;
    while (index.messageCount < 1600 && MonoTime.currTime < deadline)
        Thread.sleep(1.msecs);
    assert(index.messageCount == 1600);

    const used = index._offsetIndex.reservedBytes + index._filterIndex.reservedBytes
        + index._searchIndex.reservedBytes;
    assert(used < 4 * 1024 * 1024, "indexes reserve memory for the whole file");
}
