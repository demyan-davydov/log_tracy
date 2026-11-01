module ui.main_window;

import sciter_wrapper.sciter_window;
import sciter_wrapper.sciter_value;
import ui.app_settings;

//import ui.workspace;
//import ui.dlt_document;
//import ui.document_id;

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
import dlt_core.dlt_log_filter : DltLogFilter;
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
    }

    override void handleAttached(HELEMENT he)
    {
        writeln("handleAttached");
    }

    override void handleDetached(HELEMENT he)
    {
        writeln("handleDetached");
        saveSettings();
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
            auto getParamString = (int index, string defaultValue = string.init) {
                const(wchar)[] result = defaultValue.toUTF16();
                if (index < params.argc)
                {
                    SciterValueConstView valueView = SciterValueConstView(&params.argv[index]);
                    valueView.tryGet(result);
                }
                return result.toUTF8().idup;
            };

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
                        "active": JSONValue(item.docId == _workspace.currentId)
                    ];
                    docs ~= d;
                }
                resultView = JSONValue(docs).toString().toUTF16();
                return true;
            }
            if (method == "getDocProgress")
            {
                resultView = _workspace.current.mainView.progress();
                return true;
            }
            if (method == "isDocReady")
            {
                resultView = _workspace.current.mainView.ready();
                return true;
            }
            if (method == "getSearchProgress")
            {
                resultView = _workspace.current.searchView.progress();
                return true;
            }
            if (method == "isSearchReady")
            {
                resultView = _workspace.current.searchView.ready();
                return true;
            }
            if (method == "startSearch")
            {
                string regex = getParamString(0);
                writeln("startSearch request: ", regex);
                onStartSearch(regex);
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

    private void onApplyFilter(string json)
    {
        try
        {
            // @todo: implementation
            return;

            //auto j = parseJSON(json);
            //DlfLogFilter c = new DlfLogFilter();
            //c.load(json);

            //_workspace.current.applyFilter(c);
        }
        catch (Exception e)
        {
            writeln("Error applying filter: ", e.msg);
        }
    }

    private void onStartSearch(string regexStr)
    {
        try
        {
            writeln("Starting search with regex: ", regexStr);
            auto filter = new SearchFilter();
            //filter.addRegex(regexStr);
            filter.addCaseInsensetive("THEW"); // for test
            filter.addCaseSensetive("encryptPayload"); // for test

            _workspace.current.applySearchFilter(filter);
        }
        catch (Exception e)
        {
            writeln("Error starting search: ", e.msg);
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
        AppSettings settings = _settings;

        const auto appState = callScript("getAppState");
        const auto json = appState.to!(const(wchar)[])().toUTF8();
        writeln("Fetching settings from UI, json: ", json);

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

    // should be called in main() in sciterApplication().runIteration() cycle
    void onIdle()
    {
        fixMacTitlebarBackground();
        processCurrentDocumentState();
    }

    void processCurrentDocumentState()
    {
        if (_workspace.current !is null)
        {
            //_workspace.current.processState();
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
