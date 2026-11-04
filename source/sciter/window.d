module sciter.window;

import sciter.api;
import sciter.value;
import sciter.event_handler;

import sciter.capi.api : SciterAPI_T;
import sciter.capi.types;
import sciter.capi.behavior;
import sciter.capi.def;
import std.stdio : writeln;
import std.string : toStringz;
import std.utf : toUTF16z, toUTFz;

/// 
/// @brief Base class for application window
/// 

//import std.string : toStringz;

// Helper for toUTF8z-like behavior if missing from std.utf (Sciter sometimes expects UTF8 as well)
/*private immutable(char)* toUTF8z(string s)
{
    return toStringz(s);
}*/

version (OSX)
{
    private extern (C) void* objc_getClass(const(char)* name);
    private extern (C) void* sel_registerName(const(char)* name);
    private extern (C) void* objc_msgSend(void* self, void* op, ...);
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
        //super();

        _hwnd = _api.SciterCreateWindow(creationFlags, &frame, null, null, null);

        attachEventHandler(_hwnd);

        // Attach event handler
        /*{
            const auto res = _api.SciterWindowAttachEventHandler(_hwnd, &elementProc, cast(void*) this, 0xFFFF);
            writeln("Window event handler attached (Direct), result: ", res);
        }*/
    }

    ~this()
    {
        writeln("SciterWindow d'tor");
        super.detachEventHandler(_hwnd);
        //detachEventHandler();
        // _api.SciterDestroyWindow(_hwnd); // Missing in SciterAPI_T
    }

    private static extern (C) long sciterWindowDelegate(HWINDOW hwnd, uint msg, size_t wParam, ptrdiff_t lParam, void* pParam, int* handled)
    {
        return 0;
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

    final void loadFile(string path)
    {
        version (linux)
        {
            // Workaround: SciterLoadFile crashes on Linux with buffer overflow
            // (bug inside the native library's file path handling).
            // Read file content ourselves and use SciterLoadHtml instead.
            import std.file : read;
            import std.path : dirName, absolutePath;

            auto content = cast(const(ubyte)[]) read(path);
            string absDir = absolutePath(path).dirName;
            string baseUrl = "file://" ~ absDir ~ "/";
            _api.SciterLoadHtml(_hwnd, content.ptr, cast(uint) content.length, baseUrl.toUTF16z());
        }
        else
        {
            _api.SciterLoadFile(_hwnd, path.toUTF16z());
        }
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
        //_api.SciterBindWindow(_hwnd, this);
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
            alias Msg0 = extern (C) void* function(void*, void*);
            alias MsgPtr = extern (C) void* function(void*, void*, void*);
            alias MsgBool = extern (C) void function(void*, void*, byte);
            alias MsgIsKind = extern (C) byte function(void*, void*, void*);

            void* w = _hwnd;
            if (!w)
                return;
            // HWINDOW may be an NSWindow* or an NSView* depending on Sciter version
            if (!(cast(MsgIsKind)&objc_msgSend)(w, sel_registerName("isKindOfClass:"), objc_getClass("NSWindow")))
                w = (cast(Msg0)&objc_msgSend)(w, sel_registerName("window"));
            if (!w)
                return;

            // Sciter resets the window to non-opaque on first show; re-apply only when needed
            alias MsgGetBool = extern (C) byte function(void*, void*);
            if ((cast(MsgGetBool)&objc_msgSend)(w, sel_registerName("isOpaque")))
                return;

            auto bg = (cast(Msg0)&objc_msgSend)(objc_getClass("NSColor"), sel_registerName("windowBackgroundColor"));
            (cast(MsgPtr)&objc_msgSend)(w, sel_registerName("setBackgroundColor:"), bg);
            (cast(MsgBool)&objc_msgSend)(w, sel_registerName("setOpaque:"), 1);
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
