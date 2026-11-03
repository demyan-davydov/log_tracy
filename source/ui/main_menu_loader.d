module ui.main_menu_loader;

import ui.main_window;
import std.json;
import std.stdio;

void loadAppMenu(MainWindow window)
{
    version (OSX)
    {
        writeln("Native Menu: Loading menu.json for OSX...");
        setupMainMenuOSX(window, import("menu.json"));
        writeln("Native Menu: OSX menu setup completed.");
    }
}

version (OSX):

import std.string : toStringz, fromStringz;
import std.utf : toUTF16;
import std.uni : toLower;

extern (C) void* objc_getClass(const char* name);
extern (C) void* sel_registerName(const char* name);
extern (C) void* objc_msgSend(void* self, void* op, ...);
extern (C) bool class_addMethod(void* cls, void* name, void* imp, const char* types);
extern (C) void* objc_allocateClassPair(void* superclass, const char* name, size_t extraBytes);
extern (C) void objc_registerClassPair(void* cls);

/// Calls objc_msgSend through an exact prototype derived from the argument types.
private R msg(R = void*, Args...)(void* obj, const(char)* sel, Args args)
{
    alias Fn = extern (C) R function(void*, void*, Args) @trusted;
    return (cast(Fn)&objc_msgSend)(obj, sel_registerName(sel), args);
}

private void* cls(const(char)* name)
{
    return objc_getClass(name);
}

private void* alloc(const(char)* className)
{
    return msg(cls(className), "alloc");
}

private void* make(const(char)* className)
{
    return msg(alloc(className), "init");
}

private void* makeNSString(string str)
{
    return msg(alloc("NSString"), "initWithUTF8String:", toStringz(str));
}

private string getStr(JSONValue obj, string key)
{
    auto p = key in obj;
    return p ? p.str : "";
}

private extern (C) void menuItemClicked(void* self, void* _cmd, void* sender)
{
    void* nsStrId = msg(sender, "representedObject");
    if (!nsStrId)
    {
        writeln("Native Menu Error: nsStrId is null");
        return;
    }

    string id = fromStringz(msg!(const(char)*)(nsStrId, "UTF8String")).idup;
    auto win = cast(MainWindow)(cast(void*) msg!long(sender, "tag"));
    if (!win)
    {
        writeln("Native Menu Error: win is null for clicked item ", id);
        return;
    }

    writeln("Native Menu: Clicked ", id, ", delegating to JS onMenuCommand via callScript");
    win.callScript("onMenuCommand", id.toUTF16());
}

private void* makeItem(JSONValue sub, MainWindow window)
{
    string id = getStr(sub, "id");

    string keyEq;
    if (auto acc = "accelerator" in sub)
    {
        keyEq = getStr(*acc, "mac");
        if (keyEq.length > 0)
            keyEq = keyEq[$ - 1 .. $].toLower();
    }

    const(char)* action = "menuItemClicked:";
    if (id == "app.quit")
        action = "terminate:";
    else if (id == "window.minimize")
        action = "performMiniaturize:";

    auto item = msg(alloc("NSMenuItem"), "initWithTitle:action:keyEquivalent:",
        makeNSString(getStr(sub, "label")), sel_registerName(action), makeNSString(keyEq));
    msg!void(item, "setRepresentedObject:", makeNSString(id));
    // Pass window pointer using the tag
    msg!void(item, "setTag:", cast(long)(cast(void*) window));
    return item;
}

private void registerDelegateClass()
{
    auto clsDelegate = cls("AppDelegate");
    bool created = false;
    if (!clsDelegate)
    {
        clsDelegate = objc_allocateClassPair(cls("NSObject"), "AppDelegate", 0);
        if (!clsDelegate)
            return;
        created = true;
    }
    class_addMethod(clsDelegate, sel_registerName("menuItemClicked:"), cast(void*)&menuItemClicked, "v@:@");
    if (created)
        objc_registerClassPair(clsDelegate);
}

private void setupMainMenuOSX(MainWindow window, string menuJson)
{
    auto app = msg(cls("NSApplication"), "sharedApplication");
    msg!void(app, "setActivationPolicy:", 0L); // NSApplicationActivationPolicyRegular

    registerDelegateClass();
    msg!void(app, "setDelegate:", make("AppDelegate"));

    // Critical for menus in non-bundled apps:
    msg!void(app, "finishLaunching");

    auto menubar = msg(app, "mainMenu");
    bool createdMenubar = menubar is null;
    if (createdMenubar)
    {
        menubar = make("NSMenu");
    }
    else
    {
        // Remove everything except the App Menu (index 0)
        for (long i = msg!long(menubar, "numberOfItems") - 1; i > 0; i--)
            msg!void(menubar, "removeItemAtIndex:", i);
    }

    foreach (menuObj; parseJSON(menuJson).array)
    {
        // Existing app menu: our items are inserted at the top, before the system ones
        bool patchAppMenu = getStr(menuObj, "id") == "menu.app" && !createdMenubar;

        void* menu = null;
        if (patchAppMenu)
        {
            if (auto appItem = msg(menubar, "itemAtIndex:", 0L))
                menu = msg(appItem, "submenu");
        }
        if (!menu)
        {
            patchAppMenu = false;
            auto menuItem = make("NSMenuItem");
            msg!void(menubar, "addItem:", menuItem);
            menu = msg(alloc("NSMenu"), "initWithTitle:", makeNSString(getStr(menuObj, "label")));
            msg!void(menuItem, "setSubmenu:", menu);
        }

        auto submenu = "submenu" in menuObj;
        if (!submenu)
            continue;

        long insertIdx = 0;
        void put(void* item)
        {
            if (patchAppMenu)
                msg!void(menu, "insertItem:atIndex:", item, insertIdx++);
            else
                msg!void(menu, "addItem:", item);
        }

        if (patchAppMenu)
            msg!void(menu, "insertItem:atIndex:", msg(cls("NSMenuItem"), "separatorItem"), 0L);

        foreach (sub; submenu.array)
        {
            if (getStr(sub, "type") == "separator")
                put(msg(cls("NSMenuItem"), "separatorItem"));
            // Skip our quit item when the existing app menu already has one
            else if (!(patchAppMenu && getStr(sub, "id") == "app.quit"))
                put(makeItem(sub, window));
        }
    }

    if (createdMenubar)
        msg!void(app, "setMainMenu:", menubar);

    msg!void(app, "activateIgnoringOtherApps:", true);

    // Also ensure the window itself is key and front
    if (window && window.hwnd())
    {
        auto hwnd = cast(void*) window.hwnd();
        msg!void(hwnd, "makeKeyAndOrderFront:", cast(void*) null);
        msg!void(hwnd, "orderFrontRegardless");
    }
}
