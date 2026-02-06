module ui.main_window;

import sciter_wrapper.sciter_window;
import ui.settings;

import sciter.types;

class MainWindow : SciterWindow
{
    this(in AppSettings settings)
    {
        import sciter.def;

        enum uint creationFlags =
            SCITER_CREATE_WINDOW_FLAGS.SW_MAIN;

        RECT frame;
        frame.left = settings.windowRect.left;
        frame.top = settings.windowRect.top;
        frame.right = settings.windowRect.right;
        frame.bottom = settings.windowRect.bottom;

        super(creationFlags, frame);

        // Disable extended touchpad support on Mac to prevent gesture-related crashes
        _api.SciterSetOption(hwnd, 19 /*SCITER_EXTENDED_TOUCHPAD_SUPPORT*/ , 0);
    }
}
