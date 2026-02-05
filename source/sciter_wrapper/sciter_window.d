module sciter_wrapper.sciter_window;

import sciter_wrapper.sciter_api;
import sciter_wrapper.sciter_value;
import sciter_wrapper.sciter_event_handler;

import sciter.api : SciterAPI_T;
import sciter.types;
import sciter.behavior;
import sciter.def;
import std.stdio : writeln;
import std.utf : toUTF16z;
import std.string : toStringz;

// Helper for toUTF8z-like behavior if missing from std.utf (Sciter sometimes expects UTF8 as well)
private immutable(char)* toUTF8z(string s)
{
    return toStringz(s);
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

        _hwnd = _api.SciterCreateWindow(creationFlags, &frame, &sciterWindowDelegate, null, null);

        attachEventHandler(_hwnd);

        // Attach event handler
        /*{
            const auto res = _api.SciterWindowAttachEventHandler(_hwnd, &elementProc, cast(void*) this, 0xFFFF);
            writeln("Window event handler attached (Direct), result: ", res);
        }*/
    }

    ~this()
    {
        // _api.SciterDestroyWindow(_hwnd); // Missing in SciterAPI_T
    }

    private static extern (C) long sciterWindowDelegate(HWINDOW hwnd, uint msg, size_t wParam, ptrdiff_t lParam, void* pParam, int* handled)
    {
        return 0;
    }

    final HWINDOW hwnd()
    {
        return _hwnd;
    }

    final void loadFile(string path)
    {
        _api.SciterLoadFile(_hwnd, path.toUTF16z());
    }

    private void exec(uint cmd, uint param1, uint param2)
    {
        _api.SciterWindowExec(_hwnd, cmd, param1, param2);
    }

    private void setState(uint param1, uint param2)
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

    final void activate(bool bringToFront = false)
    {
        bind();
        exec(SCITER_WINDOW_CMD.SCITER_WINDOW_ACTIVATE, bringToFront ? 1 : 0, 0);
    }

    final void run()
    {
        // _api.SciterRun(_hwnd); // Missing in SciterAPI_T
    }

    final SciterValue callScript(T...)(const(char)[] name, T args)
    {
        SciterValue resValue;
        const(char)[] nameZ = name.toUTF8z();

        static if (args.length == 0)
        {
            _api.SciterCall(_hwnd, nameZ.ptr, 0, null, &resValue.raw);
        }
        else
        {
            SciterValue argsValue = SciterValue.makeArray!(args.length)();
            _api.SciterCall(_hwnd, nameZ.ptr, 0, argsValue.raw, &resValue.raw);
        }

        return resValue;
    }
}
