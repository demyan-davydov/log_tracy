module ui.app_settings;

import std.json;
import std.file;
import std.stdio;
import std.path;
import std.conv;
import std.array;
import std.algorithm;

import formats.registry : formatInfo;
import log_core.log_format : FormatChoice, FormatInfo;

struct WindowRect
{
    int left;
    int top;
    int width;
    int height;

    int right() const pure @nogc @property
    {
        return left + width;
    }

    int bottom() const pure @nogc @property
    {
        return top + height;
    }
}

struct FileState
{
    string path;
    int scrollPosition;
}

/// Length of the recent files list
enum recentFilesMax = 8;

/// The spelling of `path` in the recent list: absolute and normalized
string recentFilePath(string path)
{
    return buildNormalizedPath(absolutePath(path));
}

/// A file of the recent list
struct RecentFile
{
    string path;
    FormatChoice format; /// the format it was opened with last time; unset if never opened
}

/// Returns the recent files list with `file` on top, without duplicates
/// (paths are compared normalized, ignoring case where the OS does) and
/// no longer than recentFilesMax. Without a format the file keeps the one
/// it had in the list (e.g. it failed to open this time).
RecentFile[] withRecentFile(const RecentFile[] list, RecentFile file)
{
    RecentFile[] result = list.dup;
    if (file.path.length)
    {
        file.path = recentFilePath(file.path);
        if (!file.format.isSet)
            file.format = savedFormat(list, file.path);
        result = [file] ~ result.filter!(f => filenameCmp(f.path, file.path) != 0).array;
    }
    return result[0 .. min(result.length, recentFilesMax)];
}

/// ditto
RecentFile[] withRecentFile(const RecentFile[] list, string path)
{
    return withRecentFile(list, RecentFile(path));
}

/// Returns: the format `path` was opened with last time, unset if it isn't in the list
FormatChoice savedFormat(const RecentFile[] list, string path)
{
    path = recentFilePath(path);
    foreach (file; list)
        if (filenameCmp(file.path, path) == 0)
            return file.format;
    return FormatChoice.init;
}

/// The recent list for the placeholder, the newest first:
/// [{"path", "exists", "format": {"shortName", "name"} if known}]
string recentFilesJson(const RecentFile[] list)
{
    JSONValue[] items;
    foreach (file; list)
    {
        JSONValue item = ["path": file.path];
        item.object["exists"] = JSONValue(exists(file.path));
        const info = file.format.isSet ? formatInfo(file.format.id) : FormatInfo.init;
        if (info.id.length)
            item.object["format"] = JSONValue(["shortName": info.shortName, "name": info.name]);
        items ~= item;
    }
    return JSONValue(items).toString();
}

struct AppSettings
{
    WindowRect windowRect;
    FileState[] files;
    string activeFile;
    RecentFile[] recentFiles; /// files opened recently, the newest first
    string theme;
    int tableFontSize = 100; /// font size of the log tables, % of the normal one

    this(ref return scope const AppSettings rhs)
    {
        this.windowRect = rhs.windowRect;
        this.files = rhs.files.dup;
        this.activeFile = rhs.activeFile;
        this.recentFiles = rhs.recentFiles.dup;
        this.theme = rhs.theme;
        this.tableFontSize = rhs.tableFontSize;
    }

    void opAssign(const AppSettings rhs)
    {
        this.windowRect = rhs.windowRect;
        this.files = rhs.files.dup;
        this.activeFile = rhs.activeFile;
        this.recentFiles = rhs.recentFiles.dup;
        this.theme = rhs.theme;
        this.tableFontSize = rhs.tableFontSize;
    }

    bool opEquals(const ref AppSettings rhs) const
    {
        return windowRect == rhs.windowRect &&
            files == rhs.files &&
            activeFile == rhs.activeFile &&
            recentFiles == rhs.recentFiles &&
            theme == rhs.theme &&
            tableFontSize == rhs.tableFontSize;
    }

    size_t toHash() const @safe nothrow
    {
        size_t hash = windowRect.hashOf();
        hash = hashOf(files, hash);
        hash = hashOf(activeFile, hash);
        hash = hashOf(recentFiles, hash);
        hash = hashOf(theme, hash);
        hash = hashOf(tableFontSize, hash);
        return hash;
    }
}

static string defaultSettingsPath()
{
    import std.file : thisExePath;
    import std.path : dirName;

    // Get directory of executable, go up one level from resources if needed
    string exeDir = dirName(thisExePath());
    // If we're in resources folder, go up
    if (exeDir.endsWith("resources"))
        exeDir = dirName(exeDir);
    return buildPath(exeDir, "settings.json");
}

static JSONValue toJSON(in AppSettings settings)
{
    JSONValue j;
    j.object = null; // Clear

    JSONValue r = [
        "left": settings.windowRect.left, "top": settings.windowRect.top,
        "width": settings.windowRect.width, "height": settings.windowRect.height
    ];
    j.object["windowRect"] = r;

    JSONValue[] fileArray;
    foreach (f; settings.files)
    {
        JSONValue fv = ["path": f.path];
        fv.object["scrollPosition"] = JSONValue(f.scrollPosition);
        fileArray ~= fv;
    }
    j.object["files"] = JSONValue(fileArray);
    j.object["activeFile"] = JSONValue(settings.activeFile);
    JSONValue[] recentArray;
    foreach (f; settings.recentFiles)
    {
        JSONValue fv = ["path": f.path];
        if (f.format.isSet)
        {
            fv.object["format"] = JSONValue(f.format.id);
            fv.object["variant"] = JSONValue(f.format.variant);
        }
        recentArray ~= fv;
    }
    j.object["recentFiles"] = JSONValue(recentArray);
    j.object["theme"] = JSONValue(settings.theme);
    j.object["tableFontSize"] = JSONValue(settings.tableFontSize);

    return j;
}

/// The format saved in a recent file entry: {"format": id, "variant"}; unset if there is none
private FormatChoice formatOf(const JSONValue entry)
{
    const id = "format" in entry;
    if (id is null || id.type != JSONType.string)
        return FormatChoice.init;
    const variant = "variant" in entry;
    if (variant !is null && variant.type == JSONType.integer)
    {
        if (variant.integer < int.min || variant.integer > int.max)
            return FormatChoice.init; // not a variant: the format is detected again
        return FormatChoice(id.str, cast(int) variant.integer);
    }
    return FormatChoice(id.str);
}

static AppSettings loadSettings(string path = defaultSettingsPath())
{
    AppSettings settings;
    // Default values
    settings.windowRect = WindowRect(100, 100, 1200, 800);
    settings.theme = "light";

    writeln("Loading settings from: ", path);
    if (!exists(path))
    {
        return settings;
    }

    try
    {
        string content = readText(path);
        JSONValue j = parseJSON(content);

        if ("windowRect" in j)
        {
            JSONValue r = j["windowRect"];
            settings.windowRect.left = r["left"].integer.to!int;
            settings.windowRect.top = r["top"].integer.to!int;
            settings.windowRect.width = r["width"].integer.to!int;
            settings.windowRect.height = r["height"].integer.to!int;
        }

        if ("files" in j)
        {
            foreach (val; j["files"].array)
            {
                FileState fs;
                fs.path = val["path"].str;
                if ("scrollPosition" in val)
                    fs.scrollPosition = val["scrollPosition"].integer.to!int;
                settings.files ~= fs;
            }
        }
        else if ("openFiles" in j)
        {
            // Migration from old format
            foreach (val; j["openFiles"].array)
            {
                settings.files ~= FileState(val.str, 0);
            }
        }

        if ("activeFile" in j)
        {
            settings.activeFile = j["activeFile"].str;
        }

        if (auto recent = "recentFiles" in j)
        {
            // Oldest first, so the newest ends up on top; anything but a file is skipped
            if (recent.type == JSONType.array)
            {
                foreach_reverse (val; recent.array)
                {
                    if (val.type == JSONType.string) // written before the formats were saved
                        settings.recentFiles = withRecentFile(settings.recentFiles, val.str);
                    else if (val.type == JSONType.object)
                    {
                        const filePath = "path" in val;
                        if (filePath !is null && filePath.type == JSONType.string)
                            settings.recentFiles = withRecentFile(settings.recentFiles,
                                RecentFile(filePath.str, formatOf(val)));
                    }
                }
            }
        }
        else
        {
            // Written before the recent list existed: seed it with the files kept then
            foreach_reverse (f; settings.files)
                settings.recentFiles = withRecentFile(settings.recentFiles, f.path);
            settings.recentFiles = withRecentFile(settings.recentFiles, settings.activeFile);
        }

        if ("theme" in j)
        {
            settings.theme = j["theme"].str;
        }

        if ("tableFontSize" in j)
        {
            settings.tableFontSize = j["tableFontSize"].integer.to!int;
        }

    }
    catch (Exception e)
    {
        writeln("Error loading settings: ", e.msg);
    }

    return settings;
}

void saveSettings(in AppSettings settings, string path = defaultSettingsPath())
{
    import std.string : replace;

    const j = toJSON(settings);

    try
    {
        // Remove unnecessary escape slashes from JSON output
        string jsonStr = j.toPrettyString().replace("\\/", "/");
        std.file.write(path, jsonStr);
        writeln("Settings saved to ", path);
    }
    catch (Exception e)
    {
        writeln("Error saving settings: ", e.msg);
    }
}

/// Opening a file puts it on top of the recent list, without duplicates
unittest
{
    assert(withRecentFile([], "/a.dlt").paths == ["/a.dlt"]);
    assert(withRecentFile(recent("/a.dlt", "/b.dlt"), "/c.dlt").paths == ["/c.dlt", "/a.dlt", "/b.dlt"]);
    assert(withRecentFile(recent("/a.dlt", "/b.dlt", "/c.dlt"), "/b.dlt").paths == ["/b.dlt", "/a.dlt", "/c.dlt"]);
    assert(withRecentFile(recent("/a.dlt"), "").paths == ["/a.dlt"]);
}

/// The recent list keeps the newest recentFilesMax files
unittest
{
    RecentFile[] list;
    foreach (i; 0 .. recentFilesMax + 3)
        list = withRecentFile(list, "/" ~ i.to!string);
    assert(list.length == recentFilesMax);
    assert(list[0].path == "/" ~ (recentFilesMax + 2).to!string);
}

/// The recent list survives a save and a load
unittest
{
    const path = buildPath(tempDir(), "dlt_explorer_settings_recent_test.json");
    scope (exit) if (exists(path)) remove(path);

    AppSettings settings;
    settings.recentFiles = [RecentFile("/new.dlt", FormatChoice("syslog", 3)), RecentFile("/old.dlt")];
    saveSettings(settings, path);
    assert(loadSettings(path).recentFiles == settings.recentFiles, "with the formats");
}

/// Settings written before the recent list existed: its files seed the list
unittest
{
    const path = buildPath(tempDir(), "dlt_explorer_settings_migration_test.json");
    scope (exit) if (exists(path)) remove(path);

    std.file.write(path, `{"activeFile": "/b.dlt",
        "files": [{"path": "/a.dlt"}, {"path": "/b.dlt"}]}`);
    assert(loadSettings(path).recentFiles.paths == ["/b.dlt", "/a.dlt"]);
}

/// Even an empty path leaves no more than recentFilesMax files
unittest
{
    RecentFile[] list;
    foreach (i; 0 .. recentFilesMax + 2)
        list ~= RecentFile("/" ~ i.to!string);
    assert(withRecentFile(list, "").length == recentFilesMax);
}

/// One file spelled in different ways is one entry
unittest
{
    assert(withRecentFile(recent("/logs/a.dlt"), "/logs/./x/../a.dlt").paths == ["/logs/a.dlt"]);
    assert(withRecentFile([], "a.dlt").paths == [buildNormalizedPath(absolutePath("a.dlt"))]);
    version (Windows)
        assert(withRecentFile(recent(`C:\logs\a.dlt`), "c:/logs/a.dlt").paths == [`c:\logs\a.dlt`]);
}

/// A broken recent list doesn't cost the other settings
unittest
{
    const path = buildPath(tempDir(), "dlt_explorer_settings_bad_recent_test.json");
    scope (exit) if (exists(path)) remove(path);

    std.file.write(path, `{"recentFiles": null, "theme": "dark", "tableFontSize": 120}`);
    auto settings = loadSettings(path);
    assert(settings.theme == "dark");
    assert(settings.tableFontSize == 120);
    assert(settings.recentFiles == []);

    std.file.write(path, `{"recentFiles": ["/a.dlt", 5, "/b.dlt"], "theme": "dark"}`);
    settings = loadSettings(path);
    assert(settings.theme == "dark");
    assert(settings.recentFiles.paths == ["/a.dlt", "/b.dlt"]);

    std.file.write(path, `{"recentFiles": [{"path": 5}, {"format": "dlt"}, {"path": "/c.dlt", "format": 7}]}`);
    assert(loadSettings(path).recentFiles == [RecentFile("/c.dlt")], "a bad entry or format is skipped");

    std.file.write(path, `{"recentFiles": [{"path": "/d.dlt", "format": "logcat", "variant": 9999999999}], "theme": "dark"}`);
    settings = loadSettings(path);
    assert(settings.theme == "dark", "a variant out of range doesn't cost the other settings");
    assert(settings.recentFiles == [RecentFile("/d.dlt")]);
}

/// A loaded recent list is cleaned: no duplicates, no empty paths, not too long
unittest
{
    const path = buildPath(tempDir(), "dlt_explorer_settings_dirty_recent_test.json");
    scope (exit) if (exists(path)) remove(path);

    string[] paths = ["/a.dlt", "", "/a.dlt"];
    foreach (i; 0 .. recentFilesMax + 2)
        paths ~= "/" ~ i.to!string;
    std.file.write(path, JSONValue(["recentFiles": paths]).toString());

    auto list = loadSettings(path).recentFiles;
    assert(list.length == recentFilesMax);
    assert(list[0 .. 2].paths == ["/a.dlt", "/0"]);
}

/// The placeholder gets every recent file with a mark whether it still exists
unittest
{
    const existing = buildPath(tempDir(), "dlt_explorer_recent_existing_test.dlt");
    std.file.write(existing, "");
    scope (exit) remove(existing);
    const missing = buildPath(tempDir(), "dlt_explorer_recent_missing_test.dlt");

    auto j = parseJSON(recentFilesJson(recent(existing, missing)));
    assert(j.array.length == 2);
    assert(j[0]["path"].str == existing && j[0]["exists"].boolean);
    assert(j[1]["path"].str == missing && !j[1]["exists"].boolean);
}

/// A path is stored in the recent list the way recentFilePath() spells it
unittest
{
    assert(recentFilePath("/logs/./x/../a.dlt") == "/logs/a.dlt");
    assert(withRecentFile([], "/logs/./x/../a.dlt").paths == [recentFilePath("/logs/./x/../a.dlt")]);
}

version (unittest)
{
    /// Recent files without formats
    private RecentFile[] recent(string[] paths...)
    {
        return paths.map!(p => RecentFile(p)).array;
    }

    private const(string)[] paths(const RecentFile[] list)
    {
        return list.map!(f => f.path).array;
    }
}

/// A file opened again keeps the format it had, unless it was opened in another one
unittest
{
    const logcat = FormatChoice("logcat", 1);
    auto list = withRecentFile([RecentFile("/a.log", logcat), RecentFile("/b.log")], "/a.log");
    assert(list == [RecentFile("/a.log", logcat), RecentFile("/b.log")], "failed to open: format kept");

    const text = FormatChoice("text");
    list = withRecentFile(list, RecentFile("/a.log", text));
    assert(list == [RecentFile("/a.log", text), RecentFile("/b.log")]);

    assert(savedFormat(list, "/logs/../a.log") == text);
    assert(!savedFormat(list, "/b.log").isSet);
    assert(!savedFormat(list, "/c.log").isSet);
}

/// The placeholder gets the badge and the name of a file's format, if it is known
unittest
{
    import formats.logcat : logcatFormatInfo;

    auto j = parseJSON(recentFilesJson([RecentFile("/a.log", FormatChoice(logcatFormatInfo.id)),
            RecentFile("/b.log"), RecentFile("/c.log", FormatChoice("no-such-format"))]));
    assert(j[0]["format"]["shortName"].str == logcatFormatInfo.shortName);
    assert(j[0]["format"]["name"].str == logcatFormatInfo.name);
    assert("format" !in j[1], "no format saved: no badge");
    assert("format" !in j[2], "a format this build doesn't know: no badge");
}
