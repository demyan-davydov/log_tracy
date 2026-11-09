//! The main window: the bridge between the script (xcall and the global
//! functions it calls back) and the AppSession, and the rows and columns of
//! the log tables as Sciter values.
module ui.main_window;

import sciter.window;
import sciter.value;
import sciter.capi.types;
import sciter.capi.behavior;

import domain.document : Document;
import domain.document_id : DocumentId;
import domain.log_document : LogDocument;
import domain.document_item : DocumentItem;
import log_core.log_format : ColumnInfo, FormatChoice;
import log_core.log_message : TimeKind;
import ui.app_menu : MenuItem, MenuPlatform;
import ui.main_menu_loader : retitleAppMenu;
import utils.ui_text : UiText;
import log_core.rule_filter : RuleId;
import log_core.search_filter : checkRegex, MatchRange;
import ui.app_resources : appResourceOfUrl, appResourceUrl, builtInCatalogs;
import ui.app_session : AppSession;
import ui.app_settings : AppSettings, toJSON;
import ui.filter_commands : DocumentFilters;
import ui.table_rows : columnsJson, rowLength, writeRow;

import std.algorithm : startsWith;
import std.array : empty;
import std.conv : to;
import std.json : JSONValue;
import std.stdio : writeln;
import std.string : fromStringz;
import std.utf : toUTF8, toUTF16;

/// The window: the bridge between the script and the session. A call of the
/// script (xcall) is read from its Sciter values, done by the AppSession and
/// answered; what the script is to be told goes from onIdle(), never from
/// inside a call (see AppSession).
class MainWindow : SciterWindow
{
    private AppSession _session;

    /// The files of the interface are built in (`this://app/...`), for the dialogs too
    override protected immutable(ubyte)[] onLoadData(string uri)
    {
        auto data = appResourceOfUrl(uri);
        if (data is null && uri.startsWith(appResourceUrl))
            writeln("No file of the interface is built in at ", uri);
        return data;
    }

    /// The menu bar of the window on `platform`, in the language of the interface
    MenuItem[] menuBar(MenuPlatform platform)
    {
        return _session.menuBar(platform);
    }

    this(AppSettings settings)
    {
        _session = new AppSession(settings,
            (string path, FormatChoice choice) => cast(Document) new LogDocument(path, choice));
        {
            import std.process : environment;
            import ui.app_menu : hostMenuPlatform, windowMenu;

            // DLT_MENU_BAR=windows|linux: that menu bar in the window, for a try on any platform
            _session.showMenu(windowMenu(hostMenuPlatform(), environment.get("DLT_MENU_BAR", "")));
            // DLT_PSEUDO_LOCALE=1: the pseudo translation among the languages of Settings
            _session.offerPseudoLocale(environment.get("DLT_PSEUDO_LOCALE", "") == "1");
        }
        _session.useTranslations(builtInCatalogs());

        import sciter.capi.def;

        enum uint creationFlags =
            SCITER_CREATE_WINDOW_FLAGS.SW_MAIN
            | SCITER_CREATE_WINDOW_FLAGS.SW_TITLEBAR
            | SCITER_CREATE_WINDOW_FLAGS.SW_RESIZEABLE
            | SCITER_CREATE_WINDOW_FLAGS.SW_CONTROLS;

        RECT frame;
        frame.left = settings.windowRect.left;
        frame.top = settings.windowRect.top;
        frame.right = settings.windowRect.right;
        frame.bottom = settings.windowRect.bottom;

        super(creationFlags, frame);

        // Disable extended touchpad support on Mac to prevent gesture-related crashes
        _api.SciterSetOption(hwnd, SCITER_RT_OPTIONS.SCITER_EXTENDED_TOUCHPAD_SUPPORT, 0);
    }

    override void handleAttached(HELEMENT he)
    {
        writeln("handleAttached");
    }

    override void handleDetached(HELEMENT he)
    {
        // NOTE: do NOT call scripts here. BEHAVIOR_DETACH arrives while Sciter is
        // tearing the view down (view::stop -> detach_all_behaviors); a SciterCall
        // at this point touches already-detached handlers and crashes.
        // Settings are saved from JS on "closerequest" via xcall("saveAppState").
        writeln("handleDetached");
    }

    override bool handleEvent(HELEMENT he, SCRIPTING_METHOD_PARAMS* params)
    {
        const(char)[] method = fromStringz(params.name);
        auto resultView = SciterValueView(&params.result);

        // The parameter `index` of the call as a T: `defaultValue` if there
        // is no such parameter or it isn't a T
        T param(T)(int index, T defaultValue = T.init)
        {
            static if (is(T == string))
                const(wchar)[] result = defaultValue.toUTF16();
            else
                T result = defaultValue;
            if (index < params.argc)
            {
                SciterValueConstView valueView = SciterValueConstView(&params.argv[index]);
                valueView.tryGet(result);
            }
            static if (is(T == string))
                return result.toUTF8().idup;
            else
                return result;
        }
        // The document a call is about: its id is the first parameter of every
        // call of a document (the views, filters and search of a tab); an id
        // of no open document gives the null document, with no rows
        auto docParam = () => _session.findDocument(param!int(0));
        void answer(string text)
        {
            resultView = text.toUTF16();
        }

        switch (method)
        {
        // ── Settings and the window ─────────────────────────────────────────
        case "getSettings":
            answer(toJSON(_session.settings).toString());
            return true;
        case "saveAppState":
            // saveAppState(appStateJson): the window closes
            _session.saveOnClose(param!string(0));
            return true;
        case "getMenu":
            answer(_session.menuJson());
            return true;
        case "getLanguages":
            answer(_session.languagesJson());
            return true;
        case "useLanguage":
            // useLanguage(locale): the texts of the backend in that language from now on (the
            // native menu retitled); answers the catalog it takes, null: none
            if (const text = _session.useLanguage(param!string(0)))
                answer(text);
            retitleAppMenu(this);
            return true;
        case "getColumnSettings":
            answer(_session.columnSettingsJson());
            return true;
        case "setColumnLayouts":
            _session.setColumnLayouts(param!string(0));
            return true;

        // ── Files and tabs ──────────────────────────────────────────────────
        case "getRecentFiles":
            answer(_session.recentFilesJson());
            return true;
        case "removeRecentFile":
            // removeRecentFile(path) -> whether it was removed (not an open file)
            resultView = _session.removeRecentFile(param!string(0));
            return true;
        case "showInFolder":
            // showInFolder(path) -> "" or why the file manager can't be started
            answer(_session.showInFolder(param!string(0)));
            return true;
        case "openFile":
            // openFile(path) -> the id of the new document, or why the file
            // can't be opened: {"path" (as in the recent list), "error"}
            const path = param!string(0);
            if (path.empty)
                return true;
            const opened = _session.openFile(normalizePath(path));
            if (opened.docId.isValid)
                resultView = cast(int) opened.docId.toInt();
            else
                answer(opened.failureJson);
            return true;
        case "retryDocument":
            // retryDocument(docId) -> error message, "" if the file was reopened
            answer(_session.retryDocument(param!int(0)));
            return true;
        case "getWorkspaceInfo":
            answer(_session.workspaceInfoJson());
            return true;
        case "switchTab":
            _session.switchTab(param!int(0));
            return true;
        case "closeTab":
            _session.closeTab(param!int(0));
            return true;
        case "reorderTab":
            _session.reorderTab(param!int(0), param!int(1));
            return true;
        case "onTabClicked":
            writeln("Tab clicked: ", param!string(0));
            return true;
        case "loadFibex":
            return true; // FIBEX isn't decoded yet (docs/fibex.md)

        // ── The views ───────────────────────────────────────────────────────
        case "getMainViewCount":
        case "getSearchViewCount":
            // get<Main|Search>ViewCount(docId)
            auto doc = _session.doc(docParam());
            auto view = method == "getMainViewCount" ? doc.mainView : doc.searchView;
            resultView = cast(int) view.itemsCount();
            return true;
        case "getMainViewItem":
        case "getSearchViewItem":
            // get<Main|Search>ViewItem(docId, index): null if there is no such
            // row (any more): the view changed, the file is lost
            const docId = docParam();
            auto doc = _session.doc(docId);
            const bool search = method == "getSearchViewItem";
            const int index = param!int(1);
            DocumentItem docItem;
            if (!(search ? doc.searchView : doc.mainView).fetchItem(index, docItem))
                resultView.set(SciterValue.makeNull());
            else
                // the fragments the chips found, after the cells (main view rows have none)
                resultView.set(asSciterRow(index, docItem, _session.tableColumns(doc),
                    _session.ruleOf(docId, docItem), search, search ? _session.matchesOf(docId, docItem) : null));
            return true;
        case "getMainViewPosition":
            // getMainViewPosition(docId, messageIndex) -> its row in the main
            // view, null if the view doesn't show it. The row sends message
            // indexes as doubles (see asSciterRow)
            double msgIndex = -1;
            if (params.argc > 1)
            {
                SciterValueConstView valueView = SciterValueConstView(&params.argv[1]);
                int asInt;
                if (valueView.tryGet(asInt))
                    msgIndex = asInt;
                else
                    valueView.tryGet(msgIndex);
            }
            size_t position;
            if (msgIndex >= 0 && _session.doc(docParam()).mainView.positionOf(cast(size_t) msgIndex, position))
                resultView = cast(int) position;
            else
                resultView.set(SciterValue.makeNull());
            return true;
        case "getColumns":
            // getColumns(docId): all the columns of the document (the rules may
            // test any of them), [] if there is none
            auto document = _session.doc(docParam());
            answer(columnsJson(document.columns, document.formatChoice.id));
            return true;
        case "getTableColumns":
            // getTableColumns(docId): the columns the tables of the document show
            auto document = _session.doc(docParam());
            answer(columnsJson(_session.tableColumns(document), document.formatChoice.id));
            return true;
        case "setAnchor":
            // setAnchor(docId, messageIndex, value) -> true if changed
            resultView = _session.setAnchor(docParam(), param!int(1), param!bool(2));
            return true;
        case "cancelMainView":
            _session.cancelMainView(docParam());
            return true;
        case "cancelSearchView":
            _session.cancelSearchView(docParam());
            return true;

        // ── Search ──────────────────────────────────────────────────────────
        case "startChipSearch":
            // startChipSearch(docId, chipsJson) -> error message, "" on success
            answer(_session.startChipSearch(docParam(), param!string(1)));
            return true;
        case "getDocumentInfo":
            // getDocumentInfo(docId) -> {name, path, format, bytes, records}, null if not open
            answer(_session.documentInfoJson(docParam()));
            return true;
        case "getSearchHistory":
            // getSearchHistory(docId) -> [[chips]] of the document, the latest first
            answer(_session.searchHistoryJson(docParam()));
            return true;
        case "checkRegex":
            // checkRegex(pattern, matchCase) -> error message, "" for a valid regex
            answer(checkRegex(param!string(0), !param!bool(1)));
            return true;

        // ── Filters: the commands return a message for the user (an error, or
        // what was lost), "" if none ─────────────────────────────────────────
        case "getFilters":
            // getFilters(docId) -> {canFilter, canDlf, sets: [...]}, see DocumentFilters.toJson
            auto filters = _session.filters(docParam());
            answer(filters is null ? `{"canFilter":false,"canDlf":false,"sets":[]}` : filters.toJson(&_session.textForUser).toString());
            return true;
        case "getFilterRule":
            // getFilterRule(docId, set, rule) -> the fields of the rule, null
            // if there is no such rule; rule -1: a new one
            auto filters = _session.filters(docParam());
            const rule = param!int(2);
            answer(filters is null ? "null" : rule < 0 ? filters.newRuleJson(&_session.textForUser).toString()
                    : filters.ruleJson(param!int(1), rule).toString());
            return true;
        case "checkFilterRule":
            // checkFilterRule(docId, rule json) -> {error, conditions: [...]}
            auto filters = _session.filters(docParam());
            answer(filters is null ? `{"error":"","conditions":[]}` : filters.checkRule(param!string(1), &_session.textForUser).toString());
            return true;
        case "loadFilterFile":
            answer(filterCommand(docParam(), f => f.loadFile(normalizePath(param!string(1)))));
            return true;
        case "newFilterSet":
            answer(filterCommand(docParam(), f => f.newSet(&_session.textForUser)));
            return true;
        case "exportFilterSet":
            answer(filterCommand(docParam(), f => f.exportSet(param!int(1), normalizePath(param!string(2)))));
            return true;
        case "removeFilterSet":
            answer(filterCommand(docParam(), f => f.remove(param!int(1))));
            return true;
        case "enableFilterSet":
            answer(filterCommand(docParam(), f => f.enableSet(param!int(1), param!bool(2))));
            return true;
        case "addFilterRule":
            answer(filterCommand(docParam(), f => f.addRule(param!int(1), param!string(2))));
            return true;
        case "updateFilterRule":
            answer(filterCommand(docParam(), f => f.updateRule(param!int(1), param!int(2), param!string(3))));
            return true;
        case "enableFilterRule":
            answer(filterCommand(docParam(), f => f.enableRule(param!int(1), param!int(2), param!bool(3))));
            return true;
        case "removeFilterRule":
            answer(filterCommand(docParam(), f => f.removeRule(param!int(1), param!int(2))));
            return true;

        default:
            return false;
        }
    }

    /// A command on the filter sets of a document, its message logged
    private string filterCommand(DocumentId docId, scope UiText delegate(DocumentFilters) command)
    {
        const error = _session.filterCommand(docId, command);
        if (error.length)
            writeln("filter command: ", error);
        return error;
    }

    static string normalizePath(string path) pure
    {
        if (path.startsWith("file://"))
        {
            path = path[7 .. $];
            if (path.startsWith("/"))
                return path;
            version (Windows)
                if (path.length > 2 && path[1] == ':')
                    return path;
            return "/" ~ path;
        }
        return path;
    }

    /// Writes what is left of the settings and closes all documents,
    /// stopping their background operations. Call after the event loop has stopped.
    void closeAllDocuments()
    {
        _session.finish();
    }

    /// Called from main() after each iteration of the event loop: delivers the
    /// events of the documents, tells the script what changed and writes the
    /// settings when they are due. Never inside a call of the script.
    void onIdle()
    {
        //fixMacTitlebarBackground();
        _session.dispatchEvents();
        const calls = _session.takeScriptCalls();
        if (_session.closing)
            return; // the view is being torn down: calling the script would crash
        foreach (call; calls)
        {
            if (call.json is null)
                callScript(call.name, call.docId);
            else
                callScript(call.name, call.docId, call.json.toUTF16());
        }
        if (_session.settingsDue)
            _session.saveSettings(appStateOfScript());
    }

    /// The state of the script: its getAppState(), "{}" if it can't be had
    private string appStateOfScript()
    {
        try
            return callScript("getAppState").to!(const(wchar)[])().toUTF8();
        catch (Exception e)
        {
            writeln("Failed to call getAppState() ", e.msg);
            return "{}";
        }
    }
}

/// The cells of a row as Sciter values (see ui.table_rows.writeRow)
private struct SciterCells
{
    SciterValue row;
    AsArrayView cells;

    this(size_t length)
    {
        row = SciterValue.makeArrayWithSize(length);
        cells = AsArrayView(row);
    }

    void nothing(size_t cell)
    {
        SciterValue none = SciterValue.makeNull();
        cells.opIndex(cell, none);
    }

    void boolean(size_t cell, bool value) { cells.opIndex(cell, value); }
    void integer(size_t cell, int value) { cells.opIndex(cell, value); }
    void number(size_t cell, double value) { cells.opIndex(cell, value); }
    void text(size_t cell, const(wchar)[] value) { cells.opIndex(cell, value); }
    void text(size_t cell, const(char)[] value) { cells.opIndex(cell, value); }

    void time(size_t cell, double microseconds, TimeKind kind)
    {
        SciterValue time = SciterValue.makeArray(microseconds, cast(int) kind);
        cells.opIndex(cell, time);
    }

    void matches(size_t cell, const(MatchRange)[] ranges)
    {
        SciterValue list = SciterValue.makeArrayWithSize(ranges.length);
        auto view = AsArrayView(list);
        foreach (i, const ref m; ranges)
        {
            SciterValue fragment = SciterValue.makeArray(cast(int) m.start, cast(int) m.end, cast(int) m.chip);
            view.opIndex(i, fragment);
        }
        cells.opIndex(cell, list);
    }
}

/// A row of the log table as a Sciter array, see ui.table_rows.writeRow
SciterValue asSciterRow(int index, ref const(DocumentItem) item, const(ColumnInfo)[] columns,
    RuleId rule, bool withMatches = false, const(MatchRange)[] matches = null)
{
    auto cells = SciterCells(rowLength(columns.length, withMatches));
    writeRow(cells, index, item.message, item.anchored, item.realIndex, columns, rule, withMatches, matches);
    return cells.row;
}
