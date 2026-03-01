module domain.dlt_doc;

import dlt_core.dlt_log_filter;
import dlt_core.decoded_message;
import dlt_core.log_filter;
import dlt_core.dlt_source;
import dlt_core.dlt_parser : parseDltItem, parseDltItemWithFibex;
import dlt_core.fibex;

import domain.index.file_index;
import domain.index.filter_index;
import domain.index.search_index;

import core.atomic : atomicLoad, atomicStore;
import core.stdc.stdint : uint16_t, uint32_t;
import core.sync.mutex : Mutex;

//import std.parallelism : Task;

// todo: better naming

alias Filter = LogFilter!wchar;
alias Message = DecodedMessage!wchar;

struct DltDoc
{
    alias FilterFlags = uint16_t;

    private DltSource _source; // file with source data
    private FileIndex _fileIndex; // indecies of messages in the source file
    private FilterIndex _filterIndex; // indecies of messages that match the filter
    private SearchIndex _searchIndex; // indecies of messages that match the search
    private bool[size_t] _anchors; // anchors
    private bool _viewIsFiltered = false; // filtered view is enabled

    private Filter _filter; // filter for filtered view
    private Filter _searchFilter; // filter for search view

    private shared bool _cancelFlag = false; // cancel current operation
    private shared float _progress = 0.0f; // building index
    private Mutex _mutex; // mutex for building indexes

    enum maxAnchors = 16;
    enum bunchSize = 32; // number of messages to process in one bunch

    enum CurrentOperation
    {
        None,
        BuildFileIndex,
        BuildFilterIndex,
        BuildSearchIndex,
    }

    private CurrentOperation _currentOperation = CurrentOperation.None;

    this(string path)
    {
        _source = DltSource(path);

        const size_t capacity = _source.overallLength / 40 + 10_000;
        _fileIndex = FileIndex(capacity);
        _filterIndex = FilterIndex(capacity);
        _searchIndex = SearchIndex(capacity);
    }

    private bool canBuildIndex() const nothrow @nogc
    {
        return _currentOperation == CurrentOperation.None;
    }

    private bool canBuildFileIndex() const nothrow @nogc
    {
        return canBuildIndex();
    }

    private bool canBuildFilterIndex() const nothrow @nogc
    {
        return canBuildIndex();
    }

    private bool canBuildSearchIndex() const nothrow @nogc
    {
        return canBuildIndex();
    }

    private bool cancelRequested() const nothrow @nogc
    {
        return atomicLoad(_cancelFlag);
    }

    private void resetIndex()
    {
        _fileIndex.clear();
        _filterIndex.clear();
        _searchIndex.clear();
        _anchors.clear();
    }

    private void resetFilter()
    {
        _filterIndex.clear();
        _searchIndex.clear();
    }

    bool setAnchor(size_t index, bool value)
    {
        _anchors[index] = value;
        return true;
    }

    bool switchAnchor(size_t index)
    {
        // return (id in _idMap) !is null;
        _anchors[index] = !_anchors[index];
        return _anchors[index];
    }

    const(bool[size_t]) anchors() const pure nothrow @nogc
    {
        return _anchors;
    }

    void udpateFilterAndSearchIndexes(scope ref const(Message) msg, uint32_t fileIndex)
    {
        const bool isAnchoredMsg = (fileIndex in _anchors) !is null;

        if (isAnchoredMsg || _filter.matches(msg))
        {
            _filterIndex.append(fileIndex);
        }

        if (isAnchoredMsg || _searchFilter.matches(msg))
        {
            _searchIndex.append(fileIndex);
        }
    }

    void udpateSearchIndexes(scope ref const(Message) msg, uint32_t fileIndex)
    {
        const bool isAnchoredMsg = (fileIndex in _anchors) !is null;

        if (isAnchoredMsg || _searchFilter.matches(msg))
        {
            _searchIndex.append(fileIndex);
        }
    }

    //! @brief build file index, also rebuild filter and search indexes
    //! @param cancelFlag - flag to cancel the build process
    //! @return true if the build process was completed successfully, false otherwise
    bool buildFileIndex()
    {
        synchronized (_mutex)
        {
            _fileIndex.clear();
            _filterIndex.clear();
            _searchIndex.clear();
        }

        auto range = _source.range();

        while (range.hasNext)
        {
            if (cancelRequested())
            {
                return false;
            }

            FileIndex.Type[bunchSize] tempIndex;

            for (size_t i = 0; i < bunchSize && range.hasNext; ++i)
            {
                const auto msg = range.pop();
                if (msg.length == 0)
                    break;

                tempIndex[i] = range.offset;
            }

            synchronized (_mutex)
            {
                _fileIndex.append(tempIndex);
                _progress = cast(float)(range.offset) / range.overallLength;
            }
        }

        return true;
    }

    //! @brief build filter index, also rebuild search index
    //! @param cancelFlag - flag to cancel the build process
    //! @return true if the build process was completed successfully, false otherwise
    bool buildFilterIndex()
    {
        bool[size_t] localAnchors;
        Filter localFilter;

        synchronized (_mutex)
        {
            localAnchors = _anchors.dup();
            localFilter = _filter.dup();
            _filterIndex.clear();
            _searchIndex.clear();
        }

        auto isMatched = (ref const(Message) msg, size_t fileIndex) {
            const bool isAnchoredMsg = (fileIndex in localAnchors) !is null;
            return isAnchoredMsg || localFilter.matches(msg);
        };

        uint32_t messageIndex = 0;
        Message parsedMsg;
        auto range = _source.range();

        while (range.hasNext)
        {
            if (cancelRequested())
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
                _progress = cast(float)(range.offset) / range.overallLength;
            }
        }

        return true;
    }

    //! @brief build search index
    //! @param cancelFlag - flag to cancel the build process
    //! @return true if the build process was completed successfully, false otherwise
    bool buildSearchIndex()
    {
        bool[size_t] localAnchors;
        Filter localFilter;

        synchronized (_mutex)
        {
            localAnchors = _anchors.dup();
            localFilter = _searchFilter.dup();
            _searchIndex.clear();
        }

        auto isMatched = (ref const(Message) msg, size_t fileIndex) {
            const bool isAnchoredMsg = (fileIndex in localAnchors) !is null;
            return isAnchoredMsg || localFilter.matches(msg);
        };

        // Build a read-only list of file offsets to iterate over
        const size_t indexLen = _viewIsFiltered ? _filterIndex.length : _fileIndex.length;
        const bool hasStorageHeader = _source.hasStorageHeader;

        uint32_t messageIndex = 0;
        Message parsedMsg;
        SearchIndex.Type[bunchSize] tempIndex;
        size_t pos = 0;

        while (pos < indexLen)
        {
            if (cancelRequested())
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
                const size_t fileOffset = _viewIsFiltered ? _fileIndex[_filterIndex[i]]
                    : _fileIndex[i];
                const auto msgBytes = _source.getMessage(fileOffset);

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
                _progress = cast(float) batchEnd / indexLen;
            }

            pos = batchEnd;
        }

        return true;
    }
}
