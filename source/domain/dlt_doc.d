module domain.dlt_doc;

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

interface DocumentView
{
    enum State
    {
        NotReady,
        Ready,
        BuildingIndex,
        Error,
    }

    size_t itemsCount() nothrow @nogc;

    bool fetchItem(size_t index, scope ref DocumentItem item);

    State state() const;

    float progress() const; // return 1.0 if ready

    void enableFilter(bool enable);

    bool isFilterEnabled() const;

    //void applyFilter(Filter filter);

    //void resetFilter();
}

//! @brief Holds DLT file data and its associated indexes.
//! Responsible for:
//!   * Creating and maintaining indexes,
//!   * Updating indexes in the background and
//!     providing safe concurrent access to them from the GUI thread and the indexing thread.
//!
//! @brief This struct is not thread-safe. It is assumed that all access occurs
//! from the GUI thread only. It does, however, provide safe background index updates
//! and concurrent read access to the DLT file content.
struct DltDoc
{
    private alias Scoped(T) = typeof(scoped!T(string.init, bool.init));

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

    enum CurrentOperation
    {
        None,
        BuildOffsetIndex,
        BuildFilterIndex,
        BuildSearchIndex,
    }

    private CurrentOperation _currentOperation = CurrentOperation.None;

    //private MainView _mainView;
    //private SearchView _searchView;

    //private TaskPool _taskPool;

    private BackgroundSlot _backgroundSlot;

    private Mutex _mutex; // mutex for building indexes

    this(string path)
    {
        _source = scoped!DltSourceFile(path);

        const size_t capacity = _source.overallLength / 40 + 10_000;
        _offsetIndex = OffsetIndex(capacity);
        _filterIndex = FilterIndex(capacity);
        _searchIndex = SearchIndex(capacity);

        //_mainView = new MainView(&this);
        //_searchView = new SearchView(&this);

        _backgroundSlot = BackgroundSlot(null);

        _mutex = new Mutex();
    }

    bool busy() const @nogc
    {
        synchronized (_mutex)
        {
            return _currentOperation != CurrentOperation.None;
        }
    }

    private void runBuildOffsetIndex()
    {
        _backgroundSlot.runTask((BackgroundSlot.Ctx* ctx) {
            buildOffsetIndex(ctx);
        });
    }

    private void runBuildFilterIndex(Filter filter, Anchors anchors)
    {
        _backgroundSlot.runTask((BackgroundSlot.Ctx* ctx) {
            buildFilterIndex(ctx, filter, anchors);
        });
    }

    private void runBuildSearchIndex(Filter filter, Anchors anchors)
    {
        _backgroundSlot.runTask((BackgroundSlot.Ctx* ctx) {
            buildSearchIndex(ctx, filter, anchors);
        });
    }

    void enableFilter(bool enable)
    {
        synchronized (_mutex)
        {
            //if (_filterIndex.isReady)
            _viewIsFiltered = enable;
        }
    }

    DocumentView.State state() const
    {
        synchronized (_mutex)
        {
            if (_currentOperation == CurrentOperation.None)
                return DocumentView.State.Ready;
            return DocumentView.State.BuildingIndex;
        }
    }

    //! @brief build file index, also rebuild filter and search indexes
    //! @param cancelFlag - flag to cancel the build process
    //! @return true if the build process was completed successfully, false otherwise
    private bool buildOffsetIndex(BackgroundSlot.Ctx* ctx)
    {
        synchronized (_mutex)
        {
            _currentOperation = CurrentOperation.BuildOffsetIndex;

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
            {
                return false;
            }

            OffsetIndex.Type[bunchSize] tempIndex;

            for (size_t i = 0; i < bunchSize && range.hasNext; ++i)
            {
                const auto msg = range.pop();
                if (msg.length == 0)
                    break;

                tempIndex[i].offset = range.offset;
            }

            synchronized (_mutex)
            {
                _offsetIndex.append(tempIndex);
                ctx.progress = cast(float)(range.offset) / range.overallLength;
            }
        }

        synchronized (_mutex)
        {
            _offsetIndex.isReady = true;
            ctx.progress = 1.0f;
        }

        return true;
    }

    //! @brief build filter index, also rebuild search index
    //! @param cancelFlag - flag to cancel the build process
    //! @return true if the build process was completed successfully, false otherwise
    private bool buildFilterIndex(BackgroundSlot.Ctx* ctx, Filter filter, Anchors anchors)
    {
        synchronized (_mutex)
        {
            _currentOperation = CurrentOperation.BuildOffsetIndex;

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

            for (size_t i = 0; i < bunchSize && range.hasNext; ++i)
            {
                const auto msg = range.pop();
                if (msg.length == 0)
                    break;

                parseDltItem!wchar(parsedMsg, msg, range.hasStorageHeader);

                if (isMatched(parsedMsg, messageIndex))
                {
                    tempIndex[i] = messageIndex;
                }

                ++messageIndex;
            }

            synchronized (_mutex)
            {
                _filterIndex.append(tempIndex);
                ctx.progress = cast(float)(range.offset) / range.overallLength;
            }
        }

        synchronized (_mutex)
        {
            _filterIndex.isReady = true;
            ctx.progress = 1.0f;
        }

        return true;
    }

    //! @brief build search index
    //! @param cancelFlag - flag to cancel the build process
    //! @return true if the build process was completed successfully, false otherwise
    private bool buildSearchIndex(BackgroundSlot.Ctx* ctx, Filter filter, Anchors anchors)
    {
        synchronized (_mutex)
        {
            _currentOperation = CurrentOperation.BuildSearchIndex;

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

        uint32_t messageIndex = 0;
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
                const auto fileOffset = _viewIsFiltered ? _offsetIndex[_filterIndex[i]]
                    : _offsetIndex[i];
                const auto msgBytes = _source.getMessage(fileOffset.offset);

                parseDltItem!wchar(parsedMsg, msgBytes, hasStorageHeader);

                if (isMatched(parsedMsg, i))
                {
                    tempIndex[tempLen++] = cast(SearchIndex.Type) i;
                }

                ++messageIndex;
            }

            synchronized (_mutex)
            {
                _searchIndex.append(tempIndex[0 .. tempLen]);
                ctx.progress = cast(float) batchEnd / indexLen;
            }

            pos = batchEnd;
        }

        synchronized (_mutex)
        {
            _searchIndex.isReady = true;
            ctx.progress = 1.0f;
        }

        return true;
    }

    /// 
    /// Views
    ///

    private final class MainView : DocumentView
    {
        private DltDoc* _doc;

        this(DltDoc* doc)
        {
            _doc = doc;
        }

        override size_t itemsCount() nothrow @nogc
        {
            auto lock = LockGuard(_doc._mutex);
            return _doc._viewIsFiltered ? _doc._filterIndex.length : _doc._offsetIndex.length;
        }

        override bool fetchItem(size_t index, scope ref DocumentItem item)
        {
            OffsetIndexItem fileOffset;

            {
                auto lock = LockGuard(_doc._mutex);

                if (_doc._viewIsFiltered)
                {
                    index = cast(size_t) _doc._filterIndex[index];

                    const size_t count = _doc._filterIndex.length;

                    if (index >= count)
                        return false;
                }
                else
                {
                    if (index >= _doc._offsetIndex.length)
                        return false;
                }

                fileOffset = _doc._offsetIndex[index];
            }

            const auto msgBytes = _doc._source.getMessage(fileOffset.offset);
            parseDltItem!wchar(item._decodedMessage, msgBytes, _doc._source.hasStorageHeader);
            item.realIndex = index;
            item.filterMask = fileOffset.filterMask;
            item.searchMask = 0;
            item.anchored = false;
            item.selected = false;
            return true;
        }

        override State state() const
        {
            return _doc.state();
        }

        override float progress() const
        {
            return _doc._backgroundSlot.progress();
        }

        override void enableFilter(bool enable)
        {
            synchronized (_doc._mutex)
            {
                _doc._viewIsFiltered = enable;
            }
        }

        override bool isFilterEnabled() const
        {
            synchronized (_doc._mutex)
            {
                return _doc._viewIsFiltered;
            }
        }
    }

    private final class SearchView : DocumentView
    {
        private DltDoc* _doc;

        this(DltDoc* doc)
        {
            _doc = doc;
        }

        override size_t itemsCount() nothrow @nogc
        {
            auto lock = LockGuard(_doc._mutex);
            return _doc._searchIndex.length;
        }

        override bool fetchItem(size_t index, scope ref DocumentItem item)
        {
            OffsetIndexItem fileOffset;

            {
                auto lock = LockGuard(_doc._mutex);
                if (index >= _doc._searchIndex.length)
                    return false;

                fileOffset = _doc._offsetIndex[_doc._searchIndex[index]];
            }

            const auto msgBytes = _doc._source.getMessage(fileOffset.offset);
            parseDltItem!wchar(item._decodedMessage, msgBytes, _doc._source.hasStorageHeader);
            item.realIndex = index;
            item.filterMask = fileOffset.filterMask;
            item.searchMask = 0;
            item.anchored = false;
            item.selected = false;
            return true;
        }

        override State state() const
        {
            return _doc.state();
        }

        override float progress() const
        {
            return _doc._backgroundSlot.progress();
        }

        override void enableFilter(bool enable)
        {
            // do nothing
        }

        override bool isFilterEnabled() const
        {
            return false;
        }
    }

}
