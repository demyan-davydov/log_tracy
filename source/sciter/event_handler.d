//! SciterEventHandler: the base of the D handlers of Sciter's DOM and window events.
module sciter.event_handler;

import sciter.api;

import sciter.capi.types;
import sciter.capi.behavior;
import sciter.capi.def;
import std.stdio : writeln;
import utils.foreign_callback : guardCallback;

class SciterEventHandler
{
    static auto _api() @nogc nothrow @property
    {
        return sciterApi();
    }

    /*
    static void attach_dom_event_handler(HWINDOW hwnd, event_handler_raw* ph)
    {
      int r = SciterWindowAttachEventHandler( hwnd, &event_handler_raw::element_proc, static_cast<event_handler_raw*>(ph), HANDLE_ALL );
      assert(r == SCDOM_OK); (void)r;
    }

    static void detach_dom_event_handler(HWINDOW hwnd, event_handler_raw* ph)
    {
      int r = SciterWindowDetachEventHandler( hwnd, &event_handler_raw::element_proc, static_cast<event_handler_raw*>(ph));
      assert(r == SCDOM_OK); (void)r;
    }*/

    protected void attachEventHandler(HWINDOW hwnd, UINT eventMask = EVENT_GROUPS.HANDLE_ALL)
    {
        const auto res = _api.SciterWindowAttachEventHandler(hwnd, &elementProc, cast(void*) this, eventMask);
        writeln("Window event handler attached (Direct), result: ", res);
    }

    protected void detachEventHandler(HWINDOW hwnd)
    {
        import sciter.capi.dom : SCDOM_OK;

        writeln("Window event handler detaching... ");
        const auto res = _api.SciterWindowDetachEventHandler(hwnd, &elementProc, cast(void*) this);
        if (res != SCDOM_OK)
            writeln("can not detach event handler, res: ", res);

        writeln("Window event handler detached (Direct), result: ", res);
    }

    // Every event of the window and every xcall of its script: what a handler throws is logged
    // and the event is left unhandled. An xcall left unhandled throws in the script, as one of
    // no such name does: "TypeError: unknown name '<name>'" (6.0.5.5); the log has the cause
    private static extern (C) SBOOL elementProc(void* tag, HELEMENT he, uint evtg, void* prms) nothrow
    {
        auto self = cast(SciterEventHandler) tag;
        if (self is null)
            return 0;
        return guardCallback("an event of the window", false, () => self.dispatch(he, evtg, prms)) ? 1 : 0;
    }

    private bool dispatch(HELEMENT he, uint evtg, void* prms)
    {
        bool res = false;

        switch (evtg)
        {
        case EVENT_GROUPS.SUBSCRIPTIONS_REQUEST:
            {
                UINT* p = cast(UINT*) prms;
                res = handleSubscription(he, p);
                break;
            }
        case EVENT_GROUPS.HANDLE_INITIALIZATION:
            {
                auto params = cast(INITIALIZATION_PARAMS*) prms;
                if (params.cmd == INITIALIZATION_EVENTS.BEHAVIOR_DETACH)
                {
                    handleDetached(he);
                }
                else if (params.cmd == INITIALIZATION_EVENTS.BEHAVIOR_ATTACH)
                {
                    handleAttached(he);
                }
                res = false;
                break;
            }
        case EVENT_GROUPS.HANDLE_SOM:
            {
                res = handleEvent(he, cast(SOM_PARAMS*) prms);
                break;
            }
        case EVENT_GROUPS.HANDLE_BEHAVIOR_EVENT:
            {
                res = handleEvent(he, cast(BEHAVIOR_EVENT_PARAMS*) prms);
                break;
            }
        case EVENT_GROUPS.HANDLE_SCRIPTING_METHOD_CALL:
            {
                res = handleEvent(he, cast(SCRIPTING_METHOD_PARAMS*) prms);
                break;
            }
        case EVENT_GROUPS.HANDLE_GESTURE:
            {
                res = handleEvent(he, cast(GESTURE_PARAMS*) prms);
                break;
            }
        case EVENT_GROUPS.HANDLE_DRAW:
            {
                res = handleEvent(he, cast(DRAW_PARAMS*) prms);
                break;
            }
        case EVENT_GROUPS.HANDLE_DATA_ARRIVED:
            {
                res = handleEvent(he, cast(DATA_ARRIVED_PARAMS*) prms);
                break;
            }
        case EVENT_GROUPS.HANDLE_FOCUS:
            {
                res = handleEvent(he, cast(FOCUS_PARAMS*) prms);
                break;
            }
        case EVENT_GROUPS.HANDLE_KEY:
            {
                res = handleEvent(he, cast(KEY_PARAMS*) prms);
                break;
            }
        case EVENT_GROUPS.HANDLE_SCROLL:
            {
                res = handleEvent(he, cast(SCROLL_PARAMS*) prms);
                break;
            }
        case EVENT_GROUPS.HANDLE_TIMER:
            {
                res = handleEvent(he, cast(TIMER_PARAMS*) prms);
                break;
            }
        case EVENT_GROUPS.HANDLE_MOUSE:
            {
                res = handleEvent(he, cast(MOUSE_PARAMS*) prms);
                break;
            }
        case EVENT_GROUPS.HANDLE_EXCHANGE:
            {
                res = handleEvent(he, cast(EXCHANGE_PARAMS*) prms);
                break;
            }
        case EVENT_GROUPS.HANDLE_ATTRIBUTE_CHANGE:
            {
                res = handleEvent(he, cast(ATTRIBUTE_CHANGE_PARAMS*) prms);
                break;
            }
        case EVENT_GROUPS.HANDLE_STYLE_CHANGE:
            {
                res = handleEventStyleChange(he, cast(uint) prms);
                break;
            }

        default:
            break;
        }

        return res;
    }

    // to override

    protected void handleDetached(HELEMENT he)
    {
    }

    protected void handleAttached(HELEMENT he)
    {
    }

    protected bool handleSubscription(HELEMENT he, UINT* event_groups)
    {
        // Subscribe to all events except HANDLE_EXCHANGE and HANDLE_GESTURE
        // (excluded to isolate a crash on Mac)
        *event_groups = EVENT_GROUPS.HANDLE_ALL &
            ~EVENT_GROUPS.HANDLE_EXCHANGE &
            ~EVENT_GROUPS.HANDLE_GESTURE;
        return true;
    }

    protected bool handleEvent(HELEMENT he, SOM_PARAMS* params)
    {
        return false;
    }

    protected bool handleEvent(HELEMENT he, BEHAVIOR_EVENT_PARAMS* params)
    {
        return false;
    }

    protected bool handleEvent(HELEMENT he, SCRIPTING_METHOD_PARAMS* params)
    {
        return false;
    }

    protected bool handleEvent(HELEMENT he, GESTURE_PARAMS* params)
    {
        return false;
    }

    protected bool handleEvent(HELEMENT he, KEY_PARAMS* params)
    {
        return false;
    }

    protected bool handleEvent(HELEMENT he, SCROLL_PARAMS* params)
    {
        return false;
    }

    protected bool handleEvent(HELEMENT he, FOCUS_PARAMS* params)
    {
        return false;
    }

    protected bool handleEvent(HELEMENT he, MOUSE_PARAMS* params)
    {
        // On Mac, events often arrive in the SINKING phase (0x80FE), so we mask cmd
        // Commented out to allow HTML5 drag-and-drop for tabs
        /*if ((params.cmd & 0xFF) == MOUSE_EVENTS.MOUSE_DRAG_REQUEST)
        {
            return true; // Prevent the system Drag-and-Drop loop from starting
        }*/
        return false;
    }

    protected bool handleEvent(HELEMENT he, TIMER_PARAMS* params)
    {
        return false;
    }

    protected bool handleEvent(HELEMENT he, EXCHANGE_PARAMS* params)
    {
        return false;
    }

    protected bool handleEvent(HELEMENT he, ATTRIBUTE_CHANGE_PARAMS* params)
    {
        return false;
    }

    protected bool handleEventStyleChange(HELEMENT he, uint style_change_kind) // HANDLE_STYLE_CHANGE
    {
        return false;
    }

    protected bool handleEvent(HELEMENT he, DRAW_PARAMS* params)
    {
        return false;
    }

    protected bool handleEvent(HELEMENT he, DATA_ARRIVED_PARAMS* params)
    {
        return false;
    }

}

@("SciterEventHandler.elementProc: nothing thrown unwinds into Sciter")
unittest
{
    import std.traits : FunctionAttribute, functionAttributes;

    assert(functionAttributes!(SciterEventHandler.elementProc) & FunctionAttribute.nothrow_,
        "elementProc must be nothrow: an exception would unwind through the frames of Sciter");
}
