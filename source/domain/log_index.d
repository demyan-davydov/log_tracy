//! The indexes of a log and their building in the background: the offset
//! index of its records, the filter index of the main view and the search
//! index, read by the UI thread while the indexing thread grows them.
module domain.log_index;

import utils.ui_text : uiText, uiTextOf, UiText, UiTextException;

import log_core.log_message;
import log_core.log_filter;
import log_core.log_format;
import log_core.byte_source;

import domain.index.offset_index;
import domain.index.filter_index;
import domain.index.search_index;
import domain.anchors;
import utils.background_slot;
import domain.document_item;
import domain.document : Document, OperationStarted, OperationProgress, OperationFinished;

import utils.event_bus.event_bus_interface : SignalProducer;

import utils.lock_guard;

import std.typecons;

import core.atomic : atomicLoad, atomicStore;
import core.stdc.stdint : uint16_t, uint32_t;
import core.sync.mutex : Mutex;

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

    enum bunchSize = 32; // number of messages to process in one bunch

    //! Records a thread filters or searches at a time: a block's matches are
    //! at most 64 KB, and a few blocks per thread are held (utils/parallel_scan)
    enum scanBlockLength = 16 * 1024;

    //! Records a block scans between its checks of a cancel and of a lost file
    enum stopCheckRecords = 256;

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

    //! The rows of the main view and the results of the search are dropped
    //! before this returns, not later by the worker: the views show their
    //! rows while the operation fills them, and what they list from now on
    //! must be what it found
    bool runBuildFilterIndex(Filter filter, Anchors anchors)
    {
        if (_backgroundSlot.busy())
            return false;
        synchronized (cast(Mutex)_mutex)
        {
            _viewIsFiltered = filter !is null;
            _filterIndex.clear();
            _searchIndex.clear();
            _filterIndex.isReady = false;
            _searchIndex.isReady = false;
        }
        return runOperation(Operation.BuildFilterIndex,
            (ref ProgressReporter progress) => buildFilterIndex(progress, filter, anchors));
    }

    //! The results of the previous search are dropped before this returns, not
    //! later by the worker: from now on the document marks found what the index
    //! lists as found by `filter`, and the search view shows what it lists
    //! while the search fills it (a reset too: the anchors come with the worker)
    bool runBuildSearchIndex(Filter filter, Anchors anchors)
    {
        if (_backgroundSlot.busy())
            return false;
        synchronized (cast(Mutex)_mutex)
        {
            _searchIndex.clear();
            _searchIndex.isReady = false;
        }
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
            uiText("the operation was terminated unexpectedly"));
        auto events = _events;

        const bool started = _backgroundSlot.runTask((BackgroundSlot.Ctx* ctx) {
            auto progress = ProgressReporter(events, op, ctx);
            try
            {
                finished.result = work(progress)
                    ? OperationFinished.Result.Completed : OperationFinished.Result.Cancelled;
                finished.error = UiText.init;
            }
            catch (Exception e)
            {
                finished.result = OperationFinished.Result.Failed;
                finished.error = uiTextOf(e); // its template: translated where it is shown
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
            throw new UiTextException(uiText("the search index can't grow: too many records or not enough memory"));
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
            throw new UiTextException(sourceLostText());
    }

    /// The error of an operation the loss of the file fails
    static UiText sourceLostText() @safe => uiText("the file is no longer available");

    //! @return the size of the log in bytes, as it was mapped: kept once
    //! its file is lost
    ulong byteSize() const nothrow @nogc
    {
        return _source.data.length;
    }

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

    //! @brief Builds the offset index; the filter and search indexes are
    //! cleared, they are built over it afterwards
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
                    throw new UiTextException(uiText("the offset index can't grow: too many records or not enough memory"));
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

        // The offset index is complete and doesn't change while this runs
        if (!collectMatches(progress, _filterIndex, _offsetIndex.length, (size_t i) => i,
                filter, anchors, uiText("the filter index can't grow: too many records or not enough memory")))
            return false;

        synchronized (cast(Mutex)_mutex)
        {
            _filterIndex.isReady = true;
            progress.report(1.0f);
        }

        return true;
    }

    //! @brief Appends to `index`, in order, the messages of the positions
    //! [0, count) that are anchored or match `filter`. The positions are
    //! scanned in parallel blocks (utils/parallel_scan); what a block found is
    //! appended under the mutex as soon as it and the blocks before it are
    //! scanned.
    //! @param messageAt - the message index of a position; called concurrently,
    //!   so it may only read what doesn't change while the operation runs
    //! @param full - the error for the user when the index can't grow
    //! @return false if the operation was cancelled
    private bool collectMatches(Index)(ref ProgressReporter progress, ref Index index, size_t count,
        scope size_t delegate(size_t position) messageAt, Filter filter, ref const(Anchors) anchors,
        UiText full)
    {
        import utils.parallel_scan : parallelScan, ScanStop;

        auto ctx = progress.ctx;
        const completed = parallelScan!(Index.Type)(count, scanBlockLength,
            (size_t lo, size_t hi, Index.Type[] found, ScanStop stop) {
                Message msg; // a buffer per block: blocks run on several threads
                size_t n = 0;
                foreach (position; lo .. hi)
                {
                    // A cancel or a lost file: the delivery of this block stops
                    // the scan, or fails it. A stop: it is never delivered
                    if ((position - lo) % stopCheckRecords == 0 && (ctx.cancelled || _source.lost || stop()))
                        break;
                    const message = messageAt(position);
                    if (!decodeAt(msg, _offsetIndex[message].offset))
                        continue;
                    if (anchors.has(message) || filter.matches(msg))
                        found[n++] = cast(Index.Type) message;
                }
                return n;
            },
            (size_t done, const(Index.Type)[] found) {
                if (ctx.cancelled)
                    return false;
                enforceSourceAvailable();
                synchronized (cast(Mutex)_mutex)
                {
                    if (!index.append(found))
                        throw new UiTextException(full);
                    progress.report(cast(float) done / count);
                }
                return true;
            });

        if (!completed)
            return false; // cancelled: a file lost meanwhile doesn't make it a failure
        enforceSourceAvailable(); // the last block may have read zeros
        return true;
    }

    //! @brief build search index
    //! @param progress - progress reporter, also gives access to the cancel flag
    //! @param filter - null resets the search: the search view shows the anchors only
    //! @return true if the build process was completed successfully, false otherwise
    private bool buildSearchIndex(ref ProgressReporter progress, Filter filter, Anchors anchors)
    {
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

        // The search runs over the main view; neither the filter index nor
        // the offset index changes while this runs
        const bool viewIsFiltered = _viewIsFiltered;
        const size_t viewLength = viewIsFiltered ? _filterIndex.length : _offsetIndex.length;
        // A failed search (an exception) leaves no partial results either
        scope (failure)
            synchronized (cast(Mutex)_mutex)
                _searchIndex.clear();
        if (!collectMatches(progress, _searchIndex, viewLength,
                (size_t position) => viewIsFiltered ? cast(size_t) _filterIndex[position] : position,
                filter, anchors, uiText("the search index can't grow: too many records or not enough memory")))
        {
            synchronized (cast(Mutex)_mutex)
                _searchIndex.clear();
            return false;
        }

        synchronized (cast(Mutex)_mutex)
        {
            _searchIndex.isReady = true;
            progress.report(1.0f);
        }

        return true;
    }

    // ── The main view ──

    size_t mainViewItemsCount() nothrow @nogc
    {
        auto lock = LockGuard(cast(Mutex)_mutex);
        return _viewIsFiltered ? _filterIndex.length : _offsetIndex.length;
    }

    //! @brief The position in the main view of the message `realIndex`
    //! @return false if the view doesn't show it
    bool mainViewPositionOf(size_t realIndex, out size_t position) nothrow @nogc
    {
        auto lock = LockGuard(cast(Mutex)_mutex);
        if (!_viewIsFiltered)
        {
            position = realIndex;
            return realIndex < _offsetIndex.length;
        }
        return sortedPositionOf(_filterIndex, realIndex, position);
    }

    //! @brief The position in the search view of the message `realIndex`
    //! @return false if the view doesn't show it
    bool searchViewPositionOf(size_t realIndex, out size_t position) nothrow @nogc
    {
        auto lock = LockGuard(cast(Mutex)_mutex);
        return sortedPositionOf(_searchIndex, realIndex, position);
    }

    //! The position of `realIndex` in an index of message indexes sorted ascending
    private static bool sortedPositionOf(Index)(ref const(Index) index, size_t realIndex, out size_t position)
    {
        if (realIndex > Index.Type.max)
            return false;
        position = index.lowerBound(cast(Index.Type) realIndex);
        return position < index.length && index[position] == realIndex;
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
        item.anchored = false;
        item.found = false;
        item.selected = false;
        return true;
    }

    // ── The search view ──

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
        item.anchored = false;
        item.found = false;
        item.selected = false;
        return true;
    }

}

version (unittest)
{
    //! Builds the operation `run` starts and waits for it to finish
    private void waitForOperation(ref LogIndex index, scope bool delegate() run)
    {
        import core.thread : Thread;
        import core.time : msecs, MonoTime;

        while (!run()) // the offset index may still be building
            Thread.sleep(1.msecs);
        const deadline = MonoTime.currTime + 30_000.msecs;
        while (index._backgroundSlot.busy && MonoTime.currTime < deadline)
            Thread.sleep(1.msecs);
        assert(!index._backgroundSlot.busy, "the operation hangs");
    }

    //! Writes a log of `lines` lines, given by `line` without their end, to a
    //! file named after the test and the process
    //! @return its path
    private string writeLines(string name, size_t lines, scope string delegate(size_t) line)
    {
        import std.array : appender;
        import std.file : tempDir, write;
        import std.format : format;
        import std.path : buildPath;
        import std.process : thisProcessID;

        auto text = appender!string;
        foreach (i; 0 .. lines)
        {
            text ~= line(i);
            text ~= '\n';
        }
        const path = buildPath(tempDir(), format("%s-%s.log", name, thisProcessID));
        write(path, text[]);
        return path;
    }

    //! How an operation ended, by its events
    private struct Ending
    {
        OperationFinished.Result result;
        float lastProgress = 0; // the last progress it reported (an event that overrides the earlier ones)
    }

    //! @return how the last `op` the events of `events` tell of ended
    private Ending endingOf(EventBusAsync)(EventBusAsync events, Document.Operation op)
    {
        import core.thread : Thread;
        import core.time : msecs, MonoTime;

        Ending ending;
        bool seen = false;
        auto finished = events.subscribe((const OperationFinished e) {
            if (e.operation == op)
            {
                ending.result = e.result;
                seen = true;
            }
        });
        auto progress = events.subscribe((const OperationProgress e) {
            if (e.operation == op)
                ending.lastProgress = e.progress;
        });
        scope (exit)
        {
            events.unsubscribe(finished);
            events.unsubscribe(progress);
        }
        // The slot is idle before the end is published: it may not be there yet
        const deadline = MonoTime.currTime + 10_000.msecs;
        do
        {
            events.dispatch();
            if (!seen)
                Thread.sleep(1.msecs);
        }
        while (!seen && MonoTime.currTime < deadline);
        assert(seen, "the operation didn't finish");
        return ending;
    }

    //! Matches nothing; on its first call does `stop`. Counts the calls each
    //! thread makes after that: a block stopped in time makes few.
    //! Breaks the contract of LogFilter on purpose (`matches` changes it, with
    //! atomics and a mutex) to count: not a pattern for a real filter

    private final class CountingFilter : Filter
    {
        import core.sync.mutex : Mutex;
        import core.thread : Thread;

        private void delegate() _stop;
        private shared bool _stopped;
        private shared size_t _calls;
        private Mutex _mutex;
        private size_t[Thread] _callsAfterStop;

        this(void delegate() stop)
        {
            _stop = stop;
            _mutex = new Mutex();
        }

        //! The most calls a thread made after the stop
        size_t mostCallsAfterStop()
        {
            import std.algorithm : maxElement;

            synchronized (_mutex)
                return _callsAfterStop.length ? _callsAfterStop.byValue.maxElement : 0;
        }

        override bool matches(scope ref const(Message) item) const
        {
            import core.atomic : atomicLoad, atomicOp, atomicStore;

            auto self = cast() this;
            if (atomicLoad(_stopped))
            {
                synchronized (self._mutex)
                    ++self._callsAfterStop.require(Thread.getThis(), 0);
            }
            else if (atomicOp!"+="(self._calls, 1) == 1)
            {
                self._stop();
                atomicStore(self._stopped, true);
            }
            return false;
        }

        override Nullable!uint matchIndex(scope ref const(Message) item) const
        {
            return Nullable!uint.init;
        }

        override immutable(Filter) idup() const pure
        {
            assert(false);
        }

        override Filter dup() const pure
        {
            assert(false);
        }
    }

    //! A file that can be lost on demand
    private final class LosableSource : ByteSource
    {
        private FileSource _file;
        shared bool isLost;

        this(string path)
        {
            _file = new FileSource(path);
        }

        override const(ubyte)[] data() const pure nothrow @nogc
        {
            return _file.data;
        }

        override bool lost() const nothrow @nogc
        {
            import core.atomic : atomicLoad;

            return atomicLoad(isLost);
        }

        override void close() nothrow @nogc
        {
            _file.close();
        }
    }
}

@("LogIndex: the indexes take memory as they fill, not for the whole file")
unittest
{
    import utils.event_bus.event_bus_async : EventBusAsync;
    import formats.plain_text : PlainTextFormat;
    import std.array : replicate;
    import std.file : remove;

    // 16 MB of text in 1600 lines: a reserve for a record per byte would be
    // 16M entries per index
    const line = "x".replicate(10 * 1024 - 1);
    const path = writeLines("log_index_memory", 1600, (size_t i) => line);
    scope (exit)
        remove(path);

    auto index = LogIndex(new FileSource(path), new PlainTextFormat(), new EventBusAsync());
    waitForOperation(index, () => true); // the offset index is being built
    assert(index.messageCount == 1600);

    const used = index._offsetIndex.reservedBytes + index._filterIndex.reservedBytes
        + index._searchIndex.reservedBytes;
    assert(used < 4 * 1024 * 1024, "indexes reserve memory for the whole file");
}

@("LogIndex: filter and search over many blocks keep the order of the log")
unittest
{
    import utils.event_bus.event_bus_async : EventBusAsync;
    import formats.plain_text : PlainTextFormat;
    import log_core.search_filter : SearchChip, SearchFilter;
    import std.algorithm : filter, map;
    import std.array : array;
    import std.file : remove;
    import std.format : format;
    import std.range : iota;

    // Enough lines for many blocks of every thread
    enum lines = 300_000;
    const path = writeLines("log_index_order", lines, (size_t i) => format("line %s%s%s",
        i, i % 7 == 0 ? " seven" : "", i % 5 == 0 ? " five" : ""));
    scope (exit)
        remove(path);

    auto index = LogIndex(new FileSource(path), new PlainTextFormat(), new EventBusAsync());
    Anchors anchors;
    anchors.set(3, true); // shown whatever the filter

    auto sevens = SearchFilter.fromChips([SearchChip("seven")]);
    waitForOperation(index, () => index.runBuildFilterIndex(sevens, anchors));
    const expectedView = iota(lines).filter!(i => i % 7 == 0 || i == 3).array;
    assert(index.mainViewItemsCount == expectedView.length);
    assert(iota(expectedView.length).map!(p => index._filterIndex[p]).array == expectedView);

    // The search runs over the filtered view
    auto fives = SearchFilter.fromChips([SearchChip("five")]);
    waitForOperation(index, () => index.runBuildSearchIndex(fives, anchors));
    const expectedFound = expectedView.filter!(i => i % 5 == 0 || i == 3).array;
    assert(index.searchViewItemsCount == expectedFound.length);
    assert(iota(expectedFound.length).map!(p => index._searchIndex[p]).array == expectedFound);
}

@("LogIndex: a filter or a search asked for leaves no row of the content before, at once")
unittest
{
    import utils.event_bus.event_bus_async : EventBusAsync;
    import formats.plain_text : PlainTextFormat;
    import log_core.search_filter : SearchChip, SearchFilter;
    import std.file : remove;
    import std.format : format;

    enum lines = 50_000;
    const path = writeLines("log_index_replaced", lines, (size_t i) => format("line %s", i));
    scope (exit)
        remove(path);

    auto index = LogIndex(new FileSource(path), new PlainTextFormat(), new EventBusAsync());
    waitForOperation(index, () => true);
    assert(index.mainViewItemsCount == lines);

    // The views show their rows while an operation fills them: what is there
    // when it is started must be its own, not what the worker hasn't cleared yet
    auto nothing = SearchFilter.fromChips([SearchChip("no such text")]);
    while (!index.runBuildFilterIndex(nothing, Anchors.init))
    {
    }
    assert(index.mainViewItemsCount == 0, "the view shows the rows of before while the filter starts");
    waitForOperation(index, () => true);

    auto every = SearchFilter.fromChips([SearchChip("line")]);
    waitForOperation(index, () => index.runBuildFilterIndex(null, Anchors.init));
    waitForOperation(index, () => index.runBuildSearchIndex(every, Anchors.init));
    assert(index.searchViewItemsCount == lines);
    while (!index.runBuildSearchIndex(null, Anchors.init))
    {
    }
    assert(index.searchViewItemsCount == 0, "the results of before are listed while the search is reset");
    waitForOperation(index, () => true);
}

@("LogIndex: a cancel or a lost file stops the blocks being scanned, not only the next ones")
unittest
{
    import core.atomic : atomicStore;
    import utils.event_bus.event_bus_async : EventBusAsync;
    import formats.plain_text : PlainTextFormat;
    import std.file : remove;
    import std.format : format;

    const path = writeLines("log_index_stop", 400_000, (size_t i) => format("line %s", i));
    scope (exit)
        remove(path);
    // A thread goes on to the next check of its block at most: what a block
    // would scan without the checks is a whole block
    static assert(LogIndex.stopCheckRecords * 2 < LogIndex.scanBlockLength);

    {
        auto events = new EventBusAsync();
        auto index = LogIndex(new FileSource(path), new PlainTextFormat(), events);
        auto indexPtr = &index;
        auto filter = new CountingFilter(() { indexPtr.cancelCurrentOperation(); });
        waitForOperation(index, () => index.runBuildFilterIndex(filter, Anchors.init));
        assert(filter.mostCallsAfterStop < LogIndex.stopCheckRecords * 2, "a cancelled block goes on");
        assert(endingOf(events, Document.Operation.BuildFilterIndex).result == OperationFinished.Result.Cancelled);
    }
    {
        auto events = new EventBusAsync();
        auto source = new LosableSource(path);
        auto index = LogIndex(source, new PlainTextFormat(), events);
        auto filter = new CountingFilter(() { atomicStore(source.isLost, true); });
        waitForOperation(index, () => index.runBuildSearchIndex(filter, Anchors.init));
        assert(filter.mostCallsAfterStop < LogIndex.stopCheckRecords * 2, "a block of a lost file goes on");
        const ending = endingOf(events, Document.Operation.BuildSearchIndex);
        assert(ending.result == OperationFinished.Result.Failed);
        assert(ending.lastProgress == 0, "blocks are delivered after the file is lost");
    }
}

@("LogIndex: a cancel ends as a cancel even when the file is lost meanwhile")
unittest
{
    import core.atomic : atomicStore;
    import utils.event_bus.event_bus_async : EventBusAsync;
    import formats.plain_text : PlainTextFormat;
    import std.file : remove;
    import std.format : format;

    const path = writeLines("log_index_cancel_lost", 100_000, (size_t i) => format("line %s", i));
    scope (exit)
        remove(path);

    auto events = new EventBusAsync();
    auto source = new LosableSource(path);
    auto index = LogIndex(source, new PlainTextFormat(), events);
    auto indexPtr = &index;
    auto filter = new CountingFilter(() {
        indexPtr.cancelCurrentOperation();
        atomicStore(source.isLost, true);
    });
    waitForOperation(index, () => index.runBuildFilterIndex(filter, Anchors.init));
    assert(endingOf(events, Document.Operation.BuildFilterIndex).result == OperationFinished.Result.Cancelled);
}
