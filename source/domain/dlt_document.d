module domain.dlt_document;

import domain.document;
import domain.document_item;
import domain.document_id;

import dlt_core.dlt_source;
import dlt_core.dlt_log_filter;
import dlt_core.decoded_message;
import dlt_core.log_filter;

import domain.index.offset_index;
import domain.index.filter_index;
import domain.index.search_index;

import std.parallelism : Task, TaskPool;
import std.typecons : scoped;
import core.sync.mutex : Mutex;

class DltDocument : Document
{
    //private alias Scoped(T) = typeof(scoped!T(string.init, bool.init));

    private DltSourceFile _source;
    private DocumentId _id;

    private DocumentView _rawView;
    private DocumentView _filteredView;
    private DocumentView _searchView;

    private LogFilter!wchar _viewFilter;
    private LogFilter!wchar _searchFilter;
    private OffsetIndex _offsetIndex;
    private FilterIndex _filterIndex;
    private SearchIndex _searchIndex;

    private TaskPool _taskPool;
    private Mutex _mutex;
    private string _sourcePath;

    private shared bool _cancelFileLoad;
    private shared bool _cancelFilterLoad;
    private shared bool _cancelSearchLoad;

    this(DocumentId id)
    {
        _id = id;
        _rawView = new RawDocumentView();
        _filteredView = new FilteredDocumentView();
        _searchView = new SearchDocumentView();
        _mutex = new Mutex();
    }

    void loadSource(string path)
    {
        import std.parallelism : task, taskPool;
        import core.atomic : atomicStore;

        _sourcePath = path;
        _source = new DltSourceFile(path);

        const size_t capacity = _source.overallLength / 4 + 10_000;

        synchronized (_mutex)
        {
            _offsetIndex = OffsetIndex(capacity);
            _filterIndex = FilterIndex(capacity);
            _searchIndex = SearchIndex(capacity);
        }

        atomicStore(_cancelFileLoad, false);
        atomicStore(_cancelFilterLoad, true); // Don't start filter/search until applied
        atomicStore(_cancelSearchLoad, true);

        auto t = task!indexWorker(this, path, _source.hasStorageHeader);
        taskPool.put(t);
    }

    private static void indexWorker(DltDocument doc, string path, bool hasStorageHeader)
    {
        import std.stdint : uint32_t;

        import core.atomic : atomicLoad;

        auto localSource = scoped!DltSourceFile(path, hasStorageHeader);
        auto dataRange = localSource.range();

        OffsetIndex.Type[16_384] buffer;
        size_t count = 0;

        while (true)
        {
            if (atomicLoad(doc._cancelFileLoad))
                break;

            auto msg = dataRange.pop();
            if (msg.length == 0)
                break;

            buffer[count++].offset = dataRange.offset;

            if (count == buffer.length)
            {
                synchronized (doc._mutex)
                {
                    doc._offsetIndex.append(buffer[]);
                }
                count = 0;
            }
        }

        synchronized (doc._mutex)
        {
            if (count > 0)
            {
                doc._offsetIndex.append(buffer[0 .. count]);
            }
            doc._offsetIndex.isReady = true;
        }
    }

    override DocumentView rawView()
    {
        return _rawView;
    }

    override DocumentView filteredView()
    {
        return _filteredView;
    }

    override DocumentView searchView()
    {
        return _searchView;
    }

    override DocumentId id() const
    {
        return _id;
    }

    override string sourcePath() const
    {
        return "";
    }

    override string fibexPath() const
    {
        return "";
    }

    override string filterPath() const
    {
        return "";
    }

    override void openFibex(string path)
    {
        //_source.openFibex(path);
    }

    override void applyViewFilter(LogFilter!wchar filter)
    {
        import std.parallelism : task, taskPool;
        import core.atomic : atomicStore;

        synchronized (_mutex)
        {
            _viewFilter = filter;
            _filterIndex.clear();
            _filterIndex.isReady = false;
        }

        atomicStore(_cancelFilterLoad, false);
        if (_sourcePath.length > 0)
        {
            auto t = task!filterWorker(this, _sourcePath, _source.hasStorageHeader);
            taskPool.put(t);
        }
    }

    override void applySearchFilter(LogFilter!wchar filter)
    {
        import std.parallelism : task, taskPool;
        import core.atomic : atomicStore;

        synchronized (_mutex)
        {
            _searchFilter = filter;
            _searchIndex.clear();
            _searchIndex.isReady = false;
        }

        atomicStore(_cancelSearchLoad, false);
        if (_sourcePath.length > 0)
        {
            auto t = task!searchWorker(this, _sourcePath, _source.hasStorageHeader);
            taskPool.put(t);
        }
    }

    void cancelFileLoad()
    {
        import core.atomic : atomicStore;

        atomicStore(_cancelFileLoad, true);
    }

    void cancelFilterLoad()
    {
        import core.atomic : atomicStore;

        atomicStore(_cancelFilterLoad, true);
    }

    void cancelSearchLoad()
    {
        import core.atomic : atomicStore;

        atomicStore(_cancelSearchLoad, true);
    }

    private static void filterWorker(DltDocument doc, string path, bool hasStorageHeader)
    {
        import std.stdint : uint32_t;
        import core.atomic : atomicLoad;
        import core.thread : Thread;
        import core.time : msecs;
        import dlt_core.dlt_parser : parseDltItem;

        auto localSource = scoped!DltSourceFile(path, hasStorageHeader);
        DecodedMessage!wchar msg;

        uint32_t[16_384] buffer;
        size_t count = 0;
        uint32_t fileIndexPos = 0;

        while (true)
        {
            if (atomicLoad(doc._cancelFilterLoad))
                break;

            bool hasMore;
            size_t offset = 0;
            LogFilter!wchar filter;

            synchronized (doc._mutex)
            {
                hasMore = fileIndexPos < doc._offsetIndex.length;
                if (hasMore)
                    offset = doc._offsetIndex[fileIndexPos].offset;
                filter = doc._viewFilter;
            }

            if (!hasMore)
            {
                bool isReady;
                synchronized (doc._mutex)
                {
                    isReady = doc._offsetIndex.isReady;
                }
                if (isReady)
                    break;

                Thread.sleep(10.msecs);
                continue;
            }

            auto rawMsg = cast(const(ubyte)[]) localSource.getMessage(offset);
            if (parseDltItem(msg, rawMsg, hasStorageHeader))
            {
                if (filter is null || filter.matches(msg))
                {
                    buffer[count++] = fileIndexPos;
                    if (count == buffer.length)
                    {
                        synchronized (doc._mutex)
                        {
                            doc._filterIndex.append(buffer[]);
                        }
                        count = 0;
                    }
                }
            }
            fileIndexPos++;
        }

        synchronized (doc._mutex)
        {
            if (count > 0)
                doc._filterIndex.append(buffer[0 .. count]);
            doc._filterIndex.isReady = true;
        }
    }

    private static void searchWorker(DltDocument doc, string path, bool hasStorageHeader)
    {
        import std.stdint : uint32_t;
        import core.atomic : atomicLoad;
        import core.thread : Thread;
        import core.time : msecs;
        import dlt_core.dlt_parser : parseDltItem;

        auto localSource = scoped!DltSourceFile(path, hasStorageHeader);
        DecodedMessage!wchar msg;

        uint32_t[16_384] buffer;
        size_t count = 0;
        uint32_t fileIndexPos = 0;

        while (true)
        {
            if (atomicLoad(doc._cancelSearchLoad))
                break;

            bool hasMore;
            size_t offset = 0;
            LogFilter!wchar filter;

            synchronized (doc._mutex)
            {
                hasMore = fileIndexPos < doc._offsetIndex.length;
                if (hasMore)
                    offset = doc._offsetIndex[fileIndexPos].offset;
                filter = doc._searchFilter;
            }

            if (!hasMore)
            {
                bool isReady;
                synchronized (doc._mutex)
                {
                    isReady = doc._offsetIndex.isReady;
                }
                if (isReady)
                    break;

                Thread.sleep(10.msecs);
                continue;
            }

            auto rawMsg = cast(const(ubyte)[]) localSource.getMessage(offset);
            if (parseDltItem(msg, rawMsg, hasStorageHeader))
            {
                if (filter is null || filter.matches(msg))
                {
                    buffer[count++] = fileIndexPos;
                    if (count == buffer.length)
                    {
                        synchronized (doc._mutex)
                        {
                            doc._searchIndex.append(buffer[]);
                        }
                        count = 0;
                    }
                }
            }
            fileIndexPos++;
        }

        synchronized (doc._mutex)
        {
            if (count > 0)
                doc._searchIndex.append(buffer[0 .. count]);
            doc._searchIndex.isReady = true;
        }
    }

    /// Views

    private class RawDocumentView : DocumentView
    {
        override size_t itemsCount() pure nothrow @nogc const
        {
            return this.outer._offsetIndex.length;
        }

        override bool fetchItem(size_t index, out DocumentItem item)
        {
            import std.stdint : uint32_t;
            import dlt_core.dlt_parser : parseDltItem;

            size_t offset = 0;

            synchronized (this.outer._mutex)
            {
                if (index < this.outer._offsetIndex.length)
                    offset = this.outer._offsetIndex[index].offset;
                else
                    return false;
            }

            auto rawMsg = cast(const(ubyte)[]) this.outer._source.getMessage(offset);
            if (!parseDltItem(item._decodedMessage, rawMsg, this.outer._source.hasStorageHeader))
                return false;

            item.realIndex = index;
            // metadata logic (masks, filters) could be evaluated here, placeholder for now
            return true;
        }

        override DocumentView.State state() const
        {
            import core.atomic : atomicLoad;

            if (atomicLoad(this.outer._cancelFileLoad))
                return DocumentView.State.Error;

            bool ready;
            synchronized (cast(Mutex) this.outer._mutex)
            {
                ready = this.outer._offsetIndex.isReady;
            }

            return ready ? DocumentView.State.Ready : DocumentView.State.BuildingIndex;
        }

        override double progress() const
        {
            bool ready;
            synchronized (cast(Mutex) this.outer._mutex)
            {
                ready = this.outer._offsetIndex.isReady;
            }

            if (ready)
                return 1.0;
            return 0.5;
        }
    }

    private class FilteredDocumentView : DocumentView
    {
        override size_t itemsCount() pure nothrow @nogc const
        {
            return this.outer._filterIndex.length;
        }

        override bool fetchItem(size_t index, out DocumentItem item)
        {
            import std.stdint : uint32_t;
            import dlt_core.dlt_parser : parseDltItem;

            uint32_t offset = 0;

            synchronized (this.outer._mutex)
            {
                if (index < this.outer._filterIndex.length)
                    offset = this.outer._filterIndex[index];
                else
                    return false;
            }

            auto rawMsg = cast(const(ubyte)[]) this.outer._source.getMessage(offset);
            if (!parseDltItem(item._decodedMessage, rawMsg, this.outer._source.hasStorageHeader))
                return false;

            item.realIndex = index; // or matched logic if tracking index from original file
            return true;
        }

        override DocumentView.State state() const
        {
            import core.atomic : atomicLoad;

            if (atomicLoad(this.outer._cancelFilterLoad))
                return DocumentView.State.NotReady; // Uninitialized if unset/canceled

            bool ready;
            synchronized (cast(Mutex) this.outer._mutex)
            {
                ready = this.outer._filterIndex.isReady;
            }

            return ready ? DocumentView.State.Ready : DocumentView.State.BuildingIndex;
        }

        override double progress() const
        {
            bool ready;
            synchronized (cast(Mutex) this.outer._mutex)
            {
                ready = this.outer._filterIndex.isReady;
            }

            if (ready)
                return 1.0;
            return 0.5;
        }
    }

    private class SearchDocumentView : DocumentView
    {
        override size_t itemsCount() pure nothrow @nogc const
        {
            return this.outer._searchIndex.length;
        }

        override bool fetchItem(size_t index, out DocumentItem item)
        {
            import std.stdint : uint32_t;
            import dlt_core.dlt_parser : parseDltItem;

            uint32_t offset = 0;

            synchronized (this.outer._mutex)
            {
                if (index < this.outer._searchIndex.length)
                    offset = this.outer._searchIndex[index];
                else
                    return false;
            }

            auto rawMsg = cast(const(ubyte)[]) this.outer._source.getMessage(offset);
            if (!parseDltItem(item._decodedMessage, rawMsg, this.outer._source.hasStorageHeader))
                return false;

            item.realIndex = index;
            return true;
        }

        override DocumentView.State state() const
        {
            import core.atomic : atomicLoad;

            if (atomicLoad(this.outer._cancelSearchLoad))
                return DocumentView.State.NotReady; // Uninitialized/canceled

            bool ready;
            synchronized (cast(Mutex) this.outer._mutex)
            {
                ready = this.outer._searchIndex.isReady;
            }

            return ready ? DocumentView.State.Ready : DocumentView.State.BuildingIndex;
        }

        override double progress() const
        {
            bool ready;
            synchronized (cast(Mutex) this.outer._mutex)
            {
                ready = this.outer._searchIndex.isReady;
            }

            if (ready)
                return 1.0;
            return 0.5;
        }
    }
}
