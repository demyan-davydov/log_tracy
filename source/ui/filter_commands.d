module ui.filter_commands;

//! The filters of the main view of a document, apart from the window so they
//! can be tested: the filter sets of the log, the commands that change them
//! and their state for the filter panel. A set is a copy: a loaded .dlf is
//! copied, edited in place, remembered in the settings of the log and can be
//! exported to a .dlf; no file is referred to, so a .dlf loaded for two logs
//! doesn't tie them together.
//! Each command returns an error message for the user, "" on success.

import formats.dlt.dlf : canLoadDlf, DlfFilter, dlfFilterFromJson, dlfFilterToJson, readDlf,
    toRule, writeDlf;
import log_core.log_filter : LogFilter;
import log_core.log_format : LogFormat;
import log_core.rule_filter;
import ui.app_settings : SavedFilter;

import std.json : JSONValue;

final class DocumentFilters
{
    //! A set and the filters it is made of
    private struct Entry
    {
        FilterSet set; // the rules, derived from `filters`
        DlfFilter[] filters; // what is edited, saved and exported
    }

    private const(LogFormat) _format;
    private void delegate(LogFilter!wchar) _apply;
    private Entry[] _entries;

    //! @param apply - filters the main view of the document (null: no filter)
    this(const(LogFormat) format, void delegate(LogFilter!wchar) apply)
    {
        _format = format;
        _apply = apply;
    }

    const(FilterSet)[] sets() const
    {
        import std.algorithm.iteration : map;
        import std.array : array;

        return _entries.map!((ref e) => e.set).array;
    }

    //! @brief Appends a copy of the rules of a .dlf and filters the view with them
    string addDlf(string path)
    {
        import std.algorithm.searching : canFind;
        import std.path : baseName;

        if (!canLoadDlf(_format))
            return notDlt;
        if (_entries.canFind!((ref e) => e.set.source == path))
            return baseName(path) ~ " is loaded already: remove it to load it again";
        Entry entry;
        try
            entry.filters = readDlf(path);
        catch (Exception e)
            return "Can't load the filter: " ~ e.msg;
        entry.set.name = baseName(path);
        entry.set.source = path;
        rebuild(entry);
        _entries ~= entry;
        if (filtersView(entry.set))
            apply();
        return "";
    }

    //! @brief Appends an empty set, to add rules to
    string newSet()
    {
        if (!canLoadDlf(_format))
            return notDlt;
        Entry entry;
        entry.set.name = "New Filter";
        _entries ~= entry;
        return "";
    }

    //! @brief Writes a set to a .dlf in the layout of dlt-viewer, with the
    //! switches of its rules (all off if the set is); the set is named after
    //! the file then
    string exportSet(size_t set, string path)
    {
        import std.path : baseName;

        if (set >= _entries.length)
            return noSuchSet;
        // What filters is written: the rules of a set switched off are off
        auto filters = _entries[set].filters.dup;
        if (!_entries[set].set.enabled)
            foreach (ref filter; filters)
                filter.enabled = false;
        try
            writeDlf(path, filters);
        catch (Exception e)
            return "Can't export the filter: " ~ e.msg;
        _entries[set].set.name = baseName(path);
        _entries[set].set.source = path;
        return "";
    }

    //! The sets as they are saved for the log: copies of their rules
    SavedFilter[] saved() const
    {
        SavedFilter[] result;
        foreach (ref e; _entries)
            result ~= SavedFilter(e.set.name, e.set.source, e.set.enabled, e.filters.dup);
        return result;
    }

    //! @brief Takes the sets saved for the log and filters the view with them.
    //! Does nothing for a log .dlf don't apply to.
    void restore(const(SavedFilter)[] filters)
    {
        if (!canLoadDlf(_format))
            return;
        bool changed;
        foreach (ref saved; filters)
        {
            Entry entry;
            entry.set.name = saved.name;
            entry.set.source = saved.source;
            entry.set.enabled = saved.enabled;
            entry.filters = saved.rules.dup;
            rebuild(entry);
            changed |= filtersView(entry.set);
            _entries ~= entry;
        }
        if (changed)
            apply();
    }

    //! @brief Removes a set
    string remove(size_t set)
    {
        import std.algorithm.mutation : remove;

        if (set >= _entries.length)
            return noSuchSet;
        const changed = filtersView(_entries[set].set);
        _entries = _entries.remove(set);
        if (changed)
            apply();
        return "";
    }

    //! @brief Switches a whole set on or off
    string enableSet(size_t set, bool enabled)
    {
        if (set >= _entries.length)
            return noSuchSet;
        _entries[set].set.enabled = enabled;
        if (filtersView(_entries[set].set, true))
            apply();
        return "";
    }

    //! @brief Switches one rule of a set on or off
    string enableRule(size_t set, size_t rule, bool enabled)
    {
        if (set >= _entries.length || rule >= _entries[set].filters.length)
            return noSuchSet;
        auto entry = &_entries[set];
        entry.filters[rule].enabled = enabled;
        entry.set.rules[rule].enabled = enabled;
        if (entry.set.enabled && filters(entry.set.rules[rule], true)) // markers don't change what is shown
            apply();
        return "";
    }

    //! A new rule for the editor, as ruleJson gives a rule: the defaults of dlt-viewer
    static JSONValue newRuleJson()
    {
        DlfFilter filter;
        filter.name = "New Rule";
        return dlfFilterToJson(filter);
    }

    //! The filter of a rule for the editor: the fields of DlfFilter by name;
    //! null if there is no such rule
    JSONValue ruleJson(size_t set, size_t rule) const
    {
        if (set >= _entries.length || rule >= _entries[set].filters.length)
            return JSONValue(null);
        return dlfFilterToJson(_entries[set].filters[rule]);
    }

    //! @brief Appends a rule (the fields of DlfFilter by name; those missing
    //! keep the defaults) to a set
    string addRule(size_t set, string json)
    {
        if (set >= _entries.length)
            return noSuchSet;
        return edit(set, json, (entry, filter) { entry.filters ~= filter; });
    }

    //! @brief Replaces a rule of a set, as addRule takes it
    string updateRule(size_t set, size_t rule, string json)
    {
        if (set >= _entries.length || rule >= _entries[set].filters.length)
            return noSuchSet;
        return edit(set, json, (entry, filter) { entry.filters[rule] = filter; });
    }

    //! @brief Removes a rule of a set
    string removeRule(size_t set, size_t rule)
    {
        import std.algorithm.mutation : remove;

        if (set >= _entries.length || rule >= _entries[set].filters.length)
            return noSuchSet;
        auto entry = &_entries[set];
        const changed = entry.set.enabled && filters(entry.set.rules[rule]);
        entry.filters = entry.filters.remove(rule);
        rebuild(*entry);
        if (changed)
            apply();
        return "";
    }

    //! The state of the filter panel: {canLoad, sets: [{name, source,
    //! enabled, rules: [{name, kind, enabled, color, error}]}]}. canLoad
    //! tells whether .dlf filters apply to this log; kind is "include",
    //! "exclude" or "marker"; error says why a rule isn't applied, "" if it is.
    JSONValue toJson() const
    {
        static immutable string[] kinds = ["include", "exclude", "marker"];

        JSONValue[] sets;
        foreach (ref e; _entries)
        {
            JSONValue[] rules;
            foreach (ref rule; e.set.rules)
                rules ~= JSONValue([
                    "name": JSONValue(rule.name),
                    "kind": JSONValue(kinds[rule.kind]),
                    "enabled": JSONValue(rule.enabled),
                    "color": JSONValue(rule.color),
                    "error": JSONValue(rule.problem), // see rebuild()
                ]);
            sets ~= JSONValue([
                "name": JSONValue(e.set.name),
                "source": JSONValue(e.set.source),
                "enabled": JSONValue(e.set.enabled),
                "rules": JSONValue(rules),
            ]);
        }
        return JSONValue(["canLoad": JSONValue(canLoadDlf(_format)), "sets": JSONValue(sets)]);
    }

    private enum noSuchSet = "no such filter";
    private enum notDlt = "DLT filters (.dlf) apply to DLT logs only";

    //! @brief Changes the filters of a set by a filter parsed from `json`.
    //! A rule switched on must be one that can be applied (the header text is
    //! let through: it is a rule of dlt-viewer this log can't apply yet); one
    //! switched off is taken with its error, as a loaded one is, so it can be
    //! renamed or switched off before it is fixed.
    private string edit(size_t set, string json, scope void delegate(Entry*, DlfFilter) change)
    {
        import std.json : parseJSON;

        DlfFilter filter;
        try
            filter = dlfFilterFromJson(parseJSON(json));
        catch (Exception e)
            return "Invalid rule: " ~ e.msg;
        if (filter.enabled)
        {
            auto rule = toRule(filter);
            rule.problem = "";
            const error = ruleError(_format.columns, rule);
            if (error.length)
                return error;
        }

        auto entry = &_entries[set];
        const before = filtersView(entry.set);
        change(entry, filter);
        rebuild(*entry);
        if (before || filtersView(entry.set))
            apply();
        return "";
    }

    //! The rules of the set from its filters; the rules that can't be
    //! applied to this log get their error as their problem, so it is found
    //! once, not each time the panel is shown
    private void rebuild(ref Entry entry) const
    {
        import std.algorithm.iteration : map;
        import std.array : array;

        entry.set.rules = entry.filters.map!((ref f) => toRule(f)).array;
        foreach (ref rule; entry.set.rules)
            rule.problem = ruleError(_format.columns, rule);
    }

    //! @returns true if the rule filters the view (or would, when `anyState`,
    //! were it switched on): an include or exclude rule that can be applied
    private static bool filters(ref const(FilterRule) rule, bool anyState = false)
    {
        return (anyState || rule.enabled) && rule.kind != RuleKind.Marker && rule.problem.length == 0;
    }

    //! @returns true if the set filters the view (or would, when `anyState`,
    //! were it switched on)
    private static bool filtersView(ref const(FilterSet) set, bool anyState = false)
    {
        import std.algorithm.searching : any;

        return (anyState || set.enabled) && set.rules.any!(r => filters(r));
    }

    //! Filters the view with the enabled rules
    private void apply()
    {
        const columns = _format is null ? null : _format.columns;
        _apply(RuleFilter.compile(columns, sets())); // null: no filter
    }
}

// ─── Tests ──────────────────────────────────────────────────────────────────

version (unittest)
{
    import formats.dlt.format : DltFormat;
    import formats.dlt.fields : beginDltRecord;
    import log_core.log_message : LogMessage;

    //! The filters of a DLT document whose view filter is kept in `applied`
    private final class Fixture
    {
        LogFilter!wchar applied;
        int applyCount;
        DocumentFilters filters;

        this(const(LogFormat) format = new DltFormat())
        {
            filters = new DocumentFilters(format, (f) { applied = f; ++applyCount; });
        }

        //! Whether a record of the app is shown by the applied filter
        bool shows(string appId)
        {
            LogMessage!wchar msg;
            msg.beginDltRecord("ECU1", appId, "CTX1");
            return applied is null || applied.matches(msg);
        }
    }

    //! A temporary .dlf of the <filter> bodies; remove(path) after use
    private string makeDlf(string name, string[] filters...)
    {
        import std.file : tempDir, write;
        import std.path : buildPath;

        string xml = "<dltfilter>";
        foreach (f; filters)
            xml ~= "<filter>" ~ f ~ "</filter>";
        const path = buildPath(tempDir(), name);
        write(path, xml ~ "</dltfilter>");
        return path;
    }

    //! The body of an enabled filter of the app
    private string appFilter(string appId, int type = 0)
    {
        import std.format : format;

        return format("<type>%s</type><name>%s</name><enablefilter>1</enablefilter>"
                ~ "<applicationid>%s</applicationid><enableapplicationid>1</enableapplicationid>",
                type, appId, appId);
    }
}

@("DocumentFilters: a loaded .dlf filters the view; sets are appended")
unittest
{
    import std.file : remove;

    const first = makeDlf("filters_first.dlf", appFilter("APP1"));
    const second = makeDlf("filters_second.dlf", appFilter("APP2"));
    scope (exit)
    {
        remove(first);
        remove(second);
    }

    auto fx = new Fixture();
    assert(fx.filters.addDlf(first) == "");
    assert(fx.shows("APP1") && !fx.shows("APP2"));
    assert(fx.filters.addDlf(second) == "");
    assert(fx.shows("APP1") && fx.shows("APP2") && !fx.shows("APP3"));
    assert(fx.filters.sets.length == 2);
    assert(fx.filters.sets[0].name == "filters_first.dlf" && fx.filters.sets[0].source == first);
}

@("DocumentFilters: a set loaded already, a missing file and a non-DLT log are refused")
unittest
{
    import formats.plain_text : PlainTextFormat;
    import std.algorithm.searching : canFind;
    import std.file : remove;

    const path = makeDlf("filters_twice.dlf", appFilter("APP1"));
    scope (exit)
        remove(path);

    auto fx = new Fixture();
    assert(fx.filters.addDlf(path) == "");
    assert(fx.filters.addDlf(path).canFind("already"));
    assert(fx.filters.addDlf("/nonexistent/filter.dlf").length);
    assert(fx.filters.sets.length == 1);

    auto text = new Fixture(new PlainTextFormat());
    assert(text.filters.addDlf(path).canFind("DLT"));
    assert(text.filters.newSet().canFind("DLT"));
    assert(text.filters.sets.length == 0 && text.applyCount == 0);
    assert(!text.filters.toJson()["canLoad"].boolean, "the panel doesn't offer it");
}

@("DocumentFilters: a set and a rule are switched off and on, a removed set stops filtering")
unittest
{
    import std.file : remove;

    const path = makeDlf("filters_toggle.dlf", appFilter("APP1"), appFilter("APP2"));
    scope (exit)
        remove(path);

    auto fx = new Fixture();
    assert(fx.filters.addDlf(path) == "");
    assert(fx.shows("APP1") && fx.shows("APP2") && !fx.shows("APP3"));

    assert(fx.filters.enableRule(0, 1, false) == "");
    assert(fx.shows("APP1") && !fx.shows("APP2"));
    assert(!fx.filters.sets[0].rules[1].enabled);

    assert(fx.filters.enableSet(0, false) == "");
    assert(fx.applied is null, "no enabled rule: no filter");
    assert(fx.filters.enableSet(0, true) == "");
    assert(fx.shows("APP1") && !fx.shows("APP2"), "the rule states are kept");

    assert(fx.filters.remove(0) == "");
    assert(fx.filters.sets.length == 0 && fx.applied is null);
    assert(fx.filters.remove(0).length, "no such set");
    assert(fx.filters.enableRule(5, 0, true).length);
}

@("DocumentFilters: switching a marker rule doesn't filter the view again")
unittest
{
    import std.file : remove;

    const path = makeDlf("filters_marker.dlf", appFilter("APP1", 2));
    scope (exit)
        remove(path);

    auto fx = new Fixture();
    assert(fx.filters.addDlf(path) == "");
    const count = fx.applyCount;
    assert(fx.filters.enableRule(0, 0, false) == "");
    assert(fx.applyCount == count);
}

@("DocumentFilters: a set of markers only is switched and removed without filtering again")
unittest
{
    import std.file : remove;

    const markers = makeDlf("filters_markers_only.dlf", appFilter("APP1", 2));
    scope (exit)
        remove(markers);

    auto fx = new Fixture();
    assert(fx.filters.addDlf(markers) == "");
    const count = fx.applyCount;
    assert(fx.filters.enableSet(0, false) == "" && fx.filters.enableSet(0, true) == "");
    assert(fx.filters.remove(0) == "");
    assert(fx.applyCount == count);
}

@("DocumentFilters: the sets are saved as copies and restored without their files")
unittest
{
    import std.file : remove;

    const first = makeDlf("filters_save_1.dlf", appFilter("APP1"), appFilter("APP2"));
    const second = makeDlf("filters_save_2.dlf", appFilter("APP3"));

    auto fx = new Fixture();
    assert(fx.filters.addDlf(first) == "" && fx.filters.addDlf(second) == "");
    assert(fx.filters.enableRule(0, 1, false) == "" && fx.filters.enableSet(1, false) == "");
    assert(fx.filters.addRule(0, `{"name": "Four", "appId": "APP4", "enableApp": true}`) == "");
    const saved = fx.filters.saved();
    assert(saved.length == 2 && saved[0].name == "filters_save_1.dlf" && saved[0].source == first);
    assert(saved[0].rules.length == 3 && !saved[0].rules[1].enabled && !saved[1].enabled);

    remove(first);
    remove(second); // a copy doesn't need them
    auto again = new Fixture();
    again.filters.restore(saved);
    assert(again.filters.saved() == saved);
    assert(again.shows("APP1") && !again.shows("APP2") && !again.shows("APP3") && again.shows("APP4"));
}

@("DocumentFilters: nothing is restored for a log .dlf don't apply to")
unittest
{
    import formats.plain_text : PlainTextFormat;

    auto fx = new Fixture(new PlainTextFormat());
    fx.filters.restore([SavedFilter("one.dlf")]);
    assert(fx.filters.sets.length == 0 && fx.applyCount == 0);
}

@("DocumentFilters: New Filter is an empty set without a file")
unittest
{
    auto fx = new Fixture();
    assert(fx.filters.newSet() == "");
    assert(fx.filters.sets.length == 1 && fx.filters.sets[0].name == "New Filter");
    assert(fx.filters.sets[0].source == "" && fx.filters.sets[0].rules.length == 0);
    assert(fx.applyCount == 0);
}

@("DocumentFilters: rules are added, edited and removed, and filter the view at once")
unittest
{
    import std.file : remove;

    const path = makeDlf("filters_edit.dlf", appFilter("APP1"));
    scope (exit)
        remove(path);

    auto fx = new Fixture();
    assert(fx.filters.addDlf(path) == "");

    auto rule = fx.filters.ruleJson(0, 0);
    assert(rule["name"].str == "APP1" && rule["appId"].str == "APP1");
    assert(rule["enableApp"].boolean && rule["type"].integer == 0);
    assert(fx.filters.ruleJson(0, 5).isNull, "no such rule");

    assert(fx.filters.addRule(0, `{"name": "Two", "appId": "APP2", "enableApp": true, "enabled": true}`) == "");
    assert(fx.filters.sets[0].rules.length == 2 && fx.filters.sets[0].rules[1].name == "Two");
    assert(fx.shows("APP1") && fx.shows("APP2") && !fx.shows("APP3"));

    assert(fx.filters.updateRule(0, 0, `{"name": "Three", "appId": "APP3", "enableApp": true, "enabled": true}`) == "");
    assert(fx.filters.sets[0].rules[0].name == "Three");
    assert(!fx.shows("APP1") && fx.shows("APP3"));

    assert(fx.filters.removeRule(0, 0) == "");
    assert(fx.filters.sets[0].rules.length == 1 && !fx.shows("APP3") && fx.shows("APP2"));
    assert(fx.filters.removeRule(0, 3).length && fx.filters.updateRule(2, 0, `{}`).length);
}

@("DocumentFilters: a new rule starts from the defaults of dlt-viewer, switched on")
unittest
{
    auto rule = DocumentFilters.newRuleJson();
    assert(rule["name"].str == "New Rule" && rule["enabled"].boolean);
    assert(rule["levelMax"].integer == 6 && rule["type"].integer == 0);
}

@("DocumentFilters: a rule that can't be applied is refused, nothing changes")
unittest
{
    import std.file : remove;

    const path = makeDlf("filters_bad_rule.dlf", appFilter("APP1"));
    scope (exit)
        remove(path);

    auto fx = new Fixture();
    assert(fx.filters.addDlf(path) == "");
    const count = fx.applyCount;
    assert(fx.filters.addRule(0, `{"payload": "(unclosed", "enablePayload": true, "regexPayload": true}`).length);
    assert(fx.filters.updateRule(0, 0, `not json`).length);
    assert(fx.filters.sets[0].rules.length == 1 && fx.filters.sets[0].rules[0].name == "APP1");
    assert(fx.applyCount == count);

    // The header text isn't applied yet, but it is a valid rule of dlt-viewer
    assert(fx.filters.addRule(0, `{"header": "x", "enableHeader": true}`) == "");
    assert(fx.filters.sets[0].rules[1].problem.length);
}

@("DocumentFilters: a rule switched off is taken with its error, to be fixed later")
unittest
{
    import std.file : remove;

    const path = makeDlf("filters_broken.dlf", appFilter("APP1")
            ~ "<payloadtext>(unclosed</payloadtext><enablepayloadtext>1</enablepayloadtext>"
            ~ "<enableregexp_Payload>1</enableregexp_Payload>");
    scope (exit)
        remove(path);

    auto fx = new Fixture();
    assert(fx.filters.addDlf(path) == "");
    assert(fx.filters.sets[0].rules[0].problem.length, "loaded with its error");

    auto broken = fx.filters.ruleJson(0, 0);
    broken["name"] = "Renamed";
    assert(fx.filters.updateRule(0, 0, broken.toString()).length, "still on: refused");
    broken["enabled"] = false;
    assert(fx.filters.updateRule(0, 0, broken.toString()) == "");
    assert(fx.filters.sets[0].rules[0].name == "Renamed" && fx.filters.sets[0].rules[0].problem.length);
    assert(fx.filters.addRule(0, broken.toString()) == "", "a new one too");
}

@("DocumentFilters: a set is exported to a .dlf with its switches and named after it")
unittest
{
    import formats.dlt.dlf : readDlf;
    import std.file : exists, remove, tempDir;
    import std.path : buildPath;

    const path = buildPath(tempDir(), "filters_export.dlf");
    scope (exit)
        if (exists(path))
            remove(path);

    auto fx = new Fixture();
    assert(fx.filters.newSet() == "");
    assert(fx.filters.addRule(0, `{"name": "One", "appId": "APP1", "enableApp": true}`) == "");
    assert(fx.filters.addRule(0, `{"name": "Two", "appId": "APP2", "enableApp": true}`) == "");
    assert(fx.filters.enableRule(0, 0, false) == "");

    assert(fx.filters.exportSet(0, path) == "");
    const filters = readDlf(path);
    assert(filters.length == 2 && filters[1].name == "Two" && filters[1].appId == "APP2");
    assert(!filters[0].enabled, "the switch of the panel");
    assert(fx.filters.sets[0].name == "filters_export.dlf" && fx.filters.sets[0].source == path);

    assert(fx.filters.enableSet(0, false) == "");
    assert(fx.filters.exportSet(0, path) == "");
    assert(!readDlf(path)[1].enabled, "a set switched off is exported off: what filters is written");
    assert(fx.filters.sets[0].rules[1].enabled, "the switches of its rules are kept");

    assert(fx.filters.exportSet(0, "/nonexistent/dir/x.dlf").length);
    assert(fx.filters.exportSet(3, path).length);
}

@("DocumentFilters: the panel state of the sets and their rules")
unittest
{
    import std.file : remove;

    const path = makeDlf("filters_json.dlf", appFilter("APP1", 1),
        "<type>2</type><name>Header</name><enableheadertext>1</enableheadertext>");
    scope (exit)
        remove(path);

    auto fx = new Fixture();
    assert(fx.filters.addDlf(path) == "");
    auto json = fx.filters.toJson();
    assert(json["canLoad"].boolean);
    assert(json["sets"].array.length == 1);
    auto set = json["sets"][0];
    assert(set["name"].str == "filters_json.dlf" && set["source"].str == path);
    assert(set["enabled"].boolean);
    assert(set["rules"].array.length == 2);
    assert(set["rules"][0]["name"].str == "APP1" && set["rules"][0]["kind"].str == "exclude");
    assert(set["rules"][0]["enabled"].boolean && set["rules"][0]["error"].str == "");
    assert(set["rules"][1]["kind"].str == "marker" && set["rules"][1]["error"].str.length);
}
