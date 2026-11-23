//! Puts the main menu of `ui/app_menu` into the window: the native menu on macOS.
module ui.main_menu_loader;

import ui.app_menu;
import ui.main_window;
import std.stdio;

void loadAppMenu(MainWindow window)
{
    version (OSX)
    {
        setupMainMenuOSX(window, window.menuBar(MenuPlatform.mac));
        writeln("Native Menu: OSX menu setup completed.");
    }
}

/// The window is about to be destroyed: the application no longer tells it that it terminates
void forgetAppMenuWindow()
{
    version (OSX)
        terminatingWindow = null;
}

/// Puts the labels of the menu of `window` in the language of the interface now (the native
/// menu on macOS; the script draws its menu on the other platforms itself). The items
/// stay as they are, only their titles change: one may be running its action (Settings...
/// opened from the menu), and the items of macOS stay untouched.
void retitleAppMenu(MainWindow window)
{
    version (OSX)
        retitleMenuOSX(window.menuBar(MenuPlatform.mac));
}

version (OSX):

import std.string : toStringz, fromStringz;
import std.utf : toUTF16;

import utils.foreign_callback : guardCallback;
import utils.objc : cls, msg, sel_registerName;

extern (C) bool class_addMethod(void* cls, void* name, void* imp, const char* types);
extern (C) void* objc_allocateClassPair(void* superclass, const char* name, size_t extraBytes);
extern (C) void objc_registerClassPair(void* cls);

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

private extern (C) void menuItemClicked(void* self, void* _cmd, void* sender) nothrow
{
    guardCallback("a click of the menu", () => clickMenuItem(sender));
}

private void clickMenuItem(void* sender)
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

private void* makeItem(in MenuItem sub, MainWindow window)
{
    string id = sub.id;

    const(char)* action = "menuItemClicked:";
    if (id == MenuCommand.quit)
        action = "terminate:";
    else if (id == MenuCommand.minimize)
        action = "performMiniaturize:";

    auto item = msg(alloc("NSMenuItem"), "initWithTitle:action:keyEquivalent:",
        makeNSString(sub.label), sel_registerName(action),
        makeNSString(macKeyEquivalent(sub.shortcut)));
    if (!sub.shortcut.isNone)
        msg!void(item, "setKeyEquivalentModifierMask:", macModifierMask(sub.shortcut));
    msg!void(item, "setRepresentedObject:", makeNSString(id));
    commandItems[id] = item;
    // Pass window pointer using the tag
    msg!void(item, "setTag:", cast(long)(cast(void*) window));
    return item;
}

// The window the application delegate tells that the application terminates
private __gshared MainWindow terminatingWindow;

// NSApplicationDelegate: Quit, Quit of the Dock, logging out. Cocoa exits the process right
// after this (exit() inside the event loop: main() never goes on) and closes the window
// without its closerequest, so the window saves now, while its script is alive.
private extern (C) ulong applicationShouldTerminate(void* self, void* _cmd, void* sender) nothrow
{
    guardCallback("the termination of the application", () {
        if (terminatingWindow)
            terminatingWindow.terminate();
    });
    return 1; // NSTerminateNow
}

private void registerDelegateClass(MainWindow window)
{
    terminatingWindow = window;
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
    class_addMethod(clsDelegate, sel_registerName("applicationShouldTerminate:"),
        cast(void*)&applicationShouldTerminate, "Q@:@");
    if (created)
        objc_registerClassPair(clsDelegate);
}

/// The bar of the menu of the window: our menus, our items at the top of the application
/// menu macOS has. Built once: another language only retitles it (retitleMenuOSX).
private void buildMenuBarOSX(MainWindow window, MenuItem[] bar)
{
    auto app = msg(cls("NSApplication"), "sharedApplication");
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

    foreach (barIndex, ref menuObj; bar)
    {
        // Existing app menu: our items are inserted at the top, before the system ones
        bool patchAppMenu = menuObj.role == MenuRole.app && !createdMenubar;

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
            menu = msg(alloc("NSMenu"), "initWithTitle:", makeNSString(menuObj.label));
            msg!void(menuItem, "setSubmenu:", menu);
            barMenus[barIndex] = [menuItem, menu];
        }

        if (menuObj.kind != MenuItemKind.submenu)
            continue;

        long insertIdx = 0;
        void put(void* item)
        {
            if (patchAppMenu)
                msg!void(menu, "insertItem:atIndex:", item, insertIdx++);
            else
                msg!void(menu, "addItem:", item);
        }

        // The existing app menu has its own Quit and separators of its own
        auto items = patchAppMenu ? macAppMenuMerge(menuObj.items) : menuObj.items;
        foreach (ref sub; items)
        {
            if (sub.kind == MenuItemKind.separator)
                put(msg(cls("NSMenuItem"), "separatorItem"));
            else if (sub.kind == MenuItemKind.command)
                put(makeItem(sub, window));
        }
    }

    if (createdMenubar)
        msg!void(app, "setMainMenu:", menubar);
}

// What of the menu is ours, to retitle: the items of the commands by id, and the entries of
// the bar we made ([item, menu]) by their index in the bar (the application menu macOS has
// is none of them: macOS titles it)
private __gshared void*[string] commandItems;
private __gshared void*[2][size_t] barMenus;

// Sets the title of `obj` (an NSMenu or NSMenuItem: it copies the string)
private void setTitle(void* obj, string title)
{
    auto text = makeNSString(title);
    msg!void(obj, "setTitle:", text);
    msg!void(text, "release");
}

// The titles of our items and menus, from `bar` (as built: the same items, other labels)
private void retitleMenuOSX(MenuItem[] bar)
{
    void retitle(MenuItem[] items)
    {
        foreach (ref item; items)
        {
            if (item.kind == MenuItemKind.command)
                if (auto native = item.id in commandItems)
                    setTitle(*native, item.label);
            retitle(item.items);
        }
    }

    foreach (i, ref entry; bar)
    {
        if (auto menus = i in barMenus)
        {
            setTitle((*menus)[0], entry.label);
            setTitle((*menus)[1], entry.label);
        }
        retitle(entry.items);
    }
}

private void setupMainMenuOSX(MainWindow window, MenuItem[] bar)
{
    auto app = msg(cls("NSApplication"), "sharedApplication");
    msg!void(app, "setActivationPolicy:", 0L); // NSApplicationActivationPolicyRegular

    registerDelegateClass(window);
    msg!void(app, "setDelegate:", make("AppDelegate"));

    // Critical for menus in non-bundled apps:
    msg!void(app, "finishLaunching");

    buildMenuBarOSX(window, bar);

    msg!void(app, "activateIgnoringOtherApps:", true);

    // Also ensure the window itself is key and front
    if (window && window.hwnd())
    {
        auto hwnd = cast(void*) window.hwnd();
        msg!void(hwnd, "makeKeyAndOrderFront:", cast(void*) null);
        msg!void(hwnd, "orderFrontRegardless");
    }
}

@("menuItemClicked, applicationShouldTerminate: nothing thrown unwinds into Cocoa")
unittest
{
    import std.traits : FunctionAttribute, functionAttributes;

    assert(functionAttributes!menuItemClicked & FunctionAttribute.nothrow_, "menuItemClicked must be nothrow");
    assert(functionAttributes!applicationShouldTerminate & FunctionAttribute.nothrow_,
        "applicationShouldTerminate must be nothrow");
}
