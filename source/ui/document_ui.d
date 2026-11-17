//! The UI side of one open document: the machines of its main and search
//! views, the views they show (sent to the script from the idle loop) and its
//! filter sets.
module ui.document_ui;

import domain.document_store : DocumentStore;
import domain.document : Document;
import domain.document_id : DocumentId;
import std.sumtype : match;
import log_core.log_message : LogMessage;
import log_core.rule_filter : RuleId;
import ui.filter_commands : DocumentFilters;
import ui.main_view_fsm;
import ui.search_view_fsm;

/// UI side of one document: the machines of its main and search views and the
/// views they show. Lives as long as its document; a reopened document gets a new one.
final class DocumentUi : MainViewSink, MainViewCommands, SearchViewSink, SearchViewCommands
{
    private DocumentStore _documents;
    private DocumentId _docId;
    private MainViewFsm _mainView;
    private SearchViewFsm _searchView;
    private DocumentFilters _filters;
    private bool _filterCancelAsked; // set by cancelOperation, read by pressMainCancel

    MainViewModel mainViewShown; // the latest view shown by the machine
    bool mainViewChanged; // shown since it was last sent to JS
    SearchViewModel searchViewShown; // likewise for the search view
    bool searchViewChanged;
    bool attachmentsChanged; // the files sent in the log changed since it was last told to JS
    bool fileInfoChanged; // its descriptions or format choice changed since it was last told to JS

    this(DocumentStore documents, DocumentId docId)
    {
        _documents = documents;
        _docId = docId;
        _mainView = makeMainViewFsm(this, this);
        _searchView = makeSearchViewFsm(this, this);
        _mainView.start();
        _searchView.start();
    }

    /// Feeds an event of the document to both machines
    void process(E)(in E e)
    {
        _mainView.process(e);
        _searchView.process(e);
    }

    /// The filter sets of the main view of the document, created on first use
    DocumentFilters filters()
    {
        if (_filters is null)
        {
            auto doc = _documents.doc(_docId);
            _filters = new DocumentFilters(doc.format, (filter) { doc.applyViewFilter(filter); });
        }
        return _filters;
    }

    /// The first filter rule with a color a record of the document matches;
    /// called for every row shown, so it doesn't create the filters
    RuleId ruleOf(scope ref const(LogMessage!wchar) message) const
    {
        return _filters is null ? RuleId.init : _filters.ruleOf(message);
    }

    /// Returns: true if a running filter was asked to stop
    bool pressMainCancel()
    {
        _filterCancelAsked = false;
        _mainView.process(CancelPressed());
        return _filterCancelAsked;
    }

    void pressSearchCancel()
    {
        _searchView.process(SearchCancelPressed());
    }

    void show(in MainViewModel vm)
    {
        // A load or a filter that just ended: the boxes are what the view shows. Not a ready view that
        // only grew, a switch may have come since
        const built = mainViewShown.match!((in FilteringView _) => true, (in LoadingFileView _) => true, (in _) => false);
        const ready = vm.match!((in ReadyView _) => true, (in _) => false);
        mainViewShown = vm;
        mainViewChanged = true;
        if (built && ready && _filters !is null)
            _filters.markApplied();
    }

    void show(in SearchViewModel vm)
    {
        searchViewShown = vm;
        searchViewChanged = true;
    }

    // A search may run with a filter, over what it has found so far: the
    // filter is stopped with it, the search alone
    bool cancelOperation()
    {
        _filterCancelAsked = _documents.doc(_docId).requestCancel(Document.Operation.BuildFilterIndex);
        return _filterCancelAsked;
    }

    bool cancelSearch()
    {
        return _documents.doc(_docId).requestCancel(Document.Operation.BuildSearchIndex);
    }
}
