//! The path of a file the script names: a `file://` URL (what Sciter's dialogs return) or a
//! path as it is.
module utils.file_url;

import std.algorithm.searching : startsWith;

/// The path a `file://` URL names, anything else as it is. Windows keeps the drive's letter
/// first: "file:///C:/a" (three slashes) and "file://C:/a" are both "C:/a", never "/C:/a".
string pathOfFileUrl(string url, bool windows = isWindows) pure
{
    if (!url.startsWith("file://"))
        return url;
    string path = url[7 .. $];
    if (windows && path.startsWith("/") && startsWithDrive(path[1 .. $]))
        return path[1 .. $];
    if (path.startsWith("/") || (windows && startsWithDrive(path)))
        return path;
    return "/" ~ path;
}

/// Whether a path starts with a drive's letter and its colon: "C:"
private bool startsWithDrive(string path) pure
{
    import std.ascii : isAlpha;

    return path.length >= 2 && isAlpha(path[0]) && path[1] == ':';
}

version (Windows)
    private enum isWindows = true;
else
    private enum isWindows = false;

@("pathOfFileUrl: on Windows a drive's letter after three slashes leads the path")
unittest
{
    assert(pathOfFileUrl("file:///C:/logs/a.dlt", true) == "C:/logs/a.dlt");
    assert(pathOfFileUrl("file:///d:/a.dlt", true) == "d:/a.dlt");
}

@("pathOfFileUrl: on Windows a drive's letter after two slashes leads the path")
unittest
{
    assert(pathOfFileUrl("file://C:/logs/a.dlt", true) == "C:/logs/a.dlt");
}

@("pathOfFileUrl: elsewhere the path starts at the root")
unittest
{
    assert(pathOfFileUrl("file:///Users/me/a.dlt", false) == "/Users/me/a.dlt");
    assert(pathOfFileUrl("file://Users/me/a.dlt", false) == "/Users/me/a.dlt");
    assert(pathOfFileUrl("file:///C:/a.dlt", false) == "/C:/a.dlt");
}

@("pathOfFileUrl: a path that is no URL stays as it is")
unittest
{
    assert(pathOfFileUrl(`C:\logs\a.dlt`, true) == `C:\logs\a.dlt`);
    assert(pathOfFileUrl("/logs/a.dlt", false) == "/logs/a.dlt");
}
