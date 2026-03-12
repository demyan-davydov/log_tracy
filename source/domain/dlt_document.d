module domain.dlt_document;

import domain.document;
import domain.document_item;
import domain.document_id;

import dlt_core.dlt_source;
import dlt_core.dlt_log_filter;
import dlt_core.decoded_message;
import dlt_core.log_filter;

import domain.index.anchors;
import domain.dlt_index;

import utils.lock_guard;

import std.parallelism : Task, TaskPool;
import std.typecons : scoped, Unique, Proxy;

class DltDocument : Document
{
    private DocumentId _id;

    private MainDocumentView _mainView;
    private SearchDocumentView _searchView;

    private LogFilter!wchar _viewFilter;
    private LogFilter!wchar _searchFilter;
    private Anchors _anchors;

    private string _sourcePath;

    private DltIndex _index;

    this() @disable;

    this(DocumentId id, string path)
    {
        _index = DltIndex(path);
        _sourcePath = path;
        _mainView = new MainDocumentView();
        _searchView = new SearchDocumentView();
    }

    override DocumentView mainView()
    {
        return _mainView;
    }

    override DocumentView searchView()
    {
        return _searchView;
    }

    /*override string sourcePath() const
    {
        return _sourcePath;
    }*/

    override void applyViewFilter(LogFilter!wchar filter)
    {
        if (_index.runBuildFilterIndex(filter, _anchors))
        {
            _viewFilter = filter;
        }
    }

    override void applySearchFilter(LogFilter!wchar filter)
    {
        if (_index.runBuildSearchIndex(filter, _anchors))
        {
            _searchFilter = filter;
        }
    }

    Operation currentOperation() const
    {
        return _index.currentOperation();
    }

    bool setAnchor(size_t index, bool value)
    {
        return _anchors.set(index, value);
    }

    size_t[] exportAnchors() const pure
    {
        return _anchors.exportAnchors();
    }

    void importAnchors(const(size_t[]) anchors)
    {
        _anchors.importAnchors(anchors);
    }

    void requestCancel()
    {
        _index.cancelCurrentOperation();
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
            return this.outer._index.fetchMainViewItem(index, item);
        }

        override DocumentView.State state()
        {
            const auto op = this.outer.currentOperation();
            return op == Operation.None ? DocumentView.State.Ready
                : DocumentView.State.BuildingIndex;
        }

        override double progress()
        {
            return this.outer._index.currentOperationProgress();
        }

        override void enableFilter(bool enable)
        {
            this.outer._index.enableFilter(enable);
        }

        override bool isFilterEnabled() const
        {
            return this.outer._index.isMainViewFilterEnabled();
        }

        override void applyFilter(LogFilter!wchar filter)
        {
            this.outer.applyViewFilter(filter);
        }

        override void resetFilter()
        {
            this.outer.applyViewFilter(null);
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
            return this.outer._index.fetchSearchViewItem(index, item);
        }

        override DocumentView.State state()
        {
            const auto op = this.outer.currentOperation();
            return op == Operation.None ? DocumentView.State.Ready
                : DocumentView.State.BuildingIndex;
        }

        override double progress()
        {
            return this.outer._index.currentOperationProgress();
        }

        override void enableFilter(bool enable)
        {
            this.outer._index.enableFilter(enable);
        }

        override bool isFilterEnabled() const
        {
            return true;
        }

        override void applyFilter(LogFilter!wchar filter)
        {
            this.outer.applySearchFilter(filter);
        }

        override void resetFilter()
        {
            this.outer.applySearchFilter(null);
        }
    }
}
