//! The settings of the application, kept in settings.json next to the
//! executable (in the user's folder for an installed copy): the window, the theme, the font size of the tables, the
//! layouts of the columns by format and the recent files (ui.recent_files);
//! read, merged with the state of the script, written.
module ui.app_settings;

import std.json;
import std.file;
import std.stdio;
import std.path;
import std.conv;
import std.array;
import std.algorithm;

import log_core.log_format : FormatChoice;
import log_core.column_layout : ColumnState;
import log_core.search_filter : SearchChip;
public import ui.recent_files; // the recent list is a part of the settings

// One overload set with the copies of the recent list
alias copyOf = ui.recent_files.copyOf;

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
}

/// The layouts of the columns chosen by the user, by FormatInfo.id: one
/// for all the logs of a format. A format without one shows its columns as
/// they are.
alias ColumnLayouts = ColumnState[][string];

/// A copy of layouts
ColumnLayouts copyOf(const ColumnLayouts layouts)
{
    ColumnLayouts copy;
    foreach (id, layout; layouts)
        copy[id] = layout.dup;
    return copy;
}

/// The layouts as settings.json and the Settings dialog have them:
/// {format id: [{"id", "visible"}]}
JSONValue columnLayoutsToJson(const ColumnLayouts layouts)
{
    JSONValue j = parseJSON("{}");
    foreach (id, layout; layouts)
        j.object[id] = JSONValue(layout.map!(c => JSONValue([
            "id": JSONValue(c.id), "visible": JSONValue(c.visible)
        ])).array);
    return j;
}

/// Reads layouts written by columnLayoutsToJson(); an entry that isn't a
/// layout, and a column that isn't one, are skipped
ColumnLayouts columnLayoutsFromJson(const JSONValue json)
{
    ColumnLayouts layouts;
    if (json.type != JSONType.object)
        return layouts;
    foreach (formatId, layout; json.object)
    {
        if (layout.type != JSONType.array)
            continue;
        ColumnState[] columns;
        foreach (ref column; layout.array)
        {
            if (column.type != JSONType.object)
                continue;
            const id = "id" in column;
            if (id is null || id.type != JSONType.string)
                continue;
            const visible = "visible" in column; // shown without the key
            columns ~= ColumnState(id.str, visible is null || visible.type != JSONType.false_);
        }
        layouts[formatId] = columns;
    }
    return layouts;
}

/// Returns `layouts` with those of the Settings dialog (`json`, as
/// columnLayoutsToJson() writes them) in place of theirs. A layout that
/// shows the columns as they are without one is dropped: a column the format
/// gets later is then shown at its place.
ColumnLayouts withColumnLayouts(const ColumnLayouts layouts, const(char)[] json)
{
    import formats.registry : formatColumns;
    import log_core.column_layout : defaultLayout, isDefaultLayout;

    ColumnLayouts result = copyOf(layouts);
    ColumnLayouts changed;
    try
        changed = columnLayoutsFromJson(parseJSON(json));
    catch (JSONException)
        return result;
    foreach (formatId, layout; changed)
    {
        if (isDefaultLayout(layout, defaultLayout(formatColumns(formatId))))
            result.remove(formatId);
        else
            result[formatId] = layout;
    }
    return result;
}

/// What the Columns section of the Settings dialog shows: {"current": the
/// format to show first, "formats": [{"id", "name", "payload": the title of
/// the last column, "defaults": [ids in the order of the format], "columns":
/// [{"id", "title", "visible"}] as `layouts` arrange them}]}. Only the formats
/// that have columns to arrange (more than Payload) are listed.
string columnSettingsJson(const ColumnLayouts layouts, string currentFormat)
{
    import formats.registry : formatColumns, formatInfos;
    import log_core.column_layout : defaultLayout, fullLayout;
    import log_core.log_format : ColumnKind;

    JSONValue[] formats;
    foreach (info; formatInfos())
    {
        const columns = formatColumns(info.id);
        const defaults = defaultLayout(columns);
        if (defaults.length == 0)
            continue;
        const layout = info.id in layouts;
        JSONValue[] shown;
        foreach (state; fullLayout(defaults, layout is null ? null : *layout))
        {
            const at = columns.countUntil!(c => c.id == state.id);
            if (at < 0)
                continue; // the format has it no more
            shown ~= JSONValue([
                "id": JSONValue(state.id), "title": JSONValue(columns[at].title),
                "visible": JSONValue(state.visible)
            ]);
        }
        auto payload = columns.filter!(c => c.kind == ColumnKind.Payload);
        formats ~= JSONValue([
            "id": JSONValue(info.id), "name": JSONValue(info.name),
            "payload": JSONValue(payload.empty ? "" : payload.front.title),
            "defaults": JSONValue(defaults.map!(d => d.id).array), "columns": JSONValue(shown),
        ]);
    }
    return JSONValue(["current": JSONValue(currentFormat), "formats": JSONValue(formats)]).toString();
}

struct AppSettings
{
    WindowRect windowRect;
    FileState[] files;
    string activeFile;
    RecentFile[] recentFiles; /// files opened recently, the newest first
    string theme;
    int tableFontSize = 100; /// font size of the log tables, % of the normal one
    bool singleLineRows; /// every row of the log tables one line high, the payload cut
    bool monospacePayload; /// the payload of the log tables in the monospace font of the other columns
    ColumnLayouts columnLayouts; /// the columns of the log tables, by format
    string language; /// of the interface: a BCP 47 tag ("ru", "x-pseudo"); "": the language of the system
    string searchPanelHeight; /// of the search (bottom) panel of the documents, as on exit ("250dip"); "": the script's own
    /// the bottom panel is collapsed to its tabs; `searchPanelHeight` is then the height it expands to
    bool bottomPanelCollapsed;

    this(ref return scope const AppSettings rhs)
    {
        this.windowRect = rhs.windowRect;
        this.files = rhs.files.dup;
        this.activeFile = rhs.activeFile;
        this.recentFiles = copyOf(rhs.recentFiles);
        this.theme = rhs.theme;
        this.tableFontSize = rhs.tableFontSize;
        this.singleLineRows = rhs.singleLineRows;
        this.monospacePayload = rhs.monospacePayload;
        this.columnLayouts = copyOf(rhs.columnLayouts);
        this.language = rhs.language;
        this.searchPanelHeight = rhs.searchPanelHeight;
        this.bottomPanelCollapsed = rhs.bottomPanelCollapsed;
    }

    void opAssign(const AppSettings rhs)
    {
        this.windowRect = rhs.windowRect;
        this.files = rhs.files.dup;
        this.activeFile = rhs.activeFile;
        this.recentFiles = copyOf(rhs.recentFiles);
        this.theme = rhs.theme;
        this.tableFontSize = rhs.tableFontSize;
        this.singleLineRows = rhs.singleLineRows;
        this.monospacePayload = rhs.monospacePayload;
        this.columnLayouts = copyOf(rhs.columnLayouts);
        this.language = rhs.language;
        this.searchPanelHeight = rhs.searchPanelHeight;
        this.bottomPanelCollapsed = rhs.bottomPanelCollapsed;
    }

    bool opEquals(const ref AppSettings rhs) const
    {
        return windowRect == rhs.windowRect &&
            files == rhs.files &&
            activeFile == rhs.activeFile &&
            recentFiles == rhs.recentFiles &&
            theme == rhs.theme &&
            tableFontSize == rhs.tableFontSize &&
            singleLineRows == rhs.singleLineRows &&
            monospacePayload == rhs.monospacePayload &&
            columnLayouts == rhs.columnLayouts &&
            language == rhs.language &&
            searchPanelHeight == rhs.searchPanelHeight &&
            bottomPanelCollapsed == rhs.bottomPanelCollapsed;
    }

    size_t toHash() const @safe nothrow
    {
        size_t hash = windowRect.hashOf();
        hash = hashOf(files, hash);
        hash = hashOf(activeFile, hash);
        hash = hashOf(recentFiles, hash);
        hash = hashOf(theme, hash);
        hash = hashOf(tableFontSize, hash);
        hash = hashOf(singleLineRows, hash);
        hash = hashOf(monospacePayload, hash);
        hash = hashOf(language, hash);
        hash = hashOf(searchPanelHeight, hash);
        hash = hashOf(bottomPanelCollapsed, hash);
        foreach (id, layout; columnLayouts) // in no order: summed
            hash += hashOf(layout, hashOf(id));
        return hash;
    }
}

/// Whether this is the build of a distribution (`dist`, dub's build type "dist" with
/// `version (Installed)`): a program installed into the system, where the folder of the
/// program isn't the user's to write.
version (Installed) enum bool installedBuild = true;
else enum bool installedBuild = false;

static string defaultSettingsPath()
{
    import std.file : thisExePath;
    import std.path : dirName;
    import std.process : environment;

    return buildPath(settingsDir(installedBuild, dirName(thisExePath()),
        (name) => environment.get(name, "")), "settings.json");
}

/// The folder of settings.json (and settings.lock). A build of our own (debug, release, the
/// unittests) keeps it next to the program: every build folder has settings of its own and its
/// copies run side by side. An installed one (`installed`) keeps it in the user's folder for
/// settings of the system, from the environment variables `env` gives: the folder of an
/// installed program is read-only, and a write into a macOS bundle breaks its signature.
/// Without those variables it falls back to the folder of the program.
static string settingsDir(bool installed, string exeDir, scope string delegate(string) env)
{
    import std.path : dirName;

    if (installed)
    {
        const home = env("HOME");
        version (OSX)
        {
            if (home.length)
                return buildPath(home, "Library", "Application Support", "Log Tracy");
        }
        else version (Windows)
        {
            const appData = env("APPDATA");
            if (appData.length) // not `if (appData)`: an empty string is not null
                return buildPath(appData, "Log Tracy");
        }
        else
        {
            const config = env("XDG_CONFIG_HOME");
            if (config.length && isAbsolute(config))
                return buildPath(config, "log_tracy");
            if (home.length)
                return buildPath(home, ".config", "log_tracy");
        }
    }
    // the program run from a resources folder keeps the settings one level up
    if (exeDir.endsWith("resources"))
        exeDir = dirName(exeDir);
    return exeDir;
}

@("settingsDir: a build of our own keeps the settings next to the program")
unittest
{
    string env(string name) => name == "HOME" ? testPath("/home/u") : "";
    assert(settingsDir(false, testPath("/b/osx-aarch64-debug"), &env) == testPath("/b/osx-aarch64-debug"));
    assert(settingsDir(false, buildPath(testPath("/b"), "resources"), &env) == testPath("/b"));
}

@("settingsDir: an installed build keeps the settings in the user's folder")
unittest
{
    string[string] vars = ["HOME": "/home/u", "APPDATA": `C:\Users\u\AppData\Roaming`];
    string env(string name) => vars.get(name, "");
    version (OSX)
        assert(settingsDir(true, testPath("/Applications/LogTracy.app/Contents/MacOS"), &env)
            == testPath("/home/u/Library/Application Support/Log Tracy"));
    else version (Windows)
        assert(settingsDir(true, `C:\Program Files\Log Tracy`, &env)
            == `C:\Users\u\AppData\Roaming\Log Tracy`);
    else
    {
        assert(settingsDir(true, testPath("/opt/log_tracy"), &env) == testPath("/home/u/.config/log_tracy"));
        vars["XDG_CONFIG_HOME"] = testPath("/home/u/conf");
        assert(settingsDir(true, testPath("/opt/log_tracy"), &env) == testPath("/home/u/conf/log_tracy"));
        vars["XDG_CONFIG_HOME"] = "conf"; // relative: ignored, as the XDG spec says
        assert(settingsDir(true, testPath("/opt/log_tracy"), &env) == testPath("/home/u/.config/log_tracy"));
    }
}

@("settingsDir: an installed build without the user's folder keeps them next to the program")
unittest
{
    string env(string name) => "";
    assert(settingsDir(true, testPath("/opt/log_tracy"), &env) == testPath("/opt/log_tracy"));
}

/// The lock file of the running copy (utils/single_instance), next to the settings it guards:
/// copies in other folders have settings of their own and run side by side.
static string instanceLockPath(string settingsPath = defaultSettingsPath())
{
    import std.path : dirName;

    return buildPath(dirName(settingsPath), "settings.lock");
}

@("instanceLockPath: next to the settings")
unittest
{
    assert(instanceLockPath(buildPath("a", "b", "settings.json")) == buildPath("a", "b", "settings.lock"));
}

/// The version of the layout of settings.json, written into it for a change of the layout that
/// can't be read by the keys alone; nothing reads it yet.
enum settingsVersion = 1;

static JSONValue toJSON(in AppSettings settings)
{
    JSONValue j;
    j.object = null; // Clear
    j.object["version"] = JSONValue(settingsVersion);

    JSONValue r = [
        "left": settings.windowRect.left, "top": settings.windowRect.top,
        "width": settings.windowRect.width, "height": settings.windowRect.height
    ];
    j.object["windowRect"] = r;

    JSONValue[] fileArray;
    foreach (f; settings.files)
    {
        fileArray ~= JSONValue(["path": f.path]);
    }
    j.object["files"] = JSONValue(fileArray);
    j.object["activeFile"] = JSONValue(settings.activeFile);
    j.object["recentFiles"] = recentFilesToJson(settings.recentFiles);
    j.object["theme"] = JSONValue(settings.theme);
    j.object["tableFontSize"] = JSONValue(settings.tableFontSize);
    j.object["singleLineRows"] = JSONValue(settings.singleLineRows);
    j.object["monospacePayload"] = JSONValue(settings.monospacePayload);
    j.object["language"] = JSONValue(settings.language);
    j.object["searchPanelHeight"] = JSONValue(settings.searchPanelHeight);
    j.object["bottomPanelCollapsed"] = JSONValue(settings.bottomPanelCollapsed);
    if (settings.columnLayouts.length)
        j.object["columnLayouts"] = columnLayoutsToJson(settings.columnLayouts);

    return j;
}

static AppSettings loadSettings(string path = defaultSettingsPath())
{
    AppSettings settings;
    // Default values
    // None: the markup sizes the window and the script restores a saved frame
    settings.windowRect = WindowRect.init;
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

        if ("files" in j)
        {
            foreach (val; j["files"].array)
            {
                settings.files ~= FileState(val["path"].str); // a "scrollPosition" of an older version is let go
            }
        }
        else if ("openFiles" in j)
        {
            // Migration from old format
            foreach (val; j["openFiles"].array)
            {
                settings.files ~= FileState(val.str);
            }
        }

        if ("activeFile" in j)
        {
            settings.activeFile = j["activeFile"].str;
        }

        if (auto recent = "recentFiles" in j)
            settings.recentFiles = recentFilesFromJson(*recent);
        else
        {
            // Written before the recent list existed: seed it with the files kept then
            foreach_reverse (f; settings.files)
                settings.recentFiles = withRecentFile(settings.recentFiles, f.path);
            settings.recentFiles = withRecentFile(settings.recentFiles, settings.activeFile);
        }

        // After the files and the recent list: a bad preference loses only what follows
        readPreferences(j, settings);
        if (const layouts = "columnLayouts" in j)
            settings.columnLayouts = columnLayoutsFromJson(*layouts);

    }
    catch (Exception e)
    {
        writeln("Error loading settings: ", e.msg);
    }

    return settings;
}

/// The settings with the state the script reports on closing put in: the
/// JSON of its getAppState() (window rect, theme, font size of the tables, the
/// sizes of the panels). Keys it doesn't have keep their values;
/// a malformed JSON changes nothing more after the first bad key.
AppSettings mergeAppStateFromScript(const AppSettings base, const(char)[] appStateJson)
{
    AppSettings settings = base;
    try
    {
        const j = parseJSON(appStateJson);
        readPreferences(j, settings);
    }
    catch (Exception e)
    {
        writeln("Error parsing the state of the script: ", e.msg);
    }
    return settings;
}

/// Reads what both the settings file and the state of the script hold: the
/// window rect, the theme, the font size of the tables, whether their rows are
/// single-line, whether their payload is monospace, the language, the height of the search panel and whether it is collapsed. Keys `j`
/// doesn't have leave their values in `settings` (a key it no longer knows, as
/// the sidePanelWidth of the removed side panel, is ignored).
private void readPreferences(in JSONValue j, ref AppSettings settings)
{
    if (const r = "windowRect" in j) // taken whole or not at all
        settings.windowRect = WindowRect((*r)["left"].integer.to!int, (*r)["top"].integer.to!int,
            (*r)["width"].integer.to!int, (*r)["height"].integer.to!int);
    if (const theme = "theme" in j)
        settings.theme = theme.str;
    if (const fontSize = "tableFontSize" in j)
        settings.tableFontSize = fontSize.integer.to!int;
    if (const singleLine = "singleLineRows" in j)
        if (singleLine.type == JSONType.true_ || singleLine.type == JSONType.false_)
            settings.singleLineRows = singleLine.boolean;
    if (const monospace = "monospacePayload" in j)
        if (monospace.type == JSONType.true_ || monospace.type == JSONType.false_)
            settings.monospacePayload = monospace.boolean;
    if (const language = "language" in j)
        settings.language = language.type == JSONType.string ? language.str : "";
    if (const height = "searchPanelHeight" in j)
        settings.searchPanelHeight = height.str;
    if (const collapsed = "bottomPanelCollapsed" in j)
        if (collapsed.type == JSONType.true_ || collapsed.type == JSONType.false_)
            settings.bottomPanelCollapsed = collapsed.boolean;
}

void saveSettings(in AppSettings settings, string path = defaultSettingsPath())
{
    import std.string : replace;

    const j = toJSON(settings);

    try
    {
        // Remove unnecessary escape slashes from JSON output
        string jsonStr = j.toPrettyString().replace("\\/", "/");
        mkdirRecurse(dirName(path)); // the user's folder of an installed copy, on its first save
        std.file.write(path, jsonStr);
        writeln("Settings saved to ", path);
    }
    catch (Exception e)
    {
        writeln("Error saving settings: ", e.msg);
    }
}

@("settings: the version of the settings is written")
unittest
{
    assert(toJSON(AppSettings.init)["version"].integer == 1);
}

@("settings: the recent list survives a save and a load")
unittest
{
    const path = buildPath(tempDir(), "log_tracy_settings_recent_test.json");
    scope (exit) if (exists(path)) remove(path);

    AppSettings settings;
    settings.recentFiles = [RecentFile(testPath("/new.dlt"), FormatChoice("syslog", 3)), RecentFile(testPath("/old.dlt"))];
    saveSettings(settings, path);
    assert(loadSettings(path).recentFiles == settings.recentFiles, "with the formats");
}

@("settings: single-line rows survive a save and a load, off by default")
unittest
{
    const path = buildPath(tempDir(), "log_tracy_settings_single_line_test.json");
    scope (exit) if (exists(path)) remove(path);

    AppSettings settings;
    assert(!settings.singleLineRows);
    saveSettings(settings, path);
    assert(parseJSON(readText(path))["singleLineRows"].type == JSONType.false_, "written as a JSON bool");
    settings.singleLineRows = true;
    saveSettings(settings, path);
    assert(parseJSON(readText(path))["singleLineRows"].type == JSONType.true_, "written as a JSON bool");
    assert(loadSettings(path).singleLineRows);

    std.file.write(path, `{"theme": "dark"}`);
    assert(!loadSettings(path).singleLineRows, "settings without the key: off");
    std.file.write(path, `{"theme": "dark", "singleLineRows": 1}`);
    const bad = loadSettings(path);
    assert(!bad.singleLineRows && bad.theme == "dark", "a value not a bool is ignored");
}

@("mergeAppStateFromScript: single-line rows come from the script")
unittest
{
    AppSettings base;
    assert(mergeAppStateFromScript(base, `{"singleLineRows": true}`).singleLineRows);
    base.singleLineRows = true;
    assert(mergeAppStateFromScript(base, `{"theme": "dark"}`).singleLineRows, "kept when not sent");
    assert(!mergeAppStateFromScript(base, `{"singleLineRows": false}`).singleLineRows);
}

@("settings: the monospace payload survives a save and a load, off by default")
unittest
{
    const path = buildPath(tempDir(), "log_tracy_settings_monospace_payload_test.json");
    scope (exit) if (exists(path)) remove(path);

    AppSettings settings;
    assert(!settings.monospacePayload);
    saveSettings(settings, path);
    assert(parseJSON(readText(path))["monospacePayload"].type == JSONType.false_, "written as a JSON bool");
    settings.monospacePayload = true;
    saveSettings(settings, path);
    assert(loadSettings(path).monospacePayload);

    std.file.write(path, `{"theme": "dark"}`);
    assert(!loadSettings(path).monospacePayload, "settings without the key: off");
    std.file.write(path, `{"theme": "dark", "monospacePayload": 1}`);
    assert(!loadSettings(path).monospacePayload, "a value not a bool is ignored");
}

@("mergeAppStateFromScript: the monospace payload comes from the script, kept when not sent")
unittest
{
    AppSettings base;
    assert(mergeAppStateFromScript(base, `{"monospacePayload": true}`).monospacePayload);
    base.monospacePayload = true;
    assert(mergeAppStateFromScript(base, `{"theme": "dark"}`).monospacePayload);
    assert(!mergeAppStateFromScript(base, `{"monospacePayload": false}`).monospacePayload);
}

@("AppSettings: the monospace payload is copied, compared and hashed")
unittest
{
    AppSettings a;
    a.monospacePayload = true;
    const AppSettings b = a;
    assert(b.monospacePayload);
    AppSettings c;
    assert(c != a && c.toHash != a.toHash);
    c = b;
    assert(c == a);
}

@("AppSettings: single-line rows are copied and compared")
unittest
{
    AppSettings a;
    a.singleLineRows = true;
    const AppSettings b = a;
    assert(b.singleLineRows);
    AppSettings c;
    assert(c != a);
    c = b;
    assert(c == a);
}

@("loadSettings: settings written before the recent list existed seed it with their files")
unittest
{
    const path = buildPath(tempDir(), "log_tracy_settings_migration_test.json");
    scope (exit) if (exists(path)) remove(path);

    std.file.write(path, `{"activeFile": "/b.dlt",
        "files": [{"path": "/a.dlt"}, {"path": "/b.dlt"}]}`);
    // the paths of the JSON as the list spells them: with the current drive on Windows
    assert(loadSettings(path).recentFiles.pathsOf == [recentFilePath("/b.dlt"), recentFilePath("/a.dlt")]);
}

@("loadSettings: a broken recent list doesn't cost the other settings")
unittest
{
    const path = buildPath(tempDir(), "log_tracy_settings_bad_recent_test.json");
    scope (exit) if (exists(path)) remove(path);

    std.file.write(path, `{"recentFiles": null, "theme": "dark", "tableFontSize": 120}`);
    auto settings = loadSettings(path);
    assert(settings.theme == "dark");
    assert(settings.tableFontSize == 120);
    assert(settings.recentFiles == []);

    std.file.write(path, `{"recentFiles": ["/a.dlt", 5, "/b.dlt"], "theme": "dark"}`);
    settings = loadSettings(path);
    assert(settings.theme == "dark");
    assert(settings.recentFiles.pathsOf == [testPath("/a.dlt"), testPath("/b.dlt")]);

    std.file.write(path, `{"recentFiles": [{"path": 5}, {"format": "dlt"}, {"path": "/c.dlt", "format": 7}]}`);
    assert(loadSettings(path).recentFiles == [RecentFile(testPath("/c.dlt"))], "a bad entry or format is skipped");

    std.file.write(path, `{"recentFiles": [{"path": "/d.dlt", "format": "logcat", "variant": 9999999999}], "theme": "dark"}`);
    settings = loadSettings(path);
    assert(settings.theme == "dark", "a variant out of range doesn't cost the other settings");
    assert(settings.recentFiles == [RecentFile(testPath("/d.dlt"))]);
}

@("loadSettings: a loaded recent list is cleaned: no duplicates, no empty paths, not too long")
unittest
{
    const path = buildPath(tempDir(), "log_tracy_settings_dirty_recent_test.json");
    scope (exit) if (exists(path)) remove(path);

    string[] paths = [testPath("/a.dlt"), "", testPath("/a.dlt")];
    foreach (i; 0 .. recentFilesMax + 2)
        paths ~= testPath("/") ~ i.to!string;
    std.file.write(path, JSONValue(["recentFiles": paths]).toString());

    auto list = loadSettings(path).recentFiles;
    assert(list.length == recentFilesMax);
    assert(list[0 .. 2].pathsOf == [testPath("/a.dlt"), testPath("/0")]);
}

@("settings: the time a file was used survives a save and a load; a broken one is unknown")
unittest
{
    const path = buildPath(tempDir(), "log_tracy_settings_last_used_test.json");
    scope (exit) if (exists(path)) remove(path);

    AppSettings settings;
    settings.recentFiles = [RecentFile(testPath("/a.dlt"), FormatChoice("dlt"), 1_762_250_000_123), RecentFile(testPath("/b.dlt"))];
    saveSettings(settings, path);
    assert(loadSettings(path).recentFiles == settings.recentFiles);

    std.file.write(path, `{"recentFiles": [{"path": "/a.dlt", "lastUsed": "x"}, {"path": "/b.dlt", "lastUsed": -5}]}`);
    assert(loadSettings(path).recentFiles == [RecentFile(testPath("/a.dlt")), RecentFile(testPath("/b.dlt"))]);
}

@("settings: the filter sets of a file survive a save and a load with their rules; broken entries are skipped, the old DLT-only filters aren't read")
unittest
{
    import log_core.rule_filter : Check, Condition, FilterRule, RuleKind;

    const path = buildPath(tempDir(), "log_tracy_settings_filters_test.json");
    scope (exit) if (exists(path)) remove(path);

    FilterRule errors;
    errors.name = "Errors";
    errors.conditions = [Condition("level", Check.Range, "", 1, 2), Condition("tag", Check.Equals, "AM")];
    FilterRule off;
    off.enabled = false;
    off.kind = RuleKind.Exclude;

    AppSettings settings;
    settings.recentFiles = [RecentFile(testPath("/a.log"), FormatChoice("logcat"), 100,
            [SavedFilter("one.dlf", testPath("/f/one.dlf"), true, [errors, off]), SavedFilter("New Filter", "", false, [])]),
        RecentFile(testPath("/b.dlt"))];
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

@("settings: the search history survives a save and a load; a query that can't be read is skipped")
unittest
{
    const path = buildPath(tempDir(), "log_tracy_settings_searches_test.json");
    scope (exit) if (exists(path)) remove(path);

    AppSettings settings;
    settings.recentFiles = [RecentFile(testPath("/a.dlt"), FormatChoice.init, 0, null,
        [[SearchChip("x|y", true, true), SearchChip(" ")], [SearchChip("z")]])];
    saveSettings(settings, path);
    assert(loadSettings(path).recentFiles == settings.recentFiles);

    std.file.write(path, `{"recentFiles": [{"path": "/a.dlt", "searches": [5, [{"text": 1}],
        [{"text": "ok", "isRegex": false, "matchCase": true}], [], "x"]}]}`);
    assert(loadSettings(path).recentFiles[0].searches == [[SearchChip("ok")]]);
}

@("settings: the layouts of the columns survive a save and a load; broken entries are skipped")
unittest
{
    const path = buildPath(tempDir(), "log_tracy_settings_columns_test.json");
    scope (exit) if (exists(path)) remove(path);

    AppSettings settings;
    settings.columnLayouts["dlt"] = [ColumnState("level"), ColumnState("time", false)];
    settings.columnLayouts["logcat"] = [ColumnState("tag", false)];
    saveSettings(settings, path);
    assert(loadSettings(path).columnLayouts == settings.columnLayouts);

    std.file.write(path, `{"columnLayouts": {"dlt": [{"id": "app"}, {"id": 5}, "x",
        {"id": "ctx", "visible": false}], "logcat": 7}, "theme": "dark"}`);
    settings = loadSettings(path);
    assert(settings.theme == "dark");
    assert(settings.columnLayouts == ["dlt": [ColumnState("app"), ColumnState("ctx", false)]],
        "a column without an id and a layout that isn't one are skipped; shown without the key");

    std.file.write(path, `{"columnLayouts": [1, 2], "theme": "dark"}`);
    settings = loadSettings(path);
    assert(settings.theme == "dark" && settings.columnLayouts is null);
}

@("withColumnLayouts: the layouts of the dialog replace those of their formats; a default one is dropped")
unittest
{
    import formats.dlt.format : dltFormatInfo;
    import formats.registry : formatColumns;
    import log_core.column_layout : defaultLayout;

    ColumnLayouts layouts;
    layouts["dlt"] = [ColumnState("level")];
    layouts["logcat"] = [ColumnState("tag", false)];

    auto changed = withColumnLayouts(layouts, `{"dlt": [{"id": "app", "visible": false}]}`);
    assert(changed == ["dlt": [ColumnState("app", false)], "logcat": [ColumnState("tag", false)]]);
    assert(layouts["dlt"] == [ColumnState("level")], "a copy");

    auto defaults = defaultLayout(formatColumns(dltFormatInfo.id))
        .map!(d => JSONValue(["id": JSONValue(d.id), "visible": JSONValue(d.visible)])).array;
    changed = withColumnLayouts(layouts, `{"dlt": ` ~ JSONValue(defaults).toString() ~ `}`);
    assert("dlt" !in changed, "the default layout is no layout");
    assert(withColumnLayouts(layouts, "not json") == layouts);
}

@("columnSettingsJson: the formats with columns to arrange, as their layouts arrange them")
unittest
{
    import formats.logcat : logcatFormatInfo;
    import formats.plain_text : plainTextFormatInfo;

    ColumnLayouts layouts;
    layouts[logcatFormatInfo.id] = [ColumnState("tag", false), ColumnState("time"), ColumnState("gone")];
    auto j = parseJSON(columnSettingsJson(layouts, logcatFormatInfo.id));
    assert(j["current"].str == logcatFormatInfo.id);

    const(JSONValue)* logcat;
    foreach (ref f; j["formats"].array)
    {
        assert(f["id"].str != plainTextFormatInfo.id, "nothing to arrange in plain text");
        if (f["id"].str == logcatFormatInfo.id)
            logcat = &f;
    }
    assert(logcat !is null);
    assert((*logcat)["name"].str == logcatFormatInfo.name);
    assert((*logcat)["payload"].str == "Message");
    assert((*logcat)["defaults"].array.map!(v => v.str).array == ["time", "pid", "tid", "level", "tag"]);
    const columns = (*logcat)["columns"].array;
    assert(columns.map!(c => c["id"].str).array == ["tag", "time", "pid", "tid", "level"],
        "a column the format doesn't have any more isn't listed");
    assert(columns[0]["title"].str == "Tag" && !columns[0]["visible"].boolean);
    assert(columns[1]["visible"].boolean);
}

@("columnSettingsJson: DLT without a layout hides the counter, the session and the message IDs")
unittest
{
    import formats.dlt.format : dltFormatInfo;

    auto j = parseJSON(columnSettingsJson(null, dltFormatInfo.id));
    foreach (ref f; j["formats"].array)
    {
        if (f["id"].str != dltFormatInfo.id)
            continue;
        string[] hidden;
        foreach (ref c; f["columns"].array)
            if (!c["visible"].boolean)
                hidden ~= c["id"].str;
        assert(hidden == ["counter", "session", "msgid"], hidden.to!string);
        return;
    }
    assert(false, "DLT is listed");
}

@("mergeAppStateFromScript: the window, theme and font size come from the script")
unittest
{
    AppSettings base;
    base.windowRect = WindowRect(1, 2, 3, 4);
    base.theme = "light";
    base.tableFontSize = 100;

    const merged = mergeAppStateFromScript(base, `{"windowRect": {"left": 10, "top": 20,
        "width": 300, "height": 400}, "theme": "dark", "tableFontSize": 120}`);
    assert(merged.windowRect == WindowRect(10, 20, 300, 400));
    assert(merged.theme == "dark");
    assert(merged.tableFontSize == 120);
    assert(base.theme == "light", "the settings given are not changed");
}

@("mergeAppStateFromScript: keys the script doesn't send keep their values")
unittest
{
    AppSettings base;
    base.windowRect = WindowRect(1, 2, 3, 4);
    base.theme = "dark";
    base.tableFontSize = 90;

    const merged = mergeAppStateFromScript(base, `{"tableFontSize": 110}`);
    assert(merged.windowRect == WindowRect(1, 2, 3, 4));
    assert(merged.theme == "dark");
    assert(merged.tableFontSize == 110);
    assert(mergeAppStateFromScript(base, "not json") == base, "a malformed JSON changes nothing");
}

@("loadSettings: a bad theme or font size doesn't lose the files and the recent list")
unittest
{
    const path = buildPath(tempDir(), "log_tracy_settings_bad_font_test.json");
    scope (exit) if (exists(path)) remove(path);
    std.file.write(path, `{"activeFile": "/b.dlt", "files": [{"path": "/b.dlt", "scrollPosition": 3}],
        "recentFiles": [{"path": "/a.dlt"}], "tableFontSize": 110.5}`);

    const settings = loadSettings(path);
    assert(settings.activeFile == "/b.dlt", "as written: only the recent list makes a path absolute");
    assert(settings.files == [FileState("/b.dlt")], "a scroll position of an older version is let go");
    assert(settings.recentFiles.pathsOf == [testPath("/a.dlt")]);
}

@("mergeAppStateFromScript: the height of the search panel comes from the script")
unittest
{
    // A regression guard: it held before the side panel was removed too
    AppSettings base;
    base.searchPanelHeight = "250dip";

    assert(mergeAppStateFromScript(base, `{"searchPanelHeight": "180dip"}`).searchPanelHeight == "180dip");
    assert(mergeAppStateFromScript(base, `{"theme": "dark"}`).searchPanelHeight == "250dip", "kept when not sent");
}

@("mergeAppStateFromScript: whether the bottom panel is collapsed comes from the script")
unittest
{
    AppSettings base;
    assert(mergeAppStateFromScript(base, `{"bottomPanelCollapsed": true}`).bottomPanelCollapsed);
    base.bottomPanelCollapsed = true;
    assert(!mergeAppStateFromScript(base, `{"bottomPanelCollapsed": false}`).bottomPanelCollapsed);
    assert(mergeAppStateFromScript(base, `{"theme": "dark"}`).bottomPanelCollapsed, "kept when not sent");
    assert(mergeAppStateFromScript(base, `{"bottomPanelCollapsed": "yes"}`).bottomPanelCollapsed, "not a bool: kept");
}

@("the collapsed bottom panel survives a save and a load, as a copy and in equality")
unittest
{
    const path = buildPath(tempDir(), "log_tracy_settings_collapsed_test.json");
    scope (exit) if (exists(path)) remove(path);

    AppSettings settings;
    settings.bottomPanelCollapsed = true;
    saveSettings(settings, path);
    assert(loadSettings(path).bottomPanelCollapsed);

    AppSettings copy = settings;
    assert(copy.bottomPanelCollapsed, "copied");
    const AppSettings none;
    assert(copy != none, "compared");
}

@("the height of the search panel survives a save and a load")
unittest
{
    const path = buildPath(tempDir(), "log_tracy_settings_panels_test.json");
    scope (exit) if (exists(path)) remove(path);

    AppSettings settings;
    settings.searchPanelHeight = "180dip";
    saveSettings(settings, path);
    assert(loadSettings(path).searchPanelHeight == "180dip");
}

@("the width of the removed side panel in an old settings file is ignored")
unittest
{
    // A regression guard: it passed before the side panel was removed too
    const path = buildPath(tempDir(), "log_tracy_settings_side_panel_test.json");
    scope (exit) if (exists(path)) remove(path);

    std.file.write(path, `{"sidePanelWidth": "320dip", "searchPanelHeight": "180dip", "theme": "dark"}`);
    const loaded = loadSettings(path);
    assert(loaded.searchPanelHeight == "180dip" && loaded.theme == "dark");
}

@("mergeAppStateFromScript: a window rect without all its keys is not taken in part")
unittest
{
    AppSettings base;
    base.windowRect = WindowRect(1, 2, 3, 4);

    const merged = mergeAppStateFromScript(base, `{"windowRect": {"left": 10, "top": 20}}`);
    assert(merged.windowRect == WindowRect(1, 2, 3, 4));
}

@("language: the system one by default, saved and loaded")
unittest
{
    const path = buildPath(tempDir(), "log_tracy_settings_language_test.json");
    scope (exit) if (exists(path)) remove(path);

    assert(AppSettings.init.language == "", "the language of the system");
    AppSettings settings;
    settings.language = "ru";
    saveSettings(settings, path);
    assert(loadSettings(path).language == "ru");

    std.file.write(path, `{"language": 5, "theme": "dark"}`);
    settings = loadSettings(path);
    assert(settings.language == "" && settings.theme == "dark", "a bad language is the system one");
}

@("mergeAppStateFromScript: the language comes from the script")
unittest
{
    AppSettings base;
    base.language = "ru";
    assert(mergeAppStateFromScript(base, `{"language": "x-pseudo"}`).language == "x-pseudo");
    assert(mergeAppStateFromScript(base, `{"theme": "dark"}`).language == "ru");
    AppSettings other = base;
    other.language = "";
    assert(other != base, "the language is a setting of its own");
}
