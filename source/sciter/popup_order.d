//! A workaround for Sciter 6.0.5.6 on macOS, to be removed once it is fixed (.ai/knowledge/sciter.md, Popups): the window of
//! a popup Sciter opens itself (the list of a <select>, a context menu) is ordered behind its window. `raisePopups()` makes
//! every popup a child of the window it was opened over, which keeps it above.
module sciter.popup_order;

/// Whether a window of the application is a popup of Sciter that no window holds above itself: of Sciter's window class
/// ("Window"), with no title bar (bit 0 of the style mask), shown and not a child of another
bool needsOwner(const(char)[] className, ulong styleMask, bool visible, bool hasParent) pure nothrow @nogc @safe
{
    return visible && !hasParent && (styleMask & titled) == 0 && className == "Window";
}

private enum ulong titled = 1; // NSWindowStyleMaskTitled

version (OSX)
{
    import std.string : fromStringz;
    import utils.objc : cls, msg;

    private extern (C) nothrow
    {
        alias CFRunLoopObserverCallBack = void function(void*, size_t, void*);
        void* CFRunLoopGetMain();
        void* CFRunLoopObserverCreate(void*, size_t, ubyte, ptrdiff_t, CFRunLoopObserverCallBack, void*);
        void CFRunLoopAddObserver(void*, void*, const(void)*);
        extern __gshared const(void)* kCFRunLoopCommonModes;
        const(char)* object_getClassName(void* object);
    }

    private enum size_t beforeWaiting = 1 << 5; // kCFRunLoopBeforeWaiting
    private enum long above = 1; // NSWindowAbove

    /// From now on the popups of Sciter are raised over their windows. Call once, on the main thread
    void raisePopups()
    {
        // before the main run loop waits, in its common modes: while a modal dialog runs too
        auto observer = CFRunLoopObserverCreate(null, beforeWaiting, 1, 0, &onRunLoop, null);
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, kCFRunLoopCommonModes);
    }

    private extern (C) void onRunLoop(void*, size_t, void*) nothrow
    {
        try
            giveOwners();
        catch (Exception e)
        {
            // nothing to tell and nobody to tell it: the popup stays behind
        }
    }

    private void giveOwners()
    {
        auto app = msg(cls("NSApplication"), "sharedApplication");
        auto windows = msg(app, "windows");
        foreach (i; 0 .. msg!ulong(windows, "count"))
        {
            auto window = msg(windows, "objectAtIndex:", i);
            if (!needsOwner(object_getClassName(window).fromStringz, msg!ulong(window, "styleMask"),
                    msg!bool(window, "isVisible"), msg(window, "parentWindow") !is null))
                continue;
            // a closed popup leaves its parent by itself: AppKit removes a child ordered out
            if (auto owner = ownerWindow(app))
                msg!void(owner, "addChildWindow:ordered:", window, above);
        }
    }

    // The window a popup is opened over: the key one (a dialog), with the application not active the frontmost one
    private void* ownerWindow(void* app)
    {
        static bool canOwn(void* window)
        {
            return window !is null && msg!bool(window, "isVisible") && (msg!ulong(window, "styleMask") & titled) != 0;
        }

        auto key = msg(app, "keyWindow");
        if (canOwn(key))
            return key;
        auto ordered = msg(app, "orderedWindows");
        foreach (i; 0 .. msg!ulong(ordered, "count"))
        {
            auto window = msg(ordered, "objectAtIndex:", i);
            if (canOwn(window))
                return window;
        }
        return null;
    }
}

@("needsOwner: a visible popup of Sciter with no parent window")
unittest
{
    // the mask measured on a menu and a list of 6.0.5.6
    assert(needsOwner("Window", 32_772, true, false));
}

@("needsOwner: not a window with a title bar, a hidden one, a child, or one that is not Sciter's")
unittest
{
    assert(!needsOwner("Window", 32_772 | 1, true, false));
    assert(!needsOwner("Window", 32_772, false, false));
    assert(!needsOwner("Window", 32_772, true, true));
    assert(!needsOwner("NSToolTipPanel", 0, true, false));
}
