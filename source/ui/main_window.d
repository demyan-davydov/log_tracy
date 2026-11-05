//! The main window: the bridge between the script (xcall and the global
//! functions it calls back) and the AppSession, and the rows and columns of
//! the log tables as Sciter values.
module ui.main_window;

import sciter.window;
import sciter.value;
import sciter.capi.types;
import sciter.capi.behavior;

import domain.document_id : DocumentId;
import domain.document_item : DocumentItem;
import log_core.log_format : ColumnInfo, ColumnKind;
import log_core.log_message : TimeKind;
import log_core.rule_filter : RuleId;
import log_core.search_filter : checkRegex, MatchRange;
import ui.app_session : AppSession;
import ui.app_settings : AppSettings, toJSON;
import ui.filter_commands : DocumentFilters;

import std.algorithm : count, startsWith;
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

    this(AppSettings settings)
    {
        _session = new AppSession(settings);

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
            _session.reloadLogTable(); // FIBEX isn't decoded yet
            return true;

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
            answer(columnsJson(_session.doc(docParam()).columns));
            return true;
        case "getTableColumns":
            // getTableColumns(docId): the columns the tables of the document show
            answer(columnsJson(_session.tableColumns(_session.doc(docParam()))));
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
        case "getSearchHistory":
            // getSearchHistory(docId) -> [[chips]] of the document, the latest first
            answer(_session.searchHistoryJson(docParam()));
            return true;
        case "checkRegex":
            // checkRegex(pattern, ignoreCase) -> error message, "" for a valid regex
            answer(checkRegex(param!string(0), param!bool(1)));
            return true;

        // ── Filters: the commands return a message for the user (an error, or
        // what was lost), "" if none ─────────────────────────────────────────
        case "getFilters":
            // getFilters(docId) -> {canFilter, canDlf, sets: [...]}, see DocumentFilters.toJson
            auto filters = _session.filters(docParam());
            answer(filters is null ? `{"canFilter":false,"canDlf":false,"sets":[]}` : filters.toJson().toString());
            return true;
        case "getFilterRule":
            // getFilterRule(docId, set, rule) -> the fields of the rule, null
            // if there is no such rule; rule -1: a new one
            auto filters = _session.filters(docParam());
            const rule = param!int(2);
            answer(filters is null ? "null" : rule < 0 ? DocumentFilters.newRuleJson().toString()
                    : filters.ruleJson(param!int(1), rule).toString());
            return true;
        case "checkFilterRule":
            // checkFilterRule(docId, rule json) -> {error, conditions: [...]}
            auto filters = _session.filters(docParam());
            answer(filters is null ? `{"error":"","conditions":[]}` : filters.checkRule(param!string(1)).toString());
            return true;
        case "loadFilterFile":
            answer(filterCommand(docParam(), f => f.loadFile(normalizePath(param!string(1)))));
            return true;
        case "newFilterSet":
            answer(filterCommand(docParam(), f => f.newSet()));
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
    private string filterCommand(DocumentId docId, scope string delegate(DocumentFilters) command)
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
        fixMacTitlebarBackground();
        _session.dispatchEvents();
        const calls = _session.takeScriptCalls();
        if (_session.closing)
            return; // the view is being torn down: calling the script would crash
        foreach (call; calls)
        {
            if (!call.hasDocId)
                callScript(call.name);
            else if (call.json is null)
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

//! @brief The text of a hex cell: all 64 bits, as typed into the quick filter
//! (FieldFilter reads FFFFFFFFFFFFFFFF as -1). A script number would round
//! values above 2^53 and show -1 as "-1".
string hexCellText(long value) pure
{
    import std.format : format;

    return format("%X", cast(ulong) value);
}

@("hexCellText: the 64 bits in upper case hex")
unittest
{
    assert(hexCellText(0x1F) == "1F");
    assert(hexCellText(0) == "0");
    assert(hexCellText(-1) == "FFFFFFFFFFFFFFFF");
    assert(hexCellText(0x1234_5678_9ABC_DEF1) == "123456789ABCDEF1", "no rounding above 2^53");
}

//! @brief A row of the log table: anchored, rule id, view index, message
//! index, level, then a cell per column (see virtual-dlt-view.js). The level
//! colors the cells of the columns that ask for it (ColumnInfo.byLevel).
//! @param rule - the first filter rule with a color the record matches (the
//! script shows it by its color); none is sent as null
//! @param withMatches - a row of the search results: after the cells comes what
//! the chips found in the payload, [[start, end, chip]] (see MatchRange)
SciterValue asSciterRow(int index, ref const(DocumentItem) item, const(ColumnInfo)[] columns,
    RuleId rule, bool withMatches = false, const(MatchRange)[] matches = null)
{
    enum fixedCells = 5;
    const msg = &item.message();

    SciterValue row = SciterValue.makeArrayWithSize(fixedCells + columns.length + (withMatches ? 1 : 0));
    auto cells = AsArrayView(row);
    cells.opIndex(0, item.anchored);
    if (rule.isValid())
        cells.opIndex(1, cast(double) rule.toInt());
    else
    {
        SciterValue none = SciterValue.makeNull();
        cells.opIndex(1, none);
    }
    cells.opIndex(2, index);
    cells.opIndex(3, cast(double) item.realIndex);
    cells.opIndex(4, cast(int) msg.level);

    foreach (i, ref column; columns)
    {
        const cell = fixedCells + i;
        if (column.isField && !msg.hasField(column.field))
        {
            SciterValue none = SciterValue.makeNull(); // e.g. a line without a header
            cells.opIndex(cell, none);
            continue;
        }
        final switch (column.kind)
        {
        case ColumnKind.Time:
            // [microseconds, TimeKind]: the kind of this record, the column's
            // is only the usual one. Microseconds are exact in a double (a
            // script number) for 285 years.
            if (msg.timeKind == TimeKind.None)
            {
                SciterValue none = SciterValue.makeNull();
                cells.opIndex(cell, none);
            }
            else
            {
                SciterValue time = SciterValue.makeArray(cast(double)(msg.timeNs / 1000), cast(int) msg.timeKind);
                cells.opIndex(cell, time);
            }
            break;
        case ColumnKind.Level:
            cells.opIndex(cell, cast(int) msg.level);
            break;
        case ColumnKind.Payload:
            cells.opIndex(cell, msg.payloadText);
            break;
        case ColumnKind.Text:
            cells.opIndex(cell, msg.text(column.field));
            break;
        case ColumnKind.Hex:
            cells.opIndex(cell, hexCellText(msg.number(column.field)));
            break;
        case ColumnKind.Integer:
        case ColumnKind.Duration:
        case ColumnKind.Enum:
            cells.opIndex(cell, cast(double) msg.number(column.field));
            break;
        }
    }
    if (withMatches)
    {
        SciterValue list = SciterValue.makeArrayWithSize(matches.length);
        auto view = AsArrayView(list);
        foreach (i, const ref m; matches)
        {
            SciterValue fragment = SciterValue.makeArray(cast(int) m.start, cast(int) m.end, cast(int) m.chip);
            view.opIndex(i, fragment);
        }
        cells.opIndex(fixedCells + columns.length, list);
    }
    return row;
}

//! @brief The columns as JSON for the script (see virtual-dlt-view.js)
string columnsJson(const(ColumnInfo)[] columns)
{
    import std.conv : to;

    JSONValue[] result;
    foreach (ref column; columns)
    {
        JSONValue c = [
            "id": JSONValue(column.id),
            "title": JSONValue(column.title),
            "kind": JSONValue(column.kind.to!string),
            "width": JSONValue(column.width),
        ];
        if (column.kind == ColumnKind.Time)
            c["timeKind"] = JSONValue(column.timeKind.to!string);
        if (column.kind == ColumnKind.Duration)
            c["unitsPerSecond"] = JSONValue(column.unitsPerSecond);
        if (column.kind == ColumnKind.Enum)
            c["labels"] = JSONValue(column.labels);
        if (column.byLevel)
            c["byLevel"] = JSONValue(true);
        result ~= c;
    }
    return JSONValue(result).toString();
}

@("columnsJson: a column colored by the level says so")
unittest
{
    import std.algorithm.searching : canFind;

    const json = columnsJson([
        ColumnInfo("status", "Status", ColumnKind.Integer, 0, 50, TimeKind.None, 0, null, true),
        ColumnInfo("bytes", "Bytes", ColumnKind.Integer, 1, 70),
    ]);
    assert(json.canFind(`"byLevel":true`), json);
    assert(json.count(`"byLevel"`) == 1, "only for the flagged column");
}
