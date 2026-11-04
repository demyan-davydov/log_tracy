module ui.app_settings;

import std.json;
import std.file;
import std.stdio;
import std.path;
import std.conv;
import std.array;
import std.algorithm;

import formats.registry : formatInfo;
import log_core.filter_file : ruleFromJson, rulesToJson;
import log_core.rule_filter : FilterRule;
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

/// A filter set of a log: a copy of the rules of the .dlf it was loaded
/// from (or made from scratch), with the edits and switches made since
struct SavedFilter
{
    string name;
    string source; /// the .dlf it was loaded from or exported to; "" if none
    bool enabled = true; /// the whole set
    FilterRule[] rules; /// in the order of the file
}

/// A file of the recent list
struct RecentFile
{
    string path;
    FormatChoice format; /// the format it was opened with last time; unset if never opened
    long lastUsed; /// when it was worked with last: ms since the Unix epoch (UTC); 0 if unknown
    SavedFilter[] filters; /// loaded for it, in the order loaded
}

/// A mutable copy of a recent file entry
RecentFile copyOf(const RecentFile file)
{
    return RecentFile(file.path, file.format, file.lastUsed,
        file.filters.map!(f => SavedFilter(f.name, f.source, f.enabled, copyOf(f.rules))).array);
}

/// A mutable copy of rules
FilterRule[] copyOf(const(FilterRule)[] rules)
{
    FilterRule[] copy;
    foreach (ref rule; rules)
    {
        // All its fields, then a copy of the conditions: a field added later is copied too
        auto c = cast(FilterRule) rule;
        c.conditions = rule.conditions.dup;
        copy ~= c;
    }
    return copy;
}

/// ditto, of the list
private RecentFile[] copyOf(const RecentFile[] list)
{
    return list.map!(f => copyOf(f)).array;
}

/// Returns: the filters loaded for `path` last time, null if it isn't in the list
SavedFilter[] savedFilters(const RecentFile[] list, string path)
{
    path = recentFilePath(path);
    foreach (file; list)
        if (filenameCmp(file.path, path) == 0)
            return copyOf(file).filters;
    return null;
}

/// Returns the recent list with the filters of `path` replaced, in place; a
/// file not in the list isn't added
RecentFile[] withFilters(const RecentFile[] list, string path, SavedFilter[] filters)
{
    path = recentFilePath(path);
    RecentFile[] result = copyOf(list);
    foreach (ref file; result)
        if (filenameCmp(file.path, path) == 0)
            file.filters = filters;
    return result;
}

/// Now, as RecentFile.lastUsed counts it: UTC, so a change of the time zone or
/// of daylight saving time doesn't move the times already saved
long nowMs()
{
    import std.datetime.systime : Clock, unixTimeToStdTime;

    enum hnsecsPerMs = 10_000;
    return (Clock.currStdTime - unixTimeToStdTime(0)) / hnsecsPerMs;
}

/// Returns the recent files list with `file` on top, without duplicates
/// (paths are compared normalized, ignoring case where the OS does) and
/// no longer than recentFilesMax. Without a format or a time the file keeps
/// the one it had in the list (e.g. it failed to open this time).
RecentFile[] withRecentFile(const RecentFile[] list, RecentFile file)
{
    RecentFile[] result = copyOf(list);
    if (file.path.length)
    {
        file.path = recentFilePath(file.path);
        foreach (ref saved; result)
        {
            if (filenameCmp(saved.path, file.path) != 0)
                continue;
            if (!file.format.isSet)
                file.format = saved.format;
            if (file.lastUsed == 0)
                file.lastUsed = saved.lastUsed;
            if (file.filters is null)
                file.filters = saved.filters;
        }
        result = [file] ~ result.filter!(f => filenameCmp(f.path, file.path) != 0).array;
    }
    return result[0 .. min(result.length, recentFilesMax)];
}

/// ditto
RecentFile[] withRecentFile(const RecentFile[] list, string path)
{
    return withRecentFile(list, RecentFile(path));
}

/// Returns the recent list with the files in `paths` (e.g. the open ones)
/// used at `now`: on top, in the order they had in the list, with that time
RecentFile[] withFilesUsed(const RecentFile[] list, const string[] paths, long now)
{
    const normalized = paths.map!(p => recentFilePath(p)).array;
    const isUsed = (const RecentFile f) => normalized.canFind!(p => filenameCmp(p, f.path) == 0);

    RecentFile[] used;
    foreach (file; list.filter!(f => isUsed(f)))
    {
        auto copy = copyOf(file);
        copy.lastUsed = now;
        used ~= copy;
    }
    foreach (path; normalized) // open, but pushed out of the list
        if (!used.canFind!(f => filenameCmp(f.path, path) == 0))
            used ~= RecentFile(path, FormatChoice.init, now);

    RecentFile[] result = used ~ copyOf(list).filter!(f => !isUsed(f)).array;
    return result[0 .. min(result.length, recentFilesMax)];
}

/// Returns the recent list with the files in `paths` used at `now`, in place:
/// the order doesn't change, files not in the list aren't added
RecentFile[] withFilesStamped(const RecentFile[] list, const string[] paths, long now)
{
    RecentFile[] result = copyOf(list);
    foreach (ref file; result)
        if (paths.canFind!(p => filenameCmp(recentFilePath(p), file.path) == 0))
            file.lastUsed = now;
    return result;
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

/// The recent list for the placeholder, the newest first: [{"path", "exists",
/// "opened" (one of `openPaths`), "format": {"shortName", "name"} if known,
/// "lastUsed" (ms since the Unix epoch) if known}]
string recentFilesJson(const RecentFile[] list, const string[] openPaths = null)
{
    const opened = openPaths.map!recentFilePath.array;
    JSONValue[] items;
    foreach (file; list)
    {
        JSONValue item = ["path": file.path];
        item.object["exists"] = JSONValue(exists(file.path));
        item.object["opened"] = JSONValue(opened.canFind!(p => filenameCmp(p, file.path) == 0));
        if (file.lastUsed > 0)
            item.object["lastUsed"] = JSONValue(file.lastUsed);
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
        this.recentFiles = copyOf(rhs.recentFiles);
        this.theme = rhs.theme;
        this.tableFontSize = rhs.tableFontSize;
    }

    void opAssign(const AppSettings rhs)
    {
        this.windowRect = rhs.windowRect;
        this.files = rhs.files.dup;
        this.activeFile = rhs.activeFile;
        this.recentFiles = copyOf(rhs.recentFiles);
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
        if (f.lastUsed > 0)
            fv.object["lastUsed"] = JSONValue(f.lastUsed);
        if (f.filters.length)
            fv.object["filterSets"] = JSONValue(f.filters.map!(filter => JSONValue([
                "name": JSONValue(filter.name),
                "source": JSONValue(filter.source),
                "enabled": JSONValue(filter.enabled),
                "rules": rulesToJson(filter.rules),
            ])).array);
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

/// The filter sets saved in a recent file entry: {"filterSets": [{"name",
/// "source", "enabled", "rules": [rules as in a filter file]}]}; a set without
/// a name and a rule that can't be read are skipped. The "filters" of the
/// DLT-only format written before aren't read.
private SavedFilter[] filtersOf(const JSONValue entry)
{
    const filters = "filterSets" in entry;
    if (filters is null || filters.type != JSONType.array)
        return null;
    SavedFilter[] result;
    foreach (filter; filters.array)
    {
        if (filter.type != JSONType.object)
            continue;
        const name = "name" in filter;
        if (name is null || name.type != JSONType.string)
            continue;
        SavedFilter saved;
        saved.name = name.str;
        if (const source = "source" in filter)
            if (source.type == JSONType.string)
                saved.source = source.str;
        if (const enabled = "enabled" in filter) // on without the key or when true only
            saved.enabled = enabled.type == JSONType.true_;
        if (const rules = "rules" in filter)
            if (rules.type == JSONType.array)
                foreach (ref rule; rules.array)
                {
                    try
                        saved.rules ~= ruleFromJson(rule);
                    catch (Exception)
                    {
                    } // skipped
                }
        result ~= saved;
    }
    return result;
}

/// The time saved in a recent file entry: {"lastUsed": ms}; 0 if there is none
private long lastUsedOf(const JSONValue entry)
{
    const lastUsed = "lastUsed" in entry;
    if (lastUsed is null || lastUsed.type != JSONType.integer || lastUsed.integer <= 0)
        return 0;
    return lastUsed.integer;
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
                                RecentFile(filePath.str, formatOf(val), lastUsedOf(val), filtersOf(val)));
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

/// The time a file was used survives a save and a load; a broken one is unknown
unittest
{
    const path = buildPath(tempDir(), "dlt_explorer_settings_last_used_test.json");
    scope (exit) if (exists(path)) remove(path);

    AppSettings settings;
    settings.recentFiles = [RecentFile("/a.dlt", FormatChoice("dlt"), 1_762_250_000_123), RecentFile("/b.dlt")];
    saveSettings(settings, path);
    assert(loadSettings(path).recentFiles == settings.recentFiles);

    std.file.write(path, `{"recentFiles": [{"path": "/a.dlt", "lastUsed": "x"}, {"path": "/b.dlt", "lastUsed": -5}]}`);
    assert(loadSettings(path).recentFiles == [RecentFile("/a.dlt"), RecentFile("/b.dlt")]);
}

/// A file that failed to open keeps the time it was used last
unittest
{
    auto list = withRecentFile([RecentFile("/b.log"), RecentFile("/a.log", FormatChoice.init, 100)], "/a.log");
    assert(list[0] == RecentFile("/a.log", FormatChoice.init, 100));
    list = withRecentFile(list, RecentFile("/a.log", FormatChoice.init, 200));
    assert(list[0].lastUsed == 200);
}

/// Closing the window marks the open files used now: they come on top in the
/// order they had in the list (the tabs have an order of their own)
unittest
{
    const logcat = FormatChoice("logcat");
    auto list = [RecentFile("/b.log", FormatChoice.init, 300), RecentFile("/a.log", logcat, 200),
        RecentFile("/c.log", FormatChoice.init, 100)];
    auto used = withFilesUsed(list, ["/c.log", "/a.log"], 1000);
    assert(used == [RecentFile("/a.log", logcat, 1000), RecentFile("/c.log", FormatChoice.init, 1000),
        RecentFile("/b.log", FormatChoice.init, 300)]);
    assert(withFilesUsed(list, [], 1000) == list);
    assert(withFilesUsed(list, ["/d.log"], 1000)[0] == RecentFile("/d.log", FormatChoice.init, 1000),
        "an open file the list lost (more tabs than its length) comes back");
}

/// Any save marks the open files used now, in place: the order of the list
/// stays that of the files opened, failed and closed
unittest
{
    auto list = [RecentFile("/b.log", FormatChoice.init, 300), RecentFile("/a.log", FormatChoice("dlt"), 200)];
    assert(withFilesStamped(list, ["/a.log", "/d.log"], 1000)
            == [RecentFile("/b.log", FormatChoice.init, 300), RecentFile("/a.log", FormatChoice("dlt"), 1000)]);
}

/// The placeholder gets the time a file was used and whether it is open
unittest
{
    auto j = parseJSON(recentFilesJson([RecentFile("/a.log", FormatChoice.init, 1_762_250_000_123),
            RecentFile("/b.log")], ["/b.log"]));
    assert(j[0]["lastUsed"].integer == 1_762_250_000_123);
    assert(!j[0]["opened"].boolean);
    assert("lastUsed" !in j[1], "unknown: no time");
    assert(j[1]["opened"].boolean);
}

/// Now is counted from the Unix epoch in ms
unittest
{
    assert(nowMs() > 1_762_000_000_000); // after Nov 2025
    assert(nowMs() < 4_102_444_800_000); // before 2100
}

/// The filter sets of a file survive a save and a load with their rules;
/// broken entries and rules are skipped, the entries of the DLT-only format
/// written before ("filters") aren't read
unittest
{
    import log_core.rule_filter : Check, Condition, FilterRule, RuleKind;

    const path = buildPath(tempDir(), "dlt_explorer_settings_filters_test.json");
    scope (exit) if (exists(path)) remove(path);

    FilterRule errors;
    errors.name = "Errors";
    errors.conditions = [Condition("level", Check.Range, "", 1, 2), Condition("tag", Check.Equals, "AM")];
    FilterRule off;
    off.enabled = false;
    off.kind = RuleKind.Exclude;

    AppSettings settings;
    settings.recentFiles = [RecentFile("/a.log", FormatChoice("logcat"), 100,
            [SavedFilter("one.dlf", "/f/one.dlf", true, [errors, off]), SavedFilter("New Filter", "", false, [])]),
        RecentFile("/b.dlt")];
    saveSettings(settings, path);
    assert(loadSettings(path).recentFiles == settings.recentFiles);

    std.file.write(path, `{"recentFiles": [{"path": "/a.dlt", "filterSets": [{"name": 5}, "x",
        {"name": "one", "rules": [{"name": "Errors"}, {"kind": "sometimes"}, 7]}]}]}`);
    FilterRule named;
    named.name = "Errors";
    assert(loadSettings(path).recentFiles[0].filters == [SavedFilter("one", "", true, [named])],
        "a set without a name and rules that aren't rules are skipped");

    std.file.write(path, `{"recentFiles": [{"path": "/a.dlt", "filterSets": [{"name": "a"},
        {"name": "b", "enabled": true}, {"name": "c", "enabled": 0}, {"name": "d", "enabled": null}]}]}`);
    assert(loadSettings(path).recentFiles[0].filters.map!(f => f.enabled).array == [true, true, false, false],
        "on without the key or when true only");

    std.file.write(path, `{"recentFiles": [{"path": "/a.dlt", "filters": [{"name": "old", "rules": [{"name": "x"}]}]}]}`);
    assert(loadSettings(path).recentFiles[0].filters.length == 0);
}

/// Opening a file again or closing the window keeps its filters; they are
/// changed in place, without reordering the list
unittest
{
    auto filters = [SavedFilter("one.dlf", "/f/one.dlf")];
    auto list = [RecentFile("/b.log"), RecentFile("/a.log", FormatChoice("dlt"), 100, filters.dup)];
    assert(withRecentFile(list, RecentFile("/a.log", FormatChoice("dlt"), 200))[0].filters == filters);
    assert(withFilesUsed(list, ["/a.log"], 300)[0].filters == filters);

    assert(savedFilters(list, "/logs/../a.log") == filters);
    assert(savedFilters(list, "/c.log") is null);

    auto changed = withFilters(list, "/a.log", []);
    assert(changed[1].path == "/a.log" && changed[1].filters.length == 0, "in place");
    assert(withFilters(list, "/c.log", filters.dup) == list, "a file not in the list isn't added");
}
