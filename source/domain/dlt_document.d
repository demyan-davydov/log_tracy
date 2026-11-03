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

import event_bus.event_bus_async : EventBusAsync;
import event_bus.event_bus_interface : SignalConsumer;

import std.parallelism : Task, TaskPool;
import std.typecons : scoped, Unique, Proxy;

class DltDocument : Document
{
    private MainDocumentView _mainView;
    private SearchDocumentView _searchView;

    private LogFilter!wchar _viewFilter;
    private LogFilter!wchar _searchFilter;
    private Anchors _anchors;

    private string _sourcePath;

    private EventBusAsync _events; // must outlive _index: its worker publishes here
    private DltIndex _index;

    this() @disable;

    this(string path)
    {
        _events = new EventBusAsync();
        _index = DltIndex(path, _events);
        _sourcePath = path;
        _mainView = new MainDocumentView();
        _searchView = new SearchDocumentView();
    }

    override SignalConsumer events()
    {
        return _events;
    }

    override void dispatchEvents()
    {
        _events.dispatch();
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

    Operation currentOperation()
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
            // Main view is ready if it's not building initial index or applying main filter
            if (op == Operation.BuildOffsetIndex || op == Operation.BuildFilterIndex)
                return DocumentView.State.BuildingIndex;
            return DocumentView.State.Ready;
        }

        override float progress()
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
            // Search view is only building when BuildSearchIndex is active
            if (op == Operation.BuildSearchIndex)
                return DocumentView.State.BuildingIndex;
            return DocumentView.State.Ready;
        }

        override float progress()
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

// =============================================================================
// Unit tests
// =============================================================================

version (unittest)
{
    import dlt_core.dlt_source : buildDltMessage;

    private string writeTestDlt(string name, size_t messageCount)
    {
        import std.file : write, tempDir;
        import std.path : buildPath;

        ubyte[] data;
        foreach (i; 0 .. messageCount)
            data ~= buildDltMessage("ECU1", cast(uint) i, 0, 0, cast(ubyte) i, [0xAA, 0xBB]);

        auto path = buildPath(tempDir(), name);
        write(path, data);
        return path;
    }

    /// Pumps document events like MainWindow.onIdle() until `done` or timeout
    private void dispatchUntil(Document doc, scope bool delegate() done)
    {
        import core.thread : Thread;
        import core.time : msecs, MonoTime;

        const deadline = MonoTime.currTime + 3000.msecs;
        while (!done() && MonoTime.currTime < deadline)
        {
            doc.dispatchEvents();
            Thread.sleep(1.msecs);
        }
    }
}

@("DltDocument: opening reports Started, Progress, Finished in order")
unittest
{
    import std.file : remove;

    enum messageCount = 2000;
    auto path = writeTestDlt("dlt_document_events.dlt", messageCount);
    scope (exit)
        remove(path);

    auto doc = new DltDocument(path);

    string[] log;
    float lastProgress = -1;
    OperationFinished finished;
    bool readyOnFinish;
    size_t countOnFinish;

    // Subscribing after construction is fine: nothing is delivered before dispatchEvents()
    doc.events.subscribe((const OperationStarted e) {
        assert(e.operation == Document.Operation.BuildOffsetIndex);
        log ~= "started";
    });
    doc.events.subscribe((const OperationProgress e) {
        assert(e.progress >= lastProgress, "progress must not go backwards");
        lastProgress = e.progress;
        if (log.length == 0 || log[$ - 1] != "progress")
            log ~= "progress";
    });
    doc.events.subscribe((const OperationFinished e) {
        finished = e;
        // Finished is published after the slot is idle: views are already updated
        readyOnFinish = doc.mainView.ready;
        countOnFinish = doc.mainView.itemsCount;
        log ~= "finished";
    });

    dispatchUntil(doc, () => log.length > 0 && log[$ - 1] == "finished");

    assert(log == ["started", "progress", "finished"], "unexpected event order");
    assert(finished.operation == Document.Operation.BuildOffsetIndex);
    assert(finished.result == OperationFinished.Result.Completed);
    assert(lastProgress == 1.0f, "last progress event must report completion");
    assert(readyOnFinish, "main view must be ready when OperationFinished is delivered");
    assert(countOnFinish == messageCount);
}

@("DltDocument: destroy while indexing cancels and joins the worker")
unittest
{
    import std.file : remove;
    import core.time : MonoTime, seconds;

    auto path = writeTestDlt("dlt_document_destroy.dlt", 200_000);
    scope (exit)
        remove(path);

    auto doc = new DltDocument(path);
    const start = MonoTime.currTime;
    destroy(doc); // must cancel the running BuildOffsetIndex, not wait for it or crash
    assert(MonoTime.currTime - start < 1.seconds, "destroy must not wait for indexing to complete");
}
