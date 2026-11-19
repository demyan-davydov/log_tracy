//! What the painted tables are told of a document's views: a view shown (its content version) and the columns
//! changed, and how a table's model turns them into `ModelChange`s. Free of Sciter.
//! The rule is that of ReadyView.dataVersion (ui/main_view_fsm): under one version a view only grows, a
//! new version replaces it.
module ui.log_table.view_events;

import ptable.model : ModelChange;
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

/// What a table listening to a document hears
struct ViewListener
{
    void delegate(bool search, ViewVersion shown) viewShown; /// a view of the document was shown anew
    void delegate() columnsChanged; /// the columns the tables show changed (the Settings)
}

/// Turns the views shown into the changes of one model: rows appended under the same version, everything
/// else when the view was replaced or has no content
struct ViewChangeTracker
{
    private bool _known;
    private uint _version;
    private size_t _count;

    /// `shown` is the view now, `count` its items. Returns false if the table has nothing to hear.
    bool next(ViewVersion shown, size_t count, out ModelChange change)
    {
        scope (exit)
        {
            _known = shown.has;
            _version = shown.value;
            _count = count;
        }
        if (!shown.has || !_known || shown.value != _version || count < _count)
        {
            change = ModelChange(ModelChange.Kind.everything);
            return true;
        }
        if (count == _count)
            return false;
        change = ModelChange(ModelChange.Kind.count, _count, count);
        return true;
    }
}

@("ViewChangeTracker: rows appended under the same version are a count change from the old count")
unittest
{
    ViewChangeTracker t;
    ModelChange c;
    assert(t.next(ViewVersion(true, 1), 10, c) && c.kind == ModelChange.Kind.everything, "the first one is a start");
    assert(t.next(ViewVersion(true, 1), 25, c) && c == ModelChange(ModelChange.Kind.count, 10, 25));
    assert(!t.next(ViewVersion(true, 1), 25, c), "nothing new");
}

@("ViewChangeTracker: a new version, a view without content or a smaller count start again")
unittest
{
    ViewChangeTracker t;
    ModelChange c;
    t.next(ViewVersion(true, 1), 10, c);
    assert(t.next(ViewVersion(true, 2), 10, c) && c.kind == ModelChange.Kind.everything, "replaced by a filter");
    assert(t.next(ViewVersion(false, 0), 0, c) && c.kind == ModelChange.Kind.everything, "cancelled");
    assert(t.next(ViewVersion(true, 2), 5, c) && c.kind == ModelChange.Kind.everything, "back, the version is not trusted");
    assert(t.next(ViewVersion(true, 2), 3, c) && c.kind == ModelChange.Kind.everything, "it only grows under a version");
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
