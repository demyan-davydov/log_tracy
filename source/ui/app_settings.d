//! The settings of the application, kept in settings.json next to the
//! executable: the window, the theme, the font size of the tables, the
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
    int scrollPosition;
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
    import log_core.column_layout : isDefaultLayout, movableIds;

    ColumnLayouts result = copyOf(layouts);
    ColumnLayouts changed;
    try
        changed = columnLayoutsFromJson(parseJSON(json));
    catch (JSONException)
        return result;
    foreach (formatId, layout; changed)
    {
        if (isDefaultLayout(layout, movableIds(formatColumns(formatId))))
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
    import log_core.column_layout : fullLayout, movableIds;
    import log_core.log_format : ColumnKind;

    JSONValue[] formats;
    foreach (info; formatInfos())
    {
        const columns = formatColumns(info.id);
        const ids = movableIds(columns);
        if (ids.length == 0)
            continue;
        const layout = info.id in layouts;
        JSONValue[] shown;
        foreach (state; fullLayout(ids, layout is null ? null : *layout))
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
            "defaults": JSONValue(ids), "columns": JSONValue(shown),
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
    ColumnLayouts columnLayouts; /// the columns of the log tables, by format
    string language; /// of the interface: a BCP 47 tag ("ru", "x-pseudo"); "": the language of the system

    this(ref return scope const AppSettings rhs)
    {
        this.windowRect = rhs.windowRect;
        this.files = rhs.files.dup;
        this.activeFile = rhs.activeFile;
        this.recentFiles = copyOf(rhs.recentFiles);
        this.theme = rhs.theme;
        this.tableFontSize = rhs.tableFontSize;
        this.columnLayouts = copyOf(rhs.columnLayouts);
        this.language = rhs.language;
    }

    void opAssign(const AppSettings rhs)
    {
        this.windowRect = rhs.windowRect;
        this.files = rhs.files.dup;
        this.activeFile = rhs.activeFile;
        this.recentFiles = copyOf(rhs.recentFiles);
        this.theme = rhs.theme;
        this.tableFontSize = rhs.tableFontSize;
        this.columnLayouts = copyOf(rhs.columnLayouts);
        this.language = rhs.language;
    }

    bool opEquals(const ref AppSettings rhs) const
    {
        return windowRect == rhs.windowRect &&
            files == rhs.files &&
            activeFile == rhs.activeFile &&
            recentFiles == rhs.recentFiles &&
            theme == rhs.theme &&
            tableFontSize == rhs.tableFontSize &&
            columnLayouts == rhs.columnLayouts &&
            language == rhs.language;
    }

    size_t toHash() const @safe nothrow
    {
        size_t hash = windowRect.hashOf();
        hash = hashOf(files, hash);
        hash = hashOf(activeFile, hash);
        hash = hashOf(recentFiles, hash);
        hash = hashOf(theme, hash);
        hash = hashOf(tableFontSize, hash);
        hash = hashOf(language, hash);
        foreach (id, layout; columnLayouts) // in no order: summed
            hash += hashOf(layout, hashOf(id));
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
    j.object["recentFiles"] = recentFilesToJson(settings.recentFiles);
    j.object["theme"] = JSONValue(settings.theme);
    j.object["tableFontSize"] = JSONValue(settings.tableFontSize);
    j.object["language"] = JSONValue(settings.language);
    if (settings.columnLayouts.length)
        j.object["columnLayouts"] = columnLayoutsToJson(settings.columnLayouts);

    return j;
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
/// JSON of its getAppState() (window rect, theme, font size of the tables,
/// scroll position of the active file). Keys it doesn't have keep their values;
/// a malformed JSON changes nothing more after the first bad key.
AppSettings mergeAppStateFromScript(const AppSettings base, const(char)[] appStateJson)
{
    AppSettings settings = base;
    try
    {
        const j = parseJSON(appStateJson);
        readPreferences(j, settings);
        const scroll = "scrollPosition" in j;
        if (scroll !is null && settings.activeFile.length > 0)
            foreach (ref f; settings.files)
                if (f.path == settings.activeFile)
                {
                    f.scrollPosition = scroll.integer.to!int;
                    break;
                }
    }
    catch (Exception e)
    {
        writeln("Error parsing the state of the script: ", e.msg);
    }
    return settings;
}

/// Reads what both the settings file and the state of the script hold: the
/// window rect, the theme, the font size of the tables and the language. Keys
/// `j` doesn't have leave their values in `settings`.
private void readPreferences(in JSONValue j, ref AppSettings settings)
{
    if (const r = "windowRect" in j) // taken whole or not at all
        settings.windowRect = WindowRect((*r)["left"].integer.to!int, (*r)["top"].integer.to!int,
            (*r)["width"].integer.to!int, (*r)["height"].integer.to!int);
    if (const theme = "theme" in j)
        settings.theme = theme.str;
    if (const fontSize = "tableFontSize" in j)
        settings.tableFontSize = fontSize.integer.to!int;
    if (const language = "language" in j)
        settings.language = language.type == JSONType.string ? language.str : "";
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
    assert(loadSettings(path).recentFiles.pathsOf == ["/b.dlt", "/a.dlt"]);
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
    assert(settings.recentFiles.pathsOf == ["/a.dlt", "/b.dlt"]);

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
    assert(list[0 .. 2].pathsOf == ["/a.dlt", "/0"]);
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

/// The search history survives a save and a load; a query that can't be read is skipped
unittest
{
    const path = buildPath(tempDir(), "dlt_explorer_settings_searches_test.json");
    scope (exit) if (exists(path)) remove(path);

    AppSettings settings;
    settings.recentFiles = [RecentFile("/a.dlt", FormatChoice.init, 0, null,
        [[SearchChip("x|y", true, true), SearchChip(" ")], [SearchChip("z")]])];
    saveSettings(settings, path);
    assert(loadSettings(path).recentFiles == settings.recentFiles);

    std.file.write(path, `{"recentFiles": [{"path": "/a.dlt", "searches": [5, [{"text": 1}],
        [{"text": "ok", "isRegex": false, "ignoreCase": false}], [], "x"]}]}`);
    assert(loadSettings(path).recentFiles[0].searches == [[SearchChip("ok")]]);
}

/// The layouts of the columns survive a save and a load; broken entries are skipped
unittest
{
    const path = buildPath(tempDir(), "dlt_explorer_settings_columns_test.json");
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

/// The layouts of the dialog replace those of their formats; a default one is dropped
unittest
{
    import formats.dlt.format : dltFormatInfo;
    import formats.registry : formatColumns;
    import log_core.column_layout : movableIds;

    ColumnLayouts layouts;
    layouts["dlt"] = [ColumnState("level")];
    layouts["logcat"] = [ColumnState("tag", false)];

    auto changed = withColumnLayouts(layouts, `{"dlt": [{"id": "app", "visible": false}]}`);
    assert(changed == ["dlt": [ColumnState("app", false)], "logcat": [ColumnState("tag", false)]]);
    assert(layouts["dlt"] == [ColumnState("level")], "a copy");

    auto defaults = movableIds(formatColumns(dltFormatInfo.id)).map!(id => JSONValue(["id": id])).array;
    changed = withColumnLayouts(layouts, `{"dlt": ` ~ JSONValue(defaults).toString() ~ `}`);
    assert("dlt" !in changed, "the default layout is no layout");
    assert(withColumnLayouts(layouts, "not json") == layouts);
}

/// The dialog gets the formats with columns to arrange, as their layouts arrange them
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

@("mergeAppStateFromScript: the scroll position goes to the active file")
unittest
{
    AppSettings base;
    base.files = [FileState("/a.dlt", 1), FileState("/b.dlt", 2)];
    base.activeFile = "/b.dlt";

    const merged = mergeAppStateFromScript(base, `{"scrollPosition": 42}`);
    assert(merged.files == [FileState("/a.dlt", 1), FileState("/b.dlt", 42)]);
    assert(base.files[1].scrollPosition == 2, "the files of the settings given are not changed");
}

@("loadSettings: a bad theme or font size doesn't lose the files and the recent list")
unittest
{
    const path = buildPath(tempDir(), "dlt_explorer_settings_bad_font_test.json");
    scope (exit) if (exists(path)) remove(path);
    std.file.write(path, `{"activeFile": "/b.dlt", "files": [{"path": "/b.dlt", "scrollPosition": 3}],
        "recentFiles": [{"path": "/a.dlt"}], "tableFontSize": 110.5}`);

    const settings = loadSettings(path);
    assert(settings.activeFile == "/b.dlt");
    assert(settings.files == [FileState("/b.dlt", 3)]);
    assert(settings.recentFiles.pathsOf == ["/a.dlt"]);
}

@("mergeAppStateFromScript: a window rect without all its keys is not taken in part")
unittest
{
    AppSettings base;
    base.windowRect = WindowRect(1, 2, 3, 4);

    const merged = mergeAppStateFromScript(base, `{"windowRect": {"left": 10, "top": 20}}`);
    assert(merged.windowRect == WindowRect(1, 2, 3, 4));
}

@("mergeAppStateFromScript: without an active file no file gets the scroll position")
unittest
{
    AppSettings base;
    base.files = [FileState("", 1)];

    const merged = mergeAppStateFromScript(base, `{"scrollPosition": 42}`);
    assert(merged.files == [FileState("", 1)]);
}

@("language: the system one by default, saved and loaded")
unittest
{
    const path = buildPath(tempDir(), "dlt_explorer_settings_language_test.json");
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
