module sciter_wrapper.sciter_api;

import sciter.api;
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
    instance.lib = loadLib(LIB_NAME);
    enforce(instance.lib, "Could not load Sciter library: " ~ LIB_NAME);

    alias SciterAPIFunc = extern (C) SciterAPI_T* function();
    auto getApi = cast(SciterAPIFunc) getSymbol(instance.lib, "SciterAPI");
    enforce(getApi, "Could not find SciterAPI symbol");

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
