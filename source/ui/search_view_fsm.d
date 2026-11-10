//! @brief State machine of the search view of one document: the search
//! results, the running search, a cancelled or failed one, the wait for the
//! main view and the loss of the file.
//!
//! The search runs over the main view: while the file loads or a filter
//! rebuilds the main view there is no result to show, and the document repeats
//! the search after the filter (see LogDocument.applyViewFilter).
//!
//! Input: the operation events of the document and SearchCancelPressed.
//! Output: SearchViewModel shown through SearchViewSink, and requests to the
//! document through SearchViewCommands. Same structure as ui.main_view_fsm.
module ui.search_view_fsm;

import utils.fsm : Fsm, NoTransition, To, Transition;
import domain.document : ContentGrown, Document, OperationFinished, OperationProgress, OperationStarted, SourceLost;

import std.json : JSONValue;
import utils.ui_text : plainText, say, TextForUser, UiText;
import std.sumtype : SumType, match;

// ─── Output ────────────────────────────────────────────────────────────────

/// The main view is being built (the file loads or a filter runs): no result yet
struct SearchWaitingView
{
    enum status = "waitingForView";
}

/// The view shows the search results (the anchors only when nothing was searched)
struct SearchResultsView
{
    enum status = "ready";
    /// The content of the view: changes when it is replaced (a search starts,
    /// the main view is rebuilt), the table reloads then. Under one version
    /// the content only grows, see ReadyView.dataVersion of ui.main_view_fsm
    uint dataVersion;
}

/// A search is running
struct SearchingView
{
    enum status = "searching";
    enum canCancel = true;
    float progress = 0; // 0..1
    /// The content the view is being filled with, see SearchResultsView.dataVersion:
    /// what the search found so far is shown
    uint dataVersion;
}

/// The search was cancelled: no result until the next search
struct SearchCancelledView
{
    enum status = "searchCancelled";
}

/// The search failed: no result until the next search
struct SearchFailedView
{
    enum status = "searchFailed";
    UiText error; // for the user, see toJson
}

/// The file can't be read any more
struct SearchLostView
{
    enum status = "sourceLost";
}

/// What the search view shows: exactly one of the views above
alias SearchViewModel = SumType!(SearchWaitingView, SearchResultsView, SearchingView,
    SearchCancelledView, SearchFailedView, SearchLostView);

/// Receives the view to show each time it changes
interface SearchViewSink
{
    void show(in SearchViewModel vm);
}

/// Requests of the search view to its document
interface SearchViewCommands
{
    /// Cancels the running search. Returns: true if it was asked to stop
    bool cancelSearch();
}

/// Serializes the view for JS: {"status": "<name>", "canCancel": bool, <fields of the view>}
/// A text for the user (the error of a view) is put in by `text`: translated by the session,
/// english if none is given.
JSONValue toJson(in SearchViewModel vm, scope TextForUser text = null)
{
    import std.traits : FieldNameTuple, Unqual;

    return vm.match!((v) {
        alias T = Unqual!(typeof(v));
        auto json = JSONValue(["status": JSONValue(T.status)]);
        json["canCancel"] = __traits(hasMember, T, "canCancel");
        static foreach (name; FieldNameTuple!T)
        {
            static if (is(typeof(__traits(getMember, v, name)) : const UiText))
                json[name] = say(text, __traits(getMember, v, name));
            else
                json[name] = JSONValue(__traits(getMember, v, name));
        }
        return json;
    });
}

// ─── Machine ───────────────────────────────────────────────────────────────

/// The user pressed Cancel in the search view
struct SearchCancelPressed
{
}

struct SearchViewContext
{
    SearchViewSink view;
    SearchViewCommands commands;
    uint dataVersion; // see SearchResultsView.dataVersion
    UiText error; // of the failed search, set before the transition to SearchFailed
}

alias SearchViewFsm = Fsm!(SearchViewContext, WaitingForView, ShowingResults, Searching,
    SearchCancelled, SearchFailed, SearchLost);

/// Creates the machine of a document whose file is being loaded; call start() on it.
SearchViewFsm makeSearchViewFsm(SearchViewSink view, SearchViewCommands commands)
{
    return SearchViewFsm(SearchViewContext(view, commands));
}

private enum loadOperation = Document.Operation.BuildOffsetIndex;
private enum filterOperation = Document.Operation.BuildFilterIndex;
private enum searchOperation = Document.Operation.BuildSearchIndex;

private void show(View)(ref SearchViewContext c, View v)
{
    c.view.show(SearchViewModel(v));
}

/// Transitions shared by the states that show a search outcome: a new search
/// starts over, a new filter makes the result obsolete
private Transition onSearchOrFilterStarted(in OperationStarted e)
{
    if (e.operation == searchOperation)
        return To!Searching;
    if (e.operation == filterOperation)
        return To!WaitingForView;
    return NoTransition;
}

/// Initial state: the main view is being built. A cancelled or failed load or
/// filter leaves it incomplete, so the view keeps waiting for the next filter.
struct WaitingForView
{
    void onEnter(ref SearchViewContext c)
    {
        ++c.dataVersion; // the results shown before are gone with the main view
        c.show(SearchWaitingView());
    }

    Transition on(in OperationStarted e, ref SearchViewContext c)
    {
        return e.operation == searchOperation ? To!Searching : NoTransition;
    }

    Transition on(in OperationFinished e, ref SearchViewContext c)
    {
        const bool mainViewBuilt = (e.operation == loadOperation || e.operation == filterOperation)
            && e.result == OperationFinished.Result.Completed;
        return mainViewBuilt ? To!ShowingResults : NoTransition;
    }

    Transition on(in SourceLost e, ref SearchViewContext c)
    {
        return To!SearchLost;
    }
}

/// The content the search filled, complete (the anchors only without a search)
struct ShowingResults
{
    void onEnter(ref SearchViewContext c)
    {
        c.show(SearchResultsView(c.dataVersion));
    }

    Transition on(in OperationStarted e, ref SearchViewContext c)
    {
        return onSearchOrFilterStarted(e);
    }

    /// The source of the document got more: the view may show more rows
    void on(in ContentGrown e, ref SearchViewContext c)
    {
        c.show(SearchResultsView(c.dataVersion));
    }

    Transition on(in SourceLost e, ref SearchViewContext c)
    {
        return To!SearchLost;
    }
}

struct Searching
{
    void onEnter(ref SearchViewContext c)
    {
        ++c.dataVersion; // the search fills the view anew
        c.show(SearchingView(0, c.dataVersion));
    }

    void on(in OperationProgress e, ref SearchViewContext c)
    {
        if (e.has(searchOperation))
            c.show(SearchingView(e.of(searchOperation), c.dataVersion));
    }

    Transition on(in OperationFinished e, ref SearchViewContext c)
    {
        if (e.operation != searchOperation)
            return NoTransition;
        final switch (e.result)
        {
        case OperationFinished.Result.Completed:
            return To!ShowingResults;
        case OperationFinished.Result.Cancelled:
            return To!SearchCancelled;
        case OperationFinished.Result.Failed:
            c.error = e.error;
            return To!SearchFailed;
        }
    }

    /// A new filter cancels the search first: its Finished(Cancelled) comes
    /// before the Started of the filter, so it isn't handled here
    void on(in SearchCancelPressed e, ref SearchViewContext c)
    {
        c.commands.cancelSearch(); // the transition follows on OperationFinished(Cancelled)
    }

    Transition on(in SourceLost e, ref SearchViewContext c)
    {
        return To!SearchLost;
    }
}

struct SearchCancelled
{
    void onEnter(ref SearchViewContext c)
    {
        c.show(SearchCancelledView());
    }

    Transition on(in OperationStarted e, ref SearchViewContext c)
    {
        return onSearchOrFilterStarted(e);
    }

    Transition on(in SourceLost e, ref SearchViewContext c)
    {
        return To!SearchLost;
    }
}

struct SearchFailed
{
    void onEnter(ref SearchViewContext c)
    {
        c.show(SearchFailedView(c.error));
    }

    Transition on(in OperationStarted e, ref SearchViewContext c)
    {
        return onSearchOrFilterStarted(e);
    }

    Transition on(in SourceLost e, ref SearchViewContext c)
    {
        return To!SearchLost;
    }
}

/// Final: reopening the file creates a new document with a new machine
struct SearchLost
{
    void onEnter(ref SearchViewContext c)
    {
        c.show(SearchLostView());
    }
}

// ─── Tests ─────────────────────────────────────────────────────────────────

version (unittest) private
{
    class SinkMock : SearchViewSink
    {
        SearchViewModel[] shown;

        void show(in SearchViewModel vm)
        {
            shown ~= vm;
        }

        SearchViewModel last()
        {
            assert(shown.length, "nothing was shown");
            return shown[$ - 1];
        }
    }

    class CommandsMock : SearchViewCommands
    {
        int cancelCalls;

        bool cancelSearch()
        {
            ++cancelCalls;
            return true;
        }
    }

    alias Result = OperationFinished.Result;

    struct Fixture
    {
        SinkMock sink;
        CommandsMock commands;
        SearchViewFsm fsm;

        static Fixture started()
        {
            Fixture f;
            f.sink = new SinkMock;
            f.commands = new CommandsMock;
            f.fsm = makeSearchViewFsm(f.sink, f.commands);
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

        void finish(Document.Operation op, Result result, string error = null)
        {
            process(OperationFinished(op, result, error is null ? UiText.init : plainText(error)));
        }

        /// The file is loaded: the view shows the (empty) result
        static Fixture ready()
        {
            auto f = started();
            f.start(loadOperation);
            f.finish(loadOperation, Result.Completed);
            return f;
        }

        /// A search is running over the loaded file
        static Fixture searching()
        {
            auto f = ready();
            f.start(searchOperation);
            return f;
        }

        size_t shownCount()
        {
            return sink.shown.length;
        }
    }

    SearchViewModel vm(View)(View v)
    {
        return SearchViewModel(v);
    }
}

@("SearchViewFsm: waits for the file, then shows the empty result")
unittest
{
    auto f = Fixture.started();
    assert(f.sink.shown == [vm(SearchWaitingView())]);

    f.start(loadOperation);
    f.progress(loadOperation, 0.5);
    assert(f.shownCount == 1, "the load progress is shown by the main view");

    f.finish(loadOperation, Result.Completed);
    assert(f.sink.last == vm(SearchResultsView(1)));
}

@("SearchViewFsm: a search requested while loading starts after the load")
unittest
{
    auto f = Fixture.started();
    f.finish(loadOperation, Result.Completed);
    f.start(searchOperation);
    assert(f.sink.last == vm(SearchingView(0, 2)), "new content: the table reloads");
}

@("SearchViewFsm: a search asked for while the file loads runs with the load")
unittest
{
    auto f = Fixture.started();
    f.start(loadOperation);
    f.start(searchOperation);
    assert(f.sink.last == vm(SearchingView(0, 2)));
    f.progress(searchOperation, 0.5);
    assert(f.sink.last == vm(SearchingView(0.5, 2)));

    // The load and the search end together
    f.finish(loadOperation, Result.Completed);
    assert(f.sink.last == vm(SearchingView(0.5, 2)), "the end of the load isn't the end of the search");
    f.finish(searchOperation, Result.Completed);
    assert(f.sink.last == vm(SearchResultsView(2)));
}

@("SearchViewFsm: the results shown get the rows the source gets later")
unittest
{
    auto f = Fixture.ready();
    const count = f.shownCount;
    f.process(ContentGrown());
    assert(f.shownCount == count + 1 && f.sink.last == vm(SearchResultsView(1)));
}

@("SearchViewFsm: a failed load leaves the view waiting")
unittest
{
    auto f = Fixture.started();
    f.finish(loadOperation, Result.Failed, "bad file");
    assert(f.sink.shown == [vm(SearchWaitingView())]);
}

@("SearchViewFsm: shows the search progress, then the result")
unittest
{
    auto f = Fixture.searching();
    f.progress(searchOperation, 0.25);
    assert(f.sink.last == vm(SearchingView(0.25, 2)));

    f.finish(searchOperation, Result.Completed);
    assert(f.sink.last == vm(SearchResultsView(2)), "the same content, complete: the table isn't reloaded");
}

@("SearchViewFsm: cancelling asks the document and waits for its result")
unittest
{
    auto f = Fixture.searching();
    f.process(SearchCancelPressed());
    assert(f.commands.cancelCalls == 1);
    assert(f.sink.last == vm(SearchingView(0, 2)), "the search is still running");

    f.finish(searchOperation, Result.Cancelled);
    assert(f.sink.last == vm(SearchCancelledView()));

    f.start(searchOperation);
    assert(f.sink.last == vm(SearchingView(0, 3)), "the next search starts over");
}

@("SearchViewFsm: a failed search waits for the next one")
unittest
{
    auto f = Fixture.searching();
    f.finish(searchOperation, Result.Failed, "read error");
    assert(f.sink.last == vm(SearchFailedView(plainText("read error"))));

    f.start(searchOperation);
    f.finish(searchOperation, Result.Completed);
    assert(f.sink.last == vm(SearchResultsView(3)));
}

@("SearchViewFsm: a new filter waits for the view, then shows the repeated search")
unittest
{
    auto f = Fixture.ready();
    f.start(filterOperation);
    assert(f.sink.last == vm(SearchWaitingView()));

    f.progress(filterOperation, 0.5);
    f.process(SearchCancelPressed());
    assert(f.sink.last == vm(SearchWaitingView()), "the filter progress is shown by the main view");
    assert(f.commands.cancelCalls == 0, "no search to cancel while the view is built");

    // The document repeats the search right after the filter
    f.finish(filterOperation, Result.Completed);
    f.start(searchOperation);
    f.finish(searchOperation, Result.Completed);
    assert(f.sink.last == vm(SearchResultsView(3)));
}

@("SearchViewFsm: a rebuilt main view without a search shows new (empty) content")
unittest
{
    auto f = Fixture.ready();
    f.start(filterOperation);
    f.finish(filterOperation, Result.Completed);
    assert(f.sink.last == vm(SearchResultsView(2)), "the results of before are gone: the table reloads");
}

@("SearchViewFsm: a filter replacing a running search waits for the view")
unittest
{
    // The document cancels the search before it starts the filter
    auto f = Fixture.searching();
    f.finish(searchOperation, Result.Cancelled);
    f.start(filterOperation);
    assert(f.sink.last == vm(SearchWaitingView()));

    auto failed = Fixture.searching();
    failed.finish(searchOperation, Result.Failed, "x");
    failed.start(filterOperation);
    assert(failed.sink.last == vm(SearchWaitingView()));
}

@("SearchViewFsm: a cancelled or failed filter leaves the view waiting")
unittest
{
    foreach (result; [Result.Cancelled, Result.Failed])
    {
        auto f = Fixture.ready();
        f.start(filterOperation);
        f.finish(filterOperation, result);
        assert(f.sink.last == vm(SearchWaitingView()));

        f.start(filterOperation);
        f.finish(filterOperation, Result.Completed);
        assert(f.sink.last == vm(SearchResultsView(2)), "the next filter completes the view");
    }

    // The document doesn't repeat the search after a cancelled filter, but the
    // user may start one: it runs over what the view has
    auto f = Fixture.ready();
    f.start(filterOperation);
    f.finish(filterOperation, Result.Cancelled);
    f.start(searchOperation);
    assert(f.sink.last == vm(SearchingView(0, 3)));
}

@("SearchViewFsm: cancel is ignored unless a search is running")
unittest
{
    auto waiting = Fixture.started();
    waiting.process(SearchCancelPressed());
    auto ready = Fixture.ready();
    ready.process(SearchCancelPressed());
    auto cancelled = Fixture.searching();
    cancelled.finish(searchOperation, Result.Cancelled);
    cancelled.process(SearchCancelPressed());

    assert(waiting.commands.cancelCalls == 0);
    assert(ready.commands.cancelCalls == 0);
    assert(cancelled.commands.cancelCalls == 0);
}

@("SearchViewFsm: the loss of the file is final from any state")
unittest
{
    Fixture[] fixtures = [Fixture.started(), Fixture.ready(), Fixture.searching()];
    auto cancelled = Fixture.searching();
    cancelled.finish(searchOperation, Result.Cancelled);
    auto failed = Fixture.searching();
    failed.finish(searchOperation, Result.Failed, "x");
    fixtures ~= [cancelled, failed];

    foreach (ref f; fixtures)
    {
        f.process(SourceLost());
        assert(f.sink.last == vm(SearchLostView()));

        const count = f.shownCount;
        const cancelCalls = f.commands.cancelCalls;
        f.start(searchOperation);
        f.finish(searchOperation, Result.Completed);
        f.start(filterOperation);
        f.process(SearchCancelPressed());
        f.process(SourceLost());
        assert(f.shownCount == count, "a lost document ignores everything");
        assert(f.commands.cancelCalls == cancelCalls);
    }
}

@("SearchViewModel: serializes the status, canCancel and the fields of each view")
unittest
{
    import std.json : parseJSON;

    void check(View)(View v, string expected)
    {
        const actual = toJson(SearchViewModel(v));
        assert(actual == parseJSON(expected), View.stringof ~ ": " ~ actual.toString);
    }

    check(SearchWaitingView(), `{"status": "waitingForView", "canCancel": false}`);
    check(SearchResultsView(3), `{"status": "ready", "canCancel": false, "dataVersion": 3}`);
    check(SearchingView(0.25, 2), `{"status": "searching", "canCancel": true, "progress": 0.25, "dataVersion": 2}`);
    check(SearchCancelledView(), `{"status": "searchCancelled", "canCancel": false}`);
    check(SearchFailedView(plainText("e")), `{"status": "searchFailed", "canCancel": false, "error": "e"}`);
    check(SearchLostView(), `{"status": "sourceLost", "canCancel": false}`);
}
