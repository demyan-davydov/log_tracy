module sciter.api;

import sciter.capi.api;
import utils.dllib;
import std.exception : enforce;
import std.stdio : writeln;

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
    loadSciterLib();
}

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
    }
}

public SciterAPI_T* sciterApi() nothrow @nogc
{
    return instance.api;
}
