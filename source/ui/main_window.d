module ui.main_window;

import sciter_wrapper.sciter_window;
import sciter_wrapper.sciter_value;
import ui.app_settings;

import domain.workspace;
import domain.document_id;
import domain.document;
import domain.document_item;
import domain.dlt_document;

import dlt_core.dlt_filter_serialization;
import dlt_core.dlt_filter_record;
import dlt_core.dlt_log_filter : DltLogFilter, quickFilter;
import domain.search_filter : SearchFilter;
import ui.main_view_fsm;
import ui.search_view_fsm;
import dlt_core.log_filter : LogFilter;

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

/// UI side of one document: the machines of its main and search views and the
/// views they show. Lives as long as its document; a reopened document gets a new one.
private final class DocumentUi : MainViewSink, MainViewCommands, SearchViewSink, SearchViewCommands
{
    private Workspace _workspace;
    private DocumentId _docId;
    private MainViewFsm _mainView;
    private SearchViewFsm _searchView;

    MainViewModel mainViewShown; // the latest view shown by the machine
    bool mainViewChanged; // shown since it was last sent to JS
    SearchViewModel searchViewShown; // likewise for the search view
    bool searchViewChanged;
    bool closeRequested; // the machine asked to close the document

    this(Workspace workspace, DocumentId docId)
    {
        _workspace = workspace;
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

    void pressMainCancel()
    {
        _mainView.process(CancelPressed());
    }

    void pressSearchCancel()
    {
        _searchView.process(SearchCancelPressed());
    }

    void show(in MainViewModel vm)
    {
        mainViewShown = vm;
        mainViewChanged = true;
    }

    void show(in SearchViewModel vm)
    {
        searchViewShown = vm;
        searchViewChanged = true;
    }

    // Only one operation runs at a time, and each machine handles Cancel only
    // while its own operation runs: requestCancel() stops just that one
    bool cancelOperation()
    {
        return _workspace.doc(_docId).requestCancel();
    }

    bool cancelSearch()
    {
        return _workspace.doc(_docId).requestCancel();
    }

    void closeDocument()
    {
        closeRequested = true; // done by MainWindow.applyDocumentCommands()
    }
}

class MainWindow : SciterWindow
{
    private AppSettings _settings;
    private Workspace _workspace;
    private DocumentUi[DocumentId] _documentUis;

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

    /// Feeds document events to the machines of the documents; their views
    /// reach JS from onIdle(), see flushViews()
    private void subscribeToDocumentEvents()
    {
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
                e.event.error.length ? ": " ~ e.event.error : "");
            processDocumentEvent(e.docId, e.event);
        });
    }

    private void processDocumentEvent(E)(DocumentId docId, in E e)
    {
        if (auto ui = _documentUis.get(docId, null))
            ui.process(e);
    }

    /// Sends the views changed since the last call to JS:
    /// onMainViewChanged(docId, json) and onSearchViewChanged(docId, json),
    /// json is toJson of ui.main_view_fsm and ui.search_view_fsm
    private void flushViews()
    {
        foreach (docId, ui; _documentUis)
        {
            if (ui.mainViewChanged)
            {
                ui.mainViewChanged = false;
                callScript("onMainViewChanged", docId.toInt(), toJson(ui.mainViewShown).toString().toUTF16());
            }
            if (ui.searchViewChanged)
            {
                ui.searchViewChanged = false;
                callScript("onSearchViewChanged", docId.toInt(), toJson(ui.searchViewShown).toString().toUTF16());
            }
        }
    }

    /// Carries out what the machines asked for. Not called from their handlers:
    /// a document must not be destroyed while its events are being dispatched.
    private void applyDocumentCommands()
    {
        DocumentId[] toClose;
        foreach (docId, ui; _documentUis)
            if (ui.closeRequested)
                toClose ~= docId;

        foreach (docId; toClose)
        {
            writeln("Closing document ", docId.toInt(), " on request of its view");
            closeDocument(docId);
            callScript("onDocumentClosed", docId.toInt());
        }
    }

    private void addDocumentUi(DocumentId docId)
    {
        _documentUis[docId] = new DocumentUi(_workspace, docId);
    }

    private void closeDocument(DocumentId docId)
    {
        _documentUis.remove(docId);
        auto doc = _workspace.removeDocument(docId);
        if (doc !is null)
            doc.destroy();
    }

    /// Returns: the id of the open document `id`, invalid if there is none
    private DocumentId findDocumentId(int id)
    {
        foreach (item; _workspace.documents)
            if (item.docId.toInt() == id)
                return item.docId;
        return DocumentId.init;
    }

    /// The view shown by the main view machine of the document, see ui.main_view_fsm.toJson
    private JSONValue mainViewJson(DocumentId docId)
    {
        auto ui = _documentUis.get(docId, null);
        return ui is null ? JSONValue(null) : toJson(ui.mainViewShown);
    }

    /// The view shown by the search view machine of the document, see ui.search_view_fsm.toJson
    private JSONValue searchViewJson(DocumentId docId)
    {
        auto ui = _documentUis.get(docId, null);
        return ui is null ? JSONValue(null) : toJson(ui.searchViewShown);
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
                        "mainView": mainViewJson(item.docId),
                        "searchView": searchViewJson(item.docId)
                    ];
                    docs ~= d;
                }
                resultView = JSONValue(docs).toString().toUTF16();
                return true;
            }
            if (method == "setAnchor")
            {
                // setAnchor(messageIndex, value) -> true if changed; false while an
                // operation is running or at the anchor limit (nothing changes then)
                const index = getParamInt(0);
                resultView = index >= 0 && _workspace.current.setAnchor(cast(size_t) index, getParamBool(1));
                return true;
            }
            if (method == "cancelMainView")
            {
                // cancelMainView(docId): Cancel pressed in the main view of the
                // document; its machine decides what it means
                if (auto ui = _documentUis.get(findDocumentId(getParamInt(0)), null))
                {
                    ui.pressMainCancel();
                    applyDocumentCommands();
                }
                return true;
            }
            if (method == "cancelSearchView")
            {
                // cancelSearchView(docId): Cancel pressed in the search view of the document
                if (auto ui = _documentUis.get(findDocumentId(getParamInt(0)), null))
                    ui.pressSearchCancel();
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
            if (method == "retryDocument")
            {
                // retryDocument(docId) -> error message, "" if the file was reopened
                resultView = onRetryDocument(getParamInt(0)).toUTF16();
                return true;
            }
            if (method == "closeTab")
            {
                const docId = findDocumentId(getParamInt(0));
                if (docId.isValid)
                    closeDocument(docId);
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

    /// Reopens the file of a document whose source was lost, in the same tab.
    /// Returns: an error message for the UI (e.g. the disk is still missing),
    /// or "" if the document was replaced by a freshly opened one
    private string onRetryDocument(int id)
    {
        DocumentId docId;
        string path;
        foreach (item; _workspace.documents)
        {
            if (item.docId.toInt() == id)
            {
                docId = item.docId;
                path = item.sourcePath;
            }
        }
        if (!docId.isValid)
            return "the document is not open";

        try
        {
            import core.time : MonoTime;

            // Timings: both steps run on the UI thread and may block on a disk
            // that has just been reconnected or removed
            const openStart = MonoTime.currTime;
            auto fresh = new DltDocument(path);
            const openTime = MonoTime.currTime - openStart;

            const destroyStart = MonoTime.currTime;
            auto old = _workspace.replaceDocument(docId, fresh);
            addDocumentUi(docId); // the new document starts with a new machine
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
            return e.msg;
        }
    }

    private DocumentId onFileSelected(string path)
    {
        writeln("Opening file: ", path);
        try
        {
            writeln("Creating new document: ", path);
            auto newDoc = new DltDocument(path);
            auto docId = _workspace.addDocument(newDoc, path);
            addDocumentUi(docId);
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

            // Preferences changed in the Settings dialog
            if ("theme" in j)
                settings.theme = j["theme"].str;
            if ("tableFontSize" in j)
                settings.tableFontSize = j["tableFontSize"].integer.to!int;

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
        _documentUis = null;
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
        applyDocumentCommands();
        flushViews();
    }
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
