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
import core.stdc.stdint : uint32_t;

// todo: better naming

alias Filter = LogFilter!wchar;
alias Message = DecodedMessage!wchar;

struct DltDoc
{
    private DltSource _source;
    private FileIndex _fileIndex;
    private FilterIndex _filterIndex;
    private SearchIndex _searchIndex;
    private bool[size_t] _anchors;

    enum maxAnchors = 16;

    this(string path)
    {
        _source = DltSource(path);

        const size_t capacity = _source.overallLength / 40 + 10_000;
        _fileIndex = FileIndex(capacity);
        _filterIndex = FilterIndex(capacity);
        _searchIndex = SearchIndex(capacity);
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

    void buildFileIndex(shared ref bool cancelFlag)
    {
        _fileIndex.clear();

        auto range = _source.range();

        while (range.hasNext && !atomicLoad(cancelFlag))
        {
            auto msg = range.pop();
            if (msg.length == 0)
                break;

            _fileIndex.append(range.offset);
        }
    }

    void buildFilterIndex(shared ref bool cancelFlag, Filter filter)
    {
        _filterIndex.clear();

        uint32_t messageIndex = 0;
        Message parsedMsg;
        auto range = _source.range();

        while (range.hasNext && !atomicLoad(cancelFlag))
        {
            auto msg = range.pop();
            if (msg.length == 0)
                break;

            parseDltItem!wchar(parsedMsg, msg, range.hasStorageHeader);

            if (filter.matches(parsedMsg))
            {
                _filterIndex.append(messageIndex);
            }

            ++messageIndex;
        }
    }

    void buildSearchIndex(shared ref bool cancelFlag, Filter filter)
    {
        _searchIndex.clear();

        uint32_t messageIndex = 0;
        Message parsedMsg;
        auto range = _source.range();

        while (range.hasNext && !atomicLoad(cancelFlag))
        {
            auto msg = range.pop();
            if (msg.length == 0)
                break;

            parseDltItem!wchar(parsedMsg, msg, range.hasStorageHeader);

            if (filter.matches(parsedMsg))
            {
                _searchIndex.append(messageIndex);
            }

            ++messageIndex;
        }
    }
}
