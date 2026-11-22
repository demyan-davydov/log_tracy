//! The application behind the window, free of Sciter: the tabs of the documents and
//! their UI side, the settings, and what each call of the script does. The documents
//! are in a DocumentStore given by main(), each held by its tab.
//!
//! The session never calls the script: what the script is to be told
//! (a document opened or closed, a view changed) is queued and taken by the
//! window from its idle loop (takeScriptCalls), so no script runs inside a
//! call of the script. Likewise the settings are only marked changed; the
//! window writes them from its next idle round (settingsDue()), with the
//! state of the script (its getAppState()) merged in: the changes of one
//! round make one write. Once the window closes (saveOnClose) the script is
//! not called any more; what changes after that is written by finish().
module ui.app_session;

import core.time : Duration, MonoTime;
import domain.attachments : Attachment, AttachmentState;
import domain.document;
import domain.document_id;
import domain.document_item : DocumentItem;
import domain.document_store;
import log_core.log_format : ColumnInfo, FormatChoice, LogFormat;
import log_core.rule_filter : RuleId;
import log_core.search_filter : MatchBuffer, MatchRange, SearchFilter;
import ui.app_menu : hostMenuPlatform, MenuItem, MenuPlatform, MenuState, WindowMenu, windowMenu;
import ui.app_settings;
import ui.document_tabs : DocumentTabs;
import ui.document_ui : DocumentUi;
import ui.filter_commands : DocumentFilters;
import ui.table_columns : TableColumns;
import ui.view_listeners : versionOf, ViewListener, ViewListeners, ViewVersion;
import ui.translations : Catalog, CatalogFile, parseCatalog, Translation, findTranslations,
    catalogLanguagesJson = languagesJson, catalogTranslationJson = translationJson;
import ui.main_view_fsm : toJson;
import ui.search_view_fsm : toJson;

import std.json : JSONValue;
import utils.ui_text : english, uiText, uiTextOf, UiText;
static import utils.file_manager;


/// A call of a global function of the script: name(docId) or name(docId, json)
struct ScriptCall
{
    string name;
    int docId;
    string json; // the second argument; null: there is none
}

/// The result of opening a file: the id of its document, or why it can't be opened
struct OpenResult
{
    DocumentId docId; // invalid on failure
    string failureJson; // {"path" (as in the recent list), "error"}
}

/// Opens the file of a document in a format (unset: detected). Throws if it can't.
alias DocumentFactory = Document delegate(string path, FormatChoice choice);

/// Writes the settings (to their file)
alias SettingsWriter = void delegate(in AppSettings settings);

/// Shows a file in the file manager of the system. Throws if it can't.
alias FileShower = void delegate(string path);

final class AppSession
{
    private AppSettings _settings;
    private DocumentStore _documents; // given: others may hold its documents too
    private DocumentTabs _tabs; // the documents of the window, each held by its tab
    private DocumentHold[DocumentId] _tabHolds; // the hold of each tab
    private DocumentUi[DocumentId] _documentUis;
    private TableColumns _tableColumns; // the columns the tables show for each format
    private DocumentFactory _open;
    private SettingsWriter _write;
    private FileShower _showInFolder;
    private ScriptCall[] _scriptCalls; // queued for the idle loop
    private void delegate(DocumentId)[] _documentClosed; // told when the tab of a document goes
    private ViewListeners _viewListeners; // the painted tables, each hearing the views of its document
    private DocumentId[] _reopen; // to be opened anew after the dispatch (ReopenWanted)
    // When each document began to open, until its load completes: the console tells
    // how long the whole load took (a load that never completes tells nothing)
    private MonoTime[DocumentId] _loadStarted;
    private bool _settingsChanged; // since they were last written
    private bool _closing; // the window closes: no more calls of the script
    private WindowMenu _menu = windowMenu(hostMenuPlatform(), ""); // the menu of the window
    private MenuState _menuState; // what of the window the labels of the menu follow
    private Translation[] _translations; // of the interface, by locale
    private Catalog _catalog; // of the language of the interface: the texts of the session
    private bool _offerPseudo; // the pseudo locale among the languages (PSEUDO_LOCALE=1)
    private string[] _startFiles; // to open once the window is up (OPEN_AT_START)

    /// @param documents - where the documents of the tabs are kept
    /// @param open - opens a document (a LogDocument in the app)
    /// @param write - writes the settings, to their file if not given
    /// @param showInFolder - shows a file in the file manager, of the system if not given
    this(AppSettings settings, DocumentStore documents, DocumentFactory open, SettingsWriter write = null,
        FileShower showInFolder = null)
    {
        assert(documents !is null && open !is null);
        _settings = settings;
        _documents = documents;
        _tableColumns = new TableColumns();
        _open = open;
        _write = write !is null ? write : (in AppSettings s) { ui.app_settings.saveSettings(s); };
        _showInFolder = showInFolder !is null ? showInFolder : (string path) { utils.file_manager.showInFolder(path); };
        subscribeToDocumentEvents();
    }

    // ── Script calls and settings, for the idle loop of the window ──────────

    /// Delivers the events of the documents to their views and queues the
    /// views that changed
    void dispatchEvents()
    {
        import std.stdio : writeln;

        try
            _documents.dispatchEvents();
        catch (Exception e)
        {
            for (Throwable t = e; t !is null; t = t.next)
                writeln("Document event handler failed: ", t.msg);
        }
        // Opened anew apart from the dispatch: the documents are replaced
        auto reopened = _reopen;
        _reopen = null;
        foreach (docId; reopened)
            reopenWanted(docId);
    }

    /// The file of a document is to be opened anew (ReopenWanted: truncated by a rotation,
    /// or of a format its first bytes tell): it is, in its tab, by the format choice of the
    /// document, and the script resets the tab
    private void reopenWanted(DocumentId docId)
    {
        import std.stdio : writeln;

        if (!_documents.isOpen(docId))
            return; // closed meanwhile
        const error = reopen(docId);
        if (error.length == 0)
        {
            _scriptCalls ~= ScriptCall("onDocumentReopened", idOf(docId));
            return;
        }
        // Its rows are gone: shown lost, with Retry, rather than frozen on them
        writeln("Reopening the file failed: ", error);
        processDocumentEvent(docId, SourceLost());
    }

    /// The calls of the script queued since the last time, in order: the
    /// documents opened and the anchors applied (onAnchorApplied), as they
    /// came, then the views that changed. An anchor comes before the views of
    /// its round: the table edits the row of the anchor in place before it
    /// counts the rows its view grew by, which take that row in already
    ScriptCall[] takeScriptCalls()
    {

        foreach (docId, ui; _documentUis)
        {
            if (ui.mainViewChanged)
            {
                ui.mainViewChanged = false;
                tellViewShown(docId, false, versionOf(ui.mainViewShown));
                _scriptCalls ~= ScriptCall("onMainViewChanged", idOf(docId),
                    toJson(ui.mainViewShown, &textForUser).toString());
            }
            if (ui.searchViewChanged)
            {
                ui.searchViewChanged = false;
                tellViewShown(docId, true, versionOf(ui.searchViewShown));
                _scriptCalls ~= ScriptCall("onSearchViewChanged", idOf(docId),
                    toJson(ui.searchViewShown, &textForUser).toString());
            }
            if (ui.attachmentsChanged)
            {
                ui.attachmentsChanged = false;
                _scriptCalls ~= ScriptCall("onAttachmentsChanged", idOf(docId));
            }
            if (ui.fileInfoChanged)
            {
                ui.fileInfoChanged = false;
                _scriptCalls ~= ScriptCall("onFileInfoChanged", idOf(docId));
            }
        }
        auto calls = _scriptCalls;
        _scriptCalls = null;
        return calls;
    }

    /// The tables drawn by D hear the views of `docId` at the moment the script is told of them (and not
    /// through the script), and a change of the columns of any document. Returns the handle for `unsubscribeViews`.
    size_t subscribeViews(DocumentId docId, ViewListener listener)
    {
        return _viewListeners.subscribe(docId, listener);
    }

    /// ditto
    void unsubscribeViews(size_t handle)
    {
        _viewListeners.unsubscribe(handle);
    }

    private void tellViewShown(DocumentId docId, bool search, ViewVersion shown)
    {
        _viewListeners.viewShown(docId, search, shown);
    }

    private void tellColumnsChanged()
    {
        _viewListeners.columnsChanged();
    }

    /// Returns: true if the settings changed and are to be written now
    bool settingsDue() const
    {
        return _settingsChanged && !_closing;
    }

    /// True once the window closes (saveOnClose): the script is not to be
    /// called any more, its view is being torn down
    bool closing() const
    {
        return _closing;
    }

    /// The event loop stopped: writes what changed since the settings were
    /// last written (without the state of the script, it can't be asked any
    /// more) and closes all tabs (closeAll)
    void finish()
    {
        if (_settingsChanged)
            saveSettings("{}");
        closeAll();
    }

    /// The user moved or resized the window: the settings are written by the
    /// next idle round, with the frame of the script's getAppState()
    void windowFrameChanged()
    {
        _settingsChanged = true;
    }

    /// The application terminates (macOS: Quit, the Dock, logging out), the event
    /// loop won't return: writes the settings with `appStateJson` unless the
    /// window already did (then the script isn't asked for it), and closes every
    /// document, those held by others too: main() doesn't get to close the store
    void terminate(lazy const(char)[] appStateJson)
    {
        if (!_closing)
            saveOnClose(appStateJson);
        finish();
        _documents.closeAll();
    }

    /// Writes the settings with `appStateJson` (the script's getAppState())
    /// merged in. The open files are marked used now, in place: the time
    /// survives a crash, the order of the list stays that of the files opened
    /// and closed.
    void saveSettings(const(char)[] appStateJson)
    {
        import std.stdio : writeln;

        _settings.recentFiles = withFilesStamped(_settings.recentFiles, openPaths(), nowMs());
        // Kept, not only written: a later write without the script ("{}") keeps it
        _settings = mergeAppStateFromScript(_settings, appStateJson);
        _settingsChanged = false;
        try
            _write(_settings);
        catch (Exception e)
            writeln("Failed to save settings: ", e.msg);
    }

    /// The window closes: the settings are written at once, the open files on
    /// top of the files closed before (they were being worked with until now)
    void saveOnClose(const(char)[] appStateJson)
    {
        _settings.recentFiles = withFilesUsed(_settings.recentFiles, openPaths(), nowMs());
        saveSettings(appStateJson);
        _closing = true;
    }

    /// Closes all tabs: a document no one else holds is closed, its background
    /// operations stopped
    void closeAll()
    {
        _documentUis = null;
        foreach (docId; _tabs.ids.dup)
        {
            _tabs.remove(docId);
            releaseTabHold(docId);
            tellDocumentClosed(docId);
        }
    }

    /// `listener` is told when the tab of a document goes (what was kept for it, such as its tables' columns, is no longer wanted)
    void subscribeDocumentClosed(void delegate(DocumentId) listener)
    {
        _documentClosed ~= listener;
    }

    private void tellDocumentClosed(DocumentId docId)
    {
        foreach (listener; _documentClosed)
            listener(docId);
    }

    // ── The documents ────────────────────────────────────────────────────────

    /// The settings as they are now
    ref const(AppSettings) settings() const return
    {
        return _settings;
    }

    /// Returns: the id of the document of the tab `id`, invalid if there is none
    DocumentId findDocument(int id)
    {
        foreach (docId; _tabs.ids)
            if (docId.toInt() == id)
                return docId;
        return DocumentId.init;
    }

    /// The document `docId`, the null document (no rows) if it isn't open
    Document doc(DocumentId docId)
    {
        return _documents.doc(docId);
    }

    /// Opens `path` in a new tab, or shows its tab if it is open already
    OpenResult openFile(string path)
    {
        import std.stdio : writeln;

        writeln("Opening file: ", path);
        const existing = _documents.findBySourcePath(path);
        if (existing.isValid)
        {
            // Only the window opens files yet. A document another holder (an AI session)
            // opened has no tab; giving it one needs its view machines started from the
            // state of the document, not from a load: decided with the holders of branch mcp
            // (docs/backlog.md, "Вкладка для документа другого держателя")
            assert(_tabs.has(existing), "a document open without a tab");
            _tabs.activate(existing);
            rememberRecentFile(RecentFile(path, _documents.doc(existing).formatChoice, nowMs()));
            _scriptCalls ~= ScriptCall("onDocumentOpened", idOf(existing));
            return OpenResult(existing);
        }

        try
        {
            // Opened the way it was last time: the format may have been chosen by hand
            const openStart = MonoTime.currTime;
            auto document = _open(path, savedFormat(_settings.recentFiles, path));
            const hold = _documents.add(document, path); // held by its tab
            const docId = hold.docId;
            _loadStarted[docId] = openStart; // the load goes on (BuildOffsetIndex)
            addTab(hold, path);
            _tabs.activate(docId);
            rememberRecentFile(RecentFile(path, document.formatChoice, nowMs()));
            _scriptCalls ~= ScriptCall("onDocumentOpened", idOf(docId));
            return OpenResult(docId);
        }
        catch (Exception e)
        {
            import std.json : JSONValue;

            writeln("Error opening file ", path, ": ", e.msg);
            // Listed with the reason, to retry or see: a file of the list stays
            // where it is, a new one goes on top
            _settings.recentFiles = withFailedFile(_settings.recentFiles, path);
            settingsChanged();
            JSONValue failure = ["path": recentFilePath(path), "error": _catalog.translate(uiTextOf(e))];
            return OpenResult(DocumentId.init, failure.toString());
        }
    }

    /// Reopens the file of a document whose source was lost, in the same tab.
    /// Returns: an error message for the UI (e.g. the disk is still missing),
    /// "" if the document was replaced by a freshly opened one
    string retryDocument(int id)
    {
        const docId = findDocument(id);
        if (!docId.isValid)
            return _catalog.translate(uiText("the document is not open"));
        return reopen(docId);
    }

    /// Opens the file of the document anew in its place, in the format it had, its filters
    /// restored. Returns: an error message for the UI, "" if it was replaced
    private string reopen(DocumentId docId)
    {
        import std.stdio : writeln;

        const id = idOf(docId);
        const path = sourcePathOf(docId);
        // reopened in the format it had, not detected again
        const choice = _documents.doc(docId).formatChoice;
        try
        {
            // Timings: both steps run on the UI thread and may block on a disk
            // that has just been reconnected or removed
            const openStart = MonoTime.currTime;
            auto fresh = _open(path, choice);
            const openTime = MonoTime.currTime - openStart;
            _loadStarted[docId] = openStart; // its load starts anew

            const destroyStart = MonoTime.currTime;
            // The filters the old document had, for the new one
            auto oldUi = _documentUis.get(docId, null);
            const filters = oldUi is null ? null : oldUi.filters.saved();
            auto old = _documents.replace(docId, fresh);
            addDocumentUi(docId); // the new document starts with a new machine
            restoreAnchors(docId, path); // before the filters: their pass lists them
            _documentUis[docId].filters.restore(filters);
            if (old !is null)
                old.destroy();
            const destroyTime = MonoTime.currTime - destroyStart;

            writeln("Reopened document ", id, ": ", path, " (open: ", openTime,
                ", destroy old: ", destroyTime, ")");
            return "";
        }
        catch (Exception e)
        {
            writeln("Retry failed for ", path, ": ", e.msg);
            return _catalog.translate(uiTextOf(e));
        }
    }

    /// Closes the tab of the document; its file is marked used now
    void closeTab(int id)
    {
        const docId = findDocument(id);
        if (docId.isValid)
            closeDocument(docId);
    }

    void switchTab(int id)
    {
        const docId = findDocument(id);
        if (docId.isValid)
            _tabs.activate(docId);
    }

    void reorderTab(int id, int targetIndex)
    {
        const docId = findDocument(id);
        if (docId.isValid)
            _tabs.move(docId, targetIndex);
    }

    /// The open documents for the tabs: id, name, path, active, the views shown
    string workspaceInfoJson()
    {
        import std.path : baseName;

        JSONValue[] docs;
        foreach (docId; _tabs.ids)
        {
            auto ui = _documentUis.get(docId, null);
            const path = _documents.sourcePath(docId);
            docs ~= JSONValue([
                "id": JSONValue(docId.toInt()),
                "name": JSONValue(path.baseName),
                "path": JSONValue(path),
                "active": JSONValue(docId == _tabs.active),
                "mainView": ui is null ? JSONValue(null) : toJson(ui.mainViewShown, &textForUser),
                "searchView": ui is null ? JSONValue(null) : toJson(ui.searchViewShown, &textForUser)
            ]);
        }
        return JSONValue(docs).toString();
    }

    /// Removes a file from the recent list, with what was kept for it (its
    /// filters, its searches). An open file stays: it would be listed again
    /// as soon as it is stamped used. Returns: whether it was removed
    bool removeRecentFile(string path)
    {
        import std.algorithm : canFind;

        if (openPaths().canFind!(p => sameRecentFile(p, path)))
            return false;
        const before = _settings.recentFiles.length;
        _settings.recentFiles = withoutRecentFile(_settings.recentFiles, path);
        if (_settings.recentFiles.length == before)
            return false;
        settingsChanged();
        return true;
    }

    /// Shows a file in the file manager. Returns: "" or why it can't be
    /// (the message of the system, untranslated)
    string showInFolder(string path)
    {
        try
            _showInFolder(path);
        catch (Exception e)
            return e.msg;
        return "";
    }

    /// The recent files for the placeholder, the open ones marked
    string recentFilesJson()
    {
        return ui.app_settings.recentFilesJson(_settings.recentFiles, openPaths());
    }

    // ── The views ────────────────────────────────────────────────────────────

    /// The columns the tables of `document` show: those of its format as the
    /// layout of the format arranges them
    const(ColumnInfo)[] tableColumns(Document document)
    {
        return _tableColumns.of(document.columns, document.formatInfo.id, _settings.columnLayouts);
    }

    /// The first filter rule with a color a row of the document matches
    RuleId ruleOf(DocumentId docId, ref const(DocumentItem) item)
    {
        auto ui = _documentUis.get(docId, null);
        return ui is null ? RuleId.init : ui.ruleOf(item.message);
    }

    /// The color "#rrggbb" of the filter rule `rule` of the document, empty if it has none
    string ruleColor(DocumentId docId, RuleId rule)
    {
        auto ui = _documentUis.get(docId, null);
        return ui is null ? "" : ui.ruleColorOf(rule);
    }

    /// The row of view (the search view if `searchView`, else the main one) of
    /// the document that shows the message `messageIndex` (a script number:
    /// negative when the script has none)
    /// @return false if that view doesn't show it
    bool viewPosition(DocumentId docId, bool searchView, double messageIndex, out size_t position)
    {
        // a double: a message index above 2^31 doesn't fit an int
        if (!(messageIndex >= 0) || messageIndex >= size_t.max)
            return false;
        auto doc = _documents.doc(docId);
        auto view = searchView ? doc.searchView : doc.mainView;
        return view.positionOf(cast(size_t) messageIndex, position);
    }

    /// The row of the main view nearest to the message `messageIndex` (see
    /// DocumentView.nearestPositionOf): where Go to Message lands
    /// @return false for no message index or an empty view
    bool nearestMainViewPosition(DocumentId docId, double messageIndex, out size_t position)
    {
        if (!(messageIndex >= 0))
            return false;
        const index = messageIndex >= size_t.max ? size_t.max : cast(size_t) messageIndex;
        return _documents.doc(docId).mainView.nearestPositionOf(index, position);
    }

    /// What the chips of the search found in the payload of a row of either
    /// view; nothing for a row the search didn't find (DocumentItem.found), so
    /// the rows of the main view it didn't find cost nothing.
    ///
    /// The chips are those of the search the document found the rows by, not of
    /// a search asked for that hasn't started yet. The same filter the indexing
    /// thread searches with: its rules are only read, and a regex keeps the
    /// state of a search out of the filter (utils/text_regex).
    /// @param buffer - where they are written, its length the most of them (a
    /// MatchBuffer for a table row, see maxMatchRanges)
    /// @return the start of `buffer`
    const(MatchRange)[] matchesOf(DocumentId docId, ref const(DocumentItem) item, return scope MatchRange[] buffer)
    {
        if (!item.found)
            return null;
        // null for another filter (none of the chips' searches)
        auto search = cast(const(SearchFilter)) _documents.doc(docId).searchFilter;
        return search is null ? null : search.matchRanges(item.message(), buffer);
    }

    /// The match colors of the chips of the search the document runs (the one `matchesOf` gives the matches of, not a query that
    /// hasn't started yet), by the place of a chip (`MatchRange.chip`): its own color, as the search editor shows it (null: none
    /// told, a chip is colored by its place)
    const(uint)[] searchColors(DocumentId docId)
    {
        auto ui = _documentUis.get(docId, null);
        return ui is null ? null : ui.searchColors.of(_documents.doc(docId).searchFilter);
    }

    /// Sets or clears the anchor of a message.
    /// Returns: JSON `{"refused": null | "limit" | "unavailable", "max": <the
    /// anchor limit>, "full": <no room for another anchor now>, "pending": <the
    /// views take it later, onAnchorApplied tells its rows then>, "rows": <the
    /// rows it changed (anchorRowsJson), null if refused, pending or none came
    /// or went>}`; nothing
    /// changes when refused: at the anchor limit, or when the document can't
    /// change (its file is lost). The script writes the text (plural forms of
    /// the limit: trn). The anchors are kept in the settings of the file, as its
    /// filters are.
    string setAnchor(DocumentId docId, int messageIndex, bool value)
    {
        import domain.anchors : Anchors;

        auto doc = _documents.doc(docId);
        const change = messageIndex < 0 ? AnchorChange(AnchorRefusal.unavailable)
            : doc.setAnchor(cast(size_t) messageIndex, value);
        if (change)
            saveAnchors(docId);
        JSONValue json = ["full": doc.anchorsFull];
        json["max"] = Anchors.MaxAnchors;
        json["pending"] = change.pending;
        json["rows"] = change.rows.moved ? anchorRowsJson(change.rows) : JSONValue(null);
        final switch (change.refusal)
        {
        case AnchorRefusal.none: json["refused"] = null; break;
        case AnchorRefusal.unavailable: json["refused"] = "unavailable"; break;
        case AnchorRefusal.limit: json["refused"] = "limit"; break;
        }
        return json.toString;
    }

    /// The anchors of the document kept in the settings of its file, if they changed
    private void saveAnchors(DocumentId docId)
    {
        const path = sourcePathOf(docId);
        if (path.length == 0)
            return;
        auto anchors = withAnchors(_settings.recentFiles, path, _documents.doc(docId).exportAnchors);
        if (anchors == _settings.recentFiles)
            return;
        _settings.recentFiles = anchors;
        settingsChanged();
    }

    /// The document just opened from `path` gets the anchors the file had last time
    private void restoreAnchors(DocumentId docId, string path)
    {
        import std.stdio : writeln;

        try
            _documents.doc(docId).importAnchors(savedAnchors(_settings.recentFiles, path));
        catch (Exception e)
            writeln("Anchors of ", path, " not restored: ", e.msg);
    }

    /// Cancel pressed in the main view of the document: its machine decides
    /// what it means
    void cancelMainView(DocumentId docId)
    {
        if (auto ui = _documentUis.get(docId, null))
            // The cancelled filter isn't applied: the boxes go back to what the view shows
            if (ui.pressMainCancel())
                filterCommand(docId, (DocumentFilters filters) => filters.restoreApplied());
    }

    void cancelSearchView(DocumentId docId)
    {
        if (auto ui = _documentUis.get(docId, null))
            ui.pressSearchCancel();
    }

    // ── Search ───────────────────────────────────────────────────────────────

    /// Starts the search for the chips in the document; no chips clear it.
    /// Returns: an error message for the UI, "" if the search was started
    string startChipSearch(DocumentId docId, string chipsJson)
    {
        import log_core.search_filter : SearchFilter;
        import std.stdio : writeln;
        import ui.search_chips : queryFromJson;

        writeln("startChipSearch request: ", chipsJson);
        try
        {
            // An invalid regex throws here, before any background work starts
            auto query = queryFromJson(chipsJson);
            const chips = query.chips;
            auto filter = SearchFilter.fromChips(chips);
            if (!docId.isValid)
                return _catalog.translate(uiText("the document is not open"));
            auto doc = _documents.doc(docId);
            doc.applySearchFilter(filter); // null clears the search
            if (auto ui = _documentUis.get(docId, null))
                ui.searchColors.told(filter, query.colors, doc.searchFilter); // the search that runs keeps its own till the new starts
            // the history of the file, remembered as its filters are (the
            // latest query again changes nothing)
            if (filter !is null)
                if (auto path = sourcePathOf(docId))
                {
                    const searches = savedSearches(_settings.recentFiles, path);
                    if (searches.length == 0 || searches[0] != chips)
                    {
                        _settings.recentFiles = withSearch(_settings.recentFiles, path, chips);
                        settingsChanged();
                    }
                }
            return "";
        }
        catch (Exception e)
        {
            writeln("Error starting search: ", e.msg);
            return _catalog.translate(uiTextOf(e)); // a regex error of the library as it is
        }
    }

    /// What is wrong with the regular expression of a chip, for the engine the search uses.
    /// Returns: the error message (of the engine, as startChipSearch gives it), "" for a valid one
    string checkRegex(string pattern, bool matchCase)
    {
        static import log_core.search_filter;

        return log_core.search_filter.checkRegex(pattern, !matchCase);
    }

    /// What the File Info page shows of the document: {name, path, format,
    /// bytes, records, descriptions}, null if it isn't open. descriptions: null for a log that
    /// takes none, else {taken, folder, choice, read, reading, problem} (Document.descriptions;
    /// choice: those formatChoice names, problem translated), "" for none
    string documentInfoJson(DocumentId docId)
    {
        import formats.registry : takesDescriptions;
        import std.path : baseName;

        const path = sourcePathOf(docId);
        if (!path.length)
            return "null";
        auto document = _documents.doc(docId);
        const format = document.format;
        JSONValue descriptions = null;
        if (takesDescriptions(format))
        {
            const d = document.descriptions;
            descriptions = JSONValue([
                "taken": JSONValue(d.taken),
                "folder": JSONValue(d.folder),
                "choice": JSONValue(document.formatChoice.descriptions),
                "read": JSONValue(d.read),
                "reading": JSONValue(d.reading),
                "problem": JSONValue(d.problem.empty ? "" : _catalog.translate(d.problem))
            ]);
        }
        return JSONValue([
            "name": JSONValue(path.baseName),
            "path": JSONValue(path),
            "format": JSONValue(format is null ? "" : format.info.name),
            "records": JSONValue(document.messageCount),
            "bytes": JSONValue(document.byteSize),
            "descriptions": descriptions
        ]).toString();
    }

    /// Reads the descriptions at `path` (a FIBEX file or folder) for the document, in the
    /// background (Document.loadDescriptions): the File Info is told how the read goes.
    /// Returns: "" or why it can't be (not open, a log that takes none)
    string loadDescriptions(DocumentId docId, string path)
    {
        import formats.registry : takesDescriptions;

        if (!sourcePathOf(docId).length)
            return _catalog.translate(uiText("the document is not open"));
        auto document = _documents.doc(docId);
        if (!takesDescriptions(document.format))
            return _catalog.translate(uiText("this log can't be decoded by a FIBEX"));
        document.loadDescriptions(path);
        return "";
    }

    /// Drops the descriptions of the document. Returns: "" or why it can't be
    string unloadDescriptions(DocumentId docId)
    {
        return loadDescriptions(docId, "");
    }

    /// The files sent in the log of the document (Document.attachments): [{id, name, date,
    /// size, packets, received, inTurn, state, record, serial, error, osError}], [] if it
    /// isn't open. state: "sending", "complete", "incomplete", "failed"; serial null if
    /// unknown; record: the index of the message that opened the transfer, as
    /// mainViewPosition takes it (not a row of the main view: a filter hides rows)
    string attachmentsJson(DocumentId docId)
    {
        import std.conv : to;

        if (!sourcePathOf(docId).length)
            return "[]";
        JSONValue[] list;
        foreach (a; _documents.doc(docId).attachments)
            list ~= JSONValue([
                "id": JSONValue(a.id),
                "name": JSONValue(a.name),
                "date": JSONValue(a.date),
                "size": JSONValue(a.size),
                "packets": JSONValue(a.packets),
                "received": JSONValue(a.received),
                "inTurn": JSONValue(a.inTurn),
                "state": JSONValue(a.state.to!string),
                "record": JSONValue(a.record),
                "serial": a.hasSerial ? JSONValue(a.serial) : JSONValue(null),
                "error": JSONValue(a.error),
                "osError": JSONValue(a.osError),
            ]);
        return JSONValue(list).toString();
    }

    /// Saves the attachment `id` of the document to the file `path`, whole or not at all: its
    /// bytes go to "<path>.part", which takes the place of `path` once they are all there, so
    /// a file saved over stays as it was if the save fails.
    /// Returns: the error for the user, "" if it was saved
    string saveAttachment(DocumentId docId, size_t id, string path)
    {
        import std.file : exists, remove, rename;
        import std.stdio : File;

        if (!sourcePathOf(docId).length)
            return _catalog.translate(uiText("the document is not open"));
        const part = path ~ ".part";
        File file;
        try
        {
            // Made once the attachment can be written: not for one refused
            _documents.doc(docId).writeAttachment(id, () { file = File(part, "wb"); },
                (const(ubyte)[] bytes) { file.rawWrite(bytes); });
            file.close();
            rename(part, path);
            return "";
        }
        catch (Exception e)
        {
            try
            {
                if (file.isOpen)
                    file.close();
                if (exists(part))
                    remove(part);
            }
            catch (Exception)
            {
            }
            return _catalog.translate(uiText("Can't save the file: {reason}", "reason", uiTextOf(e)));
        }
    }

    /// The queries searched in the file of the document, the latest first: [[chips]]
    string searchHistoryJson(DocumentId docId)
    {
        import ui.search_chips : chipsToJson;

        JSONValue[] queries;
        if (auto path = sourcePathOf(docId))
            foreach (query; savedSearches(_settings.recentFiles, path))
                queries ~= chipsToJson(query);
        return JSONValue(queries).toString();
    }

    /// Removes a query (its chips as JSON) from the search history of the file
    /// of the document. Returns: whether it was there
    bool removeSearch(DocumentId docId, string chipsJson)
    {
        import log_core.search_filter : SearchChip;
        import ui.search_chips : chipsFromJson;

        auto path = sourcePathOf(docId);
        if (!path)
            return false;
        SearchChip[] query;
        try
            query = chipsFromJson(chipsJson);
        catch (Exception e)
            return false;
        const before = savedSearches(_settings.recentFiles, path).length;
        _settings.recentFiles = withoutSearch(_settings.recentFiles, path, query);
        if (savedSearches(_settings.recentFiles, path).length == before)
            return false;
        settingsChanged();
        return true;
    }

    // ── Filters ──────────────────────────────────────────────────────────────

    /// The filter sets of the document, null if it isn't open
    DocumentFilters filters(DocumentId docId)
    {
        auto ui = _documentUis.get(docId, null);
        return ui is null ? null : ui.filters;
    }

    /// Runs a command on the filter sets of the document; the sets are kept
    /// in the settings of its file when it changed them (they are copies, see
    /// DocumentFilters), also with a note (what a loaded .dlf lost).
    /// Returns: its message for the user (an error, a note) in the language of the interface, ""
    /// if none
    string filterCommand(DocumentId docId, scope UiText delegate(DocumentFilters) command)
    {
        auto filters = filters(docId);
        if (filters is null)
            return "";
        const before = filters.saved();
        const message = textForUser(command(filters));
        if (filters.saved() != before)
        {
            if (auto path = sourcePathOf(docId))
                _settings.recentFiles = withFilters(_settings.recentFiles, path, filters.saved());
            settingsChanged();
            _viewListeners.rulesChanged(docId); // a row may match another rule now, of another color, though the view is not filtered again
        }
        return message;
    }

    // ── Menu ─────────────────────────────────────────────────────────────────

    /// The window has `menu` (that of the host platform until told)
    void showMenu(WindowMenu menu)
    {
        _menu = menu;
    }

    /// The bottom panel of the documents is shown (`shown`) or collapsed: the menu labels its
    /// command by it (the script tells it, as it keeps the panel)
    void setBottomPanelShown(bool shown)
    {
        _menuState.bottomPanelShown = shown;
    }

    /// The menu of the window for the script (ui.app_menu.windowMenuJson)
    string menuJson()
    {
        import ui.app_menu : windowMenuJson;

        return windowMenuJson(_menu, &_catalog.translate, _menuState);
    }

    // ── Translations ─────────────────────────────────────────────────────────

    /// The translations of the interface are the catalogs of `files`
    /// (resources/i18n/translations)
    void useTranslations(const CatalogFile[] files)
    {
        _translations = findTranslations(files);
    }

    /// Whether the languages offered end with the pseudo locale: to look for texts not translated
    void offerPseudoLocale(bool offer)
    {
        _offerPseudo = offer;
    }

    /// The files to open once the window is up (OPEN_AT_START): `paths` one per line. Not the
    /// path separator of PATH: a ':' is common in the names of logs (a time), and a single file
    /// needs no separator at all.
    void openAtStart(string paths)
    {
        import std.algorithm : filter;
        import std.array : array;
        import std.string : lineSplitter;

        _startFiles = paths.lineSplitter.filter!(path => path.length > 0).array;
    }

    /// The files to open at start, as `openAtStart` was told: a JSON array of paths
    string startFilesJson()
    {
        import std.json : JSONValue;

        return JSONValue(_startFiles).toString();
    }

    /// The languages there are translations to: [{"locale", "name"}], the pseudo locale last if
    /// offered
    string languagesJson()
    {
        import ui.translations : pseudoLocale;

        auto languages = _translations.dup;
        if (_offerPseudo)
            languages ~= Translation(pseudoLocale, "Pseudo (for testing)");
        return catalogLanguagesJson(languages);
    }

    /// The texts of the session (the menu, the errors) are in the language `requested` (a BCP 47
    /// tag) from now on: in the catalog it takes, english if none (the pseudo locale too: only
    /// the script pseudoizes, its own texts).
    /// Returns: the text of that catalog for the script, null if none
    string useLanguage(string requested)
    {
        const text = catalogTranslationJson(_translations, requested);
        _catalog = parseCatalog(text);
        return text;
    }

    /// `t` in the language of the interface: a text for the user the session answers with
    string textForUser(const UiText t) @safe
    {
        return _catalog.translate(t);
    }

    /// The menu bar of the window on `platform`, in the language of the interface
    MenuItem[] menuBar(MenuPlatform platform)
    {
        import ui.app_menu : appMenu;

        return appMenu(platform, &_catalog.translate, _menuState);
    }

    // ── Columns ──────────────────────────────────────────────────────────────

    /// The Columns section of the Settings dialog, the format of the active document first
    string columnSettingsJson()
    {
        return ui.app_settings.columnSettingsJson(_settings.columnLayouts, _documents.doc(_tabs.active).formatInfo.id);
    }

    /// Saved by the Settings dialog: {format id: [{"id", "visible"}]}
    void setColumnLayouts(string json)
    {
        _settings.columnLayouts = withColumnLayouts(_settings.columnLayouts, json);
        _tableColumns.reset(); // arranged again
        tellColumnsChanged();
        settingsChanged();
    }

    // ── Inside ───────────────────────────────────────────────────────────────

    /// Feeds document events to the machines of the documents
    private void subscribeToDocumentEvents()
    {
        import std.stdio : writeln;

        auto events = _documents.events;
        events.subscribe((const DocumentEvent!OperationStarted e) {
            writeln("Operation ", e.event.operation, " started, doc ", e.docId.toInt());
            processDocumentEvent(e.docId, e.event);
        });
        events.subscribe((const DocumentEvent!OperationProgress e) {
            processDocumentEvent(e.docId, e.event);
        });
        events.subscribe((const DocumentEvent!ContentGrown e) {
            processDocumentEvent(e.docId, e.event);
        });
        events.subscribe((const DocumentEvent!ReopenWanted e) {
            _reopen ~= e.docId;
            // A file truncated by a rotation is another log: the messages anchored are gone
            if (e.event.why == ReopenWanted.Why.truncated)
                if (auto path = sourcePathOf(e.docId))
                    if (savedAnchors(_settings.recentFiles, path).length)
                    {
                        _settings.recentFiles = withAnchors(_settings.recentFiles, path, null);
                        settingsChanged();
                    }
        });
        // An anchor taken while a pass ran: the tables follow the rows it changed
        events.subscribe((const DocumentEvent!AnchorApplied e) {
            _scriptCalls ~= ScriptCall("onAnchorApplied", idOf(e.docId), anchorRowsJson(e.event.rows).toString);
        });
        events.subscribe((const DocumentEvent!AttachmentsChanged e) {
            if (auto ui = _documentUis.get(e.docId, null))
                ui.attachmentsChanged = true;
        });
        // The choice to open the file with again: written to the recent list, in place
        events.subscribe((const DocumentEvent!FormatReplaced e) {
            const path = _documents.sourcePath(e.docId);
            const choice = _documents.doc(e.docId).formatChoice;
            // The same choice taken again (a FIBEX read at the open, read anew): nothing to write
            if (path.length && savedFormat(_settings.recentFiles, path) != choice)
            {
                _settings.recentFiles = withFormat(_settings.recentFiles, path, choice);
                settingsChanged();
            }
            if (auto ui = _documentUis.get(e.docId, null))
                ui.fileInfoChanged = true;
        });
        events.subscribe((const DocumentEvent!DescriptionsChanged e) {
            if (auto ui = _documentUis.get(e.docId, null))
                ui.fileInfoChanged = true;
        });
        events.subscribe((const DocumentEvent!SourceLost e) {
            writeln("Source lost, doc ", e.docId.toInt(), ": ", _documents.sourcePath(e.docId));
            processDocumentEvent(e.docId, e.event);
        });
        events.subscribe((const DocumentEvent!OperationFinished e) {
            writeln("Operation ", e.event.operation, " ", e.event.result, ", doc ", e.docId.toInt(),
                " in ", msText(e.event.elapsed),
                e.event.error.empty ? "" : ": " ~ english(e.event.error));
            // The first load ended: how long it took from the opening, once (a file that
            // grows builds on, a stream never completes)
            if (e.event.operation == Document.Operation.BuildOffsetIndex)
                if (auto started = e.docId in _loadStarted)
                {
                    if (e.event.result == OperationFinished.Result.Completed)
                        writeln("Loaded file in ", msText(MonoTime.currTime - *started), ": ",
                            _documents.sourcePath(e.docId));
                    _loadStarted.remove(e.docId);
                }
            processDocumentEvent(e.docId, e.event);
        });
    }

    /// A time for the console, as profiling reads it: "12.3 ms"
    private static string msText(Duration time)
    {
        import std.format : format;

        return format("%.1f ms", time.total!"usecs" / 1000.0);
    }

    /// The rows an anchor changed, for the script: {"message", "anchored", "main", "search"}
    private static JSONValue anchorRowsJson(in AnchorRows rows)
    {
        JSONValue json = ["message": JSONValue(rows.message)];
        json["anchored"] = rows.anchored;
        json["main"] = rows.main;
        json["search"] = rows.search;
        return json;
    }

    private void processDocumentEvent(E)(DocumentId docId, in E e)
    {
        if (auto ui = _documentUis.get(docId, null))
            ui.process(e);
    }

    private void addDocumentUi(DocumentId docId)
    {
        _documentUis[docId] = new DocumentUi(_documents, docId);
        // its machines start showing at once: their first views are queued
    }

    /// A tab for the document just opened from the file `path`, held by the tab by
    /// `hold`, after the others, with its UI side and the filters the file had last time
    /// (before the recent list moves it)
    private void addTab(DocumentHold hold, string path)
    {
        const docId = hold.docId;
        _tabs.add(docId);
        _tabHolds[docId] = hold;
        addDocumentUi(docId);
        restoreAnchors(docId, path); // before the filters: their pass lists them
        _documentUis[docId].filters.restore(savedFilters(_settings.recentFiles, path));
    }

    /// Closes the tab of the document, which lets it go: closed unless another holds
    /// it. Its file is marked used now in the recent list.
    private void closeDocument(DocumentId docId)
    {
        const path = sourcePathOf(docId);
        _documentUis.remove(docId);
        _loadStarted.remove(docId);
        if (_tabs.remove(docId))
            releaseTabHold(docId);
        tellDocumentClosed(docId);
        if (path.length)
        {
            _settings.recentFiles = withFilesUsed(_settings.recentFiles, [path], nowMs());
            settingsChanged();
        }
    }

    /// The tab of the document `docId` lets it go
    private void releaseTabHold(DocumentId docId)
    {
        if (auto hold = docId in _tabHolds)
        {
            _documents.release(*hold);
            _tabHolds.remove(docId);
        }
    }

    /// Puts the file opened (or tried) on top of the recent list
    private void rememberRecentFile(RecentFile file)
    {
        _settings.recentFiles = withRecentFile(_settings.recentFiles, file);
        settingsChanged();
    }

    private void settingsChanged()
    {
        _settingsChanged = true;
    }

    /// Files of the documents of the tabs, in their order
    private const(string)[] openPaths()
    {
        string[] paths;
        foreach (docId; _tabs.ids)
            paths ~= _documents.sourcePath(docId);
        return paths;
    }

    /// Returns: the path of the document, null if it isn't open
    private string sourcePathOf(DocumentId docId)
    {
        return _documents.sourcePath(docId);
    }

    private static int idOf(DocumentId docId)
    {
        return cast(int) docId.toInt();
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

version (unittest)
{
    import log_core.log_filter : LogFilter;
    import log_core.log_format : LogFormat;
    import formats.plain_text : PlainTextFormat;
    import domain.index.record_store : RecordsLease;
    import utils.event_bus.event_bus_async : EventBusAsync;
    import utils.event_bus.event_bus_interface : SignalConsumer;
    import core.time : msecs;
    import std.algorithm : canFind, filter;
    import std.array : array;
    import std.json : parseJSON;

    /// Dispatches the events of `session` until the script is told that the view
    /// `call` (onMainViewChanged, onSearchViewChanged) has one of `statuses`
    /// Returns: the status reached
    private string waitForStatus(AppSession session, string call, string[] statuses...)
    {
        import core.thread : Thread;

        string shown;
        foreach (attempt; 0 .. 500)
        {
            session.dispatchEvents();
            foreach (c; session.takeScriptCalls())
                if (c.name == call)
                    shown = parseJSON(c.json)["status"].str;
            if (statuses.canFind(shown))
                return shown;
            Thread.sleep(10.msecs);
        }
        assert(false, call ~ ": " ~ shown);
    }

    private final class FakeView : DocumentView
    {
        size_t itemsCount() nothrow @nogc { return 0; }
        bool fetchItem(size_t index, scope ref DocumentItem item) { return false; }
        bool positionOf(size_t realIndex, out size_t position) { return false; }
        bool nearestPositionOf(size_t realIndex, out size_t position) { return false; }
    }

    /// A document whose events the test publishes; it records the searches asked
    private final class FakeDocument : Document
    {
        EventBusAsync bus;
        FakeView view;
        LogFilter!wchar[] searches;
        LogFilter!wchar current; // the search searchFilter() tells
        bool cancelAsked;
        size_t records; // what messageCount() tells
        ulong bytes; // what byteSize() tells
        PlainTextFormat plainText; // filters need the columns of a format
        this() { bus = new EventBusAsync(); view = new FakeView(); plainText = new PlainTextFormat(); }

        SignalConsumer events() { return bus; }
        void dispatchEvents() { bus.dispatch(); }
        DocumentView mainView() { return view; }
        DocumentView searchView() { return view; }
        LogFormat shown; // what format() tells: a plain text log if null
        const(LogFormat) format() { return shown is null ? plainText : shown; }
        void applyViewFilter(LogFilter!wchar filter) {}
        void applySearchFilter(LogFilter!wchar filter) { searches ~= filter; current = filter; }
        // As LogDocument's: the search asked last, none once it is cancelled
        const(LogFilter!wchar) searchFilter() { return current; }
        // What setAnchor answers and anchorsFull tells after it
        AnchorChange anchorChange;
        bool full;
        size_t[] anchored; // the anchors it has: imported, or set when anchorChange lets them
        AnchorChange setAnchor(size_t index, bool value)
        {
            import std.algorithm : canFind, remove;

            if (anchorChange && anchored.canFind(index) != value)
                anchored = value ? anchored ~ index : anchored.remove!(a => a == index);
            return anchorChange;
        }
        bool anchorsFull() const { return full; }
        size_t[] exportAnchors() const pure { return anchored.dup; }
        void importAnchors(const(size_t[]) anchors) { anchored ~= anchors; }
        bool requestCancel(Operation operation) { cancelAsked = true; current = null; return true; }
        bool sourceLost() { return false; }
        FormatChoice choice = FormatChoice("plain-text", 0); // what formatChoice() tells
        FormatChoice formatChoice() const { return choice; }
        DescriptionsState described; // what descriptions() tells
        string[] loads; // the paths loadDescriptions was asked
        DescriptionsState descriptions() const { return described; }
        void loadDescriptions(string path) { loads ~= path; }
        size_t messageCount() nothrow @nogc { return records; }
        ulong byteSize() nothrow @nogc { return bytes; }
        RecordsLease leaseRecords() { return RecordsLease.init; }
        DocumentState state() { return DocumentState.init; }
        // The files sent in the log, and how writing one goes: refused before its bytes
        // (no such file), or failing after the first two of them (the log lost)
        Attachment[] files;
        ubyte[] fileBytes = [1, 2, 3, 4, 5];
        bool refuse, failMidway;
        Attachment[] attachments() { return files; }
        ulong writeAttachment(size_t id, scope void delegate() begin, scope void delegate(const(ubyte)[] bytes) write)
        {
            import utils.ui_text : uiText, UiTextException;

            if (refuse)
                throw new UiTextException(uiText("no such file in the log"));
            begin();
            write(fileBytes[0 .. 2]);
            if (failMidway)
                throw new UiTextException(uiText("the log is no longer available"));
            write(fileBytes[2 .. $]);
            return fileBytes.length;
        }
    }

    /// A session over fake documents: a path with "missing" in it can't be opened
    private struct Fixture
    {
        // What the delegates of the session record: a class, so copies of
        // the fixture share it
        private static final class Records
        {
            FakeDocument[string] opened; // by path
            AppSettings[] written;
            FormatChoice lastChoice; // asked of the factory
            string[] shown; // in the file manager
            bool refuseOpen; // every file opened from now on fails
        }

        AppSession session;
        DocumentStore store; // the session's documents: others may hold them too
        Records records;

        static Fixture make(AppSettings settings = AppSettings.init)
        {
            Fixture f;
            auto records = new Records();
            f.records = records;
            f.store = new DocumentStore();
            f.session = new AppSession(settings, f.store, (string path, FormatChoice choice) {
                records.lastChoice = choice;
                if (path.canFind("missing") || records.refuseOpen)
                    throw new Exception("no such file");
                if (path.canFind("refused"))
                {
                    import utils.ui_text : uiText, UiTextException;
                    throw new UiTextException(uiText("not a log of {kinds}", "kinds", "DLT or text"));
                }
                auto doc = new FakeDocument();
                records.opened[path] = doc;
                return cast(Document) doc;
            }, (in AppSettings s) { records.written ~= AppSettings(s); }, (string path) {
                if (path.canFind("missing"))
                    throw new Exception("no such file");
                records.shown ~= path;
            });
            return f;
        }

        FakeDocument docOf(string path) { return records.opened[path]; }
        AppSettings[] writes() { return records.written; }
        FormatChoice lastChoice() { return records.lastChoice; }
    }

    private string[] namesOf(const ScriptCall[] calls)
    {
        string[] names;
        foreach (c; calls)
            names ~= c.name;
        return names;
    }
}

@("AppSession: the menu of the window, of the host platform until told")
unittest
{
    import std.json : parseJSON;
    import ui.app_menu : appMenu, hostMenuPlatform, menuJson, windowMenu;

    auto f = Fixture.make();
    auto host = parseJSON(f.session.menuJson());
    assert(host["menuBar"].boolean == windowMenu(hostMenuPlatform(), "").menuBar);
    assert(host["menus"] == parseJSON(menuJson(appMenu(hostMenuPlatform()), hostMenuPlatform())));

    f.session.showMenu(WindowMenu(MenuPlatform.windows, true));
    auto windows = parseJSON(f.session.menuJson());
    assert(windows["menuBar"].boolean);
    assert(windows["menus"] == parseJSON(menuJson(appMenu(MenuPlatform.windows), MenuPlatform.windows)));
}

@("AppSession: the label of the bottom panel in the menu follows what the script tells")
unittest
{
    import std.json : parseJSON;
    import ui.app_menu : MenuCommand;

    auto f = Fixture.make();
    f.session.showMenu(WindowMenu(MenuPlatform.windows, true));
    string label()
    {
        foreach (menu; parseJSON(f.session.menuJson())["menus"].array)
            foreach (item; menu["items"].array)
                if ("command" in item && item["command"].str == MenuCommand.bottomPanel)
                    return item["label"].str;
        return null;
    }

    assert(label() == "Hide Bottom Panel", "shown until told");
    f.session.setBottomPanelShown(false);
    assert(label() == "Show Bottom Panel");
    assert(f.session.menuBar(MenuPlatform.mac)[2].items[0].label == "Show Bottom Panel", "the native menu too");
    f.session.setBottomPanelShown(true);
    assert(label() == "Hide Bottom Panel");
}

@("AppSession: a file opened gets a document; the script is told later, not during the call")
unittest
{
    auto f = Fixture.make();
    const result = f.session.openFile(testPath("/logs/a.log"));
    assert(result.docId.isValid && result.failureJson is null);
    assert(f.session.doc(result.docId) is f.docOf(testPath("/logs/a.log")));
    assert(f.session.settings.recentFiles.pathsOf == [testPath("/logs/a.log")]);

    const calls = f.session.takeScriptCalls();
    assert(calls.length >= 1 && calls[0] == ScriptCall("onDocumentOpened", cast(int) result.docId.toInt()));
    assert(f.session.takeScriptCalls().length == 0, "taken once");
}

@("AppSession: the listeners of the views hear the views of their document and the columns, until they unsubscribe")
unittest
{
    auto f = Fixture.make();
    const id = f.session.openFile(testPath("/logs/a.log")).docId;
    const other = f.session.openFile(testPath("/logs/b.log")).docId;
    bool[] heard; // search?
    int columns;
    const handle = f.session.subscribeViews(id, ViewListener((bool search, ViewVersion v) { heard ~= search; }, () { ++columns; }));
    f.session.dispatchEvents();
    f.session.takeScriptCalls();
    assert(heard.length >= 2 && heard.canFind(false) && heard.canFind(true), "both views of the document");
    const n = heard.length;
    f.session.setColumnLayouts("{}");
    assert(columns == 1);
    f.session.unsubscribeViews(handle);
    f.session.setColumnLayouts("{}");
    assert(columns == 1 && heard.length == n);
}

@("AppSession: a file that can't be opened is listed with the reason, the script is told nothing")
unittest
{
    auto f = Fixture.make();
    const result = f.session.openFile(testPath("/logs/missing.log"));
    assert(!result.docId.isValid);
    const failure = parseJSON(result.failureJson);
    assert(failure["path"].str == testPath("/logs/missing.log"));
    assert(failure["error"].str == "no such file");
    assert(f.session.settings.recentFiles.pathsOf == [testPath("/logs/missing.log")]);
    assert(!namesOf(f.session.takeScriptCalls()).canFind("onDocumentOpened"));
}

@("AppSession: a file open already shows its tab instead of a second document")
unittest
{
    auto f = Fixture.make();
    const first = f.session.openFile(testPath("/logs/a.log")).docId;
    f.session.openFile(testPath("/logs/b.log"));
    f.session.takeScriptCalls();

    assert(f.session.openFile(testPath("/logs/a.log")).docId == first);
    assert(parseJSON(f.session.workspaceInfoJson()).array.length == 2);
    assert(f.session.takeScriptCalls()[0] == ScriptCall("onDocumentOpened", cast(int) first.toInt()));
}

@("AppSession: a document whose file was truncated is opened anew in its tab, the script told")
unittest
{
    auto f = Fixture.make();
    const path = testPath("/logs/a.log");
    const id = f.session.openFile(path).docId;
    f.session.dispatchEvents();
    f.session.takeScriptCalls();
    auto old = f.docOf(path);

    old.bus.publish(ReopenWanted(ReopenWanted.Why.truncated));
    f.session.dispatchEvents();
    assert(f.docOf(path) !is old, "opened anew");
    assert(f.store.doc(id) is f.docOf(path), "in the place of the old one, with its id");
    const calls = f.session.takeScriptCalls();
    assert(calls.length > 0 && calls[0] == ScriptCall("onDocumentReopened", cast(int) id.toInt()));
}

@("AppSession: a document that can't be opened anew is shown lost, to be retried")
unittest
{
    import std.algorithm : any;
    import std.json : parseJSON;

    auto f = Fixture.make();
    const path = testPath("/logs/a.log");
    const id = f.session.openFile(path).docId;
    f.session.dispatchEvents();
    f.session.takeScriptCalls();
    auto old = f.docOf(path);

    f.records.refuseOpen = true; // removed by the rotation meanwhile
    old.bus.publish(ReopenWanted(ReopenWanted.Why.truncated));
    f.session.dispatchEvents();
    assert(f.docOf(path) is old, "not replaced");
    const calls = f.session.takeScriptCalls();
    assert(calls.any!(c => c.name == "onMainViewChanged" && parseJSON(c.json)["status"].str == "sourceLost"),
        "shown lost: not frozen on rows that are gone");
}

@("AppSession: the views of a new document reach the script after it is told of the document")
unittest
{
    auto f = Fixture.make();
    const id = f.session.openFile(testPath("/logs/a.log")).docId;
    f.session.dispatchEvents();
    const calls = f.session.takeScriptCalls();
    assert(namesOf(calls) == ["onDocumentOpened", "onMainViewChanged", "onSearchViewChanged"]);
    assert(parseJSON(calls[1].json)["status"].str == "loadingFile");
    assert(calls[1].docId == id.toInt());
}

@("AppSession: a tab closed by the user goes away at once, its file marked used")
unittest
{
    auto f = Fixture.make();
    const id = f.session.openFile(testPath("/logs/a.log")).docId;
    f.session.openFile(testPath("/logs/b.log"));
    assert(pathsOf(f.session.settings.recentFiles) == [testPath("/logs/b.log"), testPath("/logs/a.log")]);

    f.session.closeTab(cast(int) id.toInt());
    assert(!f.session.findDocument(cast(int) id.toInt()).isValid);
    assert(pathsOf(f.session.settings.recentFiles) == [testPath("/logs/a.log"), testPath("/logs/b.log")], "used now: on top");
    assert(f.session.takeScriptCalls().length, "the views of b are still told");
}

@("AppSession: a tab closed keeps its document open while another holder holds it")
unittest
{
    auto f = Fixture.make();
    const id = f.session.openFile(testPath("/logs/a.log")).docId;
    const agent = f.store.hold(id); // an AI session, say
    assert(agent.isValid);

    f.session.closeTab(cast(int) id.toInt());
    assert(!f.session.findDocument(cast(int) id.toInt()).isValid, "no tab");
    assert(parseJSON(f.session.workspaceInfoJson()).array.length == 0);
    assert(f.store.doc(id) is f.docOf(testPath("/logs/a.log")), "still open for its holder");

    f.store.release(agent);
    assert(!f.store.isOpen(id), "closed by its last holder");
}

@("AppSession: the tab of a document going is told to everyone who subscribed, by closing it and by closing all")
unittest
{
    auto f = Fixture.make();
    DocumentId[] gone, alsoGone;
    f.session.subscribeDocumentClosed((DocumentId docId) { gone ~= docId; });
    f.session.subscribeDocumentClosed((DocumentId docId) { alsoGone ~= docId; });
    const a = f.session.openFile(testPath("/logs/a.log")).docId;
    const b = f.session.openFile(testPath("/logs/b.log")).docId;
    f.session.closeTab(cast(int) a.toInt());
    assert(gone == [a] && alsoGone == [a]);
    f.session.closeAll();
    assert(gone == [a, b] && alsoGone == [a, b]);
}

@("AppSession: another holder releasing its hold twice leaves the tab its document")
unittest
{
    auto f = Fixture.make();
    const id = f.session.openFile(testPath("/logs/a.log")).docId;
    const agent = f.store.hold(id);
    f.store.release(agent);
    f.store.release(agent);
    assert(f.store.isOpen(id), "the hold of the tab stays");

    f.session.closeTab(cast(int) id.toInt());
    assert(!f.store.isOpen(id), "closed with its tab");
}

@("AppSession: the settings are written from the idle loop, once for the changes before it")
unittest
{
    auto f = Fixture.make();
    assert(!f.session.settingsDue, "nothing changed");

    f.session.openFile(testPath("/logs/a.log"));
    f.session.openFile(testPath("/logs/b.log"));
    assert(f.writes.length == 0, "not written during the calls");
    assert(f.session.settingsDue);
    f.session.saveSettings(`{"theme": "dark"}`);
    assert(f.writes.length == 1, "both changes in one write");
    assert(f.writes[0].theme == "dark", "the state of the script is merged in");
    assert(pathsOf(f.writes[0].recentFiles) == [testPath("/logs/b.log"), testPath("/logs/a.log")]);
    assert(!f.session.settingsDue, "written: nothing changed since");
}

@("AppSession: on close the settings are written at once, the open files on top")
unittest
{
    auto f = Fixture.make();
    f.session.openFile(testPath("/logs/a.log"));
    const closed = f.session.openFile(testPath("/logs/c.log")).docId;
    f.session.closeTab(cast(int) closed.toInt());
    assert(pathsOf(f.session.settings.recentFiles) == [testPath("/logs/c.log"), testPath("/logs/a.log")]);

    f.session.saveOnClose(`{"tableFontSize": 120}`);
    assert(f.writes.length == 1 && f.writes[0].tableFontSize == 120);
    assert(pathsOf(f.writes[0].recentFiles) == [testPath("/logs/a.log"), testPath("/logs/c.log")],
        "the open files were used until now");
}

@("AppSession: once the window closes the script is no longer asked; the rest is written on exit")
unittest
{
    auto f = Fixture.make();
    const id = f.session.openFile(testPath("/logs/a.log")).docId;
    f.session.saveOnClose(`{}`);
    assert(f.session.closing);

    f.session.closeTab(cast(int) id.toInt());
    f.session.dispatchEvents();
    assert(!f.session.settingsDue, "no getAppState() of a closing window");

    f.session.finish();
    assert(f.writes.length == 2, "written without the state of the script");
    assert(f.session.findDocument(cast(int) id.toInt()) == DocumentId.init);
}


@("AppSession: a window moved or resized makes the settings due, not once the window closes")
unittest
{
    auto f = Fixture.make();
    assert(!f.session.settingsDue);
    f.session.windowFrameChanged();
    assert(f.session.settingsDue, "written by the idle loop with the frame of getAppState()");
    f.session.saveSettings(`{"windowRect": {"left": 10, "top": 20, "width": 300, "height": 400}}`);
    assert(f.writes[$ - 1].windowRect == WindowRect(10, 20, 300, 400));

    f.session.saveOnClose(`{}`);
    f.session.windowFrameChanged();
    assert(!f.session.settingsDue, "no getAppState() of a closing window");
}

@("AppSession: the application terminates (macOS Quit): written with the state of the script, documents closed")
unittest
{
    auto f = Fixture.make();
    const id = f.session.openFile(testPath("/logs/a.log")).docId;
    f.session.terminate(`{"tableFontSize": 120}`);
    assert(f.writes.length == 1 && f.writes[0].tableFontSize == 120);
    assert(pathsOf(f.writes[0].recentFiles) == [testPath("/logs/a.log")]);
    assert(f.session.closing);
    assert(f.session.findDocument(cast(int) id.toInt()) == DocumentId.init, "documents closed");
}

@("AppSession: the application terminates: documents held by others are closed too")
unittest
{
    auto f = Fixture.make();
    const id = f.session.openFile(testPath("/logs/a.log")).docId;
    f.store.hold(id); // an AI session, say: main() never closes the store on this path
    f.session.terminate(`{}`);
    assert(!f.store.isOpen(id), "no document is left with its threads running");
}

@("AppSession: terminating after the window closed keeps what the window wrote")
unittest
{
    auto f = Fixture.make();
    f.session.saveOnClose(`{"tableFontSize": 130}`);
    f.session.terminate(`{"tableFontSize": 90}`); // the window is gone: no state of the script
    assert(f.writes.length == 1, "nothing changed since the window wrote");
    assert(f.session.settings.tableFontSize == 130);
}


@("AppSession: the info of a document: its file, its size, its format and how many records it has")
unittest
{
    auto f = Fixture.make();
    const id = f.session.openFile(testPath("/logs/a.log")).docId;
    f.docOf(testPath("/logs/a.log")).records = 1234;
    f.docOf(testPath("/logs/a.log")).bytes = 5_000_000_000;
    const info = parseJSON(f.session.documentInfoJson(id));
    assert(info["name"].str == "a.log");
    assert(info["path"].str == testPath("/logs/a.log"));
    assert(info["format"].str == "Plain text", info["format"].str);
    assert(info["records"].integer == 1234);
    assert(info["bytes"].integer == 5_000_000_000);
}

@("AppSession.loadDescriptions: a FIBEX asked of a DLT log, dropped by unloadDescriptions; refused for a text log")
unittest
{
    import formats.dlt.format : DltFormat;

    auto f = Fixture.make();
    const dlt = f.session.openFile(testPath("/logs/a.dlt")).docId;
    f.docOf(testPath("/logs/a.dlt")).shown = new DltFormat();
    assert(f.session.loadDescriptions(dlt, testPath("/fibex/ecu.xml")) == "");
    assert(f.session.unloadDescriptions(dlt) == "");
    assert(f.docOf(testPath("/logs/a.dlt")).loads == [testPath("/fibex/ecu.xml"), ""]);

    const text = f.session.openFile(testPath("/logs/b.log")).docId;
    assert(f.session.loadDescriptions(text, testPath("/fibex/ecu.xml")).length, "a text log takes none");
    assert(f.session.unloadDescriptions(text).length);
    assert(f.docOf(testPath("/logs/b.log")).loads.length == 0);
    assert(f.session.loadDescriptions(DocumentId.init, testPath("/fibex/ecu.xml")).length, "not open");
}

@("AppSession: the info of a document tells the descriptions of a DLT log, none for a text log")
unittest
{
    import formats.dlt.format : DltFormat;
    import utils.ui_text : uiText;

    auto f = Fixture.make();
    const text = f.session.openFile(testPath("/logs/b.log")).docId;
    assert(parseJSON(f.session.documentInfoJson(text))["descriptions"].isNull, "no FIBEX row");

    const id = f.session.openFile(testPath("/logs/a.dlt")).docId;
    auto doc = f.docOf(testPath("/logs/a.dlt"));
    doc.shown = new DltFormat();
    auto none = parseJSON(f.session.documentInfoJson(id))["descriptions"];
    assert(none["taken"].str == "" && none["choice"].str == "" && none["read"].str == "");
    assert(!none["folder"].boolean && !none["reading"].boolean && none["problem"].str == "");

    doc.choice = FormatChoice("dlt", 0);
    doc.choice.descriptions = testPath("/fibex");
    doc.described = DescriptionsState(testPath("/fibex"), true, testPath("/fibex/new.xml"), false,
        uiText("no such file"));
    auto d = parseJSON(f.session.documentInfoJson(id))["descriptions"];
    assert(d["taken"].str == testPath("/fibex") && d["folder"].boolean && d["choice"].str == testPath("/fibex"));
    assert(d["read"].str == testPath("/fibex/new.xml") && !d["reading"].boolean);
    assert(d["problem"].str == "no such file", "the reason for the user");
}

@("AppSession: a format choice replaced is written to the recent list in place, the File Info told")
unittest
{
    auto f = Fixture.make();
    const id = f.session.openFile(testPath("/logs/a.dlt")).docId;
    f.session.openFile(testPath("/logs/b.log"));
    f.session.saveSettings("{}");
    f.session.takeScriptCalls();
    auto doc = f.docOf(testPath("/logs/a.dlt"));
    doc.choice = FormatChoice("dlt", 0);
    doc.choice.descriptions = testPath("/fibex/ecu.xml");
    doc.bus.publish(FormatReplaced(true));
    f.session.dispatchEvents();

    assert(savedFormat(f.session.settings.recentFiles, testPath("/logs/a.dlt")) == doc.choice);
    assert(pathsOf(f.session.settings.recentFiles) == [testPath("/logs/b.log"), testPath("/logs/a.dlt")],
        "in place, not moved on top");
    assert(f.session.settingsDue, "written by the next idle round");
    const calls = f.session.takeScriptCalls();
    assert(calls.canFind(ScriptCall("onFileInfoChanged", cast(int) id.toInt())));

    f.session.saveSettings("{}");
    doc.bus.publish(FormatReplaced(true)); // the same FIBEX read anew
    f.session.dispatchEvents();
    assert(!f.session.settingsDue, "the same choice: nothing to write");
    assert(f.session.takeScriptCalls().canFind(ScriptCall("onFileInfoChanged", cast(int) id.toInt())));
}

@("AppSession: the script is told when the descriptions of a document change, once a change")
unittest
{
    auto f = Fixture.make();
    const id = f.session.openFile(testPath("/logs/a.dlt")).docId;
    f.session.saveSettings("{}");
    f.session.takeScriptCalls();
    f.docOf(testPath("/logs/a.dlt")).bus.publish(DescriptionsChanged());
    f.docOf(testPath("/logs/a.dlt")).bus.publish(DescriptionsChanged());
    f.session.dispatchEvents();
    assert(f.session.takeScriptCalls().canFind(ScriptCall("onFileInfoChanged", cast(int) id.toInt())));
    assert(!namesOf(f.session.takeScriptCalls()).canFind("onFileInfoChanged"), "told once");
    assert(!f.session.settingsDue, "the choice didn't change");
}

@("AppSession: the files sent in the log of a document, as the script lists them")
unittest
{
    auto f = Fixture.make();
    const id = f.session.openFile(testPath("/logs/a.dlt")).docId;
    Attachment a;
    a.id = 0;
    a.name = "trigger.tar.lz4";
    a.date = "Mon Nov  3 10:19:51 2025\n";
    a.size = 119_480_325;
    a.packets = 116_681;
    a.received = 32_590;
    a.inTurn = 32_590;
    a.state = AttachmentState.incomplete;
    a.record = 1234;
    a.hasSerial = true;
    a.serial = 3_033_975_044;
    Attachment b;
    b.id = 1;
    b.state = AttachmentState.failed;
    b.error = -400;
    b.osError = -2;
    f.docOf(testPath("/logs/a.dlt")).files = [a, b];

    const list = parseJSON(f.session.attachmentsJson(id)).array;
    assert(list.length == 2);
    assert(list[0]["id"].integer == 0 && list[0]["name"].str == "trigger.tar.lz4");
    assert(list[0]["date"].str == "Mon Nov  3 10:19:51 2025\n");
    assert(list[0]["size"].integer == 119_480_325 && list[0]["packets"].integer == 116_681);
    assert(list[0]["received"].integer == 32_590 && list[0]["inTurn"].integer == 32_590);
    assert(list[0]["state"].str == "incomplete" && list[0]["record"].integer == 1234);
    assert(list[0]["serial"].integer == 3_033_975_044);
    assert(list[1]["state"].str == "failed" && list[1]["serial"].isNull);
    assert(list[1]["error"].integer == -400 && list[1]["osError"].integer == -2);
    assert(f.session.attachmentsJson(DocumentId.init) == "[]", "a document that isn't open");
}

@("AppSession: the script is told when the files sent in a log change, once a change")
unittest
{
    auto f = Fixture.make();
    const id = f.session.openFile(testPath("/logs/a.dlt")).docId;
    f.session.takeScriptCalls();
    assert(!namesOf(f.session.takeScriptCalls()).canFind("onAttachmentsChanged"), "none yet");

    f.docOf(testPath("/logs/a.dlt")).bus.publish(AttachmentsChanged());
    f.docOf(testPath("/logs/a.dlt")).bus.publish(AttachmentsChanged());
    f.session.dispatchEvents();
    const calls = f.session.takeScriptCalls();
    assert(calls.canFind(ScriptCall("onAttachmentsChanged", cast(int) id.toInt())));
    assert(!namesOf(f.session.takeScriptCalls()).canFind("onAttachmentsChanged"), "told once");
}

@("AppSession: an attachment is saved where the script says, whole or not at all")
unittest
{
    import std.file : exists, mkdirRecurse, read, rmdirRecurse, tempDir, write;
    import std.path : buildPath;

    const dir = buildPath(tempDir(), "dlt_session_attachments");
    mkdirRecurse(dir);
    scope (exit)
        rmdirRecurse(dir);
    const path = buildPath(dir, "a.bin");

    auto f = Fixture.make();
    const id = f.session.openFile(testPath("/logs/a.dlt")).docId;
    auto doc = f.docOf(testPath("/logs/a.dlt"));
    assert(f.session.saveAttachment(id, 0, path) == "");
    assert(cast(const(ubyte)[]) read(path) == [1, 2, 3, 4, 5]);
    assert(!exists(path ~ ".part"), "written beside, then put in its place");

    write(path, "old");
    doc.failMidway = true;
    assert(f.session.saveAttachment(id, 0, path) == "Can't save the file: the log is no longer available");
    assert(cast(const(char)[]) read(path) == "old", "a file saved over stays as it was");
    assert(!exists(path ~ ".part"), "the bytes written are not left behind");

    const fresh = buildPath(dir, "b.bin");
    doc.refuse = true;
    assert(f.session.saveAttachment(id, 0, fresh) == "Can't save the file: no such file in the log");
    assert(!exists(fresh) && !exists(fresh ~ ".part"), "no file for an attachment refused");

    doc.refuse = false;
    doc.failMidway = false;
    import std.algorithm : startsWith;

    const error = f.session.saveAttachment(id, 0, buildPath(dir, "no", "such", "c.bin"));
    assert(error.startsWith("Can't save the file: "), error);
    assert(f.session.saveAttachment(DocumentId.init, 0, path) == "the document is not open");
}

@("AppSession: a document that isn't open has no info")
unittest
{
    auto f = Fixture.make();
    assert(f.session.documentInfoJson(DocumentId.init) == "null");
}

@("AppSession: a search is started in the document and kept in the history of its file")
unittest
{
    auto f = Fixture.make();
    const id = f.session.openFile(testPath("/logs/a.log")).docId;
    const chips = `[{"text": "error", "isRegex": false, "matchCase": false}]`;
    assert(f.session.startChipSearch(id, chips) == "");
    assert(f.docOf(testPath("/logs/a.log")).searches.length == 1);
    assert(parseJSON(f.session.searchHistoryJson(id)).array.length == 1);

    assert(f.session.startChipSearch(id, `[{"text": "(", "isRegex": true, "matchCase": true}]`).length,
        "an invalid regex is an error");
    assert(f.docOf(testPath("/logs/a.log")).searches.length == 1, "and searches nothing");
}

@("AppSession: a query is removed from the history of the file; one not in it, bad chips or no document remove nothing")
unittest
{
    auto f = Fixture.make();
    const id = f.session.openFile(testPath("/logs/a.log")).docId;
    const error = `[{"text": "error", "isRegex": false, "matchCase": false}]`;
    const warn = `[{"text": "warn", "isRegex": true, "matchCase": true}]`;
    f.session.startChipSearch(id, error);
    f.session.startChipSearch(id, warn);
    f.session.saveSettings(`{}`);

    assert(!f.session.removeSearch(id, `[{"text": "warn", "isRegex": true, "matchCase": false}]`),
        "another case is another query");
    assert(!f.session.removeSearch(id, `{"text": "warn"}`), "not chips");
    assert(!f.session.removeSearch(DocumentId.init, warn), "no document");
    assert(parseJSON(f.session.searchHistoryJson(id)).array.length == 2);
    assert(!f.session.settingsDue, "nothing changed");

    assert(f.session.removeSearch(id, warn));
    assert(parseJSON(f.session.searchHistoryJson(id)) == parseJSON("[" ~ error ~ "]"));
    assert(f.session.settingsDue, "the change is saved");
    assert(!f.session.removeSearch(id, warn), "it is gone");
}

@("AppSession: a file removed from the recent list loses its filters, the change is saved")
unittest
{
    auto f = Fixture.make();
    const id = f.session.openFile(testPath("/logs/a.log")).docId;
    f.session.filterCommand(id, (DocumentFilters filters) => filters.newSet());
    f.session.openFile(testPath("/logs/b.log"));
    f.session.closeTab(cast(int) id.toInt());
    f.session.saveSettings(`{}`);

    assert(f.session.removeRecentFile(testPath("/logs/a.log")));
    assert(pathsOf(f.session.settings.recentFiles) == [testPath("/logs/b.log")]);
    assert(f.session.settingsDue);
    f.session.saveSettings(`{}`);
    assert(pathsOf(f.writes[$ - 1].recentFiles) == [testPath("/logs/b.log")]);

    f.session.openFile(testPath("/logs/a.log"));
    assert(savedFilters(f.session.settings.recentFiles, testPath("/logs/a.log")).length == 0, "opened anew, without its filters");
}

@("AppSession: a file is shown in the file manager, or the reason it can't be")
unittest
{
    auto f = Fixture.make();
    assert(f.session.showInFolder(testPath("/logs/a.log")) == "");
    assert(f.records.shown == [testPath("/logs/a.log")]);
    assert(f.session.showInFolder(testPath("/logs/missing.log")) == "no such file");
}

@("AppSession: an open file is not removed from the recent list")
unittest
{
    auto f = Fixture.make();
    f.session.openFile(testPath("/logs/a.log"));
    f.session.saveSettings(`{}`);
    assert(!f.session.removeRecentFile(testPath("/logs/a.log")));
    assert(pathsOf(f.session.settings.recentFiles) == [testPath("/logs/a.log")]);
    assert(!f.session.settingsDue, "nothing changed");
}

@("AppSession: a filter command that succeeds is kept in the settings of the file")
unittest
{
    auto f = Fixture.make();
    const id = f.session.openFile(testPath("/logs/a.log")).docId;
    assert(f.session.filterCommand(id, (DocumentFilters filters) => filters.newSet()) == "");
    assert(savedFilters(f.session.settings.recentFiles, testPath("/logs/a.log")).length == 1);
}

@("AppSession: a filter command that changes the sets is told to the listeners of the document's views, one that changes nothing is not")
unittest
{
    auto f = Fixture.make();
    const id = f.session.openFile(testPath("/logs/a.log")).docId;
    const other = f.session.openFile(testPath("/logs/b.log")).docId;
    int rules, otherRules;
    ViewListener listener, otherListener;
    listener.rulesChanged = () { ++rules; };
    otherListener.rulesChanged = () { ++otherRules; };
    f.session.subscribeViews(id, listener);
    f.session.subscribeViews(other, otherListener);
    f.session.filterCommand(id, (DocumentFilters filters) => filters.newSet());
    assert(rules == 1 && otherRules == 0, "the rows of the document may match another rule");
    f.session.filterCommand(id, (DocumentFilters filters) => filters.remove(7));
    assert(rules == 1, "a refused command changed nothing");
}

@("AppSession: a filter command that changes the sets is kept even when it has a note (what was lost)")
unittest
{
    auto f = Fixture.make();
    const id = f.session.openFile(testPath("/logs/a.log")).docId;
    assert(f.session.filterCommand(id, (DocumentFilters filters) { import utils.ui_text : plainText; filters.newSet(); return plainText("a.dlf: a note"); })
        == "a.dlf: a note");
    assert(savedFilters(f.session.settings.recentFiles, testPath("/logs/a.log")).length == 1);
}

@("AppSession: a filter command that fails changes nothing in the settings")
unittest
{
    auto f = Fixture.make();
    const id = f.session.openFile(testPath("/logs/a.log")).docId;
    assert(f.session.filterCommand(id, (DocumentFilters filters) => filters.remove(7)).length);
    assert(savedFilters(f.session.settings.recentFiles, testPath("/logs/a.log")).length == 0);
}

@("AppSession: a file opened again gets the filters it had")
unittest
{
    auto f = Fixture.make();
    auto id = f.session.openFile(testPath("/logs/a.log")).docId;
    f.session.filterCommand(id, (DocumentFilters filters) => filters.newSet());
    f.session.closeTab(cast(int) id.toInt());

    id = f.session.openFile(testPath("/logs/a.log")).docId;
    assert(f.session.filters(id).saved().length == 1);
}

@("AppSession: a real file opens in a LogDocument and its main view gets ready")
unittest
{
    import core.thread : Thread;
    import std.file : remove, tempDir, write;
    import std.path : buildPath;

    const path = buildPath(tempDir(), "log_tracy_session_test.log");
    write(path, "first line\nsecond line\n");
    scope (exit) remove(path);

    import domain.log_document : LogDocument;

    AppSettings[] written;
    auto session = new AppSession(AppSettings.init, new DocumentStore(),
        (string path, FormatChoice choice) => cast(Document) new LogDocument(path, choice),
        (in AppSettings s) { written ~= AppSettings(s); });
    scope (exit) session.closeAll();
    const id = session.openFile(path).docId;
    assert(id.isValid);

    waitForStatus(session, "onMainViewChanged", "ready");
    assert(session.doc(id).mainView.itemsCount == 2);
    assert(session.settings.recentFiles[0].format.id.length, "the format detected is remembered");
    const info = parseJSON(session.documentInfoJson(id));
    assert(info["records"].integer == 2 && info["bytes"].integer == "first line\nsecond line\n".length);
}

@("AppSession: what the chips found is shown in the rows the search found, in both views")
unittest
{
    import std.array : replicate;
    import std.file : remove, tempDir, write;
    import std.path : buildPath;
    import domain.log_document : LogDocument;

    const path = buildPath(tempDir(), "log_tracy_session_matches.log");
    // Many lines after the three, so that a search can be cancelled before it ends
    write(path, "a timeout here\nnothing\nanother timeout\n" ~ "filler\n".replicate(500_000));
    scope (exit) remove(path);

    auto session = new AppSession(AppSettings.init, new DocumentStore(),
        (string path, FormatChoice choice) => cast(Document) new LogDocument(path, choice),
        (in AppSettings s) {});
    scope (exit) session.closeAll();
    const id = session.openFile(path).docId;

    waitForStatus(session, "onMainViewChanged", "ready");
    assert(session.doc(id).setAnchor(1, true), "listed in the results by its anchor only");
    enum timeout = `[{"text": "timeout", "isRegex": false, "matchCase": false}]`;
    assert(session.startChipSearch(id, timeout) == "");
    waitForStatus(session, "onSearchViewChanged", "ready");

    DocumentItem item;
    MatchBuffer buffer;
    auto main = session.doc(id).mainView;
    assert(main.fetchItem(0, item) && session.matchesOf(id, item, buffer[]) == [MatchRange(2, 9, 0)]);
    assert(main.fetchItem(1, item) && session.matchesOf(id, item, buffer[]).length == 0, "not found");
    assert(main.fetchItem(2, item) && session.matchesOf(id, item, buffer[]) == [MatchRange(8, 15, 0)]);

    // The rows of a message in both views, as a double click asks for them
    size_t position;
    assert(session.viewPosition(id, false, 2, position) && position == 2);
    assert(session.viewPosition(id, true, 2, position) && position == 2, "the third result");
    assert(session.viewPosition(id, true, 1, position) && position == 1, "listed by its anchor");
    assert(!session.viewPosition(id, true, 3, position), "not found by the search");
    assert(!session.viewPosition(id, false, -1, position), "no message index");
    assert(!session.viewPosition(id, false, 1e12, position), "past the end of the log");
    assert(session.nearestMainViewPosition(id, 1e12, position) && position == session.doc(id).mainView.itemsCount - 1,
        "past the end of the log: its last row");
    assert(session.nearestMainViewPosition(id, 2, position) && position == 2);
    assert(!session.nearestMainViewPosition(id, -1, position), "no message index");

    auto results = session.doc(id).searchView;
    assert(results.itemsCount == 3);
    assert(results.fetchItem(1, item) && item.realIndex == 1 && session.matchesOf(id, item, buffer[]).length == 0);
    assert(results.fetchItem(2, item) && session.matchesOf(id, item, buffer[]) == [MatchRange(8, 15, 0)]);

    // A cancelled search found nothing: no row shows its chips. Cancelled at
    // once (the machine hears of the search later); a search that ends first
    // is run again
    string reached;
    foreach (attempt; 0 .. 10)
    {
        assert(session.startChipSearch(id, timeout) == "");
        assert(session.doc(id).requestCancel(Document.Operation.BuildSearchIndex));
        reached = waitForStatus(session, "onSearchViewChanged", "searchCancelled", "ready");
        if (reached == "searchCancelled")
            break;
    }
    assert(reached == "searchCancelled", "the search always ended before the cancel");
    assert(main.fetchItem(0, item) && !item.found);
    assert(session.matchesOf(id, item, buffer[]).length == 0, "the cancelled search shows nothing");
}

@("AppSession: the recent list remembers the format the document was opened with")
unittest
{
    // The format saved last time is only asked for: the document opened in
    // another one (the saved one can't be made any more, say)
    AppSettings settings;
    settings.recentFiles = [RecentFile(testPath("/logs/a.log"), FormatChoice("logcat", 1), 1)];
    auto f = Fixture.make(settings);
    f.session.openFile(testPath("/logs/a.log"));
    assert(f.lastChoice == FormatChoice("logcat", 1), "the saved format is asked for");
    assert(f.session.settings.recentFiles[0].format == FormatChoice("plain-text", 0),
        "the format of the document is remembered");
}

@("AppSession: the state of the script written last is kept for the writes after it")
unittest
{
    auto f = Fixture.make();
    const id = f.session.openFile(testPath("/logs/a.log")).docId;
    f.session.saveOnClose(`{"theme": "dark", "tableFontSize": 130}`);

    f.session.closeTab(cast(int) id.toInt()); // after the window closed: a write without the script
    f.session.dispatchEvents();
    f.session.finish();
    assert(f.writes.length == 2);
    assert(f.writes[1].theme == "dark" && f.writes[1].tableFontSize == 130,
        "not the preferences the session started with");
}

@("AppSession: the languages of its translations; a language used translates the menu")
unittest
{
    import std.json : parseJSON;
    import ui.app_menu : MenuPlatform;
    import ui.translations : CatalogFile;

    auto f = Fixture.make();
    assert(parseJSON(f.session.languagesJson()).array.length == 0, "none until told where they are");
    assert(f.session.useLanguage("ru") is null);

    const text = `{"locale": "ru", "name": "Русский", "messages": {"&File": "&Файл"}}`;
    f.session.useTranslations([CatalogFile("ru.json", text)]);
    const languages = parseJSON(f.session.languagesJson());
    assert(languages.array.length == 1 && languages[0]["locale"].str == "ru");

    assert(f.session.menuBar(MenuPlatform.windows)[0].label == "File");
    assert(f.session.useLanguage("ru-RU") == text, "the catalog for the script");
    assert(f.session.menuBar(MenuPlatform.windows)[0].label == "Файл");
    f.session.showMenu(windowMenu(MenuPlatform.windows, ""));
    assert(parseJSON(f.session.menuJson())["menus"][0]["label"].str == "Файл");

    assert(f.session.useLanguage("x-pseudo") is null, "the script makes the pseudo catalog itself");
    assert(f.session.menuBar(MenuPlatform.windows)[0].label == "File", "the menu stays english");

    assert(f.session.useLanguage("de") is null);
    assert(f.session.menuBar(MenuPlatform.windows)[0].label == "File", "no catalog: english");
}

@("AppSession: the errors for the user are in the language used: of opening, of a retry, of the views")
unittest
{
    import std.json : parseJSON;
    import ui.translations : CatalogFile;

    auto f = Fixture.make();
    f.session.useTranslations([CatalogFile("ru.json", `{"locale": "ru", "name": "Русский", "messages": {
        "not a log of {kinds}": "не журнал формата {kinds}", "the document is not open": "документ не открыт"}}`)]);

    assert(parseJSON(f.session.openFile(testPath("/refused.log")).failureJson)["error"].str == "not a log of DLT or text");
    f.session.useLanguage("ru");
    assert(parseJSON(f.session.openFile(testPath("/refused.log")).failureJson)["error"].str == "не журнал формата DLT or text");
    assert(parseJSON(f.session.openFile(testPath("/missing.log")).failureJson)["error"].str == "no such file",
        "a message of the OS as it is");
    assert(f.session.retryDocument(12345) == "документ не открыт");
}


@("AppSession: setAnchor tells why an anchor was refused, the limit, and whether there is room for more")
unittest
{
    import domain.anchors : Anchors;
    import std.json : parseJSON;

    auto f = Fixture.make();
    const id = f.session.openFile(testPath("/logs/a.log")).docId;
    auto doc = f.docOf(testPath("/logs/a.log"));

    auto answer = parseJSON(f.session.setAnchor(id, 3, true));
    assert(answer["refused"].isNull && !answer["full"].boolean);
    assert(answer["max"].integer == Anchors.MaxAnchors, "the limit comes from the constant");

    doc.full = true;
    answer = parseJSON(f.session.setAnchor(id, 3, true));
    assert(answer["refused"].isNull && answer["full"].boolean, "the last anchor that fits");

    doc.anchorChange = AnchorChange(AnchorRefusal.limit);
    answer = parseJSON(f.session.setAnchor(id, 4, true));
    assert(answer["refused"].str == "limit" && answer["full"].boolean);

    doc.anchorChange = AnchorChange(AnchorRefusal.unavailable);
    answer = parseJSON(f.session.setAnchor(id, 4, true));
    assert(answer["refused"].str == "unavailable" && answer["full"].boolean,
        "the reason of the document, though the anchors are full");

    doc.anchorChange = AnchorChange.init;
    assert(parseJSON(f.session.setAnchor(id, -1, true))["refused"].str == "unavailable", "no such message");
}

@("AppSession: setAnchor tells the rows the anchor changed, or that the views take it later")
unittest
{
    auto f = Fixture.make();
    const id = f.session.openFile(testPath("/logs/a.log")).docId;
    auto doc = f.docOf(testPath("/logs/a.log"));

    AnchorChange applied;
    applied.rows = AnchorRows(4, true, true, false);
    doc.anchorChange = applied;
    auto answer = parseJSON(f.session.setAnchor(id, 4, true));
    assert(!answer["pending"].boolean);
    assert(answer["rows"] == parseJSON(`{"message": 4, "anchored": true, "main": true, "search": false}`));

    AnchorChange pending;
    pending.pending = true;
    doc.anchorChange = pending;
    answer = parseJSON(f.session.setAnchor(id, 4, true));
    assert(answer["pending"].boolean && answer["rows"].isNull);

    doc.anchorChange = AnchorChange.init; // as asked already, or no view moved
    answer = parseJSON(f.session.setAnchor(id, 4, true));
    assert(!answer["pending"].boolean && answer["rows"].isNull, "no row came or went");
}

@("AppSession: the script is told the rows of an anchor the views took later")
unittest
{
    auto f = Fixture.make();
    const id = f.session.openFile(testPath("/logs/a.log")).docId;
    f.session.takeScriptCalls();

    f.docOf(testPath("/logs/a.log")).bus.publish(AnchorApplied(AnchorRows(7, false, false, true)));
    f.session.dispatchEvents();
    const calls = f.session.takeScriptCalls().filter!(c => c.name == "onAnchorApplied").array;
    assert(calls.length == 1 && calls[0].docId == id.toInt());
    assert(parseJSON(calls[0].json) == parseJSON(`{"message": 7, "anchored": false, "main": false, "search": true}`));
}

@("AppSession: an anchor applied is told before the views that changed in the same round")
unittest
{
    import std.algorithm : countUntil;

    auto f = Fixture.make();
    f.session.openFile(testPath("/logs/a.log"));
    f.session.takeScriptCalls();

    auto bus = f.docOf(testPath("/logs/a.log")).bus;
    bus.publish(OperationProgress(Document.Operation.BuildOffsetIndex, 0.5f)); // the view grew
    bus.publish(AnchorApplied(AnchorRows(7, true, true, false)));
    f.session.dispatchEvents();
    const names = namesOf(f.session.takeScriptCalls());
    const anchor = names.countUntil("onAnchorApplied"), view = names.countUntil("onMainViewChanged");
    assert(anchor >= 0 && view >= 0 && anchor < view, "the row of the anchor would be counted as grown");
}

@("AppSession: the pseudo locale is offered only when asked for (PSEUDO_LOCALE)")
unittest
{
    import std.json : parseJSON;

    auto f = Fixture.make();
    assert(parseJSON(f.session.languagesJson()).array.length == 0);
    f.session.offerPseudoLocale(true);
    const languages = parseJSON(f.session.languagesJson());
    assert(languages.array.length == 1 && languages[0]["locale"].str == "x-pseudo");
    assert(languages[0]["name"].str == "Pseudo (for testing)");
}

@("AppSession: the files to open at start (OPEN_AT_START), one per line")
unittest
{
    import std.json : parseJSON;

    auto f = Fixture.make();
    assert(parseJSON(f.session.startFilesJson()).array.length == 0, "none unless told");
    f.session.openAtStart("/logs/trace 10:06:05.dlt\n\r\nC:\\logs\\b.dlt\r\n");
    const files = parseJSON(f.session.startFilesJson());
    assert(files.array.length == 2, "empty lines dropped");
    assert(files[0].str == "/logs/trace 10:06:05.dlt", "a ':' of a name is not a separator");
    assert(files[1].str == "C:\\logs\\b.dlt", "nor of a drive, the line end taken off");
}

@("AppSession: the message of a filter command is in the language of the interface")
unittest
{
    import ui.translations : CatalogFile;

    auto f = Fixture.make();
    f.session.useTranslations([CatalogFile("ru.json",
        `{"locale": "ru", "name": "Русский", "messages": {"no such filter": "такого фильтра нет"}}`)]);
    const id = f.session.openFile(testPath("/logs/a.log")).docId;

    assert(f.session.filterCommand(id, (DocumentFilters filters) => filters.remove(7)) == "no such filter");
    f.session.useLanguage("ru");
    assert(f.session.filterCommand(id, (DocumentFilters filters) => filters.remove(7)) == "такого фильтра нет");
}

@("AppSession: checkRegex tells what is wrong with a regular expression, nothing for a valid one")
unittest
{
    auto f = Fixture.make();
    // The patterns themselves are the cases of log_core.search_filter.checkRegex. The case of
    // the chip doesn't change whether a pattern is valid, so it can't be told apart here
    assert(f.session.checkRegex(`time(out|d)\s+\d`, false) == "");
    assert(f.session.checkRegex("(unclosed", true).length > 0);
}

@("AppSession: the anchors of a file are kept in its settings, and it gets them when opened again")
unittest
{
    auto f = Fixture.make();
    const path = testPath("/logs/a.log");
    auto id = f.session.openFile(path).docId;
    f.session.setAnchor(id, 9, true);
    f.session.setAnchor(id, 4, true);
    assert(savedAnchors(f.session.settings.recentFiles, path) == [4, 9]);
    assert(f.session.settingsDue);

    f.docOf(path).anchorChange = AnchorChange(AnchorRefusal.limit);
    f.session.saveSettings(`{}`);
    f.session.setAnchor(id, 5, true);
    assert(savedAnchors(f.session.settings.recentFiles, path) == [4, 9], "a refused one isn't");
    assert(!f.session.settingsDue, "nothing changed");

    f.docOf(path).anchorChange = AnchorChange.init;
    f.session.setAnchor(id, 9, false);
    assert(savedAnchors(f.session.settings.recentFiles, path) == [4], "a cleared one is dropped");

    f.session.closeTab(cast(int) id.toInt());
    id = f.session.openFile(path).docId;
    assert(f.docOf(path).anchored == [4], "opened again, with its anchors");
}

@("AppSession: a document opened anew keeps its anchors, unless its file was truncated")
unittest
{
    auto f = Fixture.make();
    const path = testPath("/logs/a.log");
    const id = f.session.openFile(path).docId;
    f.session.setAnchor(id, 4, true);
    f.session.dispatchEvents();

    f.docOf(path).bus.publish(ReopenWanted(ReopenWanted.Why.formatTold));
    f.session.dispatchEvents();
    assert(f.docOf(path).anchored == [4], "the same file read another way");

    f.docOf(path).bus.publish(ReopenWanted(ReopenWanted.Why.truncated));
    f.session.dispatchEvents();
    assert(f.docOf(path).anchored.length == 0, "a file truncated by a rotation is another log");
    assert(savedAnchors(f.session.settings.recentFiles, path).length == 0);
}
