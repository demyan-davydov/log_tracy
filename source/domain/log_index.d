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
import domain.document : ContentGrown, Document, OperationProgress, OperationFinished;

import utils.event_bus.event_bus_interface : SignalProducer;

import utils.lock_guard;

import std.typecons;

import core.atomic : atomicLoad, atomicStore;
import core.stdc.stdint : uint16_t, uint32_t;
import core.sync.mutex : Mutex;

alias Filter = LogFilter!wchar;
alias Message = LogMessage!wchar;

//! An operation of the running pass of LogIndex has nothing left to do, while
//! the pass goes on with the ones after it: the file is loaded to its end, or
//! the filter covers it. Published from the worker thread, before PassFinished.
struct StageFinished
{
    Document.Operation operation;
}

//! A pass of LogIndex ended (see LogIndex.runPass). Published from the worker
//! thread after its slot is idle: the next pass may be started at once.
struct PassFinished
{
    OperationFinished.Result result;
    UiText error; // set when result == Failed: for the user, translated where it is shown
    /// The operation that failed: the filter or the search, while what they are
    /// built over is sound. None: the source itself can't be read to its end
    Document.Operation failed;
}

//! @brief Holds the data of a log and its indexes.
//! Responsible for:
//!   * Creating and maintaining indexes,
//!   * Bringing them up to date in the background, a pass at a time (runPass):
//!     each index over the range it doesn't cover yet, and
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

    //! Records a stage of a pass takes at a time while another stage follows
    //! it: the views of the stages after it get their rows that often
    enum followRecords = 16 * scanBlockLength;

    alias Operation = Document.Operation;

    enum progressStep = 0.01f; // minimal progress change worth an event

    // ── What a pass brings up to date (see runPass). Written by the UI thread
    // while no pass runs, and by the worker of a pass; read by both likewise ──

    private size_t _scannedBytes; // the bytes of the source split into records
    private size_t _seenBytes; // the bytes the source had when a pass last caught up with it
    private bool _loaded; // a pass reached the end of the source once: the load is over
    private Filter _viewFilter; // of the main view, null: none
    private size_t _filterScanned; // the records the filter index covers
    private bool _filterStopped; // the filter was cancelled or failed: its index is left as it is
    private Filter _searchFilter; // null: the search view lists the anchors only
    private size_t _searchScanned; // the positions of the main view the search index covers
    private bool _searchStopped; // the search was cancelled or failed: nothing is listed
    private Anchors _anchors; // as they were when last told: the worker reads them
    private bool _reportFilter, _reportSearch; // the stage was asked for and didn't complete yet
    private bool _grownUntold; // rows no operation tells of were added, ContentGrown is to be published

    private BackgroundSlot _backgroundSlot;
    private ScopedMutex _mutex; // mutex for building indexes
    private SignalProducer _events; // operation events, published from the worker thread

    //! @brief Publishes the throttled progress of the stages of a pass in one
    //! event (events of one type override each other in the queue)
    private struct ProgressReporter
    {
        SignalProducer events;
        BackgroundSlot.Ctx* ctx;
        float[Operation.max + 1] published = -1;

        void report(float load, float filter, float search)
        {
            float[Operation.max + 1] values;
            values[Operation.BuildOffsetIndex] = load;
            values[Operation.BuildFilterIndex] = filter;
            values[Operation.BuildSearchIndex] = search;
            bool worth = false;
            foreach (i, value; values)
            {
                if (value != value) // not running
                    continue;
                ctx.progress = value;
                if ((value >= 1.0f && published[i] < 1.0f) || value - published[i] >= progressStep
                    || value < published[i])
                    worth = true;
            }
            if (!worth)
                return;
            foreach (i, value; values)
                if (value == value)
                    published[i] = value;
            events.publish(OperationProgress(values));
        }
    }

    @disable this(this); // copy constructor is disabled

    this(ByteSource source, LogFormat format, SignalProducer events)
    {
        _events = events;
        _source = source;
        _format = format;

        _backgroundSlot = BackgroundSlot(null);

        _mutex = scoped!Mutex();

        runPass();
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

    //! Asks the running pass to stop: it ends as cancelled, and what it brought
    //! up to date stays, so the next pass goes on from there
    void cancelCurrentOperation()
    {
        _backgroundSlot.cancel();
    }

    //! True while a pass runs: the indexes may be asked for nothing else
    bool busy()
    {
        return _backgroundSlot.busy();
    }

    // ── What the next pass builds. Asked while no pass runs: the rows of
    // before are dropped at once, not later by the worker, since the views
    // show their rows while a pass fills them ──

    //! @brief The main view shows the records `filter` matches (and the
    //! anchored ones), every record for null. The search view lists the
    //! anchors only, until a search is asked for again: it runs over the main view.
    void setViewFilter(Filter filter, Anchors anchors)
    {
        assert(!busy, "a pass is running");
        synchronized (cast(Mutex)_mutex)
        {
            _viewIsFiltered = filter !is null;
            _filterIndex.clear();
            _searchIndex.clear();
        }
        _viewFilter = filter;
        _filterScanned = 0;
        _filterStopped = false;
        _reportFilter = true;
        _searchFilter = null;
        _searchScanned = 0;
        _searchStopped = false;
        _reportSearch = false; // the search asked for went with the view it ran over
        _anchors = anchors;
    }

    //! @brief The search view lists what `filter` finds in the main view (and
    //! the anchored messages), the anchors only for null
    void setSearchFilter(Filter filter, Anchors anchors)
    {
        assert(!busy, "a pass is running");
        synchronized (cast(Mutex)_mutex)
            _searchIndex.clear();
        _searchFilter = filter;
        _searchScanned = 0;
        _searchStopped = false;
        _reportSearch = true;
        _anchors = anchors;
    }

    //! The search was cancelled or failed: it leaves no partial results, and
    //! nothing is listed until a search is asked for
    void stopSearch()
    {
        assert(!busy, "a pass is running");
        synchronized (cast(Mutex)_mutex)
            _searchIndex.clear();
        _searchFilter = null;
        _searchStopped = true;
        _reportSearch = false;
    }

    //! The filter was cancelled or failed: the main view is left with what
    //! was found, and no pass fills it until a filter is asked for
    void stopViewFilter()
    {
        assert(!busy, "a pass is running");
        _filterStopped = true;
        _reportFilter = false;
        stopSearch();
    }

    //! @return true if a pass has something to do: the source has bytes not
    //! split into records, or an index doesn't cover what it is built over
    bool behind()
    {
        assert(!busy, "a pass is running");
        if (_source.lost)
            return false;
        if (_source.data.length != _seenBytes)
            return true;
        if (filterBehind(_offsetIndex.length))
            return true;
        return searchBehind(viewLength());
    }

    private bool filterLive() const pure nothrow @nogc => _viewFilter !is null && !_filterStopped;
    // A filter that was stopped stops the search with it (stopViewFilter); a
    // search asked for after that runs over what the main view has
    private bool searchLive() const pure nothrow @nogc => !_searchStopped;
    private bool filterBehind(size_t records) const pure nothrow @nogc => filterLive && _filterScanned < records;
    private bool searchBehind(size_t positions) const pure nothrow @nogc => searchLive && _searchScanned < positions;

    //! The rows of the main view. For the worker, or while no pass runs
    private size_t viewLength() const pure nothrow @nogc
    {
        return _viewIsFiltered ? _filterIndex.length : _offsetIndex.length;
    }

    //! @brief Starts a pass in the background: it brings the indexes up to
    //! date with the source and with what was asked for (setViewFilter,
    //! setSearchFilter), each over the range it doesn't cover yet: the offset
    //! index over the new bytes, the filter index over the new records, the
    //! search index over the new rows of the main view. A stage takes a part
    //! at a time while another follows it, so every view grows as the pass
    //! goes; a rebuild is the same pass from zero. Reports OperationProgress*
    //! (of the load until the end of the source was reached once, of a filter
    //! and a search asked for until they cover what they are built over),
    //! StageFinished when the load or the filter has nothing left while the
    //! pass goes on, ContentGrown when a source that was loaded got more, then
    //! PassFinished, after the slot is idle.
    //! A pass that was cancelled leaves what it did: the next one goes on.
    //! @return false if a pass is running
    bool runPass()
    {
        // Called from the UI thread only, so the slot can't become busy
        // between this check and runTask() below.
        if (_backgroundSlot.busy())
            return false;

        // Stays Failed unless the pass returns normally: a worker killed by an
        // Error must not report success.
        auto finished = PassFinished(OperationFinished.Result.Failed,
            uiText("the operation was terminated unexpectedly"));
        auto events = _events;

        const bool started = _backgroundSlot.runTask((BackgroundSlot.Ctx* ctx) {
            auto progress = ProgressReporter(events, ctx);
            Operation stage = Operation.None; // the one the pass is at
            try
            {
                finished.result = pass(progress, stage)
                    ? OperationFinished.Result.Completed : OperationFinished.Result.Cancelled;
                finished.error = UiText.init;
            }
            catch (Exception e)
            {
                finished.result = OperationFinished.Result.Failed;
                finished.error = uiTextOf(e); // its template: translated where it is shown
                // A lost source fails whatever stage reads it
                finished.failed = _source.lost ? Operation.None : stage;
            }
        }, () { events.publish(finished); });

        if (!started) // slot is shutting down
        {
            _events.publish(PassFinished(OperationFinished.Result.Cancelled));
            return false;
        }
        return true;
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

    //! @return the size of the log in bytes, as its source has it now: kept
    //! once its file is lost
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
    //! Must be called from the UI thread while no pass is running.
    //! @param anchors - the anchors after the change: a later pass reads them
    void updateAnchor(size_t msgIndex, bool anchored, Anchors anchors)
    {
        assert(!_backgroundSlot.busy(), "indexes are being built");

        _anchors = anchors;
        const value = cast(SearchIndex.Type) msgIndex;
        if (anchored)
        {
            synchronized (cast(Mutex)_mutex)
            {
                if (_viewIsFiltered)
                    _filterIndex.insertSorted(value);
                if (!_searchStopped)
                    _searchIndex.insertSorted(value);
            }
            return;
        }

        // The search runs over the main view: a message hidden by the view filter
        // is not a search result either
        const bool inView = !_viewIsFiltered
            || (_viewFilter !is null && messageMatches(_viewFilter, msgIndex));
        const bool inSearch = inView && _searchFilter !is null && messageMatches(_searchFilter, msgIndex);

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

    // ── A pass, on the worker thread ──

    //! @brief Brings the indexes up to date, see runPass: a stage after
    //! another, each over what the one before it has added, until none has
    //! anything left
    //! @param stage - set to the filter or the search while the pass is at it,
    //!   None otherwise: tells which one a failure is of
    //! @return false if it was cancelled
    private bool pass(ref ProgressReporter progress, ref Operation stage)
    {
        auto ctx = progress.ctx;
        // The bytes of this pass: a source that grows meanwhile is taken by the
        // next one. Its end is asked first: asked after the bytes, a source
        // that got its last ones in between would have the record cut by the
        // end of `data` taken for a whole one
        const bool final_ = _source.complete;
        const data = _source.data;
        bool loading = !_loaded; // the load is reported until it is over
        const bool grows = _loaded; // a source that was loaded got more
        bool tailWaits = false; // the last bytes are the start of a record still to come

        void report()
        {
            const records = _offsetIndex.length;
            const float load = data.length ? cast(float) _scannedBytes / data.length : 1.0f;
            const bool loadBehind = _scannedBytes < data.length && !tailWaits;
            float filter = float.nan, search = float.nan;
            // A stage is as far as the one it follows, while that one has more to give
            if (_reportFilter)
                filter = loadBehind ? load : filterLive && records ? cast(float) _filterScanned / records : 1.0f;
            if (_reportSearch)
            {
                const positions = viewLength();
                search = loadBehind ? load : filterBehind(records) ? filter
                    : positions ? cast(float) _searchScanned / positions : 1.0f;
            }
            progress.report(loading ? load : float.nan, filter, search);
        }

        for (;;)
        {
            if (ctx.cancelled)
                return false;
            stage = Operation.None;
            enforceSourceAvailable();
            bool worked = false;

            // The offset index: over the bytes not split into records yet
            if (_scannedBytes < data.length && !tailWaits)
            {
                const before = _offsetIndex.length;
                // All of them at once unless a stage follows
                const part = filterLive || (searchLive && _searchFilter !is null) ? followRecords : size_t.max;
                if (!scanOffsets(ctx, data, final_, part, tailWaits, &report))
                    return false;
                worked = true;
                _grownUntold |= grows && _offsetIndex.length != before;
            }
            // The load is over, whatever follows it: told at once
            if (loading && (_scannedBytes == data.length || tailWaits))
            {
                report();
                loading = false;
                _loaded = true;
                _events.publish(StageFinished(Operation.BuildOffsetIndex));
            }

            // The filter index: over the records it doesn't cover
            const records = _offsetIndex.length;
            if (filterBehind(records))
            {
                stage = Operation.BuildFilterIndex;
                const part = searchLive && _searchFilter !is null ? followRecords : size_t.max;
                const from = _filterScanned;
                const to = records - from > part ? from + part : records;
                if (!collectMatches(ctx, _filterIndex, from, to, (size_t position) => position, _viewFilter,
                        (size_t done) { _filterScanned = done; report(); },
                        uiText("the filter index can't grow: too many records or not enough memory")))
                    return false;
                worked = true;
                stage = Operation.None;
            }
            // The filter covers the file, while a search may go on over its view
            if (_reportFilter && !loading && !filterBehind(records))
            {
                report();
                _reportFilter = false;
                _events.publish(StageFinished(Operation.BuildFilterIndex));
            }

            // The search index: over the rows of the main view it doesn't cover
            const positions = viewLength();
            if (searchBehind(positions))
            {
                stage = Operation.BuildSearchIndex;
                const from = _searchScanned;
                const full = uiText("the search index can't grow: too many records or not enough memory");
                if (_searchFilter is null)
                    // With no search to tell its progress, the view may be shown as ready by now
                    _grownUntold |= listAnchors(from, positions, full) && !_reportSearch;
                else
                {
                    const bool viewIsFiltered = _viewIsFiltered;
                    if (!collectMatches(ctx, _searchIndex, from, positions,
                            (size_t position) => viewIsFiltered ? cast(size_t) _filterIndex[position] : position,
                            _searchFilter, (size_t done) { _searchScanned = done; report(); }, full))
                        return false;
                }
                worked = true;
                stage = Operation.None;
            }

            // Rows no operation tells of, after every stage has added its own:
            // a view shown as ready counts them on this. Kept for the next
            // pass if this one is stopped before
            if (_grownUntold)
            {
                _grownUntold = false;
                _events.publish(ContentGrown());
            }
            if (!worked)
                break;
        }

        enforceSourceAvailable(); // the last step may have read zeros
        _seenBytes = data.length;
        // The search is complete: the stages before it told their end above
        assert(!loading && !_reportFilter);
        progress.report(float.nan, float.nan, _reportSearch ? 1.0f : float.nan);
        _reportSearch = false;
        return true;
    }

    //! @brief Appends to the offset index the records of the bytes after
    //! _scannedBytes, `part` of them at most
    //! @param tailWaits - set if the bytes left are the start of a record that
    //!   isn't whole yet (a source that isn't complete): a later pass takes it
    //! @return false if the pass was cancelled
    private bool scanOffsets(BackgroundSlot.Ctx* ctx, const(ubyte)[] data, bool final_, size_t part,
        ref bool tailWaits, scope void delegate() report)
    {
        size_t taken = 0;
        while (_scannedBytes < data.length && taken < part)
        {
            if (ctx.cancelled)
                return false;
            enforceSourceAvailable();

            size_t[bunchSize] offsets;
            const found = _format.scanRecords(data, _scannedBytes, offsets[], final_);
            if (found.next == _scannedBytes && found.count == 0)
            {
                assert(!final_, "scanning must make progress");
                tailWaits = true;
                break;
            }

            OffsetIndex.Type[bunchSize] tempIndex;
            foreach (i; 0 .. found.count)
                tempIndex[i].offset = offsets[i];

            synchronized (cast(Mutex)_mutex)
            {
                if (!_offsetIndex.append(tempIndex[0 .. found.count]))
                    throw new UiTextException(uiText("the offset index can't grow: too many records or not enough memory"));
            }
            _scannedBytes = found.next;
            taken += found.count;
            report();
        }
        return true;
    }

    //! @brief Appends to the search index the anchored messages the main view
    //! shows at the positions [from, to): what the search view lists without a search
    //! @return true if there were any
    private bool listAnchors(size_t from, size_t to, UiText full)
    {
        import std.algorithm : sort;

        bool listed = false;
        auto anchored = _anchors.exportAnchors;
        sort(anchored);
        synchronized (cast(Mutex)_mutex)
        {
            foreach (message; anchored)
            {
                size_t position;
                const bool shown = _viewIsFiltered ? sortedPositionOf(_filterIndex, message, position)
                    : (position = message) < _offsetIndex.length;
                if (!shown || position < from || position >= to)
                    continue;
                if (!_searchIndex.append(cast(SearchIndex.Type) message))
                    throw new UiTextException(full);
                listed = true;
            }
        }
        _searchScanned = to;
        return listed;
    }

    //! @brief Appends to `index`, in order, the messages of the positions
    //! [from, to) that are anchored or match `filter`. The positions are
    //! scanned in parallel blocks (utils/parallel_scan); what a block found is
    //! appended under the mutex as soon as it and the blocks before it are
    //! scanned.
    //! @param messageAt - the message index of a position; called concurrently,
    //!   so it may only read what doesn't change while the stage runs
    //! @param covered - told the position the index covers now, after every
    //!   block appended: a pass cancelled goes on from there
    //! @param full - the error for the user when the index can't grow
    //! @return false if the pass was cancelled
    private bool collectMatches(Index)(BackgroundSlot.Ctx* ctx, ref Index index, size_t from, size_t to,
        scope size_t delegate(size_t position) messageAt, Filter filter,
        scope void delegate(size_t done) covered, UiText full)
    {
        import utils.parallel_scan : parallelScan, ScanStop;

        const completed = parallelScan!(Index.Type)(to - from, scanBlockLength,
            (size_t lo, size_t hi, Index.Type[] found, ScanStop stop) {
                Message msg; // a buffer per block: blocks run on several threads
                size_t n = 0;
                foreach (position; from + lo .. from + hi)
                {
                    // A cancel or a lost file: the delivery of this block stops
                    // the scan, or fails it. A stop: it is never delivered
                    if ((position - from - lo) % stopCheckRecords == 0 && (ctx.cancelled || _source.lost || stop()))
                        break;
                    const message = messageAt(position);
                    if (!decodeAt(msg, _offsetIndex[message].offset))
                        continue;
                    if (_anchors.has(message) || filter.matches(msg))
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
                }
                covered(from + done);
                return true;
            });

        if (!completed)
            return false; // cancelled: a file lost meanwhile doesn't make it a failure
        enforceSourceAvailable(); // the last block may have read zeros
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

    //! @brief The row of the main view nearest to the message `realIndex`: its own, or of
    //! the first message after it the view shows, else the last row
    //! @return false if the view is empty
    bool mainViewNearestPositionOf(size_t realIndex, out size_t position) nothrow @nogc
    {
        auto lock = LockGuard(cast(Mutex)_mutex);
        if (!_viewIsFiltered)
            return nearestOf(realIndex, _offsetIndex.length, position);
        return sortedNearestOf(_filterIndex, realIndex, position);
    }

    //! The row of the search view nearest to the message `realIndex`, as of the main view
    bool searchViewNearestPositionOf(size_t realIndex, out size_t position) nothrow @nogc
    {
        auto lock = LockGuard(cast(Mutex)_mutex);
        return sortedNearestOf(_searchIndex, realIndex, position);
    }

    //! `position` (a row of `count`), or the last row past them; false if there are none
    private static bool nearestOf(size_t position, size_t count, out size_t nearest) pure nothrow @nogc @safe
    {
        if (count == 0)
            return false;
        nearest = position < count ? position : count - 1;
        return true;
    }

    //! The nearest position of `realIndex` in an index of message indexes sorted ascending
    private static bool sortedNearestOf(Index)(ref const(Index) index, size_t realIndex, out size_t position)
    {
        const bound = realIndex > Index.Type.max ? index.length : index.lowerBound(cast(Index.Type) realIndex);
        return nearestOf(bound, index.length, position);
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
        item.anchored = false;
        item.found = false;
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
        item.anchored = false;
        item.found = false;
        return true;
    }

}

version (unittest)
{
    //! Asks for a filter of the main view and starts the pass that builds it
    //! @return false if a pass is running
    private bool runBuildFilterIndex(ref LogIndex index, Filter filter, Anchors anchors)
    {
        if (index.busy)
            return false;
        index.setViewFilter(filter, anchors);
        return index.runPass();
    }

    //! Likewise for a search
    private bool runBuildSearchIndex(ref LogIndex index, Filter filter, Anchors anchors)
    {
        if (index.busy)
            return false;
        index.setSearchFilter(filter, anchors);
        return index.runPass();
    }

    //! Runs the pass `run` starts and waits for it to finish
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

    //! How a pass ended, and an operation of it, by their events
    private struct Ending
    {
        OperationFinished.Result result;
        float lastProgress = 0; // the last progress it reported (an event that overrides the earlier ones)
    }

    //! @return how the last pass the events of `events` tell of ended, with the
    //! progress of its operation `op`
    private Ending endingOf(EventBusAsync)(EventBusAsync events, Document.Operation op)
    {
        import core.thread : Thread;
        import core.time : msecs, MonoTime;

        Ending ending;
        bool seen = false;
        auto finished = events.subscribe((const PassFinished e) {
            ending.result = e.result;
            seen = true;
        });
        auto progress = events.subscribe((const OperationProgress e) {
            if (e.has(op))
                ending.lastProgress = e.of(op);
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

    //! Lines of text that come in parts: a source being written. Its bytes
    //! don't move as it grows
    private final class GrowingSource : ByteSource
    {
        private ubyte[] _room;
        private shared size_t _length;
        private shared bool _complete;

        this(size_t room)
        {
            _room = new ubyte[room];
        }

        void write(string text)
        {
            import core.atomic : atomicLoad, atomicStore;

            const length = atomicLoad(_length);
            _room[length .. length + text.length] = cast(const(ubyte)[]) text;
            atomicStore(_length, length + text.length);
        }

        void finish()
        {
            import core.atomic : atomicStore;

            atomicStore(_complete, true);
        }

        override const(ubyte)[] data() const pure nothrow @nogc
        {
            import core.atomic : atomicLoad;

            return _room[0 .. atomicLoad(_length)];
        }

        override bool complete() const nothrow @nogc
        {
            import core.atomic : atomicLoad;

            return atomicLoad(_complete);
        }

        override bool lost() const nothrow @nogc
        {
            return false;
        }

        override void close() nothrow @nogc
        {
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

        override bool complete() const nothrow @nogc
        {
            return true;
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

@("LogIndex: a source that grows is taken by the next pass: every index gets what was added")
unittest
{
    import utils.event_bus.event_bus_async : EventBusAsync;
    import formats.plain_text : PlainTextFormat;
    import log_core.search_filter : SearchChip, SearchFilter;
    import std.algorithm : map;
    import std.array : array;
    import std.range : iota;

    auto source = new GrowingSource(1024);
    source.write("one seven\ntwo\nthree seven five\nfo");
    auto events = new EventBusAsync();
    size_t grown;
    events.subscribe((const ContentGrown e) { ++grown; });

    auto index = LogIndex(source, new PlainTextFormat(), events);
    Anchors anchors;
    auto sevens = SearchFilter.fromChips([SearchChip("seven")]);
    auto fives = SearchFilter.fromChips([SearchChip("five")]);
    waitForOperation(index, () => index.runBuildFilterIndex(sevens, anchors));
    waitForOperation(index, () => index.runBuildSearchIndex(fives, anchors));
    assert(index.messageCount == 3, "the line cut by the end of the data is waited for");
    assert(index.mainViewItemsCount == 2 && index.searchViewItemsCount == 1);
    assert(!index.behind);
    events.dispatch();
    assert(grown == 0, "the load tells its progress, not a growth");

    // The rest of the cut line and more: only they are scanned, the rows of
    // before stay where they are
    source.write("ur seven five\nfive\nsix seven\n");
    assert(index.behind);
    waitForOperation(index, () => index.runPass());
    assert(index.messageCount == 6);
    assert(iota(index.mainViewItemsCount).map!(p => index._filterIndex[p]).array == [0, 2, 3, 5]);
    assert(iota(index.searchViewItemsCount).map!(p => index._searchIndex[p]).array == [2, 3]);
    assert(!index.behind);
    events.dispatch();
    assert(grown == 1);

    // The end of the source: what was left without its line end is a record
    source.write("seven five");
    waitForOperation(index, () => index.runPass());
    assert(index.messageCount == 6, "it may still get its end");
    source.finish();
    index._seenBytes = 0; // a source tells its end as it tells more bytes: not modelled here
    waitForOperation(index, () => index.runPass());
    assert(index.messageCount == 7 && index.mainViewItemsCount == 5 && index.searchViewItemsCount == 3);
}

@("LogIndex: the anchors listed after the end of a filter are told: a view shown by then counts them")
unittest
{
    import utils.event_bus.event_bus_async : EventBusAsync;
    import formats.plain_text : PlainTextFormat;
    import log_core.search_filter : SearchChip, SearchFilter;
    import std.algorithm : countUntil;
    import std.file : remove;
    import std.format : format;

    const path = writeLines("log_index_anchors_told", 1000, (size_t i) => format("line %s", i));
    scope (exit)
        remove(path);

    auto events = new EventBusAsync();
    auto index = LogIndex(new FileSource(path), new PlainTextFormat(), events);
    waitForOperation(index, () => true);
    events.dispatch();

    string[] told;
    events.subscribe((const StageFinished e) { told ~= "filter done"; });
    events.subscribe((const ContentGrown e) { told ~= "grown"; });
    Anchors anchors;
    anchors.set(5, true);
    auto every = SearchFilter.fromChips([SearchChip("line")]);
    waitForOperation(index, () => index.runBuildFilterIndex(every, anchors));
    events.dispatch();
    assert(index.searchViewItemsCount == 1);
    // The search view is shown as ready once the filter is done: what it
    // lists after that must be told, or its table never counts it
    assert(told.countUntil("grown") > told.countUntil("filter done"), format("%s", told));
}

@("LogIndex: a pass that was cancelled leaves what it did, the next one goes on from there")
unittest
{
    import utils.event_bus.event_bus_async : EventBusAsync;
    import formats.plain_text : PlainTextFormat;
    import log_core.search_filter : SearchChip, SearchFilter;
    import std.file : remove;
    import std.format : format;

    enum lines = 400_000;
    const path = writeLines("log_index_resume", lines, (size_t i) => format("line %s", i));
    scope (exit)
        remove(path);

    auto events = new EventBusAsync();
    auto index = LogIndex(new FileSource(path), new PlainTextFormat(), events);
    waitForOperation(index, () => true);

    // Cancelled by the first record it is asked about
    auto indexPtr = &index;
    auto every = SearchFilter.fromChips([SearchChip("line")]);
    auto filter = new CountingFilter(() { indexPtr.cancelCurrentOperation(); });
    waitForOperation(index, () => index.runBuildFilterIndex(filter, Anchors.init));
    assert(endingOf(events, Document.Operation.BuildFilterIndex).result == OperationFinished.Result.Cancelled);
    assert(index.behind, "the filter doesn't cover the file");

    // A search is asked for meanwhile: the pass goes on with both
    waitForOperation(index, () => index.runBuildSearchIndex(every, Anchors.init));
    assert(endingOf(events, Document.Operation.BuildSearchIndex).result == OperationFinished.Result.Completed);
    assert(index.mainViewItemsCount == 0 && index.searchViewItemsCount == 0, "the filter matches nothing");
    assert(index._filterScanned == lines && !index.behind);
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
