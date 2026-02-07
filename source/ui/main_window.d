module ui.main_window;

import sciter_wrapper.sciter_window;
import sciter_wrapper.sciter_value;
import ui.app_settings;

import sciter.types;
import sciter.behavior;

import std.utf : toUTF8, toUTF16;
import std.string : fromStringz;
import std.array : empty;
import std.algorithm;
import std.stdio;
import std.json;
import std.conv : to;

import dlt_core.indexer;
import dlt_core.search;
import dlt_core.fibex;

class MainWindow : SciterWindow
{
    private SearchEngine _searchEngine;
    private FibexParser _fibexParser;
    private Indexer _currentIndexer;
    private FilterConfig _currentConfig;
    private AppSettings _settings;

    this(AppSettings settings)
    {
        _settings = settings;
        import sciter.def;

        enum uint creationFlags =
            SCITER_CREATE_WINDOW_FLAGS.SW_MAIN;

        RECT frame;
        frame.left = settings.windowRect.left;
        frame.top = settings.windowRect.top;
        frame.right = settings.windowRect.right;
        frame.bottom = settings.windowRect.bottom;

        super(creationFlags, frame);

        // Disable extended touchpad support on Mac to prevent gesture-related crashes
        _api.SciterSetOption(hwnd, 19 /*SCITER_EXTENDED_TOUCHPAD_SUPPORT*/ , 0);
    }

    override bool handleEvent(HELEMENT he, INITIALIZATION_PARAMS* params)
    {
        if (params.cmd == INITIALIZATION_EVENTS.BEHAVIOR_DETACH)
        {
            writeln("BEHAVIOR_DETACH");
            saveSettings();
        }

        return false;
    }

    override bool handleEvent(HELEMENT he, BEHAVIOR_EVENT_PARAMS* params)
    {
        /*if (params.cmd == BEHAVIOR_EVENTS.DOCUMENT_CLOSE)
        {
            writeln("DOCUMENT_CLOSE_REQUEST");
            saveSettings();
            return false; // Let it continue closing
        }*/

        const(wchar)[] eventName = fromStringz(params.name);

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

        // ... getLogCount, getLogItems etc ...

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

            if (method == "getLogCount")
            {
                const int count = _searchEngine ? cast(int) _searchEngine.getLogCount() : 0;
                resultView = count;
                return true;
            }
            if (method == "getLogItems")
            {
                int start = getParamInt(0);
                int count = getParamInt(1, 10);
                string s = _searchEngine ? _searchEngine.getLogItemsAsJson(start, count) : "[]";
                import std.utf : toUTF16;

                wstring ws = toUTF16(s);
                resultView = ws;
                return true;
            }
            if (method == "getLogItem")
            {
                int index = getParamInt(0);
                string s = _searchEngine ? _searchEngine.getLogItemAsJson(
                    index) : "{}"; // Assuming implementation exists or using existing
                import std.utf : toUTF16;

                wstring ws = toUTF16(s);
                resultView = ws;
                return true;
            }
            if (method == "openFile")
            {
                string path = getParamString(0);
                if (!path.empty)
                    onFileSelected(normalizePath(path));
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
        }

        return false;
    }

    /*bool onVirtualListGetItem(uint index, out SCITER_VIRTUAL_LIST_ITEM item)
    {
        item.text = "Item " ~ to!string(index);
        item.value = index;
        return true;
    }*/

    private void onFileSelected(string path)
    {
        writeln("Opening file: ", path);
        try
        {
            _currentIndexer = new Indexer(path);
            _currentIndexer.scan();
            _searchEngine = new SearchEngine(_currentIndexer);
            _searchEngine._fibex = this._fibexParser;
            writeln("Indexed messages: ", _currentIndexer.totalMessages);

            saveSettings();
        }
        catch (Exception e)
        {
            writeln("Error indexing: ", e.msg);
        }
    }

    // ... (rest of methods) ...
    private void onLoadFibex(string path)
    {
        try
        {
            _fibexParser = new FibexParser();
            _fibexParser.load(path);
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
            auto j = parseJSON(json);
            FilterConfig c;
            c.ecuId = j["ecuId"].str;
            c.appId = j["appId"].str;
            c.ctxId = j["ctxId"].str;
            c.payloadRegex = j["payloadRegex"].str;
            if (_searchEngine)
                _searchEngine.applyFilter(c);
        }
        catch (Exception e)
        {
            writeln("Error applying filter: ", e.msg);
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
}
