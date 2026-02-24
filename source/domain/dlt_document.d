module domain.dlt_document;

import domain.document;
import domain.document_item;
import domain.document_id;

import dlt_core.dlt_source;
import dlt_core.dlt_log_filter;
import dlt_core.decoded_message;
import dlt_core.log_filter;

import domain.index.file_index;
import domain.index.filter_index;
import domain.index.search_index;

import std.parallelism : Task, TaskPool;
import core.sync.mutex : Mutex;

class DltDocument : Document
{
    private DltSource* _source;
    private DocumentId _id;

    private DocumentView _rawView;
    private DocumentView _filteredView;
    private DocumentView _searchView;

    private LogFilter!wchar _viewFilter;
    private LogFilter!wchar _searchFilter;
    private FileIndex _fileIndex;
    private FilterIndex _filterIndex;
    private SearchIndex _searchIndex;

    private TaskPool _taskPool;
    //private Task _worker;
    private Mutex _mutex;

    this(DocumentId id)
    {
        _id = id;
        _rawView = new RawDocumentView();
        _filteredView = new FilteredDocumentView();
        _searchView = new SearchDocumentView();
    }

    void loadSource(string path)
    {
        // auto source = new DltSource(path);
        //_source.load();

        // Load file in parallel
        // need to clear all the indexes and views

        DltSource* loader(string pathToLoad)
        {
            auto source = new DltSource(pathToLoad);
            return source;
        }

        //auto task = task!loader(path);
        //_taskPool.put(task);
        //_source = task.yieldForce;

        /*
     // Execute both recursion branches in parallel.
    auto recurseTask = task!parallelSort(greaterEqual);
    taskPool.put(recurseTask);
    parallelSort(less);
    recurseTask.yieldForce;
 */

        /** 
    auto file1Task = task(&read!string, "foo.txt", size_t.max);
    file1Task.executeInNewThread();

    // Read bar.txt in parallel.
    auto file2Data = read("bar.txt");

    // Get the results of reading foo.txt.
    auto file1Data = file1Task.yieldForce;
  */
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
        _viewFilter = filter;
    }

    override void applySearchFilter(LogFilter!wchar filter)
    {
        _searchFilter = filter;
    }

    /// Views

    private class RawDocumentView : DocumentView
    {
        this()
        {
        }

        override size_t itemsCount() pure nothrow @nogc const
        {
            return 0;
        }

        override bool fetchItem(size_t index, out DocumentItem item)
        {
            return false;
        }

        override DocumentView.State state() const
        {
            return DocumentView.State.Ready;
        }

        override double progress() const
        {
            return 1.0;
        }
    }

    private class FilteredDocumentView : DocumentView
    {
        this()
        {
        }

        override size_t itemsCount() pure nothrow @nogc const
        {
            return 0;
        }

        override bool fetchItem(size_t index, out DocumentItem item)
        {
            return false;
        }

        override DocumentView.State state() const
        {
            return DocumentView.State.Ready;
        }

        override double progress() const
        {
            return 1.0;
        }
    }

    private class SearchDocumentView : DocumentView
    {
        this()
        {
        }

        override size_t itemsCount() pure nothrow @nogc const
        {
            return 0;
        }

        override bool fetchItem(size_t index, out DocumentItem item)
        {
            return false;
        }

        override DocumentView.State state() const
        {
            return DocumentView.State.Ready;
        }

        override double progress() const
        {
            return 1.0;
        }
    }
}
