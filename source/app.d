//! The entry point: starts Sciter, makes the application (the session and its window) and
//! runs the event loop.
import std.stdio;

import ui.app_resources : appResource, appResourceUrl;
import domain.document : Document;
import domain.log_document : LogDocument;
import log_core.log_format : FormatChoice;
import ui.app_menu : hostMenuPlatform, windowMenu;
import ui.app_session : AppSession;
import ui.main_window;
import ui.debug_channel : startDebugChannel;
import ui.app_settings;
import ui.main_menu_loader : forgetAppMenuWindow, loadAppMenu;
import utils.single_instance : SingleInstance;

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

/// The application behind the window: its documents are LogDocuments of the files, and the
/// environment variables for development (docs/building.md, "Environment variables for
/// development") are all read here
/// @param sciterDebugMode - set when SCITER_DEBUG_MODE asks for the debug mode of Sciter
private AppSession newSession(AppSettings settings, out bool sciterDebugMode)
{
	import std.process : environment;

	auto session = new AppSession(settings,
		(string path, FormatChoice choice) => cast(Document) new LogDocument(path, choice));
	// MENU_BAR_PLATFORM=windows|linux: that menu bar in the window, for a try on any platform
	session.showMenu(windowMenu(hostMenuPlatform(), environment.get("MENU_BAR_PLATFORM", "")));
	// PSEUDO_LOCALE=1: the pseudo translation among the languages of Settings
	session.offerPseudoLocale(environment.get("PSEUDO_LOCALE", "") == "1");
	// OPEN_AT_START=<path>[<new line><path>...]: files opened at start, to look at the app
	// with a log (scripts/screenshot.mjs)
	session.openAtStart(environment.get("OPEN_AT_START", ""));
	// SCITER_DEBUG_MODE=1: the debug mode of Sciter, for its inspector (set on the window)
	sciterDebugMode = environment.get("SCITER_DEBUG_MODE", "") == "1";
	return session;
}

int main()
{
	// Debug builds write a line out as soon as it ends, also when the output goes to a file or a
	// pipe (scripts/screenshot.mjs keeps it in app.log, a redirected run): fully buffered there,
	// the lines still in the buffer are lost when the process is killed or crashes, and the log
	// of a failure comes out empty. Windows has no line buffering (_IOLBF is full buffering in
	// its C library): unbuffered there. Release builds keep the default. A stdout that can't be
	// set up (a Windows program without a console) is left as it is: the app runs anyway.
	debug
	{
		import core.stdc.stdio : _IOLBF, _IONBF;

		try
		{
			version (Windows)
				stdout.setvbuf(0, _IONBF);
			else
				stdout.setvbuf(0, _IOLBF);
		}
		catch (Exception e)
			writeln("Can't make the output line buffered: ", e.msg);
	}

	enableSciterDebugOutput();

	writeln("DLT Explorer starting...");

	// A release build runs one copy per settings.json: two would overwrite each other's
	// settings. A second copy brings the first one forward and exits. Debug builds run side by
	// side, for debugging.
	debug {} else
	{
		SingleInstance instance;
		try
			instance = new SingleInstance(instanceLockPath());
		catch (Exception e)
			writeln("Can't check for a running copy: ", e.msg); // started anyway
		scope (exit) if (instance) instance.release(); // also keeps it alive till the end

		if (instance && !instance.isFirst)
		{
			writeln("DLT Explorer is running already (process ", instance.firstPid, ")");
			instance.activateFirst();
			return 0;
		}
	}

	sciterApplication().start();

	// The script gets none of the runtime features of Sciter: it reads no files (the backend
	// does, through xcall), opens no sockets, evaluates no strings and loads no native modules,
	// and the window shows the text of logs from anywhere. What it uses works without them
	// (checked on macOS, 6.0.5.5): its modules, @env (the language of the system), the
	// clipboard, the dialogs (Window.this.modal, selectFile), SciterEval of the debug channel.
	// A new need gets its flag here, with why.
	sciterApi().SciterSetOption(null, SCITER_RT_OPTIONS.SCITER_SET_SCRIPT_RUNTIME_FEATURES, 0);

    import sciter.capi.types;
    sciterApi().SciterSetOption(null, SCITER_RT_OPTIONS.SCITER_SET_GFX_LAYER, GFX_LAYER.GFX_LAYER_SKIA_ANGLE);

	sciterApi().SciterSetMediaType(null, "desktop,gsciter"w.ptr);

	int result = 0;

	try
	{
		auto settings = loadSettings();
		bool sciterDebugMode;
		auto session = newSession(settings, sciterDebugMode);
		scope auto win = new MainWindow(session, sciterDebugMode); // scope ensures that d'tor is called on exit

		// SCITER_DEBUG_PORT=<port>: the debug channel to the window, debug builds only
		auto debugChannel = startDebugChannel(win.hwnd);
		scope (exit) debugChannel.stop(); // before the window is destroyed

        loadAppMenu(win);

		// The files of the interface are built in, served by the window at this://app/
		win.loadHtml(appResource("main.htm"), appResourceUrl ~ "main.htm");

		win.expand();
		win.activate(true); // Explicit activation for new Sciter version

		win.updateWindow();

		writeln("Event loop starting...");
		while (sciterApplication().runIteration())
			win.onIdle();
		result = 0;
		writeln("Event loop stopped");

		// Cancel and join indexing threads: they are not daemon threads, so the
		// runtime would otherwise wait for them to finish after main() returns.
		win.closeAllDocuments();
		forgetAppMenuWindow(); // `win` is destroyed at the end of this block
		writeln("Documents closed");

	}
	catch (Exception e)
	{
		writeln("Error: ", e.msg);
		result = 1;
	}

	sciterApplication().shutdown();

	return result;
}
