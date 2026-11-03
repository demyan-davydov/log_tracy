module ui.main_window;

import sciter_wrapper.sciter_window;
import sciter_wrapper.sciter_value;
import ui.app_settings;

import domain.workspace;
import domain.document_id;
import domain.document;
import domain.document_item;
import domain.dlt_document;

import dlt_core.indexer;
import dlt_core.search;
import dlt_core.fibex;
import dlt_core.dlt_filter_serialization;
import dlt_core.dlt_filter_record;
import dlt_core.dlt_log_filter : DltLogFilter, quickFilter;
import domain.search_filter : SearchFilter;
import dlt_core.log_filter : LogFilter;
import dlt_core.log_item : LogItem;

import sciter.types;
import sciter.behavior;

import std.path : baseName;
import std.utf : toUTF8, toUTF16;
import std.string : fromStringz;
import std.array : empty;
import std.algorithm;
import std.stdio;
import std.json;
import std.conv : to;

class MainWindow : SciterWindow
{
    private AppSettings _settings;
    private Workspace _workspace;

    this(AppSettings settings)
    {
        _settings = settings;
        _workspace = new Workspace();

        import sciter.def;

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

        subscribeToDocumentEvents();
    }

    /// Forwards document operation events to JS as the resulting view status:
    /// onDocumentEvent(docId, view, state, progress, operation), view is "main" or "search".
    /// The document updates its views before external subscribers are called,
    /// so the status read here already reflects the event.
    private void subscribeToDocumentEvents()
    {
        auto events = _workspace.events;
        events.subscribe((const DocumentEvent!OperationStarted e) {
            writeln("Operation ", e.event.operation, " started, doc ", e.docId.toInt());
            notifyViewStatus(e.docId, e.event.operation);
        });
        events.subscribe((const DocumentEvent!OperationProgress e) {
            notifyViewStatus(e.docId, e.event.operation);
        });
        events.subscribe((const DocumentEvent!OperationFinished e) {
            writeln("Operation ", e.event.operation, " ", e.event.result, ", doc ", e.docId.toInt(),
                e.event.error.length ? ": " ~ e.event.error : "");
            notifyViewStatus(e.docId, e.event.operation);
        });
    }

    private void notifyViewStatus(DocumentId docId, Document.Operation operation)
    {
        const bool search = isSearchOperation(operation);
        auto doc = _workspace.doc(docId);
        auto view = search ? doc.searchView : doc.mainView;
        callScript("onDocumentEvent", docId.toInt(), (search ? "search"w : "main"w),
            view.state.to!string.toUTF16(), view.progress, view.operation.to!string.toUTF16());
    }

    /// {"state": "<DocumentView.State>", "progress": 0..1, "operation": "<Document.Operation>"}
    private static JSONValue viewStatusJson(DocumentView view)
    {
        return JSONValue([
            "state": JSONValue(view.state.to!string),
            "progress": JSONValue(view.progress),
            "operation": JSONValue(view.operation.to!string)
        ]);
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

    override bool handleEvent(HELEMENT he, BEHAVIOR_EVENT_PARAMS* params)
    {
        if (params.cmd == BEHAVIOR_EVENTS.DOCUMENT_CLOSE)
        {
            // this branch is not called for some reason
            writeln("DOCUMENT_CLOSE");
            saveSettings();
            return false; // Let it continue closing
        }

        const(wchar)[] eventName = params.name ? fromStringz(params.name) : null;

        auto asString = () {
            const auto dataView = SciterValueConstView(&params.data);
            return dataView.to!(const(wchar)[])().toUTF8();
        };

        if (eventName == "openFile"w)
        {
            onFileSelected(normalizePath(asString()));
            return true;
        }

        if (eventName == "loadFibex"w)
        {
            onLoadFibex(normalizePath(asString()));
            return true;
        }
        if (eventName == "applyFilter"w)
        {
            onApplyFilter(asString());
            return true;
        }
        if (eventName == "tab-clicked"w)
        {
            onTabClicked(asString());
            return true;
        }

        return false;
    }

    override bool handleEvent(HELEMENT he, SCRIPTING_METHOD_PARAMS* params)
    {
        const(char)[] method = fromStringz(params.name);

        auto resultView = SciterValueView(&params.result);

        if (method == "getSettings")
        {
            /*
            // Serialize settings to JSON string
            JSONValue j = ["gui": "dlt-explorer"];
            j.object = null;
            j.object["windowRect"] = [
                "left": _settings.windowRect.left,
                "top": _settings.windowRect.top,
                "width": _settings.windowRect.width,
                "height": _settings.windowRect.height
            ];

            JSONValue[] filesArr;
            foreach (f; _settings.files)
            {
                JSONValue fv = ["path": f.path];
                fv.object["scrollPosition"] = JSONValue(f.scrollPosition);
                filesArr ~= fv;
            }
            j.object["files"] = JSONValue(filesArr);

            j.object["activeFile"] = JSONValue(_settings.activeFile);
            j.object["theme"] = JSONValue(_settings.theme);
            */
            auto jsonSettings = toJSON(_settings);

            wstring ws = jsonSettings.toString().toUTF16();
            resultView = ws;

            return true;
        }
        // ... (rest) ...

        // ... getLogCount, getLogItem etc ...

        if (method != "getSettings")
        { // Handled above
            // Helper lambdas
            auto getParamInt = (int index, int defaultValue = int.init) {
                int result = defaultValue;
                if (index < params.argc)
                {
                    SciterValueConstView valueView = SciterValueConstView(&params.argv[index]);
                    valueView.tryGet(result);
                }
                return result;
            };
            auto getParamBool = (int index, bool defaultValue = false) {
                bool result = defaultValue;
                if (index < params.argc)
                {
                    SciterValueConstView valueView = SciterValueConstView(&params.argv[index]);
                    valueView.tryGet(result);
                }
                return result;
            };
            auto getParamString = (int index, string defaultValue = string.init) {
                const(wchar)[] result = defaultValue.toUTF16();
                if (index < params.argc)
                {
                    SciterValueConstView valueView = SciterValueConstView(&params.argv[index]);
                    valueView.tryGet(result);
                }
                return result.toUTF8().idup;
            };

            if (method == "saveAppState")
            {
                const json = getParamString(0);
                writeln("saveAppState request: ", json);
                try
                {
                    ui.app_settings.saveSettings(applyUiState(_settings, json));
                }
                catch (Exception e)
                {
                    writeln("Failed to save settings: ", e.msg);
                }
                return true;
            }
            if (method == "getMainViewCount")
            {
                const int count = cast(int) _workspace.current.mainView.itemsCount();
                resultView = count;
                return true;
            }
            if (method == "getMainViewItem")
            {
                const int index = getParamInt(0);
                DocumentItem docItem;
                const auto res = _workspace.current.mainView.fetchItem(index, docItem);
                resultView.set(asSciterArray(index, docItem));

                return true;
            }
            if (method == "getSearchViewCount")
            {
                const int count = cast(int) _workspace.current.searchView.itemsCount();
                //writeln("getLogCount: ", count, " for doc: ", _workspace.currentId.toString());
                resultView = count;
                return true;
            }
            if (method == "getSearchViewItem")
            {
                const int index = getParamInt(0);
                DocumentItem docItem;
                const auto res = _workspace.current.searchView.fetchItem(index, docItem);
                resultView.set(asSciterArray(index, docItem));

                return true;
            }
            if (method == "openFile")
            {
                string path = getParamString(0);
                if (!path.empty)
                {
                    auto id = onFileSelected(normalizePath(path));
                    resultView = id.toInt();
                }
                return true;
            }
            if (method == "loadFibex")
            {
                string path = getParamString(0);
                if (!path.empty)
                    onLoadFibex(normalizePath(path));
                return true;
            }
            if (method == "applyFilter")
            {
                string json = getParamString(0);
                if (!json.empty)
                    onApplyFilter(json);
                return true;
            }
            if (method == "onTabClicked")
            {
                string tabId = getParamString(0);
                if (!tabId.empty)
                    onTabClicked(tabId);
                return true;
            }
            if (method == "loadDlf")
            {
                string path = getParamString(0);
                if (!path.empty)
                {
                    try
                    {
                        auto filter = new DltLogFilter!wchar();
                        filter.load(normalizePath(path));
                        _workspace.current.applySearchFilter(filter);
                        // @todo: return filter info to UI
                        /*
                        if (filters.length > 0)
                        {
                            auto f = filters[0];
                            JSONValue j = [
                                "ecuId": f.ecuId.value,
                                "appId": f.applicationId.value.asString(),
                                "ctxId": f.contextId.value.asString(),
                                "payloadRegex": f.payloadText.value.asString()
                            ];
                            resultView = j.toString().toUTF16();
                        }*/
                    }
                    catch (Exception e)
                    {
                        writeln("Error loading DLF: ", e.msg);
                    }
                }
                return true;
            }
            if (method == "getWorkspaceInfo")
            {
                JSONValue[] docs;
                foreach (idx, item; _workspace.documents)
                {
                    JSONValue d = [
                        "id": JSONValue(item.docId.toInt()),
                        "name": JSONValue(item.sourcePath.baseName),
                        "path": JSONValue(item.sourcePath),
                        "active": JSONValue(item.docId == _workspace.currentId),
                        "main": viewStatusJson(_workspace.doc(item.docId).mainView),
                        "search": viewStatusJson(_workspace.doc(item.docId).searchView)
                    ];
                    docs ~= d;
                }
                resultView = JSONValue(docs).toString().toUTF16();
                return true;
            }
            if (method == "cancelOperation")
            {
                // Cancels the running filter/search of the active document
                resultView = _workspace.current.requestCancel();
                return true;
            }
            if (method == "startSearch")
            {
                // startSearch(query, isRegex, caseInsensitive) -> error message, "" on success
                const query = getParamString(0);
                const isRegex = getParamBool(1);
                const caseInsensitive = getParamBool(2);
                resultView = onStartSearch(query, isRegex, caseInsensitive).toUTF16();
                return true;
            }
            if (method == "switchTab")
            {
                int id = getParamInt(0);
                auto oldId = _workspace.currentId;
                writeln("switchTab request: ", id, " (current: ", oldId.toInt(), ")");
                foreach (item; _workspace.documents)
                {
                    if (item.docId.toInt() == id)
                    {
                        _workspace.setCurrent(item.docId);
                        writeln("Workspace current changed to: ", id, " (", item.sourcePath.baseName, ")");
                        break;
                    }
                }
                return true;
            }
            if (method == "closeTab")
            {
                int id = getParamInt(0);
                foreach (item; _workspace.documents)
                {
                    if (item.docId.toInt() == id)
                    {
                        auto doc = _workspace.removeDocument(item.docId);
                        doc.destroy();
                        break;
                    }
                }
                return true;
            }
            if (method == "reorderTab")
            {
                int id = getParamInt(0);
                int targetIndex = getParamInt(1);
                writeln("reorderTab request: ", id, " to index ", targetIndex);
                foreach (item; _workspace.documents)
                {
                    if (item.docId.toInt() == id)
                    {
                        _workspace.moveDocumentBefore(item.docId, targetIndex);
                        writeln("Document reordered: ", id, " to index ", targetIndex);
                        break;
                    }
                }
                return true;
            }
        }

        return false;
    }

    private DocumentId onFileSelected(string path)
    {
        writeln("Opening file: ", path);
        try
        {
            writeln("Creating new document: ", path);
            auto newDoc = new DltDocument(path);
            auto docId = _workspace.addDocument(newDoc, path);
            _workspace.setCurrent(docId);
            callScript("onDocumentAdded", docId.toInt());
            return docId;
        }
        catch (Exception e)
        {
            writeln("Error opening file: ", e.msg);
            return DocumentId.init;
        }
    }

    // ... (rest of methods) ...
    private void onLoadFibex(string path)
    {
        try
        {
            //_workspace.current.openFibex(path);
            callScript("reloadLogTable");
        }
        catch (Exception e)
        {
            writeln("Error loading fibex: ", e.msg);
        }
    }

    /// Applies the quick filter of the main view:
    /// {"ecuId", "appId", "ctxId", "payloadRegex"}, all fields empty resets it.
    private void onApplyFilter(string json)
    {
        try
        {
            auto j = parseJSON(json);
            string field(string key)
            {
                auto p = key in j;
                return p && p.type == JSONType.string ? p.str : "";
            }

            auto filter = quickFilter!wchar(field("ecuId"), field("appId"), field("ctxId"),
                field("payloadRegex"));
            writeln("Applying view filter: ", filter is null ? "none" : json);
            _workspace.current.applyViewFilter(filter); // null resets the filter
        }
        catch (Exception e)
        {
            writeln("Error applying filter: ", e.msg);
        }
    }

    /// Starts the search in the active document; an empty query clears it.
    /// Returns: an error message for the UI, or "" if the search was started
    private string onStartSearch(string query, bool isRegex, bool caseInsensitive)
    {
        writeln("startSearch request: '", query, "' regex: ", isRegex, " ignore case: ", caseInsensitive);
        try
        {
            // An invalid regex throws here, before any background work starts
            auto filter = SearchFilter.fromQuery(query, isRegex, caseInsensitive);
            _workspace.current.applySearchFilter(filter); // null clears the search
            return "";
        }
        catch (Exception e)
        {
            writeln("Error starting search: ", e.msg);
            return e.msg;
        }
    }

    private void onTabClicked(string id)
    {
        writeln("Tab clicked: ", id);
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

    AppSettings fetchSettingsFromUi() const
    {
        const auto appState = callScript("getAppState");
        const auto json = appState.to!(const(wchar)[])().toUTF8();
        writeln("Fetching settings from UI, json: ", json);
        return applyUiState(_settings, json);
    }

    /// Merges UI state JSON (produced by JS getAppState()) into a copy of settings.
    static AppSettings applyUiState(const AppSettings base, const(char)[] json)
    {
        AppSettings settings = base;
        try
        {
            auto j = parseJSON(json);

            // window rect
            /*{
                const winRc = getPlacement();
                settings.windowRect.left = winRc.left;
                settings.windowRect.top = winRc.top;
                settings.windowRect.width = winRc.right - winRc.left;
                settings.windowRect.height = winRc.bottom - winRc.top;

                writeln("windowRect: ", settings.windowRect);
            }*/

            if ("windowRect" in j)
            {
                auto r = j["windowRect"];
                settings.windowRect.left = r["left"].integer.to!int;
                settings.windowRect.top = r["top"].integer.to!int;
                settings.windowRect.width = r["width"].integer.to!int;
                settings.windowRect.height = r["height"].integer.to!int;
            }

            // Get active file scroll pos
            int scroll = 0;
            if ("scrollPosition" in j)
            {
                scroll = j["scrollPosition"].integer.to!int;
            }

            // Update scroll for active file
            if (settings.activeFile.length > 0)
            {
                foreach (ref f; settings.files)
                {
                    if (f.path == settings.activeFile)
                    {
                        f.scrollPosition = scroll;
                        break;
                    }
                }
            }
        }
        catch (Exception e)
        {
            writeln("Error parsing UI settings: ", e.msg);
        }

        // if we wanted to trust JS for activeFile:
        // if ("activeFile" in j) _settings.activeFile = j["activeFile"].str;

        return settings;
    }

    void saveSettings() const
    {
        try
        {
            auto settings = fetchSettingsFromUi();
            ui.app_settings.saveSettings(settings);
        }
        catch (Exception e)
        {
            writeln("Failed to call getSettings() ", e.msg);
        }
    }

    /// Closes all documents, stopping their background operations.
    /// Call after the event loop has stopped.
    void closeAllDocuments()
    {
        _workspace.closeAll();
    }

    // should be called in main() in sciterApplication().runIteration() cycle
    void onIdle()
    {
        fixMacTitlebarBackground();
        processCurrentDocumentState();
    }

    void processCurrentDocumentState()
    {
        try
            _workspace.dispatchEvents();
        catch (Exception e)
        {
            for (Throwable t = e; t !is null; t = t.next)
                writeln("Document event handler failed: ", t.msg);
        }
    }
}

SciterValue asSciterArray(int index, ref const(LogItem) item)
{
    /** 
     size_t index;
    ulong offset;
    ushort length;
    ulong timestamp;
    string ecu;
    string appId;
    string ctxId;
    LogLevel level;
    MessageType type;
    uint messageId;
    string payload;
 */

    SciterValue array = SciterValue.makeArray(
        index, //
        item.timestamp, //
        item.ecu, //
        item.appId, //
        item.ctxId, //
        item.messageId, //
        cast(int) item.level, //
        cast(int) item.type, //
        item.payload //

        

    );
    return array;
}

SciterValue asSciterArray(int index, ref const(DocumentItem) item)
{
    /** 
     size_t index;
    ulong offset;
    ushort length;
    ulong timestamp;
    string ecu;
    string appId;
    string ctxId;
    LogLevel level;
    MessageType type;
    uint messageId;
    string payload;
 */

    // index, time, timestamp(rel), ecuId, appId, ctxId, level, type, (messageId), payload

    SciterValue array = SciterValue.makeArray(
        item.anchored, //
        item.filterMask, //
        index,
        item.realIndex, //
        item.timestampSeconds, //
        item.timestampMicroseconds, //
        item.relativeTimestamp_10000, //
        item.ecuId, //
        item.appId, //
        item.ctxId, //
        cast(int) item.level, //
        cast(int) item.type, //
        item.messageId, //
        item.payload //

        

    );
    return array;
}
