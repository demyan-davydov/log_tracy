module ui.filter_commands;

//! The filters of the main view of a document, apart from the window so they
//! can be tested: the filter sets loaded for it (appended one file at a time),
//! the commands that change them and their state for the filter panel.
//! Each command returns an error message for the user, "" on success.

import log_core.log_filter : LogFilter;
import log_core.log_format : LogFormat;
import log_core.rule_filter;
import ui.app_settings : SavedFilter;

import std.json : JSONValue;

final class DocumentFilters
{
    private const(LogFormat) _format;
    private void delegate(LogFilter!wchar) _apply;
    private FilterSet[] _sets;
    private bool[][string] _unreadRules; // by path: the switches of the sets that couldn't be read

    //! @param apply - filters the main view of the document (null: no filter)
    this(const(LogFormat) format, void delegate(LogFilter!wchar) apply)
    {
        _format = format;
        _apply = apply;
    }

    const(FilterSet)[] sets() const
    {
        return _sets;
    }

    //! @brief Appends the rules of a .dlf and filters the view with them. A
    //! set whose file couldn't be read is read again in its place, with the
    //! switches it kept.
    string addDlf(string path)
    {
        import formats.dlt.dlf : canLoadDlf;
        import std.algorithm.searching : countUntil;
        import std.path : baseName;

        if (!canLoadDlf(_format))
            return "DLT filters (.dlf) apply to DLT logs only";
        const index = _sets.countUntil!(s => s.path == path);
        if (index >= 0 && _sets[index].problem.length == 0)
            return baseName(path) ~ " is loaded already";
        try
        {
            if (index >= 0) // its file is back
            {
                _sets[index] = read(path, _sets[index].enabled, _unreadRules.get(path, null));
                _unreadRules.remove(path);
            }
            else
                _sets ~= read(path, true, null);
        }
        catch (Exception e)
            return "Can't load the filter: " ~ e.msg;
        if (filtersView(_sets[index >= 0 ? index : $ - 1]))
            apply();
        return "";
    }

    //! The sets as they are saved for the log: their files and switches
    SavedFilter[] saved() const
    {
        import std.algorithm.iteration : map;
        import std.array : array;

        SavedFilter[] result;
        foreach (ref set; _sets)
        {
            if (auto kept = set.path in _unreadRules)
                result ~= SavedFilter(set.path, set.enabled, (*kept).dup);
            else
                result ~= SavedFilter(set.path, set.enabled, set.rules.map!(r => cast(bool) r.enabled).array);
        }
        return result;
    }

    //! @brief Loads the sets saved for the log again, with their switches,
    //! and filters the view with them. A file that can't be read stays listed
    //! with its problem and keeps its switches; a file whose rules changed
    //! keeps the switches it has. Does nothing for a log .dlf don't apply to.
    void restore(const(SavedFilter)[] filters)
    {
        import formats.dlt.dlf : canLoadDlf;
        import std.algorithm.searching : canFind;
        import std.file : exists;
        import std.path : baseName;

        if (!canLoadDlf(_format))
            return;
        bool changed;
        foreach (ref saved; filters)
        {
            if (_sets.canFind!(s => s.path == saved.path))
                continue;
            FilterSet set;
            try
                set = read(saved.path, saved.enabled, saved.rules);
            catch (Exception e)
            {
                set.name = baseName(saved.path);
                set.path = saved.path;
                set.enabled = saved.enabled;
                set.problem = exists(saved.path) ? "Can't load: " ~ e.msg : "File not found";
                _unreadRules[saved.path] = saved.rules.dup;
            }
            changed |= filtersView(set);
            _sets ~= set;
        }
        if (changed)
            apply();
    }

    //! @brief Unloads a set
    string remove(size_t set)
    {
        import std.algorithm.mutation : remove;

        if (set >= _sets.length)
            return noSuchSet;
        const changed = filtersView(_sets[set]);
        _unreadRules.remove(_sets[set].path);
        _sets = _sets.remove(set);
        if (changed)
            apply();
        return "";
    }

    //! @brief Switches a whole set on or off
    string enableSet(size_t set, bool enabled)
    {
        if (set >= _sets.length)
            return noSuchSet;
        _sets[set].enabled = enabled;
        if (filtersView(_sets[set], true))
            apply();
        return "";
    }

    //! @brief Switches one rule of a set on or off
    string enableRule(size_t set, size_t rule, bool enabled)
    {
        if (set >= _sets.length || rule >= _sets[set].rules.length)
            return noSuchSet;
        auto target = &_sets[set].rules[rule];
        target.enabled = enabled;
        if (_sets[set].enabled && filters(*target, true)) // markers don't change what is shown
            apply();
        return "";
    }

    //! The state of the filter panel: {canLoad, sets: [{name, path, enabled,
    //! error, rules: [{name, kind, enabled, color, error}]}]}. canLoad tells
    //! whether a .dlf can be loaded for this log; kind is "include", "exclude"
    //! or "marker"; error says why a set or a rule isn't applied, "" if it is.
    JSONValue toJson() const
    {
        static immutable string[] kinds = ["include", "exclude", "marker"];

        JSONValue[] sets;
        foreach (ref set; _sets)
        {
            JSONValue[] rules;
            foreach (ref rule; set.rules)
                rules ~= JSONValue([
                    "name": JSONValue(rule.name),
                    "kind": JSONValue(kinds[rule.kind]),
                    "enabled": JSONValue(rule.enabled),
                    "color": JSONValue(rule.color),
                    "error": JSONValue(rule.problem), // see read()
                ]);
            sets ~= JSONValue([
                "name": JSONValue(set.name),
                "path": JSONValue(set.path),
                "enabled": JSONValue(set.enabled),
                "error": JSONValue(set.problem),
                "rules": JSONValue(rules),
            ]);
        }
        import formats.dlt.dlf : canLoadDlf;

        return JSONValue(["canLoad": JSONValue(canLoadDlf(_format)), "sets": JSONValue(sets)]);
    }

    private enum noSuchSet = "no such filter";

    //! @brief Reads a .dlf as a set with the given switches; the rules that
    //! can't be applied to this log get their error as their problem, so it
    //! is found once, not each time the panel is shown
    //! @param rules - the switch of each rule; those of the file if the count differs
    //! @throws Exception if the file can't be read
    private FilterSet read(string path, bool enabled, const(bool)[] rules)
    {
        import formats.dlt.dlf : loadDlf;

        auto set = loadDlf(path);
        set.enabled = enabled;
        if (rules.length == set.rules.length)
            foreach (i, ref rule; set.rules)
                rule.enabled = rules[i];
        foreach (ref rule; set.rules)
            rule.problem = ruleError(_format.columns, rule);
        return set;
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
        _apply(RuleFilter.compile(columns, _sets)); // null: no filter
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
    private string writeDlf(string name, string[] filters...)
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

    const first = writeDlf("filters_first.dlf", appFilter("APP1"));
    const second = writeDlf("filters_second.dlf", appFilter("APP2"));
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
    assert(fx.filters.sets[0].name == "filters_first.dlf");
}

@("DocumentFilters: a set loaded already, a missing file and a non-DLT log are refused")
unittest
{
    import formats.plain_text : PlainTextFormat;
    import std.algorithm.searching : canFind;
    import std.file : remove;

    const path = writeDlf("filters_twice.dlf", appFilter("APP1"));
    scope (exit)
        remove(path);

    auto fx = new Fixture();
    assert(fx.filters.addDlf(path) == "");
    assert(fx.filters.addDlf(path).canFind("already"));
    assert(fx.filters.addDlf("/nonexistent/filter.dlf").length);
    assert(fx.filters.sets.length == 1);

    auto text = new Fixture(new PlainTextFormat());
    assert(text.filters.addDlf(path).canFind("DLT"));
    assert(text.filters.sets.length == 0 && text.applyCount == 0);
    assert(!text.filters.toJson()["canLoad"].boolean, "the panel doesn't offer it");
}

@("DocumentFilters: a set and a rule are switched off and on, a removed set stops filtering")
unittest
{
    import std.file : remove;

    const path = writeDlf("filters_toggle.dlf", appFilter("APP1"), appFilter("APP2"));
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

    const path = writeDlf("filters_marker.dlf", appFilter("APP1", 2));
    scope (exit)
        remove(path);

    auto fx = new Fixture();
    assert(fx.filters.addDlf(path) == "");
    const count = fx.applyCount;
    assert(fx.filters.enableRule(0, 0, false) == "");
    assert(fx.applyCount == count);
}

@("DocumentFilters: the sets are saved with their switches and restored")
unittest
{
    import std.file : remove;

    const first = writeDlf("filters_save_1.dlf", appFilter("APP1"), appFilter("APP2"));
    const second = writeDlf("filters_save_2.dlf", appFilter("APP3"));
    scope (exit)
    {
        remove(first);
        remove(second);
    }

    auto fx = new Fixture();
    assert(fx.filters.addDlf(first) == "" && fx.filters.addDlf(second) == "");
    assert(fx.filters.enableRule(0, 1, false) == "" && fx.filters.enableSet(1, false) == "");
    const saved = fx.filters.saved();
    assert(saved == [SavedFilter(first, true, [true, false]), SavedFilter(second, false, [true])]);

    auto again = new Fixture();
    again.filters.restore(saved);
    assert(again.filters.saved() == saved);
    assert(again.shows("APP1") && !again.shows("APP2") && !again.shows("APP3"));
}

@("DocumentFilters: a saved file that is gone stays listed with its switches")
unittest
{
    auto fx = new Fixture();
    const saved = [SavedFilter("/nonexistent/gone.dlf", false, [true, false])];
    fx.filters.restore(saved);
    assert(fx.filters.sets.length == 1);
    assert(fx.filters.sets[0].name == "gone.dlf" && fx.filters.sets[0].problem.length);
    assert(fx.filters.saved() == saved, "kept as it was saved");
    assert(fx.filters.toJson()["sets"][0]["error"].str.length);
    assert(fx.applyCount == 0, "nothing to filter with");
    assert(fx.filters.remove(0) == "" && fx.filters.saved().length == 0);
}

@("DocumentFilters: a file that comes back is loaded in place of its entry, with its switches")
unittest
{
    import std.file : remove, tempDir;
    import std.path : buildPath;

    const path = buildPath(tempDir(), "filters_back.dlf");
    auto fx = new Fixture();
    fx.filters.restore([SavedFilter(path, true, [true, false])]);
    assert(fx.filters.sets[0].problem.length, "not there yet");

    writeDlf("filters_back.dlf", appFilter("APP1"), appFilter("APP2"));
    scope (exit)
        remove(path);
    assert(fx.filters.addDlf(path) == "");
    assert(fx.filters.sets.length == 1 && fx.filters.sets[0].problem == "");
    assert(fx.filters.saved() == [SavedFilter(path, true, [true, false])]);
    assert(fx.shows("APP1") && !fx.shows("APP2"));
}

@("DocumentFilters: a set of markers only is switched and removed without filtering again")
unittest
{
    import std.file : remove;

    const markers = writeDlf("filters_markers_only.dlf", appFilter("APP1", 2));
    scope (exit)
        remove(markers);

    auto fx = new Fixture();
    assert(fx.filters.addDlf(markers) == "");
    const count = fx.applyCount;
    assert(fx.filters.enableSet(0, false) == "" && fx.filters.enableSet(0, true) == "");
    assert(fx.filters.remove(0) == "");
    assert(fx.applyCount == count);
}

@("DocumentFilters: a file whose rules changed keeps the switches of the file")
unittest
{
    import std.file : remove;

    const path = writeDlf("filters_changed.dlf", appFilter("APP1"), appFilter("APP2"));
    scope (exit)
        remove(path);

    auto fx = new Fixture();
    fx.filters.restore([SavedFilter(path, true, [false])]);
    assert(fx.filters.saved() == [SavedFilter(path, true, [true, true])]);
    assert(fx.shows("APP1") && fx.shows("APP2"));
}

@("DocumentFilters: nothing is restored for a log .dlf don't apply to")
unittest
{
    import formats.plain_text : PlainTextFormat;

    auto fx = new Fixture(new PlainTextFormat());
    fx.filters.restore([SavedFilter("/f/one.dlf")]);
    assert(fx.filters.sets.length == 0 && fx.applyCount == 0);
}

@("DocumentFilters: the panel state of the sets and their rules")
unittest
{
    import std.file : remove;

    const path = writeDlf("filters_json.dlf", appFilter("APP1", 1),
        "<type>2</type><name>Header</name><enableheadertext>1</enableheadertext>");
    scope (exit)
        remove(path);

    auto fx = new Fixture();
    assert(fx.filters.addDlf(path) == "");
    auto json = fx.filters.toJson();
    assert(json["canLoad"].boolean);
    assert(json["sets"].array.length == 1);
    auto set = json["sets"][0];
    assert(set["name"].str == "filters_json.dlf" && set["path"].str == path);
    assert(set["enabled"].boolean && set["error"].str == "");
    assert(set["rules"].array.length == 2);
    assert(set["rules"][0]["name"].str == "APP1" && set["rules"][0]["kind"].str == "exclude");
    assert(set["rules"][0]["enabled"].boolean && set["rules"][0]["error"].str == "");
    assert(set["rules"][1]["kind"].str == "marker" && set["rules"][1]["error"].str.length);
}
