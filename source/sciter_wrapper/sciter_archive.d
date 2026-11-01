module sciter_wrapper.sciter_archive;

import sciter.def;
import sciter.types;
import sciter.api;
import sciter.dom;

import sciter_wrapper.sciter_api;

// Sciter's compressed archive produced by sdk/bin/packfolder.exe
struct Archive
{
    private HSARCHIVE har = null;

    // open archive blob (NOTE: archive does not copy the data - it has to be available while archive is used )
    bool open(const(ubyte)[] data)
    {
        close();
        har = sciterApi().SciterOpenArchive(data.ptr, cast(uint)data.length);
        return !(har is null);
    }

    void close()
    {
        if (har)
        {
            sciterApi().SciterCloseArchive(har);
            har = null;
        }
    }

    // get archive item:
    const(ubyte)[] get(LPCWSTR path)
    {
        const(ubyte)* pb = null;
        uint blen = 0;
        // skip leading double slash if present
        if (path[0] == '/' && path[1] == '/')
            path += 2;
        sciterApi().SciterGetArchiveItem(har, path, &pb, &blen);
        return pb[0 .. blen];
    }
}

private __gshared Archive instance;

public Archive* sciterArchive() nothrow @nogc
{
    return &instance;
}
