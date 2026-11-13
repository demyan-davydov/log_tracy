//! The recent files: the list the placeholder shows (recentFilesMax files, the
//! latest first) and what is kept for each of them (the format it was opened
//! with, when it was used, its filter sets, its search history), the
//! operations on the list and how the settings keep it in JSON.
module ui.recent_files;

import formats.registry : formatInfo;
import log_core.filter_file : ruleFromJson, rulesToJson;
import log_core.log_format : FormatChoice, FormatInfo;
import log_core.rule_filter : FilterRule;
import log_core.search_filter : SearchChip;
import log_core.text_encoding : encodingByName, encodingName, TextEncoding;
import ui.search_chips : chipsFromJson, chipsToJson;

import std.algorithm;
import std.array;
import std.conv : to;
import std.file;
import std.json;
import std.path;

/// Length of the recent files list
enum recentFilesMax = 8;

/// The spelling of `path` in the recent list: absolute and normalized
string recentFilePath(string path)
{
    return buildNormalizedPath(absolutePath(path));
}

/// Whether two paths name the same file of the recent list: compared
/// normalized, ignoring case where the OS does
bool sameRecentFile(string a, string b)
{
    return filenameCmp(recentFilePath(a), recentFilePath(b)) == 0;
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
    SearchChip[][] searches; /// the queries searched in it, the latest first (searchHistoryMax at most)
}

/// The most queries the search history of a file keeps
enum searchHistoryMax = 30;

/// A mutable copy of a recent file entry
RecentFile copyOf(const RecentFile file)
{
    return RecentFile(file.path, file.format, file.lastUsed,
        file.filters.map!(f => SavedFilter(f.name, f.source, f.enabled, copyOf(f.rules))).array,
        file.searches.map!(q => q.dup).array);
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
RecentFile[] copyOf(const RecentFile[] list)
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

/// Returns: the search history of `path`, the latest query first; null if it isn't in the list
SearchChip[][] savedSearches(const RecentFile[] list, string path)
{
    path = recentFilePath(path);
    foreach (file; list)
        if (filenameCmp(file.path, path) == 0)
            return file.searches.map!(q => q.dup).array;
    return null;
}

/// Returns the recent list with `query` on top of the search history of `path`,
/// in place: a query searched before moves up instead of being added again, the
/// history keeps searchHistoryMax queries. An empty query and a file not in
/// the list change nothing.
RecentFile[] withSearch(const RecentFile[] list, string path, const(SearchChip)[] query)
{
    path = recentFilePath(path);
    RecentFile[] result = copyOf(list);
    if (query.length == 0)
        return result;
    foreach (ref file; result)
    {
        if (filenameCmp(file.path, path) != 0)
            continue;
        auto searches = [query.dup] ~ file.searches.filter!(q => q != query).array;
        file.searches = searches[0 .. min(searches.length, searchHistoryMax)];
    }
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
            if (file.searches is null)
                file.searches = saved.searches;
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

/// Returns the recent list after `path` failed to open: a file already in the
/// list stays where it is, as it was (its entry shows why it failed; moving it
/// would pull it from under the mouse); a file new to it goes on top, to be
/// tried again
RecentFile[] withFailedFile(const RecentFile[] list, string path)
{
    const normalized = recentFilePath(path);
    if (list.canFind!(f => filenameCmp(f.path, normalized) == 0))
        return copyOf(list);
    return withRecentFile(list, path);
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
        if (paths.canFind!(p => sameRecentFile(p, file.path)))
            file.lastUsed = now;
    return result;
}

/// Returns the recent list without `path` (spelled in any way), and so
/// without what was kept for it: its format, filter sets, search history
RecentFile[] withoutRecentFile(const RecentFile[] list, string path)
{
    return copyOf(list).filter!(f => !sameRecentFile(f.path, path)).array;
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

/// The recent list as the settings keep it: [{"path", "format", "variant",
/// "encoding", "lastUsed", "filterSets", "searches"}], the keys without a value left out
JSONValue recentFilesToJson(const RecentFile[] list)
{
    JSONValue[] recentArray;
    foreach (f; list)
    {
        JSONValue fv = ["path": f.path];
        if (f.format.isSet)
        {
            fv.object["format"] = JSONValue(f.format.id);
            fv.object["variant"] = JSONValue(f.format.variant);
            if (f.format.encoding != TextEncoding.utf8)
                fv.object["encoding"] = JSONValue(encodingName(f.format.encoding));
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
        if (f.searches.length)
            fv.object["searches"] = JSONValue(f.searches.map!(q => chipsToJson(q)).array);
        recentArray ~= fv;
    }
    return JSONValue(recentArray);
}

/// The recent list the settings keep, cleaned: no duplicates, no empty paths,
/// not too long; an entry that isn't a file is skipped. An entry of a path
/// only was written before the formats were saved.
RecentFile[] recentFilesFromJson(const JSONValue json)
{
    RecentFile[] list;
    if (json.type != JSONType.array)
        return list;
    // Oldest first, so the newest ends up on top
    foreach_reverse (val; json.array)
    {
        if (val.type == JSONType.string)
            list = withRecentFile(list, val.str);
        else if (val.type == JSONType.object)
        {
            const filePath = "path" in val;
            if (filePath !is null && filePath.type == JSONType.string)
                list = withRecentFile(list,
                    RecentFile(filePath.str, formatOf(val), lastUsedOf(val), filtersOf(val), searchesOf(val)));
        }
    }
    return list;
}

/// The format saved in a recent file entry: {"format": id, "variant",
/// "encoding"}; unset if there is none or this build can't read it
private FormatChoice formatOf(const JSONValue entry)
{
    const id = "format" in entry;
    if (id is null || id.type != JSONType.string)
        return FormatChoice.init;
    FormatChoice choice = FormatChoice(id.str);
    const variant = "variant" in entry;
    if (variant !is null && variant.type == JSONType.integer)
    {
        if (variant.integer < int.min || variant.integer > int.max)
            return FormatChoice.init; // not a variant: the format is detected again
        choice.variant = cast(int) variant.integer;
    }
    const encoding = "encoding" in entry;
    if (encoding !is null && (encoding.type != JSONType.string || !encodingByName(encoding.str, choice.encoding)))
        return FormatChoice.init; // an encoding of another build: detected again
    return choice;
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

/// The search history saved in a recent file entry: {"searches": [[chips as
/// the script sends them]]}; a query that can't be read, or an empty one, is skipped
private SearchChip[][] searchesOf(const JSONValue entry)
{
    const searches = "searches" in entry;
    if (searches is null || searches.type != JSONType.array)
        return null;
    SearchChip[][] result;
    foreach (ref query; searches.array)
    {
        try
        {
            auto chips = chipsFromJson(query);
            if (chips.length)
                result ~= chips;
        }
        catch (Exception)
        {
        } // skipped
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

version (unittest)
{
    /// Recent files without formats
    RecentFile[] recentList(string[] paths...)
    {
        return paths.map!(p => RecentFile(p)).array;
    }

    const(string)[] pathsOf(const RecentFile[] list)
    {
        return list.map!(f => f.path).array;
    }
}

/// A file removed from the list takes what was kept for it along
unittest
{
    auto list = [RecentFile("/a.dlt", FormatChoice("dlt"), 10), RecentFile("/b.dlt", FormatChoice("logcat"), 20),
        RecentFile("/c.dlt")];
    list[1].filters = [SavedFilter("f")];
    const removed = withoutRecentFile(list, "/logs/../b.dlt");
    assert(removed.pathsOf == ["/a.dlt", "/c.dlt"], "the same file spelled otherwise");
    assert(removed[0] == list[0] && removed[1] == list[2], "the others as they were");
    assert(savedFilters(removed, "/b.dlt").length == 0);
    assert(withoutRecentFile(list, "/other.dlt").pathsOf == ["/a.dlt", "/b.dlt", "/c.dlt"], "not in the list");
}

/// Opening a file puts it on top of the recent list, without duplicates
unittest
{
    assert(withRecentFile([], "/a.dlt").pathsOf == ["/a.dlt"]);
    assert(withRecentFile(recentList("/a.dlt", "/b.dlt"), "/c.dlt").pathsOf == ["/c.dlt", "/a.dlt", "/b.dlt"]);
    assert(withRecentFile(recentList("/a.dlt", "/b.dlt", "/c.dlt"), "/b.dlt").pathsOf == ["/b.dlt", "/a.dlt", "/c.dlt"]);
    assert(withRecentFile(recentList("/a.dlt"), "").pathsOf == ["/a.dlt"]);
}

/// A file of the list that fails to open stays where it is, as it was
unittest
{
    auto list = [RecentFile("/a.dlt", FormatChoice("dlt"), 10), RecentFile("/b.dlt", FormatChoice("logcat"), 20)];
    const failed = withFailedFile(list, "/b.dlt");
    assert(failed.pathsOf == ["/a.dlt", "/b.dlt"], "not moved on top");
    assert(failed[1] == list[1], "its format and time are kept");
    assert(withFailedFile(list, "/logs/../b.dlt").pathsOf == ["/a.dlt", "/b.dlt"], "the same file spelled otherwise");
}

/// A file new to the list that fails to open goes on top, to be tried again
unittest
{
    assert(withFailedFile(recentList("/a.dlt"), "/new.dlt").pathsOf == ["/new.dlt", "/a.dlt"]);
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
    assert(withRecentFile(recentList("/logs/a.dlt"), "/logs/./x/../a.dlt").pathsOf == ["/logs/a.dlt"]);
    assert(withRecentFile([], "a.dlt").pathsOf == [buildNormalizedPath(absolutePath("a.dlt"))]);
    version (Windows)
        assert(withRecentFile(recentList(`C:\logs\a.dlt`), "c:/logs/a.dlt").pathsOf == [`c:\logs\a.dlt`]);
}

/// The placeholder gets every recent file with a mark whether it still exists
unittest
{
    const existing = buildPath(tempDir(), "log_tracy_recent_existing_test.dlt");
    std.file.write(existing, "");
    scope (exit) remove(existing);
    const missing = buildPath(tempDir(), "log_tracy_recent_missing_test.dlt");

    auto j = parseJSON(recentFilesJson(recentList(existing, missing)));
    assert(j.array.length == 2);
    assert(j[0]["path"].str == existing && j[0]["exists"].boolean);
    assert(j[1]["path"].str == missing && !j[1]["exists"].boolean);
}

/// A path is stored in the recent list the way recentFilePath() spells it
unittest
{
    assert(recentFilePath("/logs/./x/../a.dlt") == "/logs/a.dlt");
    assert(withRecentFile([], "/logs/./x/../a.dlt").pathsOf == [recentFilePath("/logs/./x/../a.dlt")]);
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

/// The encoding of a text format is saved with it, UTF-8 left out; an encoding
/// this build doesn't know has the format detected again
unittest
{
    import log_core.text_encoding : TextEncoding;

    const utf16 = FormatChoice("text", 0, TextEncoding.utf16be);
    auto j = recentFilesToJson([RecentFile("/a.log", utf16), RecentFile("/b.log", FormatChoice("text"))]);
    assert(j[0]["encoding"].str == "utf-16be");
    assert("encoding" !in j[1]);

    auto list = recentFilesFromJson(j);
    assert(savedFormat(list, "/a.log") == utf16);
    assert(savedFormat(list, "/b.log") == FormatChoice("text"));

    auto unknown = parseJSON(`[{"path": "/c.log", "format": "text", "variant": 0, "encoding": "koi8-r"}]`);
    assert(!savedFormat(recentFilesFromJson(unknown), "/c.log").isSet);
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

/// The search history of a file: the latest query on top, a repeated one moved
/// up, searchHistoryMax at most; kept when the file is opened again
unittest
{
    const a = [SearchChip("a")], b = [SearchChip("b", true, true)], c = [SearchChip("a"), SearchChip("c")];
    auto list = [RecentFile("/b.log"), RecentFile("/a.log")];
    list = withSearch(list, "/a.log", a);
    list = withSearch(list, "/a.log", b);
    list = withSearch(list, "/logs/../a.log", c);
    assert(savedSearches(list, "/a.log") == [c, b, a]);
    assert(list[1].path == "/a.log", "in place");
    assert(savedSearches(list, "/b.log").length == 0);
    assert(savedSearches(list, "/c.log") is null);

    list = withSearch(list, "/a.log", a);
    assert(savedSearches(list, "/a.log") == [a, c, b], "a repeated query moves up");
    assert(withSearch(list, "/a.log", [SearchChip("b", true, false)])[1].searches.length == 4,
        "another case is another query");

    assert(withSearch(list, "/a.log", a) == list, "the latest query again changes nothing");
    assert(withSearch(list, "/a.log", []) == list, "an empty query isn't kept");
    assert(withSearch(list, "/c.log", a) == list, "a file not in the list isn't added");

    auto full = [RecentFile("/a.log")];
    foreach (i; 0 .. searchHistoryMax + 5)
        full = withSearch(full, "/a.log", [SearchChip(i.to!string)]);
    assert(full[0].searches.length == searchHistoryMax);
    assert(full[0].searches[0] == [SearchChip((searchHistoryMax + 4).to!string)], "the latest are kept");

    assert(withRecentFile(list, RecentFile("/a.log", FormatChoice("dlt"), 200))[0].searches == [a, c, b]);
    assert(withFilesUsed(list, ["/a.log"], 300)[0].searches == [a, c, b]);
}
