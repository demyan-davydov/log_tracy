module ui.main_menu_loader;

import ui.main_window;
import std.string : toStringz, fromStringz;
import std.utf : toUTF16;
import std.json;
import std.stdio;

// OS-specific external declarations
version (OSX)
{
    extern (C) void* objc_getClass(const char* name);
    extern (C) void* sel_registerName(const char* name);
    extern (C) void* objc_msgSend(void* self, void* op, ...);

    // Helpers
    extern (C) void* objc_msgSend_id(void* self, void* op) @trusted;
    alias msgSend_ptr = extern (C) void* function(void*, void*) @trusted;
    alias msgSend_ptr_ptr = extern (C) void* function(void*, void*, void*) @trusted;
    extern (C) bool class_addMethod(void* cls, void* name, void* imp, const char* types);
    extern (C) void* objc_allocateClassPair(void* superclass, const char* name, size_t extraBytes);
    extern (C) void objc_registerClassPair(void* cls);

    private void* makeNSString(string str)
    {
        auto cls_NSString = objc_getClass("NSString");
        auto sel_alloc = sel_registerName("alloc");
        auto sel_initWithUTF8String = sel_registerName("initWithUTF8String:");
        alias msgSend_str = extern (C) void* function(void*, void*, const char*) @trusted;
        return (cast(msgSend_str)&objc_msgSend)((cast(msgSend_ptr)&objc_msgSend)(cls_NSString, sel_alloc), sel_initWithUTF8String, toStringz(
                str));
    }

    private extern (C) void menuItemClicked(void* self, void* _cmd, void* sender)
    {
        auto sel_representedObject = sel_registerName("representedObject");
        void* nsStrId = (cast(msgSend_ptr)&objc_msgSend)(sender, sel_representedObject);
        if (nsStrId)
        {
            auto sel_UTF8String = sel_registerName("UTF8String");
            alias msgSend_cStr = extern (C) const(char)* function(void*, void*) @trusted;
            auto cStrId = (cast(msgSend_cStr)&objc_msgSend)(nsStrId, sel_UTF8String);
            string id = fromStringz(cStrId).idup;
            alias msgSend_long = extern (C) long function(void*, void*) @trusted;
            long tag = (cast(msgSend_long)&objc_msgSend)(sender, sel_registerName("tag"));
            MainWindow win = cast(MainWindow)(cast(void*) tag);

            if (win)
            {
                writeln("Native Menu: Clicked ", id, ", delegating to JS onMenuCommand via callScript");
                import std.utf : toUTF16;

                win.callScript("onMenuCommand", id.toUTF16());
            }
            else
            {
                writeln("Native Menu Error: win is null for clicked item ", id);
            }
        }
        else
        {
            writeln("Native Menu Error: nsStrId is null");
        }
    }
}

void loadAppMenu(MainWindow window)
{
    version (OSX)
    {
        writeln("Native Menu: Loading menu.json for OSX...");
        string menuJson = import("menu.json");
        setupMainMenuOSX(window, menuJson);
        writeln("Native Menu: OSX menu setup completed.");
    }
}

version (OSX)
{
    private void setupMainMenuOSX(MainWindow window, string menuJson)
    {
        auto j = parseJSON(menuJson);

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

        alias msgSend_ptr_long = extern (C) void* function(void*, void*, long) @trusted;
        (cast(msgSend_ptr_long)&objc_msgSend)(app, sel_registerName("setActivationPolicy:"), 0L); // NSApplicationActivationPolicyRegular

        // Re-adding custom event handlers using AppDelegate
        auto clsDelegate = objc_getClass("AppDelegate");
        if (!clsDelegate)
        {
            clsDelegate = objc_allocateClassPair(objc_getClass("NSObject"), "AppDelegate", 0);
            if (clsDelegate)
            {
                class_addMethod(clsDelegate, sel_registerName("menuItemClicked:"), cast(void*)&menuItemClicked, "v@:@");
                objc_registerClassPair(clsDelegate);
            }
        }
        else
        {
            class_addMethod(clsDelegate, sel_registerName("menuItemClicked:"), cast(void*)&menuItemClicked, "v@:@");
        }

        auto delegateObj = (cast(msgSend_ptr)&objc_msgSend)(
            (cast(msgSend_ptr)&objc_msgSend)(clsDelegate, sel_alloc), sel_init);

        (cast(msgSend_ptr_ptr)&objc_msgSend)(app, sel_registerName("setDelegate:"), delegateObj);

        // Critical for menus in non-bundled apps:
        (cast(msgSend_ptr)&objc_msgSend)(app, sel_registerName("finishLaunching"));

        auto sel_mainMenu = sel_registerName("mainMenu");
        auto menubar = (cast(msgSend_ptr)&objc_msgSend)(app, sel_mainMenu);
        bool createdMenubar = false;

        if (!menubar) {
            menubar = (cast(msgSend_ptr)&objc_msgSend)(
                (cast(msgSend_ptr)&objc_msgSend)(cls_NSMenu, sel_alloc), sel_init);
            createdMenubar = true;
        } else {
            // Remove everything except the App Menu (index 0)
            alias msgSend_numberOfItems = extern (C) long function(void*, void*) @trusted;
            alias msgSend_removeItemAtIndex = extern (C) void function(void*, void*, long) @trusted;
            long count = (cast(msgSend_numberOfItems)&objc_msgSend)(menubar, sel_registerName("numberOfItems"));
            for (long i = count - 1; i > 0; i--) {
                (cast(msgSend_removeItemAtIndex)&objc_msgSend)(menubar, sel_registerName("removeItemAtIndex:"), i);
            }
        }

        alias msgSend_initItem = extern (C) void* function(void*, void*, void*, void*, void*) @trusted;
        alias msgSend_initMenu = extern (C) void* function(void*, void*, void*) @trusted;
        alias msgSend_itemAtIndex = extern (C) void* function(void*, void*, long) @trusted;
        alias msgSend_insertItem = extern (C) void function(void*, void*, void*, long) @trusted;

        foreach (menuObj; j.array)
        {
            string menuId = "id" in menuObj ? menuObj["id"].str : "";
            
            void* menuItem = null;
            void* menu = null;

            if (menuId == "menu.app" && !createdMenubar) {
                // Get the existing App menu
                menuItem = (cast(msgSend_itemAtIndex)&objc_msgSend)(menubar, sel_registerName("itemAtIndex:"), 0);
                if (menuItem) {
                    menu = (cast(msgSend_ptr)&objc_msgSend)(menuItem, sel_registerName("submenu"));
                }
            }

            if (!menuItem || !menu) {
                menuItem = (cast(msgSend_ptr)&objc_msgSend)(
                    (cast(msgSend_ptr)&objc_msgSend)(cls_NSMenuItem, sel_alloc), sel_init);
                (cast(msgSend_ptr_ptr)&objc_msgSend)(menubar, sel_addItem, menuItem);

                string label = "label" in menuObj ? menuObj["label"].str : "";
                menu = (cast(msgSend_initMenu)&objc_msgSend)((cast(msgSend_ptr)&objc_msgSend)(cls_NSMenu, sel_alloc), sel_initWithTitle, makeNSString(
                        label));
                (cast(msgSend_ptr_ptr)&objc_msgSend)(menuItem, sel_setSubmenu, menu);
            }

            if ("submenu" in menuObj)
            {
                long insertIdx = 0;
                
                if (menuId == "menu.app" && !createdMenubar) {
                    auto masterItemSep = (cast(msgSend_ptr)&objc_msgSend)(cls_NSMenuItem, sel_registerName(
                            "separatorItem"));
                    (cast(msgSend_insertItem)&objc_msgSend)(menu, sel_registerName("insertItem:atIndex:"), masterItemSep, 0);
                }
                foreach (subItem; menuObj["submenu"].array)
                {
                    if ("type" in subItem && subItem["type"].str == "separator")
                    {
                        auto itemSep = (cast(msgSend_ptr)&objc_msgSend)(cls_NSMenuItem, sel_registerName(
                                "separatorItem"));
                        if (menuId == "menu.app" && !createdMenubar) {
                            (cast(msgSend_insertItem)&objc_msgSend)(menu, sel_registerName("insertItem:atIndex:"), itemSep, insertIdx++);
                        } else {
                            (cast(msgSend_ptr_ptr)&objc_msgSend)(menu, sel_addItem, itemSep);
                        }
                    }
                    else
                    {
                        string idStr = "id" in subItem ? subItem["id"].str : "";
                        string itemLabel = "label" in subItem ? subItem["label"].str : "";
                        string keyEq = "";

                        if ("accelerator" in subItem)
                        {
                            auto acc = subItem["accelerator"];
                            if ("mac" in acc)
                            {
                                keyEq = acc["mac"].str;
                                if (keyEq.length > 0)
                                {
                                    import std.uni : toLower;

                                    keyEq = keyEq[$ - 1 .. $].toLower();
                                }
                            }
                        }

                        void* action = sel_registerName("menuItemClicked:");
                        if (idStr == "app.quit")
                            action = sel_registerName("terminate:");
                        else if (idStr == "window.minimize")
                            action = sel_registerName("performMiniaturize:");

                        auto item = (cast(msgSend_initItem)&objc_msgSend)(
                            (cast(msgSend_ptr)&objc_msgSend)(cls_NSMenuItem, sel_alloc),
                            sel_initWithTitleActionKey,
                            makeNSString(itemLabel),
                            action,
                            makeNSString(keyEq)
                        );

                        (cast(msgSend_ptr_ptr)&objc_msgSend)(item, sel_registerName(
                                "setRepresentedObject:"), makeNSString(idStr));

                        // Pass window pointer using the tag
                        alias msgSend_ptr_long2 = extern (C) void* function(void*, void*, long) @trusted;
                        (cast(msgSend_ptr_long2)&objc_msgSend)(item, sel_registerName("setTag:"), cast(
                                long)(cast(void*) window));

                        // Skip default quit item if using existing app menu
                        if (menuId == "menu.app" && !createdMenubar && idStr == "app.quit") {
                            continue;
                        }

                        if (menuId == "menu.app" && !createdMenubar) {
                            (cast(msgSend_insertItem)&objc_msgSend)(menu, sel_registerName("insertItem:atIndex:"), item, insertIdx++);
                        } else {
                            (cast(msgSend_ptr_ptr)&objc_msgSend)(menu, sel_addItem, item);
                        }
                    }
                }
            }
        }

        if (createdMenubar) {
            (cast(msgSend_ptr_ptr)&objc_msgSend)(app, sel_setMainMenu, menubar);
        }

        alias msgSend_ptr_bool = extern (C) void* function(void*, void*, bool) @trusted;
        (cast(msgSend_ptr_bool)&objc_msgSend)(app, sel_registerName("activateIgnoringOtherApps:"), true);

        // Also ensure the window itself is key and front
        if (window && window.hwnd())
        {
            auto hwnd = cast(void*) window.hwnd();
            alias msgSend_ptr_ptr_ptr = extern (C) void* function(void*, void*, void*) @trusted;
            (cast(msgSend_ptr_ptr_ptr)&objc_msgSend)(hwnd, sel_registerName("makeKeyAndOrderFront:"), cast(
                    void*) null);
            (cast(msgSend_ptr)&objc_msgSend)(hwnd, sel_registerName("orderFrontRegardless"));
        }
    }
}
