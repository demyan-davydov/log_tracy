module sciter_wrapper.sciter_event_handler;

import sciter_wrapper.sciter_api;

import sciter.types;
import sciter.behavior;
import sciter.def;
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
                res = self.handleEvent(he, cast(INITIALIZATION_PARAMS*) prms);
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

        default:
            break;
        }

        return res ? 1 : 0;
    }

    // to override

    protected bool handleSubscription(HELEMENT he, UINT* event_groups)
    {
        // Подписываемся на всё, кроме HANDLE_EXCHANGE и HANDLE_GESTURE (для изоляции краша на Mac)
        *event_groups = EVENT_GROUPS.HANDLE_ALL &
            ~EVENT_GROUPS.HANDLE_EXCHANGE &
            ~EVENT_GROUPS.HANDLE_GESTURE;
        return true;
    }

    protected bool handleEvent(HELEMENT he, INITIALIZATION_PARAMS* params)
    {
        return false;
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
        // На Mac события часто приходят в фазе SINKING (0x80FE), поэтому маскируем cmd
        if ((params.cmd & 0xFF) == MOUSE_EVENTS.MOUSE_DRAG_REQUEST)
        {
            return true; // Предотвращаем запуск системного Drag-and-Drop цикла
        }
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

    protected bool handleEvent(HELEMENT he, DRAW_PARAMS* params)
    {
        return false;
    }

    protected bool handleEvent(HELEMENT he, DATA_ARRIVED_PARAMS* params)
    {
        return false;
    }

}
