//! SciterWindow: the base of an application window: its creation, its events, the calls
//! of its script and the tasks posted to its thread.
module sciter.window;

import sciter.api;
import sciter.value;
import sciter.event_handler;

import sciter.capi.api : SciterAPI_T;
import sciter.capi.types;
import sciter.capi.behavior;
import sciter.capi.def;
import utils.foreign_callback : guardCallback;
import utils.keys : KeyPress;
import std.stdio : writeln;
import std.string : toStringz;
import std.utf : toUTF16z, toUTFz;

/// 
/// @brief Base class for application window
/// 

/// From any thread: has the thread of the window `hwnd` run `task` in its event loop, between
/// events, and returns at once (SciterPostCallback, handled by SciterWindow). The task may run
/// after the caller has given up waiting for it, or never if the window is gone: it must hold
/// nothing of the caller's stack (a closure on the heap, not `scope`).
void postToWindowThread(HWINDOW hwnd, void delegate() nothrow task)
{
    import core.memory : GC;

    auto posted = new PostedTask(task);
    GC.addRoot(cast(void*) posted); // only Sciter's queue refers to it till it runs
    sciterApi().SciterPostCallback(hwnd, postedTaskTag, cast(UINT_PTR) cast(void*) posted, 0);
}

/// On the thread of the window `hwnd`: runs `script` in the global scope of its document
/// (SciterEval) and puts the value of its last expression in `result`; false if the script
/// didn't run (no document loaded, a syntax error)
bool evalInWindow(HWINDOW hwnd, const(char)[] script, ref SciterValue result)
{
    import std.utf : toUTF16;

    const wide = script.toUTF16;
    return sciterApi().SciterEval(hwnd, wide.ptr, cast(UINT) wide.length, result.raw) != 0;
}

/// On the thread of the window `hwnd`: hands it the mouse moved to (`x`, `y`), dips of the
/// window from its top left, as an event of the system: hover states, mouseenter, popups on
/// hover follow it as if the user moved the mouse; the cursor stays where it is. An open popup
/// at the point (a window of its own) gets it instead. Null, or why not: macOS only. A press of a button can't be handed so (Sciter ignores it: checked
/// with the view, the window, the application and the event queue).
string sendMouseMove(HWINDOW hwnd, double x, double y)
{
    version (OSX)
    {
        import utils.objc : cls, msg;

        auto main = MacWindow(nsWindowOf(hwnd));
        if (!main.ok)
            return "no view of the window";
        // an open popup is a window of its own over this one: the move goes to the window of
        // this application on top at the point, in its own coordinates
        const inMain = NSPoint(x, main.height - y);
        const onScreen = msg!NSPoint(main.window, "convertPointToScreen:", inMain);
        const number = msg!long(cls("NSWindow"), "windowNumberAtPoint:belowWindowWithWindowNumber:",
            onScreen, cast(long) 0);
        auto top = msg(msg(cls("NSApplication"), "sharedApplication"), "windowWithWindowNumber:", number);
        auto view = top ? MacWindow(top) : main;
        if (!view.ok)
            view = main;
        const at = view.window is main.window ? inMain : msg!NSPoint(view.window, "convertPointFromScreen:", onScreen);
        auto event = msg(cls("NSEvent"),
            "mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:",
            nsEventMouseMoved, at, cast(ulong) 0, view.now, view.number, cast(void*) null, cast(long) 0, cast(long) 0, 0.0f);
        // to the view under the point: the window doesn't pass a mouse move made up so
        auto target = msg(view.content, "hitTest:", at);
        if (!event || !target)
            return "no view at the point";
        msg!void(target, "mouseMoved:", event);
        return null;
    }
    else
        return "hover is for macOS only";
}

/// On the thread of the window `hwnd`: hands it `press` pressed and released as events of the
/// system, to the focused element of its document as if the user typed it (the codes of
/// macOS: `utils/mac_keys`). A shortcut of the menu bar isn't a key of the window: it doesn't
/// reach the menu. Null, or why not: macOS only.
string sendKeyPress(HWINDOW hwnd, in KeyPress press)
{
    version (OSX)
    {
        import std.string : toStringz;
        import utils.mac_keys : macKeyEvent;
        import utils.objc : cls, msg;

        const stroke = macKeyEvent(press);
        auto view = MacWindow(nsWindowOf(hwnd));
        if (!view.ok)
            return "no view of the window";
        auto sciterView = msg(view.content, "hitTest:", NSPoint(view.width / 2, view.height / 2));
        if (!sciterView)
            return "no view in the window";
        auto characters = msg(cls("NSString"), "stringWithUTF8String:", stroke.characters.toStringz);
        auto plain = msg(cls("NSString"), "stringWithUTF8String:", stroke.charactersIgnoringModifiers.toStringz);
        foreach (type; [nsEventKeyDown, nsEventKeyUp])
        {
            auto event = msg(cls("NSEvent"),
                "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:",
                type, NSPoint(0, 0), stroke.modifierFlags, view.now, view.number, cast(void*) null, characters,
                plain, false, stroke.keyCode);
            if (!event)
                return "no event for the key";
            // to Sciter's view: the window passes a key made up so to no one
            msg!void(sciterView, type == nsEventKeyDown ? "keyDown:" : "keyUp:", event);
        }
        return null;
    }
    else
        return "key and type are for macOS only";
}

version (OSX)
{
    private struct NSPoint
    {
        double x, y;
    }

    private struct NSRect
    {
        double x, y, width, height;
    }

    private enum ulong nsEventMouseMoved = 5, nsEventKeyDown = 10, nsEventKeyUp = 11;

    // What an event made for an NSWindow takes: its content view (an NSVisualEffectView with
    // Sciter's view inside for the main window), size, number, the time
    private struct MacWindow
    {
        void* window;
        void* content;
        double width, height;
        long number;
        double now;

        this(void* nsWindow)
        {
            import utils.objc : cls, msg;

            window = nsWindow;
            if (!window)
                return;
            content = msg(window, "contentView");
            if (!content)
                return;
            const frame = msg!NSRect(content, "frame");
            width = frame.width;
            height = frame.height;
            number = msg!long(window, "windowNumber");
            now = msg!double(msg(cls("NSProcessInfo"), "processInfo"), "systemUptime");
        }

        bool ok() const => content !is null;
    }

    // The NSWindow of `hwnd`, null if there is none: HWINDOW may be an NSWindow* or an NSView*
    // depending on Sciter version
    private void* nsWindowOf(HWINDOW hwnd)
    {
        import utils.objc : cls, msg;

        void* window = cast(void*) hwnd;
        if (window && !msg!bool(window, "isKindOfClass:", cls("NSWindow")))
            window = msg(window, "window");
        return window;
    }
}

private final class PostedTask
{
    void delegate() nothrow run;

    this(void delegate() nothrow run) nothrow
    {
        this.run = run;
    }
}

// wparam of a posted notification carrying a PostedTask in lparam ("task")
private enum UINT_PTR postedTaskTag = 0x7461736b;

private void runPostedTask(SCN_POSTED_NOTIFICATION* notification) nothrow
{
    import core.memory : GC;

    if (notification.wparam != postedTaskTag)
        return;
    auto posted = cast(PostedTask) cast(void*) notification.lparam;
    GC.removeRoot(cast(void*) posted);
    guardCallback("a task posted to the window", () => posted.run()); // nothrow: an Error aborts
}

version (Windows)
{
    // The id of the icon in resources/app.rc ("101 ICON ...")
    private enum appIconId = 101;

    /// Gives the window the icon built into the program (the class of Sciter's windows has
    /// none): the big one for the taskbar and Alt+Tab, the small one for the title bar. Nothing
    /// changes when the program has no icon resource (dub test's runner).
    private void setWindowIcon(HWINDOW hwnd) nothrow @nogc
    {
        import core.sys.windows.windows;

        auto instance = GetModuleHandleW(null);
        const resource = cast(const(wchar)*) cast(size_t) appIconId;
        void set(WPARAM size, int metricX, int metricY)
        {
            auto icon = LoadImageW(instance, resource, IMAGE_ICON,
                GetSystemMetrics(metricX), GetSystemMetrics(metricY), LR_DEFAULTCOLOR);
            if (icon !is null)
                SendMessageW(cast(HWND) hwnd, WM_SETICON, size, cast(LPARAM) icon);
        }
        set(ICON_BIG, SM_CXICON, SM_CYICON);
        set(ICON_SMALL, SM_CXSMICON, SM_CYSMICON);
    }
}

class SciterWindow : SciterEventHandler
{
    private HWINDOW _hwnd;

    static auto _api() @nogc nothrow @property
    {
        return sciterApi();
    }

    this(uint creationFlags, in RECT frame)
    {
        _hwnd = _api.SciterCreateWindow(creationFlags, &frame, null, null, null);
        _api.SciterSetCallback(_hwnd, &hostCallback, cast(void*) this);

        attachEventHandler(_hwnd);
        version (Windows)
            setWindowIcon(_hwnd);
    }

    /// The data at `uri` the window gives Sciter itself (the files of its dialogs too), null to
    /// leave the loading to Sciter
    protected immutable(ubyte)[] onLoadData(string uri)
    {
        return null;
    }

    // Nothing may unwind through the frames of Sciter: whatever is thrown is caught here
    private static extern (C) UINT hostCallback(SCITER_CALLBACK_NOTIFICATION* pns, void* param) nothrow
    {
        if (pns.code == SC_POSTED_NOTIFICATION)
        {
            runPostedTask(cast(SCN_POSTED_NOTIFICATION*) pns);
            return 0;
        }
        if (pns.code != SC_LOAD_DATA)
            return 0;
        import std.string : fromStringz;
        import std.utf : toUTF8;

        auto request = cast(SCN_LOAD_DATA*) pns;
        guardCallback("a load of data by Sciter", () {
            const uri = request.uri.fromStringz.toUTF8;
            try
            {
                const data = (cast(SciterWindow) param).onLoadData(uri);
                if (data !is null)
                    _api.SciterDataReady(pns.hwnd, request.uri, data.ptr, cast(UINT) data.length);
            }
            catch (Exception e)
            {
                e.msg = "can't load " ~ uri ~ ": " ~ e.msg; // the log names what failed
                throw e;
            }
        });
        return SC_LOAD_DATA_RETURN_CODES.LOAD_OK;
    }

    ~this()
    {
        writeln("SciterWindow d'tor");
        _api.SciterSetCallback(_hwnd, null, null); // Sciter must not call a destroyed object
        super.detachEventHandler(_hwnd);
    }

    // workaround. better to call it in d'tor
    final void detachEventHandler()
    {
        super.detachEventHandler(_hwnd);
    }

    final HWINDOW hwnd()
    {
        return _hwnd;
    }

    final HINSTANCE getResourceInstance()
    {
        import sciter.application : sciterApplication;

        return sciterApplication().hinstance();
    }

    final void loadHtml(const(ubyte)[] content, string baseUrl = "")
    {
        _api.SciterLoadHtml(_hwnd, content.ptr, cast(uint) content.length, baseUrl.toUTF16z());
    }

    final void updateWindow()
    {
        _api.SciterUpdateWindow(_hwnd);
    }

    private INT_PTR exec(uint cmd, UINT_PTR param1, UINT_PTR param2) const
    {
        auto res = _api.SciterWindowExec(cast(HWINDOW) _hwnd, cmd, param1, param2);
        if (res == 0 && cmd != SCITER_WINDOW_CMD.SCITER_WINDOW_SET_STATE)
            writeln("SciterWindowExec failed for cmd ", cmd, " hwnd: ", _hwnd);
        return res;
    }

    private void setState(UINT_PTR param1, UINT_PTR param2)
    {
        exec(cast(uint) SCITER_WINDOW_CMD.SCITER_WINDOW_SET_STATE, param1, param2);
    }

    final void bind()
    {
      //if (_hwnd && !_bound) {
      //  _bound = true;
      //  setup_callback();
      //  sciter::attach_dom_event_handler(get_hwnd(), this);
      //}
    }

    final void collapse()
    {
        bind();
        setState(SCITER_WINDOW_STATE.SCITER_WINDOW_STATE_MINIMIZED, 0);
    }

    final void expand(bool maximize = false)
    {
        setState(maximize ? SCITER_WINDOW_STATE.SCITER_WINDOW_STATE_MAXIMIZED
                : SCITER_WINDOW_STATE.SCITER_WINDOW_STATE_SHOWN, 0);
    }

    final void request_close() // requests window to be closed, note: script can reject the closure
    {
        setState(SCITER_WINDOW_STATE.SCITER_WINDOW_STATE_CLOSED, 0);
    }

    final void close()
    {
        setState(SCITER_WINDOW_STATE.SCITER_WINDOW_STATE_CLOSED, 1);
    }

    /**
     * macOS workaround for Sciter 6.0.5.x: the engine creates the NSWindow as
     * non-opaque with a clear backgroundColor (new "window material" system).
     * On recent macOS the standard titlebar draws the window background, so it
     * becomes see-through and only the traffic-light buttons remain visible.
     * Restore an opaque window with the system window background color.
     * Cheap when nothing changed (single isOpaque check), so it is called from
     * the idle loop: Sciter re-applies the clear background after the first show.
     */
    final void fixMacTitlebarBackground()
    {
        version (OSX)
        {
            import utils.objc : cls, msg;

            auto w = nsWindowOf(_hwnd);
            if (!w)
                return;

            // Sciter resets the window to non-opaque on first show; re-apply only when needed
            if (msg!bool(w, "isOpaque"))
                return;

            auto bg = msg(cls("NSColor"), "windowBackgroundColor");
            msg!void(w, "setBackgroundColor:", bg);
            msg!void(w, "setOpaque:", true);
        }
    }

    final void activate(bool bringToFront = false)
    {
        bind();
        exec(SCITER_WINDOW_CMD.SCITER_WINDOW_ACTIVATE, bringToFront ? 1 : 0, 0);
    }

    /**
     * Retrieves the window's placement (coordinates and size).
     * NOTE: The native SciterWindowExec(SCITER_WINDOW_GET_PLACEMENT) call is known to fail
     * on macOS, returning zeros. A SciterEval fallback is implemented to fetch coordinates
     * via JavaScript's Window.this.box() in physical pixels.
     */
    final RECT getPlacement() const
    {
        POINT pos;
        SIZE size;
        auto res = exec(cast(uint) SCITER_WINDOW_CMD.SCITER_WINDOW_GET_PLACEMENT, cast(UINT_PTR)&pos, cast(
                UINT_PTR)&size);

        RECT result;
        result.left = pos.x;
        result.top = pos.y;
        result.right = pos.x + size.cx;
        result.bottom = pos.y + size.cy;

        writeln("getPlacement: ", result);

        return result;
    }

    final void setPlacement(const RECT rect)
    {
        POINT pos = {x: rect.left, y: rect.top};
        SIZE size = {cx: rect.right - rect.left, cy: rect.bottom - rect.top};
        exec(cast(uint) SCITER_WINDOW_CMD.SCITER_WINDOW_SET_PLACEMENT, cast(UINT_PTR)&pos, cast(
                UINT_PTR)&size);
    }

    final SciterValue callScript(T...)(const(char)[] name, T args) const
    {
        SciterValue resValue;
        auto nameZ = toStringz(name);

        static if (args.length == 0)
        {
            _api.SciterCall(cast(HWINDOW) _hwnd, nameZ, 0, null, resValue.raw);
        }
        else
        {
            SciterValue[args.length] argsValues;

            foreach (i, arg; args)
            {
                argsValues[i] = arg;
            }

            _api.SciterCall(cast(HWINDOW) _hwnd, nameZ, argsValues.length, argsValues[0].raw, resValue
                    .raw);
        }

        return resValue;
    }
}
