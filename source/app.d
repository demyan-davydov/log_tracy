import std.stdio;

//import ui.my_main_window;
import ui.main_window;
import ui.app_settings;

import sciter.def;

import sciter_wrapper.sciter_api;
import sciter_wrapper.sciter_application;
import sciter_wrapper.sciter_debug_output;

import std.file : getcwd, exists;
import std.path : buildPath;
import std.stdio : writeln;

/+ 
class frame : public sciter::window {
public:
  frame() : window(SW_MAIN /*| SW_ENABLE_DEBUG*/ /*, RECT({20,20,820,620})*/) {}
};

int uimain(std::function<int()> run) {

  sciter::debug_output_console _;
    
  //SciterSetOption(NULL, SCITER_SET_GFX_LAYER, GFX_LAYER_SKIA_RASTER);

  SciterSetOption(NULL, SCITER_SET_SCRIPT_RUNTIME_FEATURES,
    ALLOW_FILE_IO |
    ALLOW_SOCKET_IO |
    ALLOW_EVAL |
    ALLOW_SYSINFO |
    ALLOW_CMODULES);

#ifdef _DEBUG
  sciter::debug_output_console console;
#endif

  frame* pwin = new frame();

  // note: this:://app URL is dedicated to the sciter::archive content associated with the application
#ifdef OSX
  pwin->load(WSTR("home://../../../../../demos/tsciter/index.htm"));
#else
  pwin->load(WSTR("home://../../../demos/tsciter/index.htm"));
#endif
  pwin->expand();

  return run();

}
+/

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

	sciterApi().SciterSetMediaType(null, "desktop,gsciter"w.ptr);
	//   SciterSetMediaType(pwin->get_hwnd(), WSTR("desktop,gsciter"));

	int result = 0;

	try
	{
		auto settings = loadSettings();
		scope auto win = new MainWindow(settings); // scope ensures that d'tor is called on exit

		// Load the main HTML resource
		// In a real build, we would use "this://app/main.htm" and handle SC_LOAD_DATA to serve from import("main.htm")
		// For now, load from filesystem absolute path or relative?
		// SciterLoadFile handles absolute paths well.

		import std.file : thisExePath;
		import std.path : dirName;

		string exeDir = thisExePath().dirName;
		string projectRoot = getcwd();

		string[] possiblePaths = [
			// Relative to executable (Best for deployed apps)
			buildPath(exeDir, "resources", "main.htm"),
			buildPath(exeDir, "main.htm"),
			buildPath(exeDir, "../Resources/main.htm"), // macOS Bundle standard

			// Relative to CWD (Development)
			buildPath(projectRoot, "resources", "main.htm"),
			buildPath(projectRoot, "main.htm")
		];

		string resources;
		foreach (path; possiblePaths)
		{
			if (exists(path))
			{
				resources = path;
				break;
			}
		}

		if (resources.length > 0)
		{
			win.loadFile(resources);
		}
		else
		{
			writeln("Error: Could not find main.htm in any of the expected locations.");
		}

		//win.run();

		//win.expand();
		win.activate(true); // Explicit activation for new Sciter version

		writeln("Event loop starting...");

		result = sciterApplication().runEventLoop();

		writeln("Event loop stopped");

		//win.detachEventHandler();
		//win.destroy(); // call d'tor
	}
	catch (Exception e)
	{
		writeln("Error: ", e.msg);
	}

	sciterApplication().shutdown();

	return result;
}

/*
void prev_main()
{
	writeln("DLT Explorer starting...");

	try
	{
		auto settings = loadSettings();
		auto win = new MyMainWindow(settings);

		// Load the main HTML resource
		// In a real build, we would use "this://app/main.htm" and handle SC_LOAD_DATA to serve from import("main.htm")
		// For now, load from filesystem absolute path or relative?
		// SciterLoadFile handles absolute paths well.

		string projectRoot = getcwd();
		// If projectRoot already ends with resources, don't add it again (though dub usually runs from root)
		string resources = buildPath(projectRoot, "resources", "main.htm");
		if (exists(resources))
		{
			win.loadFile(resources);
		}
		else
		{
			// Try without "resources" if dub is running from within resources/ for some reason
			resources = buildPath(projectRoot, "main.htm");
			win.loadFile(resources);
		}

		win.run();

		writeln("DLT Explorer exiting...");
		win.saveSettings();
	}
	catch (Exception e)
	{
		writeln("Error: ", e.msg);
	}
}
*/
