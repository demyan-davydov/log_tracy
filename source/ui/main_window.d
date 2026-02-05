module ui.main_window;

import sciter_wrapper.sciter_window;
import ui.settings;

import sciter.types;

class MainWindow : SciterWindow
{
    this(in AppSettings settings)
    {
        enum uint creationFlags = 1 | 2 | 8 | 64; // SW_TITLEBAR | SW_RESIZEABLE | SW_CONTROLS | SW_MAIN

        RECT frame;
        frame.left = settings.windowRect.left;
        frame.top = settings.windowRect.top;
        frame.right = settings.windowRect.right;
        frame.bottom = settings.windowRect.bottom;

        super(creationFlags, frame);
    }
}
