module ui.filter_commands;

//! The filters of the main view of a document, apart from the window so they
//! can be tested: the filter sets of the log, the commands that change them
//! and their state for the filter panel. A set is a copy: a loaded file (a
//! filter file of DLT Explorer, or a .dlf of dlt-viewer for a DLT log) is
//! copied, edited in place, remembered in the settings of the log and can be
//! exported to either kind of file; no file is referred to, so a file loaded
//! for two logs doesn't tie them together.
//! Each command returns a message for the user: an error, or what was lost or
//! may not fit when it was done; "" when there is nothing to say.

import formats.dlt.dlf : canLoadDlf, fromDlf, readDlf, toDlf, writeDlf;
import log_core.filter_file;
import log_core.log_filter : LogFilter;
import log_core.log_format : LogFormat;
import log_core.log_message : LogMessage;
import log_core.rule_filter;
import ui.app_settings : copyOf, SavedFilter;

import std.json : JSONValue;

final class DocumentFilters
{
    private const(LogFormat) _format;
    private string _formatId; // FormatInfo.id of the log, written to the filter files
    private void delegate(LogFilter!wchar) _apply;
    private FilterSet[] _sets; // the problems of their rules are set by check()
    private RuleMatcher _matcher; // compiled from _sets by rematch(); null: no rules
    private RuleIdGenerator _ruleIds; // the rules get their ids when they come in

    //! @param formatId - FormatInfo.id of the format of the log
    //! @param apply - filters the main view of the document (null: no filter)
    this(const(LogFormat) format, string formatId, void delegate(LogFilter!wchar) apply)
    {
        _format = format;
        _formatId = formatId;
        _apply = apply;
    }

    const(FilterSet)[] sets() const
    {
        return _sets;
    }

    //! @returns the id of the first rule the record matches (see
    //! RuleMatcher), an invalid one if none
    RuleId ruleOf(scope ref const(LogMessage!wchar) item) const
    {
        return _matcher is null ? RuleId.init : _matcher.firstMatch(item);
    }

    //! @returns true if the log has columns to filter by
    bool canFilter() const
    {
        return _format !is null && _format.columns.length > 0;
    }

    //! @brief Appends a copy of the rules of a file and filters the view with
    //! them: a .dlf (DLT logs only) or a filter file of DLT Explorer (any log;
    //! one made for another format is taken, with a note)
    string loadFile(string path)
    {
        import std.algorithm.searching : canFind;
        import std.file : readText;
        import std.path : baseName;

        if (!canFilter())
            return noColumns;
        if (_sets.canFind!((ref s) => s.source == path))
            return baseName(path) ~ " is loaded already: remove it to load it again";
        FilterSet set;
        string[] notes;
        try
        {
            if (isDlf(path))
            {
                if (!canLoadDlf(_format))
                    return "DLT filters (.dlf) apply to DLT logs only";
                set.name = baseName(path);
                set.rules = fromDlf(readDlf(path), notes);
            }
            else
            {
                auto file = parseFilterFile(readText(path));
                set = file.set;
                if (set.name.length == 0)
                    set.name = baseName(path);
                if (file.logFormat.length && file.logFormat != _formatId)
                    notes ~= "made for " ~ file.logFormat ~ " logs: the rules on columns this log"
                        ~ " doesn't have aren't applied";
            }
        }
        catch (Exception e)
            return "Can't load the filter: " ~ e.msg;
        set.source = path;
        check(set);
        identify(set);
        _sets ~= set;
        rematch();
        if (filtersView(set))
            apply();
        return noteOf(baseName(path), notes);
    }

    //! @brief Appends an empty set, to add rules to
    string newSet()
    {
        if (!canFilter())
            return noColumns;
        FilterSet set;
        set.name = "New Filter";
        _sets ~= set;
        return "";
    }

    //! @brief Writes a set to a file, with the switches of its rules (all off
    //! if the set is): a .dlf (DLT logs only; what it can't hold is dropped
    //! and named) or a filter file of DLT Explorer. The set remembers the file.
    string exportSet(size_t set, string path)
    {
        import std.file : write;
        import std.path : baseName;

        if (set >= _sets.length)
            return noSuchSet;
        // What filters is written: the rules of a set switched off are off
        auto written = cast(FilterSet) _sets[set];
        written.rules = copyOf(_sets[set].rules);
        if (!written.enabled)
            foreach (ref rule; written.rules)
                rule.enabled = false;
        string[] notes;
        try
        {
            if (isDlf(path))
            {
                if (!canLoadDlf(_format))
                    return "DLT filters (.dlf) are for DLT logs only";
                writeDlf(path, toDlf(written.rules, notes));
                _sets[set].name = baseName(path); // a .dlf has no name of its own
            }
            else
                write(path, filterFileJson(written, _formatId));
        }
        catch (Exception e)
            return "Can't export the filter: " ~ e.msg;
        _sets[set].source = path;
        return noteOf(baseName(path), notes);
    }

    //! The sets as they are saved for the log: copies of their rules, without
    //! their ids (a rule gets a new one when it is restored)
    SavedFilter[] saved() const
    {
        SavedFilter[] result;
        foreach (ref s; _sets)
        {
            auto rules = copyOf(s.rules);
            foreach (ref rule; rules)
                rule.id = RuleId.init;
            result ~= SavedFilter(s.name, s.source, s.enabled, rules);
        }
        return result;
    }

    //! @brief Takes the sets saved for the log and filters the view with them
    void restore(const(SavedFilter)[] filters)
    {
        if (!canFilter())
            return;
        bool changed;
        foreach (ref saved; filters)
        {
            FilterSet set;
            set.name = saved.name;
            set.source = saved.source;
            set.enabled = saved.enabled;
            set.rules = copyOf(saved.rules);
            check(set);
            identify(set);
            changed |= filtersView(set);
            _sets ~= set;
        }
        rematch();
        if (changed)
            apply();
    }

    //! @brief Removes a set
    string remove(size_t set)
    {
        import std.algorithm.mutation : remove;

        if (set >= _sets.length)
            return noSuchSet;
        const changed = filtersView(_sets[set]);
        _sets = _sets.remove(set);
        rematch();
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
        rematch();
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
        rematch();
        if (_sets[set].enabled && filters(*target, true)) // markers don't change what is shown
            apply();
        return "";
    }

    //! A new rule for the editor, as ruleJson gives a rule
    static JSONValue newRuleJson()
    {
        FilterRule rule;
        rule.name = "New Rule";
        return rulesToJson([rule])[0];
    }

    //! A rule for the editor, as a filter file has it; null if there is no such rule
    JSONValue ruleJson(size_t set, size_t rule) const
    {
        if (set >= _sets.length || rule >= _sets[set].rules.length)
            return JSONValue(null);
        return rulesToJson(_sets[set].rules[rule .. rule + 1])[0];
    }

    //! @brief Appends a rule (as a filter file has it) to a set
    string addRule(size_t set, string json)
    {
        if (set >= _sets.length)
            return noSuchSet;
        return edit(set, json, (s, rule) { rule.id = _ruleIds.popId(); s.rules ~= rule; });
    }

    //! @brief Replaces a rule of a set, as addRule takes it
    string updateRule(size_t set, size_t rule, string json)
    {
        if (set >= _sets.length || rule >= _sets[set].rules.length)
            return noSuchSet;
        return edit(set, json, (s, r) { r.id = s.rules[rule].id; s.rules[rule] = r; });
    }

    //! @brief Checks a rule for the editor, as addRule takes it
    //! @returns {error, conditions: [what is wrong with each condition, "" if
    //! nothing], missing: [whether its column is one the log doesn't have]};
    //! error says why the rule can't be read at all, "" if it can. A
    //! condition on a missing column isn't a mistake: the rule isn't applied
    //! to this log, as when it is loaded.
    JSONValue checkRule(string json) const
    {
        import std.json : parseJSON;

        const columns = _format is null ? null : _format.columns;
        FilterRule rule;
        try
            rule = ruleFromJson(parseJSON(json));
        catch (Exception e)
            return JSONValue(["error": JSONValue("Invalid rule: " ~ e.msg),
                "conditions": JSONValue.emptyArray, "missing": JSONValue.emptyArray]);
        bool[] missing;
        foreach (ref c; rule.conditions)
            missing ~= !hasColumn(c.columnId);
        return JSONValue([
            "error": JSONValue(""),
            "conditions": JSONValue(conditionErrors(columns, rule)),
            "missing": JSONValue(missing),
        ]);
    }

    //! @brief Removes a rule of a set
    string removeRule(size_t set, size_t rule)
    {
        import std.algorithm.mutation : remove;

        if (set >= _sets.length || rule >= _sets[set].rules.length)
            return noSuchSet;
        const changed = _sets[set].enabled && filters(_sets[set].rules[rule]);
        _sets[set].rules = _sets[set].rules.remove(rule);
        rematch();
        if (changed)
            apply();
        return "";
    }

    //! The state of the filter panel: {canFilter, canDlf, sets: [{name,
    //! source, fileName, enabled, rules: [{name, kind, enabled, color,
    //! error, id}]}]}. canFilter tells whether the log has columns to filter by,
    //! canDlf whether .dlf files apply to it; fileName is the file to offer
    //! on export: the source, or <name>.<format>.logfilter; kind is
    //! "include", "exclude" or "marker"; error says why a rule isn't
    //! applied, "" if it is.
    JSONValue toJson() const
    {
        JSONValue[] sets;
        foreach (ref s; _sets)
        {
            JSONValue[] rules;
            foreach (ref rule; s.rules)
                rules ~= JSONValue([
                    "name": JSONValue(rule.name),
                    "kind": JSONValue(kindWords[rule.kind]), // as in a filter file
                    "enabled": JSONValue(rule.enabled),
                    // Only a color the rows take (see RuleMatcher): the script uses it as it is
                    "color": JSONValue(isRuleColor(rule.color) ? rule.color : ""),
                    "error": JSONValue(rule.problem), // see check()
                    "id": JSONValue(cast(long) rule.id.toInt()), // a row refers to the rule it matches by it
                ]);
            sets ~= JSONValue([
                "name": JSONValue(s.name),
                "source": JSONValue(s.source),
                "fileName": JSONValue(s.source.length ? s.source : filterFileName(s.name, _formatId)),
                "enabled": JSONValue(s.enabled),
                "rules": JSONValue(rules),
            ]);
        }
        return JSONValue([
            "canFilter": JSONValue(canFilter()),
            "canDlf": JSONValue(canLoadDlf(_format)),
            "sets": JSONValue(sets),
        ]);
    }

    private enum noSuchSet = "no such filter";
    private enum noColumns = "this log has no columns to filter by";

    private static bool isDlf(string path)
    {
        import std.path : extension;
        import std.uni : icmp;

        return icmp(extension(path), ".dlf") == 0;
    }

    //! The notes of a command on a file, one per line, "" if there are none
    private static string noteOf(string file, const(string)[] notes)
    {
        import std.array : join;

        return notes.length ? file ~ ": " ~ notes.join("\n") : "";
    }

    //! @brief Changes the rules of a set by a rule parsed from `json`. A rule
    //! switched on must have no mistake in a condition on a column of the log;
    //! one switched off is taken with its errors, as a loaded one is, so it
    //! can be renamed or switched off before it is fixed. A condition on a
    //! column the log doesn't have only keeps the rule from being applied.
    private string edit(size_t set, string json, scope void delegate(FilterSet*, FilterRule) change)
    {
        import std.json : parseJSON;

        FilterRule rule;
        try
            rule = ruleFromJson(parseJSON(json));
        catch (Exception e)
            return "Invalid rule: " ~ e.msg;
        rule.problem = ruleError(_format.columns, rule);
        // A mistake in a condition on a column of the log is refused; one on a
        // column the log doesn't have only keeps the rule from being applied
        if (rule.enabled)
            foreach (i, error; conditionErrors(_format.columns, rule))
                if (error.length && hasColumn(rule.conditions[i].columnId))
                    return error;

        auto target = &_sets[set];
        const before = filtersView(*target);
        change(target, rule);
        rematch();
        if (before || filtersView(*target))
            apply();
        return "";
    }

    //! @returns true if the log has the column
    private bool hasColumn(string id) const
    {
        import std.algorithm.searching : canFind;

        return _format !is null && _format.columns.canFind!(c => c.id == id);
    }

    //! The rules that can't be applied to this log get their error as their
    //! problem, so it is found once, not each time the panel is shown
    private void check(ref FilterSet set) const
    {
        foreach (ref rule; set.rules)
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

    //! Gives the rules of a set that comes in their ids
    private void identify(ref FilterSet set)
    {
        foreach (ref rule; set.rules)
            rule.id = _ruleIds.popId();
    }

    //! Compiles the matcher of the records from the rules, after a change of them
    private void rematch()
    {
        _matcher = RuleMatcher.compile(_format is null ? null : _format.columns, _sets);
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

    //! The filters of a DLT document whose view filter is kept in `applied`
    private final class Fixture
    {
        LogFilter!wchar applied;
        int applyCount;
        DocumentFilters filters;

        this(const(LogFormat) format = new DltFormat(), string formatId = "dlt")
        {
            filters = new DocumentFilters(format, formatId, (f) { applied = f; ++applyCount; });
        }

        //! The first rule a record of the app matches
        RuleId ruleOf(string appId)
        {
            LogMessage!wchar msg;
            msg.beginDltRecord("ECU1", appId, "CTX1");
            return filters.ruleOf(msg);
        }

        //! The id of a rule
        RuleId idOf(size_t set, size_t rule)
        {
            return filters.sets[set].rules[rule].id;
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

    //! A temporary filter file of DLT Explorer; remove(path) after use
    private string makeLogfilter(string name, string content)
    {
        import std.file : tempDir, write;
        import std.path : buildPath;

        const path = buildPath(tempDir(), name);
        write(path, content);
        return path;
    }

    //! A rule of the app, as a filter file and the editor have it
    private string appRule(string name, string appId, bool enabled = true)
    {
        import std.format : format;

        return format(`{"name": "%s", "enabled": %s, "conditions": [{"column": "app", "check": "equals", "value": "%s"}]}`,
            name, enabled, appId);
    }

    //! appRule with a color
    private string coloredAppRule(string name, string appId)
    {
        return appRule(name, appId)[0 .. $ - 1] ~ `, "color": "#00ff00"}`;
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
    assert(fx.filters.loadFile(first) == "");
    assert(fx.shows("APP1") && !fx.shows("APP2"));
    assert(fx.filters.loadFile(second) == "");
    assert(fx.shows("APP1") && fx.shows("APP2") && !fx.shows("APP3"));
    assert(fx.filters.sets.length == 2);
    assert(fx.filters.sets[0].name == "filters_first.dlf" && fx.filters.sets[0].source == first);
}

@("DocumentFilters: a filter file of DLT Explorer is loaded for any log, one of another format with a note")
unittest
{
    import formats.logcat : LogcatFormat;
    import std.algorithm.searching : canFind;
    import std.file : remove;

    const path = makeLogfilter("filters_native.dlt.logfilter", `{"type": "dlt-explorer-filter", "version": 1,
        "logFormat": "dlt", "name": "Apps", "rules": [` ~ appRule("One", "APP1") ~ `]}`);
    scope (exit)
        remove(path);

    auto fx = new Fixture();
    assert(fx.filters.loadFile(path) == "");
    assert(fx.filters.sets[0].name == "Apps" && fx.filters.sets[0].source == path);
    assert(fx.shows("APP1") && !fx.shows("APP2"));

    auto logcat = new Fixture(new LogcatFormat(LogcatFormat.Variant.Threadtime), "logcat");
    const note = logcat.filters.loadFile(path);
    assert(note.canFind("made for dlt"), note);
    assert(logcat.filters.sets.length == 1 && logcat.filters.sets[0].rules[0].problem.length,
        "logcat has no app column: not applied");
}

@("DocumentFilters: a set loaded already, a broken file, a .dlf for another log are refused")
unittest
{
    import formats.logcat : LogcatFormat;
    import std.algorithm.searching : canFind;
    import std.file : remove;

    const path = makeDlf("filters_twice.dlf", appFilter("APP1"));
    const broken = makeLogfilter("filters_broken.logfilter", "{");
    scope (exit)
    {
        remove(path);
        remove(broken);
    }

    auto fx = new Fixture();
    assert(fx.filters.loadFile(path) == "");
    assert(fx.filters.loadFile(path).canFind("already"));
    assert(fx.filters.loadFile("/nonexistent/filter.dlf").length);
    assert(fx.filters.loadFile(broken).canFind("Can't load"));
    assert(fx.filters.sets.length == 1);

    auto logcat = new Fixture(new LogcatFormat(LogcatFormat.Variant.Threadtime), "logcat");
    assert(logcat.filters.loadFile(path).canFind("DLT"));
    assert(logcat.filters.sets.length == 0 && logcat.applyCount == 0);
    assert(logcat.filters.toJson()["canFilter"].boolean && !logcat.filters.toJson()["canDlf"].boolean);
}

@("DocumentFilters: a set and a rule are switched off and on, a removed set stops filtering")
unittest
{
    import std.file : remove;

    const path = makeDlf("filters_toggle.dlf", appFilter("APP1"), appFilter("APP2"));
    scope (exit)
        remove(path);

    auto fx = new Fixture();
    assert(fx.filters.loadFile(path) == "");
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

@("DocumentFilters: switching a marker rule, or a set of markers only, doesn't filter the view again")
unittest
{
    import std.file : remove;

    const path = makeDlf("filters_marker.dlf", appFilter("APP1", 2));
    scope (exit)
        remove(path);

    auto fx = new Fixture();
    assert(fx.filters.loadFile(path) == "");
    const count = fx.applyCount;
    assert(fx.filters.enableRule(0, 0, false) == "");
    assert(fx.filters.enableSet(0, false) == "" && fx.filters.enableSet(0, true) == "");
    assert(fx.filters.remove(0) == "");
    assert(fx.applyCount == count);
}

@("DocumentFilters: every rule that comes in gets a new id; an edited rule keeps its own")
unittest
{
    import std.file : remove;

    const path = makeDlf("filters_ids.dlf", appFilter("APP1"), appFilter("APP2"));
    scope (exit)
        remove(path);

    auto fx = new Fixture();
    assert(fx.filters.loadFile(path) == "" && fx.filters.newSet() == "");
    assert(fx.filters.addRule(1, appRule("Three", "APP3")) == "");
    const ids = [fx.idOf(0, 0), fx.idOf(0, 1), fx.idOf(1, 0)];
    foreach (i, id; ids)
    {
        assert(id.isValid());
        foreach (other; ids[0 .. i])
            assert(id != other, "unique among the sets");
    }
    assert(fx.filters.updateRule(1, 0, appRule("Four", "APP4")) == "");
    assert(fx.idOf(1, 0) == ids[2], "the same rule, edited");

    auto restored = new Fixture();
    restored.filters.restore(fx.filters.saved());
    assert(restored.idOf(0, 0).isValid() && restored.idOf(0, 0) != restored.idOf(0, 1));

    const json = fx.filters.toJson()["sets"][0]["rules"][1];
    assert(json["id"].integer == ids[1].toInt(), "the panel knows the ids");
}

@("DocumentFilters: the panel gets the colors that color the rows, #rrggbb only")
unittest
{
    auto fx = new Fixture();
    assert(fx.filters.newSet() == "");
    assert(fx.filters.addRule(0, appRule("Green", "APP1")[0 .. $ - 1] ~ `, "color": "#00ff00"}`) == "");
    assert(fx.filters.addRule(0, appRule("Red", "APP2")[0 .. $ - 1] ~ `, "color": "red"}`) == "");
    const rules = fx.filters.toJson()["sets"][0]["rules"];
    assert(rules[0]["color"].str == "#00ff00");
    assert(rules[1]["color"].str == "", "a color the rows can't take: none");
}

@("DocumentFilters: a record refers to the first rule with a color it matches, after every change of the rules")
unittest
{
    import std.file : remove;

    enum red = "<filterColour>#ff0000</filterColour>";
    const path = makeDlf("filters_match.dlf", appFilter("APP1", 2) ~ red, // a marker colors
        appFilter("APP2") ~ "<enableMarker>1</enableMarker>" ~ red, appFilter("APP5") ~ red);
    scope (exit)
        remove(path);

    auto fx = new Fixture();
    assert(!fx.ruleOf("APP1").isValid(), "no rules yet");
    assert(fx.filters.loadFile(path) == "");
    assert(fx.ruleOf("APP1") == fx.idOf(0, 0) && fx.ruleOf("APP2") == fx.idOf(0, 1));
    assert(!fx.ruleOf("APP5").isValid(), "an include filter without enableMarker has no color");
    assert(!fx.ruleOf("APP3").isValid());

    assert(fx.filters.enableRule(0, 0, false) == "");
    assert(!fx.ruleOf("APP1").isValid(), "a rule switched off");
    assert(fx.filters.enableRule(0, 0, true) == "");
    assert(fx.filters.enableSet(0, false) == "");
    assert(!fx.ruleOf("APP1").isValid(), "a set switched off");
    assert(fx.filters.enableSet(0, true) == "");

    assert(fx.filters.addRule(0, coloredAppRule("Three", "APP3")) == "");
    assert(fx.ruleOf("APP3") == fx.idOf(0, 3), "an added rule");
    assert(fx.filters.updateRule(0, 3, coloredAppRule("Four", "APP4")) == "");
    assert(!fx.ruleOf("APP3").isValid() && fx.ruleOf("APP4") == fx.idOf(0, 3), "an edited rule");
    assert(fx.filters.updateRule(0, 3, appRule("Four", "APP4")) == "");
    assert(!fx.ruleOf("APP4").isValid(), "its color taken away");
    assert(fx.filters.removeRule(0, 0) == "");
    assert(!fx.ruleOf("APP1").isValid(), "a removed rule");

    auto restored = new Fixture();
    restored.filters.restore(fx.filters.saved());
    assert(restored.ruleOf("APP2") == restored.idOf(0, 0), "restored sets");
    assert(fx.filters.remove(0) == "");
    assert(!fx.ruleOf("APP2").isValid(), "a removed set");
}

@("DocumentFilters: the sets are saved as copies and restored without their files")
unittest
{
    import std.file : remove;

    const first = makeDlf("filters_save_1.dlf", appFilter("APP1"), appFilter("APP2"));
    const second = makeDlf("filters_save_2.dlf", appFilter("APP3"));

    auto fx = new Fixture();
    assert(fx.filters.loadFile(first) == "" && fx.filters.loadFile(second) == "");
    assert(fx.filters.enableRule(0, 1, false) == "" && fx.filters.enableSet(1, false) == "");
    assert(fx.filters.addRule(0, appRule("Four", "APP4")) == "");
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

@("DocumentFilters: New Filter is an empty set without a file, for any log with columns")
unittest
{
    import formats.logcat : LogcatFormat;

    auto fx = new Fixture(new LogcatFormat(LogcatFormat.Variant.Threadtime), "logcat");
    assert(fx.filters.newSet() == "");
    assert(fx.filters.sets.length == 1 && fx.filters.sets[0].name == "New Filter");
    assert(fx.filters.sets[0].source == "" && fx.filters.sets[0].rules.length == 0);
    assert(fx.filters.toJson()["sets"][0]["fileName"].str == "New Filter.logcat.logfilter");
    assert(fx.applyCount == 0);
}

@("DocumentFilters: rules are added, edited and removed, and filter the view at once")
unittest
{
    auto fx = new Fixture();
    assert(fx.filters.newSet() == "");
    assert(fx.filters.addRule(0, appRule("One", "APP1")) == "");

    auto rule = fx.filters.ruleJson(0, 0);
    assert(rule["name"].str == "One" && rule["kind"].str == "include");
    assert(rule["conditions"][0]["column"].str == "app" && rule["conditions"][0]["value"].str == "APP1");
    assert(fx.filters.ruleJson(0, 5).isNull, "no such rule");
    assert(fx.shows("APP1") && !fx.shows("APP2"));

    assert(fx.filters.addRule(0, appRule("Two", "APP2")) == "");
    assert(fx.shows("APP1") && fx.shows("APP2") && !fx.shows("APP3"));

    assert(fx.filters.updateRule(0, 0, appRule("Three", "APP3")) == "");
    assert(fx.filters.sets[0].rules[0].name == "Three");
    assert(!fx.shows("APP1") && fx.shows("APP3"));

    assert(fx.filters.removeRule(0, 0) == "");
    assert(fx.filters.sets[0].rules.length == 1 && !fx.shows("APP3") && fx.shows("APP2"));
    assert(fx.filters.removeRule(0, 3).length && fx.filters.updateRule(2, 0, `{}`).length);
}

@("DocumentFilters: a new rule is switched on, without conditions")
unittest
{
    auto rule = DocumentFilters.newRuleJson();
    assert(rule["name"].str == "New Rule" && rule["enabled"].boolean);
    assert(rule["kind"].str == "include" && rule["conditions"].array.length == 0);
}

@("DocumentFilters: a rule switched on must apply; one switched off is taken with its error")
unittest
{
    auto fx = new Fixture();
    assert(fx.filters.newSet() == "");
    assert(fx.filters.addRule(0, appRule("One", "APP1")) == "");
    const count = fx.applyCount;
    const broken = `{"name": "Broken", "conditions": [{"column": "payload", "check": "regex", "value": "(unclosed"}]}`;
    assert(fx.filters.addRule(0, broken).length);
    assert(fx.filters.updateRule(0, 0, `not json`).length);
    assert(fx.filters.sets[0].rules.length == 1 && fx.filters.sets[0].rules[0].name == "One");
    assert(fx.applyCount == count);

    const off = `{"name": "Broken", "enabled": false, "conditions": [{"column": "payload", "check": "regex", "value": "(unclosed"}]}`;
    assert(fx.filters.addRule(0, off) == "");
    assert(fx.filters.sets[0].rules[1].problem.length);
}

@("DocumentFilters: a rule is checked for the editor, condition by condition")
unittest
{
    auto fx = new Fixture();
    auto result = fx.filters.checkRule(`{"name": "x", "conditions": [
        {"column": "app", "check": "equals", "value": "APP1"},
        {"column": "level", "check": "range", "min": "verbose", "max": "error"}]}`);
    assert(result["error"].str == "");
    assert(result["conditions"].array.length == 2);
    assert(result["conditions"][0].str == "" && result["conditions"][1].str.length);
    assert(!result["missing"][0].boolean && !result["missing"][1].boolean);
    assert(fx.filters.checkRule(`not json`)["error"].str.length);

    auto header = fx.filters.checkRule(`{"conditions": [{"column": "header", "check": "contains", "value": "X"}]}`);
    assert(header["conditions"][0].str.length && header["missing"][0].boolean,
        "a column this log doesn't have: not applied, but not a mistake to fix");
}

@("DocumentFilters: a rule switched on with a condition on a column the log doesn't have is taken, not applied")
unittest
{
    auto fx = new Fixture();
    assert(fx.filters.newSet() == "");
    assert(fx.filters.addRule(0, `{"name": "Header", "conditions": [{"column": "header", "check": "contains", "value": "X"}]}`) == "");
    assert(fx.filters.sets[0].rules[0].enabled && fx.filters.sets[0].rules[0].problem.length);
}

@("DocumentFilters: a set is exported to a filter file or a .dlf, with its switches")
unittest
{
    import formats.dlt.dlf : readDlf;
    import std.algorithm.searching : canFind;
    import std.file : exists, readText, remove, tempDir;
    import std.path : buildPath;

    const native = buildPath(tempDir(), "filters_export.dlt.logfilter");
    const dlf = buildPath(tempDir(), "filters_export.dlf");
    scope (exit)
    {
        if (exists(native))
            remove(native);
        if (exists(dlf))
            remove(dlf);
    }

    auto fx = new Fixture();
    assert(fx.filters.newSet() == "");
    assert(fx.filters.addRule(0, appRule("One", "APP1")) == "");
    assert(fx.filters.addRule(0, appRule("Two", "APP2")) == "");
    assert(fx.filters.enableRule(0, 0, false) == "");

    assert(fx.filters.exportSet(0, native) == "");
    auto file = parseFilterFile(readText(native));
    assert(file.logFormat == "dlt" && file.set.name == "New Filter" && file.set.rules.length == 2);
    assert(!file.set.rules[0].enabled && file.set.rules[1].enabled);
    assert(fx.filters.sets[0].source == native);

    assert(fx.filters.addRule(0, `{"name": "Session", "conditions": [{"column": "session", "check": "equals", "value": 3}]}`) == "");
    assert(fx.filters.enableSet(0, false) == "");
    const note = fx.filters.exportSet(0, dlf);
    assert(note.canFind("Session"), "a .dlf can't hold the session id: " ~ note);
    const filters = readDlf(dlf);
    assert(filters.length == 3 && filters[1].appId == "APP2" && !filters[1].enabled,
        "a set switched off is exported off");
    assert(fx.filters.sets[0].name == "filters_export.dlf" && fx.filters.sets[0].rules[1].enabled);

    assert(fx.filters.exportSet(0, "/nonexistent/dir/x.logfilter").length);
    assert(fx.filters.exportSet(3, native).length);
}

@("DocumentFilters: the panel state of the sets and their rules")
unittest
{
    import std.file : remove;

    const path = makeDlf("filters_json.dlf", appFilter("APP1", 1),
        "<type>2</type><name>Header</name><enablefilter>1</enablefilter><enableheadertext>1</enableheadertext>");
    scope (exit)
        remove(path);

    auto fx = new Fixture();
    assert(fx.filters.loadFile(path) == "");
    auto json = fx.filters.toJson();
    assert(json["canFilter"].boolean && json["canDlf"].boolean);
    assert(json["sets"].array.length == 1);
    auto set = json["sets"][0];
    assert(set["name"].str == "filters_json.dlf" && set["source"].str == path);
    assert(set["fileName"].str == path && set["enabled"].boolean);
    assert(set["rules"].array.length == 2);
    assert(set["rules"][0]["name"].str == "APP1" && set["rules"][0]["kind"].str == "exclude");
    assert(set["rules"][0]["enabled"].boolean && set["rules"][0]["error"].str == "");
    assert(set["rules"][1]["kind"].str == "marker" && set["rules"][1]["error"].str.length);
}
