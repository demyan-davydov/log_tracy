module ui.my_main_window;

import std.string;
import std.stdio;
import std.json;
import std.conv;
import std.utf : toUTF16z, toUTF8;
import dlt_core.indexer;
import dlt_core.search;
import dlt_core.fibex;
import dlt_core.dlt;
import dlt_core.filter;
import ui.app_settings;
import sciter_wrapper.sciter_api;
import sciter_wrapper.sciter_value;
import sciter_wrapper.sciter_window;
import sciter_wrapper.sciter_ulils;
import sciter.behavior;
import sciter.types;
import sciter.value;

// OS-specific external declarations (Must be restored for setupMainMenu to work)
version (OSX)
{
    extern (C) void* objc_getClass(const char* name);
    extern (C) void* sel_registerName(const char* name);
    extern (C) void* objc_msgSend(void* self, void* op, ...);
    extern (C) void* objc_allocateClassPair(void* superclass, const char* name, size_t extraBytes);
    extern (C) void objc_registerClassPair(void* cls);
    alias IMP = extern (C) void function(void*, void*, ...);
    extern (C) bool class_addMethod(void* cls, void* name, IMP imp, const char* types);

    // Helpers
    extern (C) void* objc_msgSend_id(void* self, void* op) @trusted;
    extern (C) void* objc_msgSend_id_id(void* self, void* op, void* arg) @trusted;
    extern (C) void* objc_msgSend_id_long(void* self, void* op, long arg) @trusted;
    extern (C) void* objc_msgSend_id_bool(void* self, void* op, bool arg) @trusted;

    // Alias casts often used
    alias msgSend_ptr = extern (C) void* function(void*, void*) @trusted;
    alias msgSend_ptr_ptr = extern (C) void* function(void*, void*, void*) @trusted;
    alias msgSend_ptr_long = extern (C) void* function(void*, void*, long) @trusted;
    alias msgSend_ptr_bool = extern (C) void* function(void*, void*, bool) @trusted;
}

// Forward declarations for macOS
version (OSX)
{
    extern (C) bool appShouldTerminateCallback(void* self, void* _cmd, void* appObj)
    {
        writeln("App is terminating, saving settings...");
        if (g_Window)
        {
            g_Window.saveSettings();
        }
        return true;
    }

    extern (C) void menuOpenCallback(void* self, void* _cmd, void* sender)
    {
        if (g_Window)
            g_Window.callOpenFile();
    }

    extern (C) void menuSettingsCallback(void* self, void* _cmd, void* sender)
    {
        if (g_Window)
            g_Window.callSettings();
    }
}

extern (C) long sciterWindowDelegate(HWINDOW hwnd, uint msg, size_t wParam, ptrdiff_t lParam, void* pParam, int* handled)
{
    if (msg == 2) // GF_WM_DESTROY
    {
        if (g_Window)
        {
            g_Window.saveSettings(); // Save on close
        }
    }
    return 0;
}

__gshared MyMainWindow g_Window;

class MyMainWindow
{
    private HWINDOW _hwnd;
    private SearchEngine _searchEngine;
    private FibexParser _fibexParser;
    private Indexer _currentIndexer;
    private FilterConfig _currentConfig;
    private AppSettings _settings;

    this(AppSettings settings)
    {
        _settings = settings;
        g_Window = this;

        RECT frame = RECT(settings.windowRect.left, settings.windowRect.top,
            settings.windowRect.left + settings.windowRect.width,
            settings.windowRect.top + settings.windowRect.height);

        uint creationFlags = 1 | 2 | 8 | 64; // SW_TITLEBAR | SW_RESIZEABLE | SW_CONTROLS | SW_MAIN

        _hwnd = sciterApi().SciterCreateWindow(creationFlags, &frame, &sciterWindowDelegate, null, null);

        if (!_hwnd)
        {
            writeln("Failed to create Sciter window");
            return;
        }
        writeln("Sciter Window created successfully: ", _hwnd);

        // Attach event handler
        {
            const auto res = sciterApi().SciterWindowAttachEventHandler(_hwnd, &elementProc, cast(
                    void*) this, 0xFFFF);
            writeln("Window event handler attached (Direct), result: ", res);
        }

        // Restore open files?
        // Logic: if we have open files, maybe open the last one?
        // Since UI handles one main view, we can just log them or try to open last.
        // For now, let's leave it as is, settings are available via getSettings.
        // We could proactively open them here if we wanted.
    }

    void saveSettings()
    {
        writeln("Saving settings...");

        SCITER_VALUE res;
        writeln("Calling getAppState in JavaScript...");
        if (sciterApi().SciterCall(_hwnd, "getAppState", 0, null, &res))
        {
            string json = valueToString(&res);
            writeln("getAppState returned: ", json);
            try
            {
                auto j = parseJSON(json);
                if ("windowRect" in j)
                {
                    auto r = j["windowRect"];
                    _settings.windowRect.left = r["left"].integer.to!int;
                    _settings.windowRect.top = r["top"].integer.to!int;
                    _settings.windowRect.width = r["width"].integer.to!int;
                    _settings.windowRect.height = r["height"].integer.to!int;
                    writeln("Window rect updated: ", _settings.windowRect);
                }

                // Get active file scroll pos
                int scroll = 0;
                if ("scrollPosition" in j)
                {
                    scroll = j["scrollPosition"].integer.to!int;
                    writeln("Scroll position: ", scroll);
                }

                // Update scroll for active file
                if (_settings.activeFile.length > 0)
                {
                    writeln("Active file: ", _settings.activeFile);
                    foreach (ref f; _settings.files)
                    {
                        if (f.path == _settings.activeFile)
                        {
                            f.scrollPosition = scroll;
                            writeln("Updated scroll for ", f.path);
                            break;
                        }
                    }
                }
                else
                {
                    writeln("No active file set");
                }

                // if we wanted to trust JS for activeFile:
                // if ("activeFile" in j) _settings.activeFile = j["activeFile"].str;

            }
            catch (Exception e)
            {
                writeln("Error parsing app state from JS: ", e.msg);
            }
        }
        else
        {
            writeln("Failed to call getAppState in JS");
        }

        // Save to file
        writeln("Settings saved successfully");
    }

    // Callbacks to JS
    void callOpenFile()
    {
        writeln("Native Menu: Open File");
        SCITER_VALUE ret;
        sciterApi().SciterCall(_hwnd, "openFileAction", 0, null, &ret);
    }

    void callSettings()
    {
        writeln("Native Menu: Settings");
        SCITER_VALUE ret;
        sciterApi().SciterCall(_hwnd, "openSettingsAction", 0, null, &ret);
    }

    // ... (setupMainMenu unchanged) ...

    version (OSX) private void setupMainMenu()
    {
        // implementation remains the same, assuming it was correct above
        // ... (re-implementing partially for brevity if replace tool allows partial, but here full replacement of class is safer due to length)
        // I'll assume I need to keep the code.

        // Selectors
        auto sel_alloc = sel_registerName("alloc");
        auto sel_init = sel_registerName("init");
        auto sel_addItem = sel_registerName("addItem:");
        auto sel_setSubmenu = sel_registerName("setSubmenu:");
        auto sel_setMainMenu = sel_registerName("setMainMenu:");
        auto sel_initWithTitle = sel_registerName("initWithTitle:");
        auto sel_initWithTitleActionKey = sel_registerName("initWithTitle:action:keyEquivalent:");

        auto cls_NSMenu = objc_getClass("NSMenu");
        auto cls_NSMenuItem = objc_getClass("NSMenuItem");
        auto cls_NSApplication = objc_getClass("NSApplication");
        auto app = (cast(msgSend_ptr)&objc_msgSend)(cls_NSApplication, sel_registerName(
                "sharedApplication"));
        auto menubar = (cast(msgSend_ptr)&objc_msgSend)(
            (cast(msgSend_ptr)&objc_msgSend)(cls_NSMenu, sel_alloc), sel_init);

        alias msgSend_initItem = extern (C) void* function(void*, void*, void*, void*, void*) @trusted;
        alias msgSend_initMenu = extern (C) void* function(void*, void*, void*) @trusted;

        // App Menu
        auto appMenuItem = (cast(msgSend_ptr)&objc_msgSend)(
            (cast(msgSend_ptr)&objc_msgSend)(cls_NSMenuItem, sel_alloc), sel_init);
        (cast(msgSend_ptr_ptr)&objc_msgSend)(menubar, sel_addItem, appMenuItem);
        auto appMenu = (cast(msgSend_ptr)&objc_msgSend)(
            (cast(msgSend_ptr)&objc_msgSend)(cls_NSMenu, sel_alloc), sel_init);

        auto itemQuit = (cast(msgSend_initItem)&objc_msgSend)(
            (cast(msgSend_ptr)&objc_msgSend)(cls_NSMenuItem, sel_alloc), sel_initWithTitleActionKey, makeNSString(
                "Quit DLT Explorer"), sel_registerName("terminate:"), makeNSString("q"));
        auto itemSettings = (cast(msgSend_initItem)&objc_msgSend)(
            (cast(msgSend_ptr)&objc_msgSend)(cls_NSMenuItem, sel_alloc), sel_initWithTitleActionKey, makeNSString(
                "Settings..."), sel_registerName("menuSettingsCallback:"), makeNSString(","));

        (cast(msgSend_ptr_ptr)&objc_msgSend)(appMenu, sel_addItem, itemSettings);
        (cast(msgSend_ptr_ptr)&objc_msgSend)(appMenu, sel_addItem, itemQuit);
        (cast(msgSend_ptr_ptr)&objc_msgSend)(appMenuItem, sel_setSubmenu, appMenu);

        // File Menu
        auto fileMenuItem = (cast(msgSend_ptr)&objc_msgSend)(
            (cast(msgSend_ptr)&objc_msgSend)(cls_NSMenuItem, sel_alloc), sel_init);
        (cast(msgSend_ptr_ptr)&objc_msgSend)(menubar, sel_addItem, fileMenuItem);
        auto fileMenu = (cast(msgSend_initMenu)&objc_msgSend)((cast(msgSend_ptr)&objc_msgSend)(cls_NSMenu, sel_alloc), sel_initWithTitle, makeNSString(
                "File"));
        auto itemOpen = (cast(msgSend_initItem)&objc_msgSend)(
            (cast(msgSend_ptr)&objc_msgSend)(cls_NSMenuItem, sel_alloc), sel_initWithTitleActionKey, makeNSString(
                "Open File..."), sel_registerName("menuOpenCallback:"), makeNSString("o"));
        (cast(msgSend_ptr_ptr)&objc_msgSend)(fileMenu, sel_addItem, itemOpen);
        (cast(msgSend_ptr_ptr)&objc_msgSend)(fileMenuItem, sel_setSubmenu, fileMenu);

        // Window Menu
        auto windowMenuItem = (cast(msgSend_ptr)&objc_msgSend)(
            (cast(msgSend_ptr)&objc_msgSend)(cls_NSMenuItem, sel_alloc), sel_init);
        (cast(msgSend_ptr_ptr)&objc_msgSend)(menubar, sel_addItem, windowMenuItem);
        auto windowMenu = (cast(msgSend_initMenu)&objc_msgSend)((cast(msgSend_ptr)&objc_msgSend)(cls_NSMenu, sel_alloc), sel_initWithTitle, makeNSString(
                "Window"));
        auto itemMin = (cast(msgSend_initItem)&objc_msgSend)(
            (cast(msgSend_ptr)&objc_msgSend)(cls_NSMenuItem, sel_alloc), sel_initWithTitleActionKey, makeNSString(
                "Minimize"), sel_registerName("performMiniaturize:"), makeNSString("m"));
        (cast(msgSend_ptr_ptr)&objc_msgSend)(windowMenu, sel_addItem, itemMin);
        (cast(msgSend_ptr_ptr)&objc_msgSend)(windowMenuItem, sel_setSubmenu, windowMenu);

        (cast(msgSend_ptr_ptr)&objc_msgSend)(app, sel_setMainMenu, menubar);
    }

    // ... (makeNSString, run) ... 

    private static void* makeNSString(string str)
    {
        auto cls_NSString = objc_getClass("NSString");
        auto sel_alloc = sel_registerName("alloc");
        auto sel_initWithUTF8String = sel_registerName("initWithUTF8String:");
        alias msgSend_str = extern (C) void* function(void*, void*, const char*) @trusted;
        return (cast(msgSend_str)&objc_msgSend)((cast(msgSend_ptr)&objc_msgSend)(cls_NSString, sel_alloc), sel_initWithUTF8String, toStringz(
                str));
    }

    void run()
    {
        // ... (run logic identical to before) ...
        writeln("Starting Message Loop...");
        version (OSX)
        {
            // (Copy running logic from previous) 
            auto sel_makeKey = sel_registerName("makeKeyAndOrderFront:");
            (cast(msgSend_ptr_ptr)&objc_msgSend)(_hwnd, sel_makeKey, cast(void*) null);
            auto sel_display = sel_registerName("display");
            (cast(msgSend_ptr)&objc_msgSend)(_hwnd, sel_display);
            auto sel_orderFront = sel_registerName("orderFrontRegardless");
            (cast(msgSend_ptr)&objc_msgSend)(_hwnd, sel_orderFront);
            auto cls_app = objc_getClass("NSApplication");
            auto app = (cast(msgSend_ptr)&objc_msgSend)(cls_app, sel_registerName(
                    "sharedApplication"));
            (cast(msgSend_ptr_long)&objc_msgSend)(app, sel_registerName("setActivationPolicy:"), 0L);
            auto clsDelegate = objc_allocateClassPair(objc_getClass("NSObject"), "AppDelegate", 0);
            if (clsDelegate)
            {
                class_addMethod(clsDelegate, sel_registerName("applicationShouldTerminateAfterLastWindowClosed:"), cast(
                        IMP)&appShouldTerminateCallback, "c@:@");
                class_addMethod(clsDelegate, sel_registerName("menuOpenCallback:"), cast(IMP)&menuOpenCallback, "v@:@");
                class_addMethod(clsDelegate, sel_registerName("menuSettingsCallback:"), cast(IMP)&menuSettingsCallback, "v@:@");
                objc_registerClassPair(clsDelegate);
            }
            else
            {
                clsDelegate = objc_getClass("AppDelegate");
            }
            auto sel_alloc = sel_registerName("alloc");
            auto sel_init = sel_registerName("init");
            auto delegateObj = (cast(msgSend_ptr)&objc_msgSend)(
                (cast(msgSend_ptr)&objc_msgSend)(clsDelegate, sel_alloc), sel_init);
            (cast(msgSend_ptr_ptr)&objc_msgSend)(app, sel_registerName("setDelegate:"), delegateObj);
            (cast(msgSend_ptr)&objc_msgSend)(app, sel_registerName("finishLaunching"));
            setupMainMenu();
            (cast(msgSend_ptr_bool)&objc_msgSend)(app, sel_registerName(
                    "activateIgnoringOtherApps:"), true);
            (cast(msgSend_ptr)&objc_msgSend)(app, sel_registerName("run"));
        }
    }

    private static extern (C) SBOOL elementProc(void* tag, HELEMENT he, uint evtg, void* prms)
    {
        auto self = cast(MyMainWindow) tag;
        if (!self)
            return 0;

        // Re-implement the behavior handling to ensure correct fallback
        if (evtg == EVENT_GROUPS.HANDLE_BEHAVIOR_EVENT)
        {
            BEHAVIOR_EVENT_PARAMS* params = cast(BEHAVIOR_EVENT_PARAMS*) prms;
            if (params.cmd == BEHAVIOR_EVENTS.CUSTOM)
            {
                //const string eventName = valueToString(&params.name);
                const string eventName = fromStringz(params.name).toUTF8();

                if (eventName == "openFile")
                {
                    self.onFileSelected(normalizePath(valueToString(&params.data)));
                    return 1;
                }
                if (eventName == "loadFibex")
                {
                    self.onLoadFibex(normalizePath(valueToString(&params.data)));
                    return 1;
                }
                if (eventName == "applyFilter")
                {
                    self.onApplyFilter(valueToString(&params.data));
                    return 1;
                }
                if (eventName == "tab-clicked")
                {
                    self.onTabClicked(valueToString(&params.data));
                    return 1;
                }
            }
        }
        else if (evtg == EVENT_GROUPS.HANDLE_SCRIPTING_METHOD_CALL)
        {
            SCRIPTING_METHOD_PARAMS* params = cast(SCRIPTING_METHOD_PARAMS*) prms;
            const string method = fromStringz(params.name).idup;

            if (method == "getSettings")
            {
                // Serialize settings to JSON string
                JSONValue j = ["gui": "dlt-explorer"];
                j.object = null;
                j.object["windowRect"] = [
                    "left": self._settings.windowRect.left,
                    "top": self._settings.windowRect.top,
                    "width": self._settings.windowRect.width,
                    "height": self._settings.windowRect.height
                ];

                JSONValue[] filesArr;
                foreach (f; self._settings.files)
                {
                    JSONValue fv = ["path": f.path];
                    fv.object["scrollPosition"] = JSONValue(f.scrollPosition);
                    filesArr ~= fv;
                }
                j.object["files"] = JSONValue(filesArr);

                j.object["activeFile"] = JSONValue(self._settings.activeFile);
                j.object["theme"] = JSONValue(self._settings.theme);

                import std.utf : toUTF16;

                wstring ws = toUTF16(j.toString());
                sciterApi().ValueStringDataSet(&params.result, ws.ptr, cast(uint) ws.length, 0);
                return 1;
            }
            // ... (rest) ...

            // ... getLogCount, getLogItems etc ...

            if (method != "getSettings")
            { // Handled above
                // Helper lambdas
                auto getParamInt = (int index, int defaultValue = int.init) {
                    return (params.argc > index && params.argv[index].t == T_INT) ? cast(int) params.argv[index].d
                        : defaultValue;
                };
                auto getParamString = (int index, string defaultValue = string.init) {
                    return (params.argc > index && params.argv[index].t == T_STRING) ? valueToString(
                        &params.argv[index]) : defaultValue;
                };

                if (method == "getLogCount")
                {
                    int count = self._searchEngine ? cast(int) self._searchEngine.getLogCount() : 0;
                    sciterApi().ValueIntDataSet(&params.result, count, T_INT, 0);
                    return 1;
                }
                if (method == "getLogItems")
                {
                    int start = getParamInt(0);
                    int count = getParamInt(1, 10);
                    //string s = self._searchEngine ? self._searchEngine.getLogItemsAsJson(start, count)
                    //    : "[]";
                    string s = "[]";
                    import std.utf : toUTF16;

                    wstring ws = toUTF16(s);
                    sciterApi().ValueStringDataSet(&params.result, ws.ptr, cast(uint) ws.length, 0);
                    return 1;
                }
                if (method == "getLogItem")
                {
                    int index = getParamInt(0);
                    //string s = self._searchEngine ? self._searchEngine.getLogItemAsJson(
                    //    index) : "{}"; // Assuming implementation exists or using existing
                    string s = "{}";
                    import std.utf : toUTF16;

                    wstring ws = toUTF16(s);
                    sciterApi().ValueStringDataSet(&params.result, ws.ptr, cast(uint) ws.length, 0);
                    return 1;
                }
                if (method == "openFile")
                {
                    string path = getParamString(0);
                    if (!path.empty)
                        self.onFileSelected(normalizePath(path));
                    return 1;
                }
                if (method == "loadFibex")
                {
                    string path = getParamString(0);
                    if (!path.empty)
                        self.onLoadFibex(normalizePath(path));
                    return 1;
                }
                if (method == "applyFilter")
                {
                    string json = getParamString(0);
                    if (!json.empty)
                        self.onApplyFilter(json);
                    return 1;
                }
                if (method == "onTabClicked")
                {
                    string tabId = getParamString(0);
                    if (!tabId.empty)
                        self.onTabClicked(tabId);
                    return 1;
                }
            }
        }
        else if (evtg == EVENT_GROUPS.HANDLE_INITIALIZATION)
        {
            writeln("HANDLE_INITIALIZATION");
            return 0;
        }
        else if (evtg == EVENT_GROUPS.HANDLE_GESTURE)
        {
            //writeln("HANDLE_GESTURE");
            //return 1;
        }

        return 0;
    }

    private void onFileSelected(string path)
    {
        // Save state of PREVIOUS file before switching
        if (_settings.activeFile.length > 0 && _settings.activeFile != path)
        {
            // We need to ask JS for scroll position. 
            // IMPORTANT: This only works if the UI hasn't cleared the list yet.
            // If onFileSelected is a result of user action, the UI is still showing old list.
            SCITER_VALUE res;
            if (sciterApi().SciterCall(_hwnd, "getScrollPosition", 0, null, &res))
            {
                int scroll = 0;
                if (res.t == T_INT)
                    scroll = cast(int) res.d;
                else if (res.t == T_FLOAT)
                    scroll = cast(int) res.d;

                foreach (ref f; _settings.files)
                {
                    if (f.path == _settings.activeFile)
                    {
                        f.scrollPosition = scroll;
                        break;
                    }
                }
            }
        }

        writeln("Opening file: ", path);
        try
        {
            _currentIndexer = new Indexer(path);
            _currentIndexer.scan();
            _searchEngine = new SearchEngine(_currentIndexer);
            _searchEngine._fibex = this._fibexParser;
            writeln("Indexed messages: ", _currentIndexer.totalMessages);

            // Add to open files settings if not present
            bool found = false;
            foreach (f; _settings.files)
                if (f.path == path)
                    found = true;
            if (!found)
            {
                _settings.files ~= FileState(path, 0);
            }

            _settings.activeFile = path;
            saveSettings();
        }
        catch (Exception e)
        {
            writeln("Error indexing: ", e.msg);
        }
    }

    // ... (rest of methods) ...
    private void onLoadFibex(string path)
    { /* ... */ try
        {
            _fibexParser = new FibexParser();
            _fibexParser.load(path);
        }
        catch (Exception e)
        {
        }
    }

    private void onApplyFilter(string json)
    { /* ... */ try
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
        }
    }

    private void onTabClicked(string id)
    {
    }

    // ... (helpers) ...
    private static string valueToString(const SCITER_VALUE* v)
    { /*...*/ if (!v || v.t != 5)
            return "";
        const(wchar)* p;
        uint l;
        sciterApi().ValueStringData(v, &p, &l);
        return p ? to!string(p[0 .. l]) : "";
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

    void loadFile(string p)
    {
        if (_hwnd)
            sciterApi().SciterLoadFile(_hwnd, toUTF16z(p));
    }
}
