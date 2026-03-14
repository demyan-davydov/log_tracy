module ui.main_menu_loader;

import ui.main_window;
import std.string : toStringz;

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
    private void* makeNSString(string str)
    {
        auto cls_NSString = objc_getClass("NSString");
        auto sel_alloc = sel_registerName("alloc");
        auto sel_initWithUTF8String = sel_registerName("initWithUTF8String:");
        alias msgSend_str = extern (C) void* function(void*, void*, const char*) @trusted;
        return (cast(msgSend_str)&objc_msgSend)((cast(msgSend_ptr)&objc_msgSend)(cls_NSString, sel_alloc), sel_initWithUTF8String, toStringz(
                str));
    }

    private extern (C) void menuOpenCallback(void* self, void* _cmd, void* sender)
    {
        MainMenuLoader loader = cast(MainMenuLoader) sender;
        //if (loader._window)
        //    loader._window.onMenuPressed("open");
    }

    private extern (C) void menuSettingsCallback(void* self, void* _cmd, void* sender)
    {
        MainMenuLoader loader = cast(MainMenuLoader) sender;
        //if (loader._window)
        //    loader._window.onMenuPressed("settings");
    }
}

class MainMenuLoader
{
    private MainWindow _window;

    this(MainWindow window)
    {
        _window = window;

        //auto json = parseJSON(readText("resources/menu.json"));

        // Setup menu
        setupMainMenu();
    }

    version (OSX)
    {
        private void setupMainMenu()
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
            auto sel_initWithTitleActionKey = sel_registerName(
                "initWithTitle:action:keyEquivalent:");

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
    }
    else
    {
        private void setupMainMenu()
        {
            // todo: setup html content and show #main-menu element
        }
    }
}
