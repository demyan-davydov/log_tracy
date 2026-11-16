//! Loads the Sciter library and gives its API (sciterApi), once per process.
module sciter.api;

import sciter.capi.api;
import utils.dllib;
import std.exception : enforce;
import std.stdio : writeln;
import utils.std_streams : streamsChecked;

/// Load Sciter library and initialize API
/// This is a singleton, so it will be loaded only once
/// and unloaded when the program exits
///
/// Usage:
/// ```d
/// auto api = sciterLib();
/// ```

shared static this()
{
    streamsCheckedBeforeSciter = streamsChecked();
    loadSciterLib();
}

// Whether utils/std_streams had fixed the missing streams when Sciter was loaded: its load
// writes to stdout, a missing one would throw before main
private __gshared bool streamsCheckedBeforeSciter;

@("loadSciterLib: the missing standard streams are fixed before Sciter is loaded")
unittest
{
    assert(streamsCheckedBeforeSciter,
        "utils/std_streams's constructor must run before this module's: it writes to stdout");
}

// Unloaded after main: a use of Sciter past this point (a finalizer of the last collection of
// the GC, which runs after the module destructors) is a bug, and sciterApi() says so
shared static ~this()
{
    unloadSciterLib();
}

version (OSX)
{
    private enum LIB_NAME = "libsciter.dylib";
}
else version (linux)
{
    private enum LIB_NAME = "libsciter.so";
}
else version (Windows)
{
    private enum LIB_NAME = "sciter.dll";
}
else
{
    static assert(0, "Unsupported platform");
}

private struct LibHolder
{
    LibHandle lib;
    SciterAPI_T* api;
    bool unloaded; // by the module destructor, at exit
}

private __gshared LibHolder instance;

private void loadSciterLib()
{
    // Try to load from executable directory first (for App Bundle support)
    import std.file : thisExePath;
    import std.path : dirName, buildPath;

    string exeDir = thisExePath().dirName;
    string libPath = buildPath(exeDir, LIB_NAME);

    instance.lib = loadLib(libPath);

    if (!instance.lib)
    {
        // Fallback to standard search (LD_LIBRARY_PATH, etc.)
        instance.lib = loadLib(LIB_NAME);
    }

    // As a last ditch effort, try ../Frameworks/ (standard bundle location, though we copy to MacOS for now)
    if (!instance.lib)
    {
        string frameworkPath = buildPath(exeDir, "../Frameworks", LIB_NAME);
        instance.lib = loadLib(frameworkPath);
    }

    enforce(instance.lib, "Could not load Sciter library: " ~ LIB_NAME);

    alias SciterAPIFunc = extern (C) SciterAPI_T* function();
    auto getApi = cast(SciterAPIFunc) getSymbol(instance.lib, "SciterAPI");
    enforce(getApi, "Could not find SciterAPI symbol in " ~ LIB_NAME);

    instance.api = getApi();
    writeln("Sciter library loaded: ", LIB_NAME);
    writeln("Sciter API Version: ", instance.api.version_);
    writeln("-------------------------------");
    writeln();
}

private void unloadSciterLib()
{
    if (instance.lib)
    {
        unloadLib(instance.lib);
        instance.lib = null;
        instance.api = null;
        instance.unloaded = true;
    }
}

public SciterAPI_T* sciterApi() nothrow @nogc
{
    assert(!instance.unloaded, "Sciter is used after it was unloaded at exit: by a finalizer of "
        ~ "the GC, most likely (a SciterValue or a SciterWindow left to the GC after main)");
    return instance.api;
}
