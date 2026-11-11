//! SciterEventHandler: the base of the D handlers of Sciter's DOM and window events.
module sciter.event_handler;

import sciter.api;

import sciter.capi.types;
import sciter.capi.behavior;
import sciter.capi.def;
import std.stdio : writeln;

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

    private static extern (C) SBOOL elementProc(void* tag, HELEMENT he, uint evtg, void* prms)
    {
        auto self = cast(SciterEventHandler) tag;
        if (self is null)
            return 0;

        bool res = false;

        switch (evtg)
        {
        case EVENT_GROUPS.SUBSCRIPTIONS_REQUEST:
            {
                UINT* p = cast(UINT*) prms;
                res = self.handleSubscription(he, p);
                break;
            }
        case EVENT_GROUPS.HANDLE_INITIALIZATION:
            {
                auto params = cast(INITIALIZATION_PARAMS*) prms;
                if (params.cmd == INITIALIZATION_EVENTS.BEHAVIOR_DETACH)
                {
                    self.handleDetached(he);
                }
                else if (params.cmd == INITIALIZATION_EVENTS.BEHAVIOR_ATTACH)
                {
                    self.handleAttached(he);
                }
                res = false;
                break;
            }
        case EVENT_GROUPS.HANDLE_SOM:
            {
                res = self.handleEvent(he, cast(SOM_PARAMS*) prms);
                break;
            }
        case EVENT_GROUPS.HANDLE_BEHAVIOR_EVENT:
            {
                res = self.handleEvent(he, cast(BEHAVIOR_EVENT_PARAMS*) prms);
                break;
            }
        case EVENT_GROUPS.HANDLE_SCRIPTING_METHOD_CALL:
            {
                res = self.handleEvent(he, cast(SCRIPTING_METHOD_PARAMS*) prms);
                break;
            }
        case EVENT_GROUPS.HANDLE_GESTURE:
            {
                res = self.handleEvent(he, cast(GESTURE_PARAMS*) prms);
                break;
            }
        case EVENT_GROUPS.HANDLE_DRAW:
            {
                res = self.handleEvent(he, cast(DRAW_PARAMS*) prms);
                break;
            }
        case EVENT_GROUPS.HANDLE_DATA_ARRIVED:
            {
                res = self.handleEvent(he, cast(DATA_ARRIVED_PARAMS*) prms);
                break;
            }
        case EVENT_GROUPS.HANDLE_FOCUS:
            {
                res = self.handleEvent(he, cast(FOCUS_PARAMS*) prms);
                break;
            }
        case EVENT_GROUPS.HANDLE_KEY:
            {
                res = self.handleEvent(he, cast(KEY_PARAMS*) prms);
                break;
            }
        case EVENT_GROUPS.HANDLE_SCROLL:
            {
                res = self.handleEvent(he, cast(SCROLL_PARAMS*) prms);
                break;
            }
        case EVENT_GROUPS.HANDLE_TIMER:
            {
                res = self.handleEvent(he, cast(TIMER_PARAMS*) prms);
                break;
            }
        case EVENT_GROUPS.HANDLE_MOUSE:
            {
                res = self.handleEvent(he, cast(MOUSE_PARAMS*) prms);
                break;
            }
        case EVENT_GROUPS.HANDLE_EXCHANGE:
            {
                res = self.handleEvent(he, cast(EXCHANGE_PARAMS*) prms);
                break;
            }
        case EVENT_GROUPS.HANDLE_ATTRIBUTE_CHANGE:
            {
                res = self.handleEvent(he, cast(ATTRIBUTE_CHANGE_PARAMS*) prms);
                break;
            }
        case EVENT_GROUPS.HANDLE_STYLE_CHANGE:
            {
                res = self.handleEventStyleChange(he, cast(uint) prms);
                break;
            }

        default:
            break;
        }

        return res ? 1 : 0;
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
