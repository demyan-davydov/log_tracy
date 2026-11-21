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
    // SciterVersion(n) is the n-th part (0..3) of the library version, as in 6.0.5.5.
    writeln("Sciter Version: ", instance.api.SciterVersion(0), ".", instance.api.SciterVersion(1),
        ".", instance.api.SciterVersion(2), ".", instance.api.SciterVersion(3));
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

/// The graphics API of the loaded Sciter (sciter-x-graphics.h): drawing and text layouts of
/// a native behavior
public SciterGraphicsAPI* graphicsApi() nothrow @nogc
{
    static __gshared SciterGraphicsAPI* table;
    if (table is null)
        table = cast(SciterGraphicsAPI*) sciterApi().GetSciterGraphicsAPI();
    return table;
}

@("graphicsApi: the table is the one of the header: a color comes out as the header says")
unittest
{
    import sciter.capi.graphics : graphicsApiOrder;

    assert(graphicsApi() !is null);
    // SC_COLOR is a, b, g, r from the top byte (sciter-x-graphics.h); a function out of place
    // in the table would answer something else
    assert(graphicsApi().RGBA(0x11, 0x22, 0x33, 0x44) == 0x44_33_22_11);
    assert(graphicsApi().RGBA(1, 2, 3, 255) == 0xFF_03_02_01);
    static assert(graphicsApiOrder[8] == "RGBA");
}
