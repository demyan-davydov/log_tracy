//! Loads a dynamic library and its symbols, on each platform.
module utils.dllib;

///
/// Dynamic Linker helpers
///

import std.string : toStringz;

version (Windows)
{
    import core.sys.windows.windows;

    alias LibHandle = HMODULE;
    LibHandle loadLib(string name) nothrow
    {
        return LoadLibraryA(toStringz(name));
    }

    void unloadLib(LibHandle lib) nothrow
    {
        FreeLibrary(lib);
    }

    void* getSymbol(LibHandle lib, string sym) nothrow
    {
        return GetProcAddress(lib, toStringz(sym));
    }
}
else
{
    import core.sys.posix.dlfcn;

    alias LibHandle = void*;
    LibHandle loadLib(string name) nothrow
    {
        return dlopen(toStringz(name), RTLD_LAZY | RTLD_LOCAL); // Match OSX sample
    }

    void unloadLib(LibHandle lib) nothrow
    {
        dlclose(lib);
    }

    void* getSymbol(LibHandle lib, string sym) nothrow
    {
        return dlsym(lib, toStringz(sym));
    }
}
