module domain.dlt_index;

import dlt_core.dlt_log_filter;
import dlt_core.decoded_message;
import dlt_core.log_filter;
import dlt_core.dlt_source;
import dlt_core.dlt_parser : parseDltItem, parseDltItemWithFibex;
import dlt_core.fibex;

import domain.index.offset_index;
import domain.index.filter_index;
import domain.index.search_index;
import domain.index.index_builders;
import domain.index.anchors;
import domain.background_slot;
import domain.document_item;
import domain.document : Document, OperationStarted, OperationProgress, OperationFinished;

import event_bus.event_bus_interface : SignalProducer;

import utils.lock_guard;

import std.typecons;
import std.parallelism;

import core.atomic : atomicLoad, atomicStore;
import core.stdc.stdint : uint16_t, uint32_t;
import core.sync.mutex : Mutex;

//import std.parallelism : Task;

// todo: better naming

alias Filter = LogFilter!wchar;
alias Message = DecodedMessage!wchar;

//! @brief Holds DLT file data and its associated indexes.
//! Responsible for:
//!   * Creating and maintaining indexes,
//!   * Updating indexes in the background and
//!     providing safe concurrent access to them from the GUI thread and the indexing thread.
//!
//! @brief This struct is not thread-safe. It is assumed that all access occurs
//! from the GUI thread only. It does, however, provide safe background index updates
//! and concurrent read access to the DLT file content.
struct DltIndex
{
    private alias Scoped(T) = typeof(scoped!T(string.init, bool.init));
    private alias ScopedMutex = typeof(scoped!Mutex());

    private Scoped!DltSourceFile _source; // file with source data
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

    private Operation _currentOperation = Operation.None; // valid while _backgroundSlot is busy
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

    this(string path, SignalProducer events)
    {
        _events = events;

        _source = scoped!DltSourceFile(path);

        const size_t capacity = _source.overallLength / 40 + 10_000;
        _offsetIndex = OffsetIndex(capacity);
        _filterIndex = FilterIndex(capacity);
        _searchIndex = SearchIndex(capacity);

        _backgroundSlot = BackgroundSlot(null);

        _mutex = scoped!Mutex();

        runBuildOffsetIndex();
    }

    ~this()
    {
        // Mutex is now scoped and managed automatically
    }

    Operation currentOperation()
    {
        synchronized (cast(Mutex)_mutex)
        {
            return _backgroundSlot.busy() ? _currentOperation : Operation.None;
        }
    }

    bool busy()
    {
        return currentOperation() != Operation.None;
    }

    void cancelCurrentOperation()
    {
        _backgroundSlot.cancel();
    }

    float currentOperationProgress() const @nogc
    {
        return _backgroundSlot.progress();
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
        synchronized (cast(Mutex)_mutex)
        {
            if (_backgroundSlot.busy())
                return false;

            // Set before the thread starts: state() must never see a running
            // slot together with a stale operation.
            _currentOperation = op;
            _events.publish(OperationStarted(op));

            auto finished = OperationFinished(op, OperationFinished.Result.Completed);
            auto events = _events;

            const bool started = _backgroundSlot.runTask((BackgroundSlot.Ctx* ctx) {
                auto progress = ProgressReporter(events, op, ctx);
                try
                {
                    if (!work(progress))
                        finished.result = OperationFinished.Result.Cancelled;
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

        auto range = _source.range();

        while (range.hasNext)
        {
            if (ctx.cancelled)
                return false;

            OffsetIndex.Type[bunchSize] tempIndex;
            size_t n = 0; // items written into tempIndex this batch

            while (n < bunchSize && range.hasNext)
            {
                const size_t msgStart = range.offset; // offset BEFORE pop
                const auto msg = range.pop();
                if (msg.length == 0)
                    break;

                tempIndex[n++].offset = msgStart;
            }

            synchronized (cast(Mutex)_mutex)
            {
                _offsetIndex.append(tempIndex[0 .. n]); // only populated slice
                progress.report(cast(float)(range.offset) / range.overallLength);
            }
        }

        synchronized (cast(Mutex)_mutex)
        {
            _offsetIndex.isReady = true;
            progress.report(1.0f);
        }

        return true;
    }

    //! @brief build filter index, also rebuild search index
    //! @param progress - progress reporter, also gives access to the cancel flag
    //! @return true if the build process was completed successfully, false otherwise
    private bool buildFilterIndex(ref ProgressReporter progress, Filter filter, Anchors anchors)
    {
        auto ctx = progress.ctx;
        synchronized (cast(Mutex)_mutex)
        {
            _filterIndex.clear();
            _searchIndex.clear();
            _filterIndex.isReady = false;
            _searchIndex.isReady = false;
        }

        auto isMatched = (ref const(Message) msg, size_t fileIndex) {
            const bool isAnchoredMsg = anchors.has(fileIndex);
            return isAnchoredMsg || filter.matches(msg);
        };

        uint32_t messageIndex = 0;
        Message parsedMsg;
        auto range = _source.range();

        while (range.hasNext)
        {
            if (ctx.cancelled)
            {
                return false;
            }

            FilterIndex.Type[bunchSize] tempIndex;
            size_t n = 0; // items written into tempIndex this batch

            while (n < bunchSize && range.hasNext)
            {
                const auto msg = range.pop();
                if (msg.length == 0)
                    break;

                parseDltItem!wchar(parsedMsg, msg, range.hasStorageHeader);

                if (isMatched(parsedMsg, messageIndex))
                    tempIndex[n++] = messageIndex;

                ++messageIndex;
            }

            synchronized (cast(Mutex)_mutex)
            {
                _filterIndex.append(tempIndex[0 .. n]); // only matched entries
                progress.report(cast(float)(range.offset) / range.overallLength);
            }
        }

        synchronized (cast(Mutex)_mutex)
        {
            _filterIndex.isReady = true;
            progress.report(1.0f);
        }

        return true;
    }

    //! @brief build search index
    //! @param progress - progress reporter, also gives access to the cancel flag
    //! @return true if the build process was completed successfully, false otherwise
    private bool buildSearchIndex(ref ProgressReporter progress, Filter filter, Anchors anchors)
    {
        auto ctx = progress.ctx;
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
        const bool hasStorageHeader = _source.hasStorageHeader;

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

            size_t batchEnd = pos + bunchSize;
            if (batchEnd > indexLen)
                batchEnd = indexLen;

            size_t tempLen = 0;
            for (size_t i = pos; i < batchEnd; ++i)
            {
                const uint32_t globalIndex = _viewIsFiltered ? _filterIndex[i] : cast(uint32_t) i;
                const auto fileOffset = _offsetIndex[globalIndex];
                const auto msgBytes = _source.getMessage(fileOffset.offset);

                parseDltItem!wchar(parsedMsg, msgBytes, hasStorageHeader);

                if (isMatched(parsedMsg, globalIndex))
                {
                    tempIndex[tempLen++] = globalIndex;
                }
            }

            synchronized (cast(Mutex)_mutex)
            {
                _searchIndex.append(tempIndex[0 .. tempLen]);
                progress.report(cast(float) batchEnd / indexLen);
            }

            pos = batchEnd;
        }

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
                index = cast(size_t) _filterIndex[index];

                const size_t count = _filterIndex.length;

                if (index >= count)
                    return false;
            }
            else
            {
                if (index >= _offsetIndex.length)
                    return false;
            }

            fileOffset = _offsetIndex[index];
        }

        const auto msgBytes = _source.getMessage(fileOffset.offset);
        parseDltItem!wchar(item._decodedMessage, msgBytes, _source.hasStorageHeader);
        item.realIndex = index;
        item.filterMask = fileOffset.filterMask;
        item.searchMask = 0;
        item.anchored = false;
        item.selected = false;
        return true;
    }

    void enableMainViewFilter(bool enable)
    {
        synchronized (cast(Mutex)_mutex)
        {
            _viewIsFiltered = enable;
        }
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

        const auto msgBytes = _source.getMessage(fileOffset.offset);
        parseDltItem!wchar(item._decodedMessage, msgBytes, _source.hasStorageHeader);
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
