//! What the session tells those who listen to the views of the documents (the painted tables): a view shown anew, with the version of
//! its content, the filter rules of a document changed, and the columns changed; and the list of the listeners, each of one document. Knows no table: what a table makes of it
//! is ui/log_table/view_events. The rule of the version is that of ReadyView.dataVersion (ui/main_view_fsm): under one version a view
//! only grows, a new version replaces it. Free of Sciter.
module ui.view_listeners;

import domain.document_id : DocumentId;
import std.sumtype : match;
import ui.main_view_fsm : MainViewModel;
import ui.search_view_fsm : SearchViewModel;

/// The content version of a view shown; a view without content (cancelled, failed, lost) has none
struct ViewVersion
{
    bool has;
    uint value;
}

/// The version of the content a view shows
ViewVersion versionOf(in MainViewModel vm)
{
    return vm.match!((in v) => versionOfView(v));
}

/// ditto
ViewVersion versionOf(in SearchViewModel vm)
{
    return vm.match!((in v) => versionOfView(v));
}

private ViewVersion versionOfView(V)(in V view)
{
    static if (is(typeof(view.dataVersion)))
        return ViewVersion(true, view.dataVersion);
    else
        return ViewVersion(false, 0);
}

/// What a listener to the views of a document hears
struct ViewListener
{
    void delegate(bool search, ViewVersion shown) viewShown; /// a view of the document was shown anew
    void delegate() columnsChanged; /// the columns the tables show changed (the Settings)
    void delegate() rulesChanged; /// the filter rules of the document changed: a row may match another one, of another color
}

/// The listeners to the views, each of one document: a view shown is told to those of its document, a change of the columns to all.
/// A listener may unsubscribe one (itself too) while it is told: one gone is not told any more.
struct ViewListeners
{
    private struct Entry
    {
        size_t handle;
        DocumentId doc;
        ViewListener listener;
    }

    private Entry[] _entries;
    private size_t _next;

    /// `listener` hears the views of `doc` from now on; the handle is for `unsubscribe`
    size_t subscribe(DocumentId doc, ViewListener listener)
    {
        _entries ~= Entry(_next, doc, listener);
        return _next++;
    }

    /// The listener of `handle` hears nothing more
    void unsubscribe(size_t handle)
    {
        import std.algorithm.mutation : remove;

        foreach (i, ref entry; _entries)
            if (entry.handle == handle)
            {
                _entries = _entries.remove(i); // a copy is made when told (`tell`): the list being told keeps its length
                return;
            }
    }

    /// A view of `doc` was shown anew
    void viewShown(DocumentId doc, bool search, ViewVersion shown)
    {
        tell((ref Entry e) {
            if (e.doc == doc && e.listener.viewShown !is null)
                e.listener.viewShown(search, shown);
        });
    }

    /// The filter rules of `doc` changed
    void rulesChanged(DocumentId doc)
    {
        tell((ref Entry e) {
            if (e.doc == doc && e.listener.rulesChanged !is null)
                e.listener.rulesChanged();
        });
    }

    /// The columns changed: every listener hears it
    void columnsChanged()
    {
        tell((ref Entry e) {
            if (e.listener.columnsChanged !is null)
                e.listener.columnsChanged();
        });
    }

    // Tells the listeners there are now, each unless it was unsubscribed in the meantime
    private void tell(scope void delegate(ref Entry) call)
    {
        foreach (entry; _entries.dup)
            if (has(entry.handle))
                call(entry);
    }

    private bool has(size_t handle) const
    {
        foreach (ref entry; _entries)
            if (entry.handle == handle)
                return true;
        return false;
    }
}

@("ViewListeners: a view shown is heard by the listeners of its document, a change of the columns by all")
unittest
{
    ViewListeners listeners;
    string[] heard;
    listeners.subscribe(DocumentId(1), ViewListener((bool search, ViewVersion v) { heard ~= "a" ~ (search ? "s" : "m"); }, () { heard ~= "a cols"; }));
    listeners.subscribe(DocumentId(2), ViewListener((bool search, ViewVersion v) { heard ~= "b"; }, () { heard ~= "b cols"; }));
    listeners.viewShown(DocumentId(1), true, ViewVersion(true, 3));
    assert(heard == ["as"], "only the listener of the document");
    listeners.columnsChanged();
    assert(heard == ["as", "a cols", "b cols"]);
}

@("ViewListeners: a change of the rules is heard by the listeners of its document")
unittest
{
    ViewListeners listeners;
    string[] heard;
    ViewListener a, b;
    a.rulesChanged = () { heard ~= "a"; };
    b.rulesChanged = () { heard ~= "b"; };
    listeners.subscribe(DocumentId(1), a);
    listeners.subscribe(DocumentId(2), b);
    listeners.subscribe(DocumentId(1), ViewListener.init); // one without the hook is passed by
    listeners.rulesChanged(DocumentId(1));
    assert(heard == ["a"]);
}

@("ViewListeners: a listener unsubscribed hears nothing, also when another unsubscribes it while it is being told")
unittest
{
    ViewListeners listeners;
    int first, second;
    size_t secondHandle;
    const firstHandle = listeners.subscribe(DocumentId(1), ViewListener((bool, ViewVersion) {
        ++first;
        listeners.unsubscribe(secondHandle); // the second goes before it is told
    }, null));
    secondHandle = listeners.subscribe(DocumentId(1), ViewListener((bool, ViewVersion) { ++second; }, null));
    listeners.viewShown(DocumentId(1), false, ViewVersion.init);
    assert(first == 1 && second == 0, "the one gone is not told");
    listeners.unsubscribe(firstHandle);
    listeners.viewShown(DocumentId(1), false, ViewVersion.init);
    listeners.columnsChanged(); // a listener without a hook for the columns is passed by
    assert(first == 1);
}

@("versionOf: the views with content have a version, the others none")
unittest
{
    import ui.main_view_fsm : FilterCancelledView, FilteringView, ReadyView;
    import ui.search_view_fsm : SearchResultsView, SearchWaitingView;

    assert(versionOf(MainViewModel(ReadyView(7))) == ViewVersion(true, 7));
    assert(versionOf(MainViewModel(FilteringView(0.5, 3))) == ViewVersion(true, 3));
    assert(!versionOf(MainViewModel(FilterCancelledView())).has);
    assert(versionOf(SearchViewModel(SearchResultsView(2))) == ViewVersion(true, 2));
    assert(!versionOf(SearchViewModel(SearchWaitingView())).has);
}
