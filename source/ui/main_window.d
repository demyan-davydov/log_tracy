//! The main window: the bridge between the script (xcall and the global
//! functions it calls back) and the AppSession, and the rows and columns of
//! the log tables as Sciter values.
module ui.main_window;

import sciter.event_handler : SciterEventHandler;
import sciter.window;
import sciter.value;
import sciter.capi.types;
import sciter.capi.behavior;

import domain.document_id : DocumentId;
import ui.app_menu : MenuItem, MenuPlatform;
import ui.main_menu_loader : retitleAppMenu;
import utils.ui_text : UiText;
import ui.app_resources : appResourceOfUrl, appResourceUrl, builtInCatalogs;
import ui.app_session : AppSession;
import ui.app_settings : toJSON;
import ui.filter_commands : DocumentFilters;
import ui.log_table.column_widths : minWidthVariables;
import ui.log_table.look_json : applyLookJson;
import ui.log_table.log_table_target : LogTableTarget;
import ui.log_table.log_table : TableSource;
import ui.script_queue : ScriptQueue;
import ui.log_table_behavior : LogTableBehavior, logTableBehavior, runScript, TableHooks;
import ui.table_script : TableControl, TableRegistry;
import ui.columns_json : columnsJson;

import std.algorithm : startsWith;
import std.array : empty;
import std.conv : to;
import std.json : JSONValue;
import std.stdio : writeln;
import std.string : fromStringz;
import std.utf : toUTF8, toUTF16;

/// How many times one idle round tells the script what was queued, the script's answers queuing more
private enum maxScriptRounds = 4;

/// The window: the bridge between the script and the session. A call of the
/// script (xcall) is read from its Sciter values, done by the AppSession and
/// answered; what the script is to be told, by the session or by a log table,
/// goes from onIdle(), never from inside a call (see AppSession, ui/script_queue).
class MainWindow : SciterWindow
{
    private AppSession _session;
    private LogTableTarget _target = new LogTableTarget; // what the next log table (log-table) shows
    private TableRegistry _tables; // the painted tables the script talks to, by their numbers
    private ScriptQueue _tableCalls; // what the tables tell the script, sent by onIdle()

    /// The files of the interface are built in (`this://app/...`), for the dialogs too
    override protected immutable(ubyte)[] onLoadData(string uri)
    {
        auto data = appResourceOfUrl(uri);
        if (data is null && uri.startsWith(appResourceUrl))
            writeln("No file of the interface is built in at ", uri);
        return data;
    }

    // The native behaviors of CSS `behavior: ...`: the log table (ui/log_table_behavior)
    override protected SciterEventHandler createBehavior(string name, HELEMENT he)
    {
        if (name != logTableBehavior)
            return null;
        const id = _target.id;
        auto source = TableSource(_session, _session.findDocument(_target.doc), _target.search, _target.hostOf(_target.doc), false, _target.singleLine);
        return new LogTableBehavior(source, _target.look,
            TableHooks(id, (TableControl control) { _tables.attach(id, control); }, (TableControl control) { _tables.detach(control); },
                &_tableCalls.put), he);
    }

    /// The menu bar of the window on `platform`, in the language of the interface
    MenuItem[] menuBar(MenuPlatform platform)
    {
        return _session.menuBar(platform);
    }

    /// @param session - the application behind the window, made by main()
    /// @param sciterDebugMode - the debug mode of Sciter, for its inspector (SCITER_DEBUG_MODE):
    ///   Ctrl+Shift+I connects the window to inspector.app of the SDK, started first,
    ///   Ctrl+Shift+click shows the element clicked
    this(AppSession session, bool sciterDebugMode = false)
    {
        _session = session;
        _tableCalls = new ScriptQueue;
        _session.documentClosed = (DocumentId docId) { _target.forget(cast(int) docId.toInt()); };
        _session.useTranslations(builtInCatalogs());

        import sciter.capi.def;

        enum uint creationFlags =
            SCITER_CREATE_WINDOW_FLAGS.SW_MAIN
            | SCITER_CREATE_WINDOW_FLAGS.SW_TITLEBAR
            | SCITER_CREATE_WINDOW_FLAGS.SW_RESIZEABLE
            | SCITER_CREATE_WINDOW_FLAGS.SW_CONTROLS;

        // Only until the document loads: Sciter sizes the window by the markup of main.htm
        // (window-width, window-height), the script moves it to the saved frame
        // (restoreWindowFrame), in the pixels it saves it in
        RECT frame = RECT(100, 100, 1100, 900);

        super(creationFlags, frame);

        // Disable extended touchpad support on Mac to prevent gesture-related crashes
        _api.SciterSetOption(hwnd, SCITER_RT_OPTIONS.SCITER_EXTENDED_TOUCHPAD_SUPPORT, 0);

        if (sciterDebugMode)
        {
            import std.stdio : writeln;

            const on = _api.SciterSetOption(hwnd, SCITER_RT_OPTIONS.SCITER_SET_DEBUG_MODE, 1);
            writeln(on ? "Sciter debug mode on: Ctrl+Shift+I connects to the inspector"
                : "Can't turn the debug mode of Sciter on");
        }
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
        case "windowFrameChanged":
            // windowFrameChanged(): the user moved or resized the window
            _session.windowFrameChanged();
            return true;
        case "getMenu":
            answer(_session.menuJson());
            return true;
        case "getLanguages":
            answer(_session.languagesJson());
            return true;
        case "getStartFiles":
            answer(_session.startFilesJson());
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

        case "logTableCall":
            // logTableCall(tableId, method, args...): a call to the table drawn by D (ui/log_table_behavior) that `setLogTableTarget` gave that number; null if
            // there is none (not attached yet, or no more)
            {
                auto table = params.argc >= 2 ? _tables.get(param!int(0)) : null;
                if (table is null)
                    resultView.set(SciterValue.makeNull());
                else
                    runScript(table, param!string(1), params.argv + 2, params.argc - 2, &params.result);
            }
            return true;
        case "logTableSetLook":
            // logTableSetLook(json): the look of the application: every log table has it, one that is not attached yet too
            if (params.argc >= 1)
                applyLookJson(_target.look, param!string(0));
            return true;
        case "logTableMinWidthNames":
            // logTableMinWidthNames() -> the names of the CSS variables of the least widths of the columns, as a JSON array (ui/log_table/column_widths)
            answer(JSONValue(minWidthVariables()).toString());
            return true;
        case "logTableSingleLine":
            // logTableSingleLine(on): the rows of the painted tables are one line high (the setting of the application): every table now, the next ones from the start
            _target.singleLine = param!bool(0);
            _tables.each((TableControl table) { table.singleLine(_target.singleLine); });
            return true;
        case "setLogTableTarget":
            // setLogTableTarget(docId, search): the next element with `behavior: log-table` shows that view; answers the number of that table
            resultView = cast(int) _target.set(param!int(0), param!bool(1));
            return true;

        // ── The views ───────────────────────────────────────────────────────
        case "getMainViewNearestPosition":
        case "getMainViewPosition":
        case "getSearchViewPosition":
            // get<Main|Search>ViewPosition(docId, messageIndex) -> its row in
            // that view, null if the view doesn't show it; getMainViewNearestPosition:
            // the row Go to Message lands on (AppSession.nearestMainViewPosition),
            // null for an empty view. The script sends message indexes as doubles
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
            const found = method == "getMainViewNearestPosition"
                ? _session.nearestMainViewPosition(docParam(), msgIndex, position)
                : _session.viewPosition(docParam(), method == "getSearchViewPosition", msgIndex, position);
            if (found)
                resultView = cast(int) position;
            else
                resultView.set(SciterValue.makeNull());
            return true;
        case "getColumns":
            // getColumns(docId): all the columns of the document (the rules may
            // test any of them), [] if there is none
            auto document = _session.doc(docParam());
            answer(columnsJson(document.columns, document.formatInfo.id));
            return true;
        case "setAnchor":
            // setAnchor(docId, messageIndex, value) -> {"refused", "max", "full", "pending", "rows"}: AppSession.setAnchor
            answer(_session.setAnchor(docParam(), param!int(1), param!bool(2)));
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
            // getDocumentInfo(docId) -> {name, path, format, bytes, records, descriptions}, null if not open
            answer(_session.documentInfoJson(docParam()));
            return true;
        case "loadDescriptions":
            // loadDescriptions(docId, path) -> error message, "" if asked (read in the background)
            answer(_session.loadDescriptions(docParam(), normalizePath(param!string(1))));
            return true;
        case "unloadDescriptions":
            // unloadDescriptions(docId) -> error message, "" if dropped
            answer(_session.unloadDescriptions(docParam()));
            return true;
        case "getAttachments":
            // getAttachments(docId) -> [{id, name, ...}], see AppSession.attachmentsJson
            answer(_session.attachmentsJson(docParam()));
            return true;
        case "saveAttachment":
            // saveAttachment(docId, id, path) -> error message, "" if saved
            answer(_session.saveAttachment(docParam(), param!int(1), normalizePath(param!string(2))));
            return true;
        case "getSearchHistory":
            // getSearchHistory(docId) -> [[chips]] of the document, the latest first
            answer(_session.searchHistoryJson(docParam()));
            return true;
        case "checkRegex":
            // checkRegex(pattern, matchCase) -> error message, "" for a valid regex
            answer(_session.checkRegex(param!string(0), param!bool(1)));
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
        case "renameFilterSet":
            answer(filterCommand(docParam(), f => f.renameSet(param!int(1), param!string(2))));
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

    /// Writes what is left of the settings and closes all tabs: their documents no one
    /// else holds stop their background operations. Call after the event loop has stopped.
    void closeAllDocuments()
    {
        _session.finish();
    }

    /// The application terminates and the event loop won't return (macOS: Quit, the Dock,
    /// logging out): writes the settings with the state of the script, unless the window
    /// already closed, and closes all documents, those held by others too
    void terminate()
    {
        _session.terminate(appStateOfScript());
    }

    /// Called from main() after each iteration of the event loop: delivers the
    /// events of the documents, tells the script what changed and writes the
    /// settings when they are due. Never inside a call of the script.
    void onIdle()
    {
        //fixMacTitlebarBackground();
        // What the script does when told may queue more (a click on an anchor sets it, the document tells the anchor
        // applied): the rounds go on till nothing is left, a few at most, so that it comes now and not with the next
        // event of the loop. What is left after them goes with the next idle round.
        foreach (round; 0 .. maxScriptRounds)
        {
            const tableCalls = _tableCalls.take();
            _session.dispatchEvents();
            const calls = _session.takeScriptCalls();
            if (_session.closing)
                return; // the view is being torn down: calling the script would crash
            if (tableCalls.empty && calls.empty)
                break;
            foreach (call; tableCalls)
                callScript(call.name, call.text);
            foreach (call; calls)
            {
                if (call.json is null)
                    callScript(call.name, call.docId);
                else
                    callScript(call.name, call.docId, call.json.toUTF16());
            }
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
