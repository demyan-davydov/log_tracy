//! Shows a file in the file manager of the system (Finder, Explorer, the file
//! manager of a Linux desktop): the command for each system and its start.
module utils.file_manager;

/// The systems, by the file manager they show a file in
enum DesktopOs
{
    macOS,
    windows,
    linux,
}

/// The system this build runs on
DesktopOs hostOs() pure nothrow @nogc @safe
{
    version (OSX)
        return DesktopOs.macOS;
    else version (Windows)
        return DesktopOs.windows;
    else
        return DesktopOs.linux;
}


/// The command that shows `path` in the file manager of `os`: selected in its
/// folder (Finder, Explorer); a Linux desktop has no common way to select a
/// file, its folder is opened
string[] showInFolderCommand(DesktopOs os, string path) pure @safe
{
    import std.path : dirName;

    final switch (os)
    {
    case DesktopOs.macOS:
        return ["open", "-R", path];
    case DesktopOs.windows:
        return ["explorer.exe", "/select,", path];
    case DesktopOs.linux:
        return ["xdg-open", path.dirName];
    }
}

/// Shows `path` in the file manager of this system, without waiting for it.
/// Throws if the command can't be started.
void showInFolder(string path)
{
    import std.process : Config, spawnProcess;

    spawnProcess(showInFolderCommand(hostOs(), path), null, Config.detached | Config.suppressConsole);
}

/// Finder selects the file in its folder
unittest
{
    assert(showInFolderCommand(DesktopOs.macOS, "/logs/a b.dlt") == ["open", "-R", "/logs/a b.dlt"]);
}

/// Explorer selects it too: the path an argument of its own after "/select,",
/// so it is quoted as one (no shell between, which would expand %NAME% in it)
unittest
{
    assert(showInFolderCommand(DesktopOs.windows, `C:\logs\a %b%.dlt`)
        == ["explorer.exe", "/select,", `C:\logs\a %b%.dlt`]);
}

/// Linux opens the folder of the file
unittest
{
    assert(showInFolderCommand(DesktopOs.linux, "/logs/a b.dlt") == ["xdg-open", "/logs"]);
    assert(showInFolderCommand(DesktopOs.linux, "/a.dlt") == ["xdg-open", "/"]);
}
