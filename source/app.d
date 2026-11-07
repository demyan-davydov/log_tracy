import std.stdio;

import ui.app_resources : appResource, appResourceUrl;
import ui.main_window;
import ui.app_settings;
import ui.main_menu_loader : loadAppMenu;

import sciter.capi.def;

import sciter.api;
import sciter.application;
import sciter.debug_output;

import std.stdio : writeln;

// A 64-bit build only. A log is mapped into memory whole (utils/mapped_file), and logs of a
// gigabyte with their indexes don't fit the address space of a 32-bit process. The Sciter
// binding refuses a 32-bit build too (sciter/capi/def).
static assert(size_t.sizeof == 8, "DLT Explorer is built for 64-bit systems only "
    ~ "(logs are mapped into memory whole). Build for x86_64 or arm64.");

// macOS: Workaround for Sciter not calling setNeedsDisplay on NSView.
version (OSX)
{
	private extern (C)
	{
		alias objc_id = void*;
		alias SEL = void*;
		SEL sel_registerName(const(char)* name);
		void* objc_msgSend(objc_id self, SEL op, ...);
	}

	// Call [nsView setNeedsDisplay:YES] via objc_msgSend
	private void nsViewSetNeedsDisplay(objc_id nsView, SEL sel)
	{
		alias Fn = extern (C) void function(objc_id, SEL, byte);
		auto fn = cast(Fn)&objc_msgSend;
		fn(nsView, sel, 1); // YES = 1
	}
}

int main()
{
	enableSciterDebugOutput();

	writeln("DLT Explorer starting...");

	sciterApplication().start();

	sciterApi().SciterSetOption(null,
		SCITER_RT_OPTIONS.SCITER_SET_SCRIPT_RUNTIME_FEATURES,
		SCRIPT_RUNTIME_FEATURES.ALLOW_FILE_IO |
			SCRIPT_RUNTIME_FEATURES.ALLOW_SOCKET_IO |
			SCRIPT_RUNTIME_FEATURES.ALLOW_EVAL |
			SCRIPT_RUNTIME_FEATURES.ALLOW_SYSINFO |
			SCRIPT_RUNTIME_FEATURES.ALLOW_CMODULES
	);

    import sciter.capi.types;
    sciterApi().SciterSetOption(null, SCITER_RT_OPTIONS.SCITER_SET_GFX_LAYER, GFX_LAYER.GFX_LAYER_SKIA_ANGLE);

	sciterApi().SciterSetMediaType(null, "desktop,gsciter"w.ptr);

	int result = 0;

	try
	{
		auto settings = loadSettings();
		scope auto win = new MainWindow(settings); // scope ensures that d'tor is called on exit

        loadAppMenu(win);

		// The files of the interface are built in, served by the window at this://app/
		win.loadHtml(appResource("main.htm"), appResourceUrl ~ "main.htm");

		win.expand();
		win.activate(true); // Explicit activation for new Sciter version

		win.updateWindow();

		writeln("Event loop starting...");
		//sciterApplication().runEventLoop();

		//version (OSX)
		static if (false)
		{
			// Workaround: New Sciter versions don't call setNeedsDisplay on macOS.
			// Use manual event loop iteration + direct NSView invalidation.
			// HWINDOW on macOS is NSWindow*, so we get its contentView first.
			auto selContentView = sel_registerName("contentView");
			auto selSetNeedsDisplay = sel_registerName("setNeedsDisplay:");

			auto nsWindow = cast(objc_id) win.hwnd();
			alias ContentViewFn = extern (C) objc_id function(objc_id, SEL);
			auto getContentView = cast(ContentViewFn)&objc_msgSend;
			auto nsView = getContentView(nsWindow, selContentView);

			import core.thread : Thread;
			import core.time : dur;

			enum FRAME_TIME = dur!"msecs"(16); // ~60fps cap

			while (sciterApplication().runIteration())
			{
				win.onIdle();
				// Invalidate + sleep to cap at ~60fps, prevent busy-waiting
				nsViewSetNeedsDisplay(nsView, selSetNeedsDisplay);
				Thread.sleep(FRAME_TIME);
			}
			result = 0;
		}
		else
		{
			while (sciterApplication().runIteration())
			{
				win.onIdle();
			}
			result = 0;
		}

		writeln("Event loop stopped");

		// Cancel and join indexing threads: they are not daemon threads, so the
		// runtime would otherwise wait for them to finish after main() returns.
		win.closeAllDocuments();
		writeln("Documents closed");

		//win.detachEventHandler();
		//win.destroy(); // call d'tor
	}
	catch (Exception e)
	{
		writeln("Error: ", e.msg);
		result = 1;
	}

	sciterApplication().shutdown();

	return result;
}
