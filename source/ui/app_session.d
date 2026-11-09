//! The application behind the window, free of Sciter: the open documents and
//! their UI side, the settings, and what each call of the script does.
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

import domain.document;
import domain.document_id;
import domain.document_item : DocumentItem;
import domain.workspace;
import log_core.log_format : ColumnInfo, FormatChoice;
import log_core.rule_filter : RuleId;
import log_core.search_filter : MatchRange;
import ui.app_menu : hostMenuPlatform, MenuItem, MenuPlatform, WindowMenu, windowMenu;
import ui.app_settings;
import ui.document_ui : DocumentUi;
import ui.filter_commands : DocumentFilters;
import ui.table_columns : TableColumns;
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
    private Workspace _workspace;
    private DocumentUi[DocumentId] _documentUis;
    private TableColumns _tableColumns; // the columns the tables show for each format
    private DocumentFactory _open;
    private SettingsWriter _write;
    private FileShower _showInFolder;
    private ScriptCall[] _scriptCalls; // queued for the idle loop
    private bool _settingsChanged; // since they were last written
    private bool _closing; // the window closes: no more calls of the script
    private WindowMenu _menu = windowMenu(hostMenuPlatform(), ""); // the menu of the window
    private Translation[] _translations; // of the interface, by locale
    private Catalog _catalog; // of the language of the interface: the texts of the session
    private bool _offerPseudo; // the pseudo locale among the languages (DLT_PSEUDO_LOCALE=1)

    /// @param open - opens a document (a LogDocument in the app)
    /// @param write - writes the settings, to their file if not given
    /// @param showInFolder - shows a file in the file manager, of the system if not given
    this(AppSettings settings, DocumentFactory open, SettingsWriter write = null, FileShower showInFolder = null)
    {
        assert(open !is null);
        _settings = settings;
        _workspace = new Workspace();
        _tableColumns = new TableColumns();
        _open = open;
        _write = write !is null ? write : (in AppSettings s) { ui.app_settings.saveSettings(s); };
        _showInFolder = showInFolder !is null ? showInFolder : (string path) { utils.file_manager.showInFolder(path); };
        subscribeToDocumentEvents();
    }

    // ── Script calls and settings, for the idle loop of the window ──────────

    /// Delivers the events of the documents to their views, carries out what
    /// the views asked for, and queues the views that changed
    void dispatchEvents()
    {
        import std.stdio : writeln;

        try
            _workspace.dispatchEvents();
        catch (Exception e)
        {
            for (Throwable t = e; t !is null; t = t.next)
                writeln("Document event handler failed: ", t.msg);
        }
        applyDocumentCommands();
    }

    /// The calls of the script queued since the last time, in order: the
    /// documents opened and closed, then the views that changed
    ScriptCall[] takeScriptCalls()
    {

        foreach (docId, ui; _documentUis)
        {
            if (ui.mainViewChanged)
            {
                ui.mainViewChanged = false;
                _scriptCalls ~= ScriptCall("onMainViewChanged", idOf(docId),
                    toJson(ui.mainViewShown, &textForUser).toString());
            }
            if (ui.searchViewChanged)
            {
                ui.searchViewChanged = false;
                _scriptCalls ~= ScriptCall("onSearchViewChanged", idOf(docId),
                    toJson(ui.searchViewShown, &textForUser).toString());
            }
        }
        auto calls = _scriptCalls;
        _scriptCalls = null;
        return calls;
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
    /// more) and closes all documents
    void finish()
    {
        if (_settingsChanged)
            saveSettings("{}");
        closeAll();
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

    /// Closes all documents, stopping their background operations
    void closeAll()
    {
        _documentUis = null;
        _workspace.closeAll();
    }

    // ── The documents ────────────────────────────────────────────────────────

    /// The settings as they are now
    ref const(AppSettings) settings() const return
    {
        return _settings;
    }

    /// Returns: the id of the open document `id`, invalid if there is none
    DocumentId findDocument(int id)
    {
        foreach (item; _workspace.documents)
            if (item.docId.toInt() == id)
                return item.docId;
        return DocumentId.init;
    }

    /// The document `docId`, the null document (no rows) if it isn't open
    Document doc(DocumentId docId)
    {
        return _workspace.doc(docId);
    }

    /// Opens `path` in a new tab, or shows its tab if it is open already
    OpenResult openFile(string path)
    {
        import std.stdio : writeln;

        writeln("Opening file: ", path);
        const existing = _workspace.findBySourcePath(path);
        if (existing.isValid)
        {
            _workspace.setCurrent(existing);
            rememberRecentFile(RecentFile(path, _workspace.doc(existing).formatChoice, nowMs()));
            _scriptCalls ~= ScriptCall("onDocumentOpened", idOf(existing));
            return OpenResult(existing);
        }

        try
        {
            // Opened the way it was last time: the format may have been chosen by hand
            auto document = _open(path, savedFormat(_settings.recentFiles, path));
            auto docId = _workspace.addDocument(document, path);
            addDocumentUi(docId);
            // The filters loaded for the file last time, before the list moves it
            _documentUis[docId].filters.restore(savedFilters(_settings.recentFiles, path));
            _workspace.setCurrent(docId);
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
        import core.time : MonoTime;
        import std.stdio : writeln;

        const docId = findDocument(id);
        if (!docId.isValid)
            return _catalog.translate(uiText("the document is not open"));
        const path = sourcePathOf(docId);
        // reopened in the format it had, not detected again
        const choice = _workspace.doc(docId).formatChoice;
        try
        {
            // Timings: both steps run on the UI thread and may block on a disk
            // that has just been reconnected or removed
            const openStart = MonoTime.currTime;
            auto fresh = _open(path, choice);
            const openTime = MonoTime.currTime - openStart;

            const destroyStart = MonoTime.currTime;
            // The filters the old document had, for the new one
            auto oldUi = _documentUis.get(docId, null);
            const filters = oldUi is null ? null : oldUi.filters.saved();
            auto old = _workspace.replaceDocument(docId, fresh);
            addDocumentUi(docId); // the new document starts with a new machine
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
            _workspace.setCurrent(docId);
    }

    void reorderTab(int id, int targetIndex)
    {
        const docId = findDocument(id);
        if (docId.isValid)
            _workspace.moveDocumentBefore(docId, targetIndex);
    }

    /// The open documents for the tabs: id, name, path, active, the views shown
    string workspaceInfoJson()
    {
        import std.path : baseName;

        JSONValue[] docs;
        foreach (item; _workspace.documents)
        {
            auto ui = _documentUis.get(item.docId, null);
            docs ~= JSONValue([
                "id": JSONValue(item.docId.toInt()),
                "name": JSONValue(item.sourcePath.baseName),
                "path": JSONValue(item.sourcePath),
                "active": JSONValue(item.docId == _workspace.currentId),
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
        return _tableColumns.of(document.columns, document.formatChoice.id, _settings.columnLayouts);
    }

    /// The first filter rule with a color a row of the document matches
    RuleId ruleOf(DocumentId docId, ref const(DocumentItem) item)
    {
        auto ui = _documentUis.get(docId, null);
        return ui is null ? RuleId.init : ui.ruleOf(item.message);
    }

    /// What the chips of the search found in the payload of a search result
    const(MatchRange)[] matchesOf(DocumentId docId, ref const(DocumentItem) item)
    {
        auto ui = _documentUis.get(docId, null);
        return ui is null || ui.searchShown is null ? null : ui.searchShown.matchRanges(item.message());
    }

    /// Returns: true if the anchor changed; false while an operation is
    /// running or at the anchor limit (nothing changes then)
    bool setAnchor(DocumentId docId, int messageIndex, bool value)
    {
        return messageIndex >= 0 && _workspace.doc(docId).setAnchor(cast(size_t) messageIndex, value);
    }

    /// Cancel pressed in the main view of the document: its machine decides
    /// what it means (closing a loading document happens in dispatchEvents)
    void cancelMainView(DocumentId docId)
    {
        if (auto ui = _documentUis.get(docId, null))
            ui.pressMainCancel();
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
        import ui.search_chips : chipsFromJson;

        writeln("startChipSearch request: ", chipsJson);
        try
        {
            // An invalid regex throws here, before any background work starts
            const chips = chipsFromJson(chipsJson);
            auto filter = SearchFilter.fromChips(chips);
            if (!docId.isValid)
                return _catalog.translate(uiText("the document is not open"));
            _workspace.doc(docId).applySearchFilter(filter); // null clears the search
            if (auto ui = _documentUis.get(docId, null))
                ui.searchShown = filter;
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
        }
        return message;
    }

    // ── Menu ─────────────────────────────────────────────────────────────────

    /// The window has `menu` (that of the host platform until told)
    void showMenu(WindowMenu menu)
    {
        _menu = menu;
    }

    /// The menu of the window for the script (ui.app_menu.windowMenuJson)
    string menuJson()
    {
        import ui.app_menu : windowMenuJson;

        return windowMenuJson(_menu, &_catalog.translate);
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

        return appMenu(platform, &_catalog.translate);
    }

    // ── Columns ──────────────────────────────────────────────────────────────

    /// The Columns section of the Settings dialog, the format of the active document first
    string columnSettingsJson()
    {
        return ui.app_settings.columnSettingsJson(_settings.columnLayouts, _workspace.current.formatChoice.id);
    }

    /// Saved by the Settings dialog: {format id: [{"id", "visible"}]}
    void setColumnLayouts(string json)
    {
        _settings.columnLayouts = withColumnLayouts(_settings.columnLayouts, json);
        _tableColumns.reset(); // arranged again
        settingsChanged();
    }

    // ── Inside ───────────────────────────────────────────────────────────────

    /// Feeds document events to the machines of the documents
    private void subscribeToDocumentEvents()
    {
        import std.stdio : writeln;

        auto events = _workspace.events;
        events.subscribe((const DocumentEvent!OperationStarted e) {
            writeln("Operation ", e.event.operation, " started, doc ", e.docId.toInt());
            processDocumentEvent(e.docId, e.event);
        });
        events.subscribe((const DocumentEvent!OperationProgress e) {
            processDocumentEvent(e.docId, e.event);
        });
        events.subscribe((const DocumentEvent!SourceLost e) {
            writeln("Source lost, doc ", e.docId.toInt(), ": ", _workspace.displayName(e.docId));
            processDocumentEvent(e.docId, e.event);
        });
        events.subscribe((const DocumentEvent!OperationFinished e) {
            writeln("Operation ", e.event.operation, " ", e.event.result, ", doc ", e.docId.toInt(),
                e.event.error.empty ? "" : ": " ~ english(e.event.error));
            processDocumentEvent(e.docId, e.event);
        });
    }

    private void processDocumentEvent(E)(DocumentId docId, in E e)
    {
        if (auto ui = _documentUis.get(docId, null))
            ui.process(e);
    }

    /// Carries out what the machines asked for. Not called from their handlers:
    /// a document must not be destroyed while its events are being dispatched.
    private void applyDocumentCommands()
    {
        import std.stdio : writeln;

        DocumentId[] toClose;
        foreach (docId, ui; _documentUis)
            if (ui.closeRequested)
                toClose ~= docId;

        foreach (docId; toClose)
        {
            writeln("Closing document ", docId.toInt(), " on request of its view");
            closeDocument(docId);
            _scriptCalls ~= ScriptCall("onDocumentClosed", idOf(docId));
        }
    }

    private void addDocumentUi(DocumentId docId)
    {
        _documentUis[docId] = new DocumentUi(_workspace, docId);
        // its machines start showing at once: their first views are queued
    }

    /// Closes the document; its file is marked used now in the recent list
    private void closeDocument(DocumentId docId)
    {
        const path = sourcePathOf(docId);
        _documentUis.remove(docId);
        auto doc = _workspace.removeDocument(docId);
        if (doc !is null)
            doc.destroy();
        if (path.length)
        {
            _settings.recentFiles = withFilesUsed(_settings.recentFiles, [path], nowMs());
            settingsChanged();
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

    /// Files of the open documents, in the order of the tabs
    private const(string)[] openPaths()
    {
        string[] paths;
        foreach (item; _workspace.documents)
            paths ~= item.sourcePath;
        return paths;
    }

    /// Returns: the path of the document, null if it isn't open
    private string sourcePathOf(DocumentId docId)
    {
        foreach (item; _workspace.documents)
            if (item.docId == docId)
                return item.sourcePath;
        return null;
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
    import utils.event_bus.event_bus_async : EventBusAsync;
    import utils.event_bus.event_bus_interface : SignalConsumer;
    import core.time : msecs;
    import std.algorithm : canFind;
    import std.json : parseJSON;

    private final class FakeView : DocumentView
    {
        size_t itemsCount() nothrow @nogc { return 0; }
        bool fetchItem(size_t index, scope ref DocumentItem item) { return false; }
        bool positionOf(size_t realIndex, out size_t position) { return false; }
        void enableFilter(bool enable) {}
        bool isFilterEnabled() const { return false; }
        void applyFilter(LogFilter!wchar filter) {}
        void resetFilter() {}
    }

    /// A document whose events the test publishes; it records the searches asked
    private final class FakeDocument : Document
    {
        EventBusAsync bus;
        FakeView view;
        LogFilter!wchar[] searches;
        bool cancelAsked;
        PlainTextFormat plainText; // filters need the columns of a format
        this() { bus = new EventBusAsync(); view = new FakeView(); plainText = new PlainTextFormat(); }

        SignalConsumer events() { return bus; }
        void dispatchEvents() { bus.dispatch(); }
        DocumentView mainView() { return view; }
        DocumentView searchView() { return view; }
        const(LogFormat) format() { return plainText; }
        void applyViewFilter(LogFilter!wchar filter) {}
        void applySearchFilter(LogFilter!wchar filter) { searches ~= filter; }
        bool setAnchor(size_t index, bool value) { return true; }
        size_t[] exportAnchors() const pure { return null; }
        void importAnchors(const(size_t[]) anchors) {}
        bool requestCancel() { cancelAsked = true; return true; }
        bool sourceLost() { return false; }
        FormatChoice formatChoice() const { return FormatChoice("plain-text", 0); }
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
        }

        AppSession session;
        Records records;

        static Fixture make(AppSettings settings = AppSettings.init)
        {
            Fixture f;
            auto records = new Records();
            f.records = records;
            f.session = new AppSession(settings, (string path, FormatChoice choice) {
                records.lastChoice = choice;
                if (path.canFind("missing"))
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

@("AppSession: a file opened gets a document; the script is told later, not during the call")
unittest
{
    auto f = Fixture.make();
    const result = f.session.openFile("/logs/a.log");
    assert(result.docId.isValid && result.failureJson is null);
    assert(f.session.doc(result.docId) is f.docOf("/logs/a.log"));
    assert(f.session.settings.recentFiles.pathsOf == ["/logs/a.log"]);

    const calls = f.session.takeScriptCalls();
    assert(calls.length >= 1 && calls[0] == ScriptCall("onDocumentOpened", cast(int) result.docId.toInt()));
    assert(f.session.takeScriptCalls().length == 0, "taken once");
}

@("AppSession: a file that can't be opened is listed with the reason, the script is told nothing")
unittest
{
    auto f = Fixture.make();
    const result = f.session.openFile("/logs/missing.log");
    assert(!result.docId.isValid);
    const failure = parseJSON(result.failureJson);
    assert(failure["path"].str == "/logs/missing.log");
    assert(failure["error"].str == "no such file");
    assert(f.session.settings.recentFiles.pathsOf == ["/logs/missing.log"]);
    assert(!namesOf(f.session.takeScriptCalls()).canFind("onDocumentOpened"));
}

@("AppSession: a file open already shows its tab instead of a second document")
unittest
{
    auto f = Fixture.make();
    const first = f.session.openFile("/logs/a.log").docId;
    f.session.openFile("/logs/b.log");
    f.session.takeScriptCalls();

    assert(f.session.openFile("/logs/a.log").docId == first);
    assert(parseJSON(f.session.workspaceInfoJson()).array.length == 2);
    assert(f.session.takeScriptCalls()[0] == ScriptCall("onDocumentOpened", cast(int) first.toInt()));
}

@("AppSession: the views of a new document reach the script after it is told of the document")
unittest
{
    auto f = Fixture.make();
    const id = f.session.openFile("/logs/a.log").docId;
    f.session.dispatchEvents();
    const calls = f.session.takeScriptCalls();
    assert(namesOf(calls) == ["onDocumentOpened", "onMainViewChanged", "onSearchViewChanged"]);
    assert(parseJSON(calls[1].json)["status"].str == "loadingFile");
    assert(calls[1].docId == id.toInt());
}

@("AppSession: Cancel while a file loads closes its document from the idle loop")
unittest
{
    auto f = Fixture.make();
    const id = f.session.openFile("/logs/a.log").docId;
    f.session.takeScriptCalls();

    f.session.cancelMainView(id);
    assert(f.session.findDocument(cast(int) id.toInt()).isValid, "not closed during the call");
    f.session.dispatchEvents();
    assert(!f.session.findDocument(cast(int) id.toInt()).isValid);
    assert(f.session.takeScriptCalls() == [ScriptCall("onDocumentClosed", cast(int) id.toInt())]);
}

@("AppSession: a tab closed by the user goes away at once, its file marked used")
unittest
{
    auto f = Fixture.make();
    const id = f.session.openFile("/logs/a.log").docId;
    f.session.openFile("/logs/b.log");
    assert(pathsOf(f.session.settings.recentFiles) == ["/logs/b.log", "/logs/a.log"]);

    f.session.closeTab(cast(int) id.toInt());
    assert(!f.session.findDocument(cast(int) id.toInt()).isValid);
    assert(pathsOf(f.session.settings.recentFiles) == ["/logs/a.log", "/logs/b.log"], "used now: on top");
    assert(f.session.takeScriptCalls().length, "the views of b are still told");
}

@("AppSession: the settings are written from the idle loop, once for the changes before it")
unittest
{
    auto f = Fixture.make();
    assert(!f.session.settingsDue, "nothing changed");

    f.session.openFile("/logs/a.log");
    f.session.openFile("/logs/b.log");
    assert(f.writes.length == 0, "not written during the calls");
    assert(f.session.settingsDue);
    f.session.saveSettings(`{"theme": "dark"}`);
    assert(f.writes.length == 1, "both changes in one write");
    assert(f.writes[0].theme == "dark", "the state of the script is merged in");
    assert(pathsOf(f.writes[0].recentFiles) == ["/logs/b.log", "/logs/a.log"]);
    assert(!f.session.settingsDue, "written: nothing changed since");
}

@("AppSession: on close the settings are written at once, the open files on top")
unittest
{
    auto f = Fixture.make();
    f.session.openFile("/logs/a.log");
    const closed = f.session.openFile("/logs/c.log").docId;
    f.session.closeTab(cast(int) closed.toInt());
    assert(pathsOf(f.session.settings.recentFiles) == ["/logs/c.log", "/logs/a.log"]);

    f.session.saveOnClose(`{"tableFontSize": 120}`);
    assert(f.writes.length == 1 && f.writes[0].tableFontSize == 120);
    assert(pathsOf(f.writes[0].recentFiles) == ["/logs/a.log", "/logs/c.log"],
        "the open files were used until now");
}

@("AppSession: once the window closes the script is no longer asked; the rest is written on exit")
unittest
{
    auto f = Fixture.make();
    const id = f.session.openFile("/logs/a.log").docId;
    f.session.saveOnClose(`{}`);
    assert(f.session.closing);

    f.session.cancelMainView(id); // the loading document closes itself
    f.session.dispatchEvents();
    assert(!f.session.settingsDue, "no getAppState() of a closing window");

    f.session.finish();
    assert(f.writes.length == 2, "written without the state of the script");
    assert(f.session.findDocument(cast(int) id.toInt()) == DocumentId.init);
}


@("AppSession: a search is started in the document and kept in the history of its file")
unittest
{
    auto f = Fixture.make();
    const id = f.session.openFile("/logs/a.log").docId;
    const chips = `[{"text": "error", "isRegex": false, "ignoreCase": true}]`;
    assert(f.session.startChipSearch(id, chips) == "");
    assert(f.docOf("/logs/a.log").searches.length == 1);
    assert(parseJSON(f.session.searchHistoryJson(id)).array.length == 1);

    assert(f.session.startChipSearch(id, `[{"text": "(", "isRegex": true, "ignoreCase": false}]`).length,
        "an invalid regex is an error");
    assert(f.docOf("/logs/a.log").searches.length == 1, "and searches nothing");
}

@("AppSession: a file removed from the recent list loses its filters, the change is saved")
unittest
{
    auto f = Fixture.make();
    const id = f.session.openFile("/logs/a.log").docId;
    f.session.filterCommand(id, (DocumentFilters filters) => filters.newSet());
    f.session.openFile("/logs/b.log");
    f.session.closeTab(cast(int) id.toInt());
    f.session.saveSettings(`{}`);

    assert(f.session.removeRecentFile("/logs/a.log"));
    assert(pathsOf(f.session.settings.recentFiles) == ["/logs/b.log"]);
    assert(f.session.settingsDue);
    f.session.saveSettings(`{}`);
    assert(pathsOf(f.writes[$ - 1].recentFiles) == ["/logs/b.log"]);

    f.session.openFile("/logs/a.log");
    assert(savedFilters(f.session.settings.recentFiles, "/logs/a.log").length == 0, "opened anew, without its filters");
}

@("AppSession: a file is shown in the file manager, or the reason it can't be")
unittest
{
    auto f = Fixture.make();
    assert(f.session.showInFolder("/logs/a.log") == "");
    assert(f.records.shown == ["/logs/a.log"]);
    assert(f.session.showInFolder("/logs/missing.log") == "no such file");
}

@("AppSession: an open file is not removed from the recent list")
unittest
{
    auto f = Fixture.make();
    f.session.openFile("/logs/a.log");
    f.session.saveSettings(`{}`);
    assert(!f.session.removeRecentFile("/logs/a.log"));
    assert(pathsOf(f.session.settings.recentFiles) == ["/logs/a.log"]);
    assert(!f.session.settingsDue, "nothing changed");
}

@("AppSession: a filter command that succeeds is kept in the settings of the file")
unittest
{
    auto f = Fixture.make();
    const id = f.session.openFile("/logs/a.log").docId;
    assert(f.session.filterCommand(id, (DocumentFilters filters) => filters.newSet()) == "");
    assert(savedFilters(f.session.settings.recentFiles, "/logs/a.log").length == 1);
}

@("AppSession: a filter command that changes the sets is kept even when it has a note (what was lost)")
unittest
{
    auto f = Fixture.make();
    const id = f.session.openFile("/logs/a.log").docId;
    assert(f.session.filterCommand(id, (DocumentFilters filters) { import utils.ui_text : plainText; filters.newSet(); return plainText("a.dlf: a note"); })
        == "a.dlf: a note");
    assert(savedFilters(f.session.settings.recentFiles, "/logs/a.log").length == 1);
}

@("AppSession: a filter command that fails changes nothing in the settings")
unittest
{
    auto f = Fixture.make();
    const id = f.session.openFile("/logs/a.log").docId;
    assert(f.session.filterCommand(id, (DocumentFilters filters) => filters.remove(7)).length);
    assert(savedFilters(f.session.settings.recentFiles, "/logs/a.log").length == 0);
}

@("AppSession: a file opened again gets the filters it had")
unittest
{
    auto f = Fixture.make();
    auto id = f.session.openFile("/logs/a.log").docId;
    f.session.filterCommand(id, (DocumentFilters filters) => filters.newSet());
    f.session.closeTab(cast(int) id.toInt());

    id = f.session.openFile("/logs/a.log").docId;
    assert(f.session.filters(id).saved().length == 1);
}

@("AppSession: a real file opens in a LogDocument and its main view gets ready")
unittest
{
    import core.thread : Thread;
    import std.file : remove, tempDir, write;
    import std.path : buildPath;

    const path = buildPath(tempDir(), "dlt_explorer_session_test.log");
    write(path, "first line\nsecond line\n");
    scope (exit) remove(path);

    import domain.log_document : LogDocument;

    AppSettings[] written;
    auto session = new AppSession(AppSettings.init,
        (string path, FormatChoice choice) => cast(Document) new LogDocument(path, choice),
        (in AppSettings s) { written ~= AppSettings(s); });
    scope (exit) session.closeAll();
    const id = session.openFile(path).docId;
    assert(id.isValid);

    string status;
    foreach (attempt; 0 .. 500)
    {
        session.dispatchEvents();
        foreach (call; session.takeScriptCalls())
            if (call.name == "onMainViewChanged")
                status = parseJSON(call.json)["status"].str;
        if (status == "ready")
            break;
        Thread.sleep(10.msecs);
    }
    assert(status == "ready", status);
    assert(session.doc(id).mainView.itemsCount == 2);
    assert(session.settings.recentFiles[0].format.id.length, "the format detected is remembered");
}

@("AppSession: the recent list remembers the format the document was opened with")
unittest
{
    // The format saved last time is only asked for: the document opened in
    // another one (the saved one can't be made any more, say)
    AppSettings settings;
    settings.recentFiles = [RecentFile("/logs/a.log", FormatChoice("logcat", 1), 1)];
    auto f = Fixture.make(settings);
    f.session.openFile("/logs/a.log");
    assert(f.lastChoice == FormatChoice("logcat", 1), "the saved format is asked for");
    assert(f.session.settings.recentFiles[0].format == FormatChoice("plain-text", 0),
        "the format of the document is remembered");
}

@("AppSession: the state of the script written last is kept for the writes after it")
unittest
{
    auto f = Fixture.make();
    const id = f.session.openFile("/logs/a.log").docId;
    f.session.saveOnClose(`{"theme": "dark", "tableFontSize": 130}`);

    f.session.cancelMainView(id); // closes after the window did: a write without the script
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

    assert(parseJSON(f.session.openFile("/refused.log").failureJson)["error"].str == "not a log of DLT or text");
    f.session.useLanguage("ru");
    assert(parseJSON(f.session.openFile("/refused.log").failureJson)["error"].str == "не журнал формата DLT or text");
    assert(parseJSON(f.session.openFile("/missing.log").failureJson)["error"].str == "no such file",
        "a message of the OS as it is");
    assert(f.session.retryDocument(12345) == "документ не открыт");
}


@("AppSession: the pseudo locale is offered only when asked for (DLT_PSEUDO_LOCALE)")
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

@("AppSession: the message of a filter command is in the language of the interface")
unittest
{
    import ui.translations : CatalogFile;

    auto f = Fixture.make();
    f.session.useTranslations([CatalogFile("ru.json",
        `{"locale": "ru", "name": "Русский", "messages": {"no such filter": "такого фильтра нет"}}`)]);
    const id = f.session.openFile("/logs/a.log").docId;

    assert(f.session.filterCommand(id, (DocumentFilters filters) => filters.remove(7)) == "no such filter");
    f.session.useLanguage("ru");
    assert(f.session.filterCommand(id, (DocumentFilters filters) => filters.remove(7)) == "такого фильтра нет");
}
