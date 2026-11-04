//! @brief State machine of the main view of one document: what the user sees
//! while the file loads, a filter runs, after a failure or the loss of the file.
//!
//! Input: the operation events of the document and the user's intents
//! (CancelPressed). Output: MainViewModel shown through MainViewSink, and
//! requests to the document through MainViewCommands. The machine knows nothing
//! about Sciter or the Document implementation, so it is tested in isolation.
//!
//! Transitions follow the facts reported by the document, not the requests:
//! a filter request may wait in the document's queue, so the view becomes
//! Filtering on OperationStarted, not when the user applies the filter.
module ui.main_view_fsm;

import utils.fsm : Fsm, NoTransition, To, Transition;
import domain.document : Document, OperationFinished, OperationProgress, OperationStarted, SourceLost;

import std.json : JSONValue;
import std.sumtype : SumType, match;

// ─── Output ────────────────────────────────────────────────────────────────

/// The file is being loaded (indexed)
struct LoadingFileView
{
    enum status = "loadingFile";
    enum canCancel = true; // cancelling closes the document
    float progress = 0; // 0..1
}

/// The file could not be loaded; the document can only be closed
struct LoadFailedView
{
    enum status = "loadFailed";
    string error;
}

/// The view shows the messages
struct ReadyView
{
    enum status = "ready";
    /// Changes each time the content of the view changes: the table reloads then
    uint dataVersion;
}

/// A filter is being applied
struct FilteringView
{
    enum status = "filtering";
    enum canCancel = true;
    float progress = 0; // 0..1
}

/// The filter was cancelled: the view has no complete content until the next one
struct FilterCancelledView
{
    enum status = "filterCancelled";
}

/// The filter failed: the view has no complete content until the next one
struct FilterFailedView
{
    enum status = "filterFailed";
    string error;
}

/// The file can't be read any more; the document has to be reopened or closed
struct SourceLostView
{
    enum status = "sourceLost";
}

/// What the main view shows: exactly one of the views above
alias MainViewModel = SumType!(LoadingFileView, LoadFailedView, ReadyView, FilteringView,
    FilterCancelledView, FilterFailedView, SourceLostView);

/// Receives the view to show each time it changes
interface MainViewSink
{
    void show(in MainViewModel vm);
}

/// Requests of the main view to its document
interface MainViewCommands
{
    /// Cancels the running filter. Returns: true if it was asked to stop
    bool cancelOperation();

    /// Closes the document. The machine is destroyed with it, so the
    /// implementation must defer the closing until the event is processed.
    void closeDocument();
}

/// Serializes the view for JS: {"status": "<name>", "canCancel": bool, <fields of the view>}
JSONValue toJson(in MainViewModel vm)
{
    import std.traits : FieldNameTuple, Unqual;

    return vm.match!((v) {
        alias T = Unqual!(typeof(v));
        auto json = JSONValue(["status": JSONValue(T.status)]);
        json["canCancel"] = __traits(hasMember, T, "canCancel");
        static foreach (name; FieldNameTuple!T)
            json[name] = JSONValue(__traits(getMember, v, name));
        return json;
    });
}

// ─── Machine ───────────────────────────────────────────────────────────────

/// The user pressed Cancel in the main view
struct CancelPressed
{
}

struct MainViewContext
{
    MainViewSink view;
    MainViewCommands commands;
    uint dataVersion; // see ReadyView.dataVersion
    string error; // of the failed operation, set before the transition to the failed state
}

alias MainViewFsm = Fsm!(MainViewContext, Loading, Ready, Filtering, FilterCancelled, FilterFailed,
    LoadFailed, Lost);

/// Creates the machine of a document whose file is being loaded; call start() on it.
MainViewFsm makeMainViewFsm(MainViewSink view, MainViewCommands commands)
{
    return MainViewFsm(MainViewContext(view, commands));
}

private enum loadOperation = Document.Operation.BuildOffsetIndex;
private enum filterOperation = Document.Operation.BuildFilterIndex;

private void show(View)(ref MainViewContext c, View v)
{
    c.view.show(MainViewModel(v));
}

/// Initial state: the file is being loaded
struct Loading
{
    void onEnter(ref MainViewContext c)
    {
        c.show(LoadingFileView(0));
    }

    void on(in OperationProgress e, ref MainViewContext c)
    {
        if (e.operation == loadOperation)
            c.show(LoadingFileView(e.progress));
    }

    Transition on(in OperationFinished e, ref MainViewContext c)
    {
        if (e.operation != loadOperation)
            return NoTransition;
        if (e.result == OperationFinished.Result.Completed)
            return To!Ready;
        c.error = e.error; // loading can't be cancelled: Cancelled is a failure as well
        return To!LoadFailed;
    }

    /// Loading can't be stopped half way: cancelling it closes the document
    void on(in CancelPressed e, ref MainViewContext c)
    {
        c.commands.closeDocument();
    }

    Transition on(in SourceLost e, ref MainViewContext c)
    {
        return To!Lost;
    }
}

struct Ready
{
    void onEnter(ref MainViewContext c)
    {
        ++c.dataVersion;
        c.show(ReadyView(c.dataVersion));
    }

    Transition on(in OperationStarted e, ref MainViewContext c)
    {
        return e.operation == filterOperation ? To!Filtering : NoTransition;
    }

    Transition on(in SourceLost e, ref MainViewContext c)
    {
        return To!Lost;
    }
}

struct Filtering
{
    void onEnter(ref MainViewContext c)
    {
        c.show(FilteringView(0));
    }

    void on(in OperationProgress e, ref MainViewContext c)
    {
        if (e.operation == filterOperation)
            c.show(FilteringView(e.progress));
    }

    Transition on(in OperationFinished e, ref MainViewContext c)
    {
        if (e.operation != filterOperation)
            return NoTransition;
        final switch (e.result)
        {
        case OperationFinished.Result.Completed:
            return To!Ready;
        case OperationFinished.Result.Cancelled:
            return To!FilterCancelled;
        case OperationFinished.Result.Failed:
            c.error = e.error;
            return To!FilterFailed;
        }
    }

    /// The transition follows on OperationFinished(Cancelled)
    void on(in CancelPressed e, ref MainViewContext c)
    {
        c.commands.cancelOperation();
    }

    Transition on(in SourceLost e, ref MainViewContext c)
    {
        return To!Lost;
    }
}

/// Left by the next filter only
struct FilterCancelled
{
    void onEnter(ref MainViewContext c)
    {
        c.show(FilterCancelledView());
    }

    Transition on(in OperationStarted e, ref MainViewContext c)
    {
        return e.operation == filterOperation ? To!Filtering : NoTransition;
    }

    Transition on(in SourceLost e, ref MainViewContext c)
    {
        return To!Lost;
    }
}

/// Left by the next filter only
struct FilterFailed
{
    void onEnter(ref MainViewContext c)
    {
        c.show(FilterFailedView(c.error));
    }

    Transition on(in OperationStarted e, ref MainViewContext c)
    {
        return e.operation == filterOperation ? To!Filtering : NoTransition;
    }

    Transition on(in SourceLost e, ref MainViewContext c)
    {
        return To!Lost;
    }
}

/// Final for the document, except for the loss of its file
struct LoadFailed
{
    void onEnter(ref MainViewContext c)
    {
        c.show(LoadFailedView(c.error));
    }

    Transition on(in SourceLost e, ref MainViewContext c)
    {
        return To!Lost;
    }
}

/// Final: reopening the file creates a new document with a new machine
struct Lost
{
    void onEnter(ref MainViewContext c)
    {
        c.show(SourceLostView());
    }
}

// ─── Tests ─────────────────────────────────────────────────────────────────

version (unittest) private
{
    class SinkMock : MainViewSink
    {
        MainViewModel[] shown;

        void show(in MainViewModel vm)
        {
            shown ~= vm;
        }

        MainViewModel last()
        {
            assert(shown.length, "nothing was shown");
            return shown[$ - 1];
        }
    }

    class CommandsMock : MainViewCommands
    {
        int cancelCalls;
        int closeCalls;

        bool cancelOperation()
        {
            ++cancelCalls;
            return true;
        }

        void closeDocument()
        {
            ++closeCalls;
        }
    }

    struct Fixture
    {
        SinkMock sink;
        CommandsMock commands;
        MainViewFsm fsm;

        static Fixture started()
        {
            Fixture f;
            f.sink = new SinkMock;
            f.commands = new CommandsMock;
            f.fsm = makeMainViewFsm(f.sink, f.commands);
            f.fsm.start();
            return f;
        }

        void process(E)(E e)
        {
            fsm.process(e);
        }

        void start(Document.Operation op)
        {
            process(OperationStarted(op));
        }

        void progress(Document.Operation op, float value)
        {
            process(OperationProgress(op, value));
        }

        void finish(Document.Operation op, OperationFinished.Result result, string error = null)
        {
            process(OperationFinished(op, result, error));
        }

        /// Loads the file and shows the view
        static Fixture ready()
        {
            auto f = started();
            f.start(loadOperation);
            f.finish(loadOperation, OperationFinished.Result.Completed);
            return f;
        }

        /// A filter is running over the loaded file
        static Fixture filtering()
        {
            auto f = ready();
            f.start(filterOperation);
            return f;
        }
    }

    alias Result = OperationFinished.Result;
    enum searchOperation = Document.Operation.BuildSearchIndex;
}

@("MainViewFsm: shows the loading of the file on start")
unittest
{
    auto f = Fixture.started();
    assert(f.sink.shown == [MainViewModel(LoadingFileView(0))]);
}

@("MainViewFsm: shows the loading progress, then the messages")
unittest
{
    auto f = Fixture.started();
    f.start(loadOperation);
    f.progress(loadOperation, 0.5);
    assert(f.sink.last == MainViewModel(LoadingFileView(0.5)));

    f.finish(loadOperation, Result.Completed);
    assert(f.sink.last == MainViewModel(ReadyView(1)));
}

@("MainViewFsm: a failed load is final")
unittest
{
    auto f = Fixture.started();
    f.finish(loadOperation, Result.Failed, "bad file");
    assert(f.sink.last == MainViewModel(LoadFailedView("bad file")));

    const shownCount = f.sink.shown.length;
    f.start(filterOperation);
    f.process(CancelPressed());
    assert(f.sink.shown.length == shownCount, "a failed document ignores everything but SourceLost");
    assert(f.commands.closeCalls == 0 && f.commands.cancelCalls == 0);
}

@("MainViewFsm: cancelling the load closes the document")
unittest
{
    auto f = Fixture.started();
    f.start(loadOperation);
    f.process(CancelPressed());
    assert(f.commands.closeCalls == 1);
    assert(f.commands.cancelCalls == 0, "loading the file is not cancellable");
}

@("MainViewFsm: a completed filter shows the new content of the view")
unittest
{
    auto f = Fixture.filtering();
    assert(f.sink.last == MainViewModel(FilteringView(0)));

    f.progress(filterOperation, 0.25);
    assert(f.sink.last == MainViewModel(FilteringView(0.25)));

    f.finish(filterOperation, Result.Completed);
    assert(f.sink.last == MainViewModel(ReadyView(2)), "the table must reload");
}

@("MainViewFsm: cancelling a filter asks the document and waits for its result")
unittest
{
    auto f = Fixture.filtering();
    f.process(CancelPressed());
    assert(f.commands.cancelCalls == 1);
    assert(f.commands.closeCalls == 0);
    assert(f.sink.last == MainViewModel(FilteringView(0)), "the filter is still running");

    f.finish(filterOperation, Result.Cancelled);
    assert(f.sink.last == MainViewModel(FilterCancelledView()));

    f.start(filterOperation);
    assert(f.sink.last == MainViewModel(FilteringView(0)), "the next filter starts over");
}

@("MainViewFsm: a failed filter waits for the next one")
unittest
{
    auto f = Fixture.filtering();
    f.finish(filterOperation, Result.Failed, "bad regex");
    assert(f.sink.last == MainViewModel(FilterFailedView("bad regex")));

    f.start(filterOperation);
    assert(f.sink.last == MainViewModel(FilteringView(0)));
    f.finish(filterOperation, Result.Completed);
    assert(f.sink.last == MainViewModel(ReadyView(2)));
}

@("MainViewFsm: search operations don't affect the main view")
unittest
{
    void searchCycle(ref Fixture f)
    {
        const shownCount = f.sink.shown.length;
        f.start(searchOperation);
        f.progress(searchOperation, 0.5);
        f.finish(searchOperation, Result.Completed);
        f.finish(searchOperation, Result.Failed, "x");
        assert(f.sink.shown.length == shownCount, "a search must not change the main view");
    }

    auto loading = Fixture.started();
    searchCycle(loading);
    auto ready = Fixture.ready();
    searchCycle(ready);
    auto filtering = Fixture.filtering();
    searchCycle(filtering);

    filtering.finish(filterOperation, Result.Cancelled);
    searchCycle(filtering);
}

@("MainViewFsm: the loss of the file is final from any state")
unittest
{
    Fixture[] fixtures = [Fixture.started(), Fixture.ready(), Fixture.filtering()];

    auto cancelled = Fixture.filtering();
    cancelled.finish(filterOperation, Result.Cancelled);
    auto failed = Fixture.filtering();
    failed.finish(filterOperation, Result.Failed, "x");
    auto loadFailed = Fixture.started();
    loadFailed.finish(loadOperation, Result.Failed, "x");
    fixtures ~= [cancelled, failed, loadFailed];

    foreach (i, ref f; fixtures)
    {
        f.process(SourceLost());
        assert(f.sink.last == MainViewModel(SourceLostView()));

        const shownCount = f.sink.shown.length;
        const cancelCalls = f.commands.cancelCalls;
        f.start(filterOperation);
        f.finish(filterOperation, Result.Completed);
        f.process(CancelPressed());
        f.process(SourceLost());
        assert(f.sink.shown.length == shownCount, "a lost document ignores everything");
        assert(f.commands.cancelCalls == cancelCalls && f.commands.closeCalls == 0);
    }
}

@("MainViewFsm: cancel is ignored while the view is ready")
unittest
{
    auto f = Fixture.ready();
    f.process(CancelPressed());
    assert(f.commands.cancelCalls == 0 && f.commands.closeCalls == 0);
}

@("MainViewModel: serializes the status, canCancel and the fields of each view")
unittest
{
    import std.json : parseJSON;

    void check(View)(View v, string expected)
    {
        const actual = toJson(MainViewModel(v));
        assert(actual == parseJSON(expected), View.stringof ~ ": " ~ actual.toString);
    }

    check(LoadingFileView(0.5), `{"status": "loadingFile", "canCancel": true, "progress": 0.5}`);
    check(LoadFailedView("e"), `{"status": "loadFailed", "canCancel": false, "error": "e"}`);
    check(ReadyView(3), `{"status": "ready", "canCancel": false, "dataVersion": 3}`);
    check(FilteringView(0.25), `{"status": "filtering", "canCancel": true, "progress": 0.25}`);
    check(FilterCancelledView(), `{"status": "filterCancelled", "canCancel": false}`);
    check(FilterFailedView("e"), `{"status": "filterFailed", "canCancel": false, "error": "e"}`);
    check(SourceLostView(), `{"status": "sourceLost", "canCancel": false}`);
}
