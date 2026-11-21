//! The filters of the main view of a document, apart from the window so they
//! can be tested: the filter sets of the log, the commands that change them
//! and their state for the filter panel. A set is a copy: a loaded file (a
//! filter file of Log Tracy, or a .dlf for a DLT log) is
//! copied, edited in place, remembered in the settings of the log and can be
//! exported to either kind of file; no file is referred to, so a file loaded
//! for two logs doesn't tie them together.
//! Each command returns a message for the user: an error, or what was lost or
//! may not fit when it was done; "" when there is nothing to say.
module ui.filter_commands;

import utils.ui_text : english, say, TextForUser, uiText, uiTextOf, UiText;
import std.algorithm.iteration : map;
import std.array : array;
import formats.dlt.dlf : canLoadDlf, fromDlf, readDlf, toDlf, writeDlf;
import log_core.filter_file;
import log_core.log_filter : LogFilter;
import log_core.log_format : ColumnInfo, LogFormat;
import log_core.log_message : LogMessage;
import log_core.rule_filter;
import ui.app_settings : copyOf, SavedFilter;

import std.json : JSONValue;

final class DocumentFilters
{
    // What the filters need of the format of the log, not the format: a document may decode
    // by another one later (Document.loadDescriptions), of the same columns
    private const(ColumnInfo)[] _columns;
    private bool _canDlf; // the log takes the filter files of DLT (canLoadDlf)
    private string _formatId; // FormatInfo.id of the log, written to the filter files
    private void delegate(LogFilter!wchar) _apply;
    private FilterSet[] _sets;
    private UiText[RuleId] _problems; // why a rule isn't applied, by its id: found as it comes in
    private RuleMatcher _matcher; // compiled from _sets by rematch(); null: no rules
    private RuleIdGenerator _ruleIds; // the rules get their ids when they come in
    private bool[] _appliedSets; // the boxes of the sets and rules (by id) when the view was complete
    private bool[RuleId] _appliedRules;

    // The commands return their messages as UiText, the session puts them; what is made as text
    // here (the JSON of the panel, the name of a new set or rule) is put by the TextForUser
    // given, english if none

    //! @param format - of the log; its id is written to the filter files
    //! @param apply - filters the main view of the document (null: no filter)
    this(const(LogFormat) format, void delegate(LogFilter!wchar) apply)
    {
        _columns = format is null ? null : format.columns;
        _canDlf = canLoadDlf(format);
        _formatId = format is null ? "" : format.info.id;
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

    //! @returns the color "#rrggbb" of the rule `id`, empty if it has none (or there is no such rule)
    string colorOf(RuleId id) const
    {
        foreach (ref s; _sets)
            foreach (ref rule; s.rules)
                if (rule.id == id)
                    return isRuleColor(rule.color) ? rule.color : "";
        return "";
    }

    //! @returns true if the log has columns to filter by
    bool canFilter() const
    {
        return _columns.length > 0;
    }

    //! @brief Appends a copy of the rules of a file and filters the view with
    //! them: a .dlf (DLT logs only) or a filter file of Log Tracy (any log;
    //! one made for another format is taken, with a note)
    UiText loadFile(string path)
    {
        import std.algorithm.searching : canFind;
        import std.file : readText;
        import std.path : baseName;

        if (!canFilter())
            return noColumns();
        if (_sets.canFind!((ref s) => s.source == path))
            return uiText("{file} is loaded already: remove it to load it again", "file", baseName(path));
        FilterSet set;
        UiText[] notes;
        try
        {
            if (isDlf(path))
            {
                if (!_canDlf)
                    return uiText("DLT filters (.dlf) apply to DLT logs only");
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
                    notes ~= uiText("made for {format} logs: the rules on columns this log doesn't have aren't applied",
                        "format", file.logFormat);
            }
        }
        catch (Exception e)
            return uiText("Can't load the filter: {reason}", "reason", uiTextOf(e));
        set.source = path;
        identify(set);
        _sets = set ~ _sets; // the newest on top
        rematch();
        if (filtersView(set))
            apply();
        return noteOf(baseName(path), notes);
    }

    //! @brief Adds an empty set on top, to add rules to
    UiText newSet(TextForUser text = null)
    {
        if (!canFilter())
            return noColumns();
        FilterSet set;
        set.name = say(text, uiText("New Filter")); // a name of the user's, in the language of now
        _sets = set ~ _sets;
        return UiText.init;
    }

    //! @brief Writes a set to a file, with the switches of its rules (all off
    //! if the set is): a .dlf (DLT logs only; what it can't hold is dropped
    //! and named) or a filter file of Log Tracy. The set remembers the file.
    UiText exportSet(size_t set, string path)
    {
        import std.file : write;
        import std.path : baseName;

        if (set >= _sets.length)
            return noSuchSet();
        // What filters is written: the rules of a set switched off are off
        auto written = cast(FilterSet) _sets[set];
        written.rules = copyOf(_sets[set].rules);
        if (!written.enabled)
            foreach (ref rule; written.rules)
                rule.enabled = false;
        UiText[] notes;
        try
        {
            if (isDlf(path))
            {
                if (!_canDlf)
                    return uiText("DLT filters (.dlf) are for DLT logs only");
                writeDlf(path, toDlf(written.rules, notes));
                _sets[set].name = baseName(path); // a .dlf has no name of its own
            }
            else
                write(path, filterFileJson(written, _formatId));
        }
        catch (Exception e)
            return uiText("Can't export the filter: {reason}", "reason", uiTextOf(e));
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
            identify(set);
            changed |= filtersView(set);
            _sets ~= set;
        }
        rematch();
        if (changed)
            apply();
    }

    //! @brief Removes a set
    UiText remove(size_t set)
    {
        import std.algorithm.mutation : remove;

        if (set >= _sets.length)
            return noSuchSet();
        const changed = filtersView(_sets[set]);
        if (set < _appliedSets.length)
            _appliedSets = _appliedSets.remove(set); // its boxes go with it
        foreach (ref r; _sets[set].rules)
            _problems.remove(r.id);
        _sets = _sets.remove(set);
        rematch();
        if (changed)
            apply();
        return UiText.init;
    }

    //! @brief Switches a whole set on or off
    UiText enableSet(size_t set, bool enabled)
    {
        if (set >= _sets.length)
            return noSuchSet();
        _sets[set].enabled = enabled;
        rematch();
        if (filtersView(_sets[set], true))
            apply();
        return UiText.init;
    }

    //! @brief Renames a set; the name is trimmed, an empty one (or one of
    //! spaces only) leaves the old name
    UiText renameSet(size_t set, string name)
    {
        import std.string : strip;

        if (set >= _sets.length)
            return noSuchSet();
        if (name.strip.length)
            _sets[set].name = name.strip;
        return UiText.init;
    }

    //! @brief Switches one rule of a set on or off
    UiText enableRule(size_t set, size_t rule, bool enabled)
    {
        if (set >= _sets.length || rule >= _sets[set].rules.length)
            return noSuchSet();
        auto target = &_sets[set].rules[rule];
        target.enabled = enabled;
        rematch();
        if (_sets[set].enabled && filters(*target, true)) // markers don't change what is shown
            apply();
        return UiText.init;
    }

    //! Remembers the boxes as the view shows them: its filter is complete
    void markApplied()
    {
        _appliedSets = _sets.map!(set => set.enabled).array;
        _appliedRules = null;
        foreach (set; _sets)
            foreach (rule; set.rules)
                _appliedRules[rule.id] = rule.enabled;
    }

    //! Puts the boxes as they were when the view was complete and filters it anew: for a filter the
    //! user cancelled, which isn't applied, so no box may say it is
    UiText restoreApplied()
    {
        foreach (i, ref set; _sets)
        {
            set.enabled = i < _appliedSets.length && _appliedSets[i];
            foreach (ref rule; set.rules)
                rule.enabled = _appliedRules.get(rule.id, false);
        }
        rematch();
        apply();
        return UiText.init;
    }

    //! A new rule for the editor, as ruleJson gives a rule; named in the language of now
    JSONValue newRuleJson(TextForUser text = null) const
    {
        FilterRule rule;
        rule.name = say(text, uiText("New Rule"));
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
    UiText addRule(size_t set, string json)
    {
        if (set >= _sets.length)
            return noSuchSet();
        return edit(set, json, (s, rule) { rule.id = _ruleIds.popId(); s.rules ~= rule; return s.rules.length - 1; });
    }

    //! @brief Replaces a rule of a set, as addRule takes it
    UiText updateRule(size_t set, size_t rule, string json)
    {
        if (set >= _sets.length || rule >= _sets[set].rules.length)
            return noSuchSet();
        return edit(set, json, (s, r) { r.id = s.rules[rule].id; s.rules[rule] = r; return rule; });
    }

    //! @brief Checks a rule for the editor, as addRule takes it
    //! @returns {error, conditions: [what is wrong with each condition, "" if
    //! nothing], missing: [whether its column is one the log doesn't have]};
    //! error says why the rule can't be read at all, "" if it can. A
    //! condition on a missing column isn't a mistake: the rule isn't applied
    //! to this log, as when it is loaded.
    JSONValue checkRule(string json, TextForUser text = null) const
    {
        import std.json : parseJSON;

        const columns = _columns;
        FilterRule rule;
        try
            rule = ruleFromJson(parseJSON(json));
        catch (Exception e)
            return JSONValue(["error": JSONValue(say(text, uiText("Invalid rule: {reason}", "reason", uiTextOf(e)))),
                "conditions": JSONValue.emptyArray, "missing": JSONValue.emptyArray]);
        bool[] missing;
        foreach (ref c; rule.conditions)
            missing ~= !hasColumn(c.columnId);
        return JSONValue([
            "error": JSONValue(""),
            "conditions": JSONValue(conditionErrors(columns, rule).map!(error => say(text, error)).array),
            "missing": JSONValue(missing),
        ]);
    }

    //! @brief Removes a rule of a set
    UiText removeRule(size_t set, size_t rule)
    {
        import std.algorithm.mutation : remove;

        if (set >= _sets.length || rule >= _sets[set].rules.length)
            return noSuchSet();
        const changed = _sets[set].enabled && filters(_sets[set].rules[rule]);
        _problems.remove(_sets[set].rules[rule].id);
        _sets[set].rules = _sets[set].rules.remove(rule);
        rematch();
        if (changed)
            apply();
        return UiText.init;
    }

    //! The state of the filter panel: {canFilter, canDlf, active, sets: [{name,
    //! source, fileName, enabled, rules: [{name, kind, enabled, color,
    //! error, id}]}]}. canFilter tells whether the log has columns to filter by,
    //! canDlf whether .dlf files apply to it; fileName is the file to offer
    //! on export: the source, or <name>.<format>.logfilter; kind is
    //! "include", "exclude" or "marker"; error says why a rule isn't
    //! applied, "" if it is. active tells whether any rule works on the log:
    //! filters the view or colors its rows (works()).
    JSONValue toJson(TextForUser text = null) const
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
                    "error": JSONValue(say(text, problemOf(rule))), // see identify()
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
            "canDlf": JSONValue(_canDlf),
            "active": JSONValue(active()),
            "sets": JSONValue(sets),
        ]);
    }

    private static UiText noSuchSet() => uiText("no such filter");
    private static UiText noColumns() => uiText("this log has no columns to filter by");

    private static bool isDlf(string path)
    {
        import std.path : extension;
        import std.uni : icmp;

        return icmp(extension(path), ".dlf") == 0;
    }

    //! The notes of a command on a file, one per line; none if there are none
    private static UiText noteOf(string file, const(UiText)[] notes)
    {
        if (notes.length == 0)
            return UiText.init;
        UiText lines = notes[0];
        foreach (note; notes[1 .. $])
            lines = uiText("{lines}\n{line}", "lines", lines, "line", note);
        return uiText("{file}: {notes}", "file", file, "notes", lines);
    }

    //! @brief Changes the rules of a set by a rule parsed from `json`. A rule
    //! switched on must have no mistake in a condition on a column of the log;
    //! one switched off is taken with its errors, as a loaded one is, so it
    //! can be renamed or switched off before it is fixed. A condition on a
    //! column the log doesn't have only keeps the rule from being applied.
    //! `change` puts the rule in the set and returns where it is.
    private UiText edit(size_t set, string json, scope size_t delegate(FilterSet*, FilterRule) change)
    {
        import std.json : parseJSON;

        FilterRule rule;
        try
            rule = ruleFromJson(parseJSON(json));
        catch (Exception e)
            return uiText("Invalid rule: {reason}", "reason", uiTextOf(e));
        // A mistake in a condition on a column of the log is refused; one on a
        // column the log doesn't have only keeps the rule from being applied
        if (rule.enabled)
            foreach (i, error; conditionErrors(_columns, rule))
                if (!error.empty && hasColumn(rule.conditions[i].columnId))
                    return error;

        auto target = &_sets[set];
        const before = filtersView(*target);
        findProblem(target.rules[change(target, rule)]);
        rematch();
        if (before || filtersView(*target))
            apply();
        return UiText.init;
    }

    //! @returns true if the log has the column
    private bool hasColumn(string id) const
    {
        import std.algorithm.searching : canFind;

        return _columns.canFind!(c => c.id == id);
    }

    //! @returns why the rule can't be applied to this log (see ruleError), empty if it can
    UiText problemOf(ref const(FilterRule) rule) const
    {
        if (auto problem = rule.id in _problems)
            return *problem;
        return UiText.init;
    }

    //! The rules that can't be applied to this log get their error kept by their id, so it is
    //! found once, not each time the panel is shown
    private void findProblems(ref const(FilterSet) set)
    {
        foreach (ref rule; set.rules)
            findProblem(rule);
    }

    private void findProblem(ref const(FilterRule) rule)
    {
        const problem = ruleError(_columns, rule);
        if (problem.empty)
            _problems.remove(rule.id);
        else
            _problems[rule.id] = problem;
    }

    //! @returns true if the rule filters the view (or would, when `anyState`,
    //! were it switched on): an include or exclude rule that can be applied
    private bool filters(ref const(FilterRule) rule, bool anyState = false) const
    {
        return (anyState || rule.enabled) && rule.kind != RuleKind.Marker && problemOf(rule).empty;
    }

    //! @returns true if the rule works on the log: it filters the view, or it
    //! is a marker the rows take the color of (RuleMatcher)
    private bool works(ref const(FilterRule) rule) const
    {
        return filters(rule) || (rule.enabled && rule.kind == RuleKind.Marker
            && isRuleColor(rule.color) && problemOf(rule).empty);
    }

    //! @returns true if any rule of a set switched on works on the log
    private bool active() const
    {
        import std.algorithm.searching : any;

        return _sets.any!(set => set.enabled && set.rules.any!(r => works(r)));
    }

    //! @returns true if the set filters the view (or would, when `anyState`,
    //! were it switched on)
    private bool filtersView(ref const(FilterSet) set, bool anyState = false) const
    {
        import std.algorithm.searching : any;

        return (anyState || set.enabled) && set.rules.any!(r => filters(r));
    }

    //! Gives the rules of a set that comes in their ids
    //! and finds why the ones that can't be applied can't (findProblems)
    private void identify(ref FilterSet set)
    {
        foreach (ref rule; set.rules)
            rule.id = _ruleIds.popId();
        findProblems(set);
    }

    //! Compiles the matcher of the records from the rules, after a change of them
    private void rematch()
    {
        _matcher = RuleMatcher.compile(_columns, _sets);
    }

    //! Filters the view with the enabled rules
    private void apply()
    {
        const columns = _columns;
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

        this(const(LogFormat) format = new DltFormat())
        {
            filters = new DocumentFilters(format, (f) { applied = f; ++applyCount; });
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

    //! A temporary filter file of Log Tracy; remove(path) after use
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
    assert(fx.filters.loadFile(first).empty);
    assert(fx.shows("APP1") && !fx.shows("APP2"));
    assert(fx.filters.loadFile(second).empty);
    assert(fx.shows("APP1") && fx.shows("APP2") && !fx.shows("APP3"));
    assert(fx.filters.sets.length == 2);
    assert(fx.filters.sets[1].name == "filters_first.dlf" && fx.filters.sets[1].source == first);
}

@("DocumentFilters: a filter file of Log Tracy is loaded for any log, one of another format with a note")
unittest
{
    import formats.logcat : LogcatFormat;
    import std.algorithm.searching : canFind;
    import std.file : remove;

    const path = makeLogfilter("filters_native.dlt.logfilter", `{"type": "log-tracy-filter", "version": 1,
        "logFormat": "dlt", "name": "Apps", "rules": [` ~ appRule("One", "APP1") ~ `]}`);
    scope (exit)
        remove(path);

    auto fx = new Fixture();
    assert(fx.filters.loadFile(path).empty);
    assert(fx.filters.sets[0].name == "Apps" && fx.filters.sets[0].source == path);
    assert(fx.shows("APP1") && !fx.shows("APP2"));

    auto logcat = new Fixture(new LogcatFormat(LogcatFormat.Variant.Threadtime));
    const note = logcat.filters.loadFile(path);
    assert(english(note).canFind("made for dlt"), english(note));
    assert(logcat.filters.sets.length == 1 && !logcat.filters.problemOf(logcat.filters.sets[0].rules[0]).empty,
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
    assert(fx.filters.loadFile(path).empty);
    assert(english(fx.filters.loadFile(path)).canFind("already"));
    assert(!fx.filters.loadFile("/nonexistent/filter.dlf").empty);
    assert(english(fx.filters.loadFile(broken)).canFind("Can't load"));
    assert(fx.filters.sets.length == 1);

    auto logcat = new Fixture(new LogcatFormat(LogcatFormat.Variant.Threadtime));
    assert(english(logcat.filters.loadFile(path)).canFind("DLT"));
    assert(logcat.filters.sets.length == 0 && logcat.applyCount == 0);
    assert(logcat.filters.toJson()["canFilter"].boolean && !logcat.filters.toJson()["canDlf"].boolean);
}

@("DocumentFilters: restoreApplied puts the boxes as the complete view had them")
unittest
{
    import std.file : remove;

    const path = makeDlf("filters_restore.dlf", appFilter("APP1"), appFilter("APP2"));
    scope (exit)
        remove(path);

    auto fx = new Fixture();
    assert(fx.filters.loadFile(path).empty);
    fx.filters.markApplied();
    assert(fx.filters.enableRule(0, 1, false).empty);
    assert(fx.filters.enableSet(0, false).empty);
    assert(fx.filters.restoreApplied().empty);
    assert(fx.filters.sets[0].enabled && fx.filters.sets[0].rules[0].enabled && fx.filters.sets[0].rules[1].enabled);
    assert(fx.shows("APP2") && !fx.shows("APP3"), "the view shows what the boxes say");


    // A removed set takes its remembered boxes with it
    assert(fx.filters.newSet().empty);
    assert(fx.filters.enableSet(1, false).empty);
    fx.filters.markApplied();
    assert(fx.filters.enableSet(1, true).empty);
    assert(fx.filters.remove(0).empty);
    assert(fx.filters.restoreApplied().empty);
    assert(!fx.filters.sets[0].enabled, "the set that remains is the one that was off");
}

@("DocumentFilters: a set and a rule are switched off and on, a removed set stops filtering")
unittest
{
    import std.file : remove;

    const path = makeDlf("filters_toggle.dlf", appFilter("APP1"), appFilter("APP2"));
    scope (exit)
        remove(path);

    auto fx = new Fixture();
    assert(fx.filters.loadFile(path).empty);
    assert(fx.shows("APP1") && fx.shows("APP2") && !fx.shows("APP3"));

    assert(fx.filters.enableRule(0, 1, false).empty);
    assert(fx.shows("APP1") && !fx.shows("APP2"));
    assert(!fx.filters.sets[0].rules[1].enabled);

    assert(fx.filters.enableSet(0, false).empty);
    assert(fx.applied is null, "no enabled rule: no filter");
    assert(fx.filters.enableSet(0, true).empty);
    assert(fx.shows("APP1") && !fx.shows("APP2"), "the rule states are kept");

    assert(fx.filters.remove(0).empty);
    assert(fx.filters.sets.length == 0 && fx.applied is null);
    assert(!fx.filters.remove(0).empty, "no such set");
    assert(!fx.filters.enableRule(5, 0, true).empty);
}

@("DocumentFilters: a set is renamed, its name trimmed; an empty name or one of spaces leaves the old one")
unittest
{
    auto fx = new Fixture();
    assert(fx.filters.newSet().empty);
    assert(fx.filters.renameSet(0, "  Errors of APP1 ").empty);
    assert(fx.filters.sets[0].name == "Errors of APP1", fx.filters.sets[0].name);
    assert(fx.filters.saved()[0].name == "Errors of APP1", "kept for the log");
    assert(fx.filters.renameSet(0, "").empty && fx.filters.sets[0].name == "Errors of APP1");
    assert(fx.filters.renameSet(0, " \t ").empty && fx.filters.sets[0].name == "Errors of APP1");
    assert(!fx.filters.renameSet(3, "Other").empty, "no such set");
}

@("DocumentFilters: switching a marker rule, or a set of markers only, doesn't filter the view again")
unittest
{
    import std.file : remove;

    const path = makeDlf("filters_marker.dlf", appFilter("APP1", 2));
    scope (exit)
        remove(path);

    auto fx = new Fixture();
    assert(fx.filters.loadFile(path).empty);
    const count = fx.applyCount;
    assert(fx.filters.enableRule(0, 0, false).empty);
    assert(fx.filters.enableSet(0, false).empty && fx.filters.enableSet(0, true).empty);
    assert(fx.filters.remove(0).empty);
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
    assert(fx.filters.newSet().empty && fx.filters.loadFile(path).empty);
    assert(fx.filters.addRule(1, appRule("Three", "APP3")).empty);
    const ids = [fx.idOf(0, 0), fx.idOf(0, 1), fx.idOf(1, 0)];
    foreach (i, id; ids)
    {
        assert(id.isValid());
        foreach (other; ids[0 .. i])
            assert(id != other, "unique among the sets");
    }
    assert(fx.filters.updateRule(1, 0, appRule("Four", "APP4")).empty);
    assert(fx.idOf(1, 0) == ids[2], "the same rule, edited");

    auto restored = new Fixture();
    restored.filters.restore(fx.filters.saved());
    assert(restored.idOf(0, 0).isValid() && restored.idOf(0, 0) != restored.idOf(0, 1));

    const json = fx.filters.toJson()["sets"][0]["rules"][1];
    assert(json["id"].integer == ids[1].toInt(), "the panel knows the ids");
}

@("DocumentFilters: the panel is told whether any rule works on the log, as the view and the rows take the rules")
unittest
{
    auto fx = new Fixture();
    bool active() => fx.filters.toJson()["active"].boolean;
    assert(fx.filters.newSet().empty);
    assert(!active(), "an empty set");

    const marker = appRule("Marker", "APP1")[0 .. $ - 1] ~ `, "kind": "marker"}`;
    assert(fx.filters.addRule(0, marker).empty);
    assert(!active(), "a marker without a color neither filters nor colors");
    assert(fx.filters.updateRule(0, 0, marker[0 .. $ - 1] ~ `, "color": "#00ff00"}`).empty);
    assert(active(), "a marker with a color colors the rows");
    assert(fx.filters.enableSet(0, false).empty);
    assert(!active(), "in a set switched off");

    auto other = new Fixture();
    assert(other.filters.newSet().empty);
    assert(other.filters.addRule(0, appRule("Include", "APP1")).empty);
    assert(other.filters.toJson()["active"].boolean, "an include rule filters");
    assert(other.filters.enableRule(0, 0, false).empty);
    assert(!other.filters.toJson()["active"].boolean, "a rule switched off");
    const missing = `{"name": "Missing", "conditions": [{"column": "nosuch", "check": "equals", "value": "x"}]}`;
    assert(other.filters.addRule(0, missing).empty);
    assert(!other.filters.toJson()["active"].boolean, "a rule not applied");
}

@("DocumentFilters: the panel gets the colors that color the rows, #rrggbb only")
unittest
{
    auto fx = new Fixture();
    assert(fx.filters.newSet().empty);
    assert(fx.filters.addRule(0, appRule("Green", "APP1")[0 .. $ - 1] ~ `, "color": "#00ff00"}`).empty);
    assert(fx.filters.addRule(0, appRule("Red", "APP2")[0 .. $ - 1] ~ `, "color": "red"}`).empty);
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
    assert(fx.filters.loadFile(path).empty);
    assert(fx.ruleOf("APP1") == fx.idOf(0, 0) && fx.ruleOf("APP2") == fx.idOf(0, 1));
    assert(!fx.ruleOf("APP5").isValid(), "an include filter without enableMarker has no color");
    assert(!fx.ruleOf("APP3").isValid());

    assert(fx.filters.enableRule(0, 0, false).empty);
    assert(!fx.ruleOf("APP1").isValid(), "a rule switched off");
    assert(fx.filters.enableRule(0, 0, true).empty);
    assert(fx.filters.enableSet(0, false).empty);
    assert(!fx.ruleOf("APP1").isValid(), "a set switched off");
    assert(fx.filters.enableSet(0, true).empty);

    assert(fx.filters.addRule(0, coloredAppRule("Three", "APP3")).empty);
    assert(fx.ruleOf("APP3") == fx.idOf(0, 3), "an added rule");
    assert(fx.filters.updateRule(0, 3, coloredAppRule("Four", "APP4")).empty);
    assert(!fx.ruleOf("APP3").isValid() && fx.ruleOf("APP4") == fx.idOf(0, 3), "an edited rule");
    assert(fx.filters.updateRule(0, 3, appRule("Four", "APP4")).empty);
    assert(!fx.ruleOf("APP4").isValid(), "its color taken away");
    assert(fx.filters.removeRule(0, 0).empty);
    assert(!fx.ruleOf("APP1").isValid(), "a removed rule");

    auto restored = new Fixture();
    restored.filters.restore(fx.filters.saved());
    assert(restored.ruleOf("APP2") == restored.idOf(0, 0), "restored sets");
    assert(fx.filters.remove(0).empty);
    assert(!fx.ruleOf("APP2").isValid(), "a removed set");
}

@("DocumentFilters: the sets are saved as copies and restored without their files")
unittest
{
    import std.file : remove;

    const first = makeDlf("filters_save_1.dlf", appFilter("APP1"), appFilter("APP2"));
    const second = makeDlf("filters_save_2.dlf", appFilter("APP3"));

    auto fx = new Fixture();
    assert(fx.filters.loadFile(second).empty && fx.filters.loadFile(first).empty);
    assert(fx.filters.enableRule(0, 1, false).empty && fx.filters.enableSet(1, false).empty);
    assert(fx.filters.addRule(0, appRule("Four", "APP4")).empty);
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

    auto fx = new Fixture(new LogcatFormat(LogcatFormat.Variant.Threadtime));
    assert(fx.filters.newSet().empty);
    assert(fx.filters.sets.length == 1 && fx.filters.sets[0].name == "New Filter");
    assert(fx.filters.sets[0].source == "" && fx.filters.sets[0].rules.length == 0);
    assert(fx.filters.toJson()["sets"][0]["fileName"].str == "New Filter.logcat.logfilter");
    assert(fx.applyCount == 0);
}

@("DocumentFilters: rules are added, edited and removed, and filter the view at once")
unittest
{
    auto fx = new Fixture();
    assert(fx.filters.newSet().empty);
    assert(fx.filters.addRule(0, appRule("One", "APP1")).empty);

    auto rule = fx.filters.ruleJson(0, 0);
    assert(rule["name"].str == "One" && rule["kind"].str == "include");
    assert(rule["conditions"][0]["column"].str == "app" && rule["conditions"][0]["value"].str == "APP1");
    assert(fx.filters.ruleJson(0, 5).isNull, "no such rule");
    assert(fx.shows("APP1") && !fx.shows("APP2"));

    assert(fx.filters.addRule(0, appRule("Two", "APP2")).empty);
    assert(fx.shows("APP1") && fx.shows("APP2") && !fx.shows("APP3"));

    assert(fx.filters.updateRule(0, 0, appRule("Three", "APP3")).empty);
    assert(fx.filters.sets[0].rules[0].name == "Three");
    assert(!fx.shows("APP1") && fx.shows("APP3"));

    assert(fx.filters.removeRule(0, 0).empty);
    assert(fx.filters.sets[0].rules.length == 1 && !fx.shows("APP3") && fx.shows("APP2"));
    assert(!fx.filters.removeRule(0, 3).empty && !fx.filters.updateRule(2, 0, `{}`).empty);
}

@("DocumentFilters: a new rule is switched on, without conditions")
unittest
{
    auto rule = (new Fixture).filters.newRuleJson();
    assert(rule["name"].str == "New Rule" && rule["enabled"].boolean);
    assert(rule["kind"].str == "include" && rule["conditions"].array.length == 0);
}

@("DocumentFilters: a rule switched on must apply; one switched off is taken with its error")
unittest
{
    auto fx = new Fixture();
    assert(fx.filters.newSet().empty);
    assert(fx.filters.addRule(0, appRule("One", "APP1")).empty);
    const count = fx.applyCount;
    const broken = `{"name": "Broken", "conditions": [{"column": "payload", "check": "regex", "value": "(unclosed"}]}`;
    assert(!fx.filters.addRule(0, broken).empty);
    assert(!fx.filters.updateRule(0, 0, `not json`).empty);
    assert(fx.filters.sets[0].rules.length == 1 && fx.filters.sets[0].rules[0].name == "One");
    assert(fx.applyCount == count);

    const off = `{"name": "Broken", "enabled": false, "conditions": [{"column": "payload", "check": "regex", "value": "(unclosed"}]}`;
    assert(fx.filters.addRule(0, off).empty);
    assert(!fx.filters.problemOf(fx.filters.sets[0].rules[1]).empty);
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
    assert(fx.filters.newSet().empty);
    assert(fx.filters.addRule(0, `{"name": "Header", "conditions": [{"column": "header", "check": "contains", "value": "X"}]}`).empty);
    assert(fx.filters.sets[0].rules[0].enabled && !fx.filters.problemOf(fx.filters.sets[0].rules[0]).empty);
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
    assert(fx.filters.newSet().empty);
    assert(fx.filters.addRule(0, appRule("One", "APP1")).empty);
    assert(fx.filters.addRule(0, appRule("Two", "APP2")).empty);
    assert(fx.filters.enableRule(0, 0, false).empty);

    assert(fx.filters.exportSet(0, native).empty);
    auto file = parseFilterFile(readText(native));
    assert(file.logFormat == "dlt" && file.set.name == "New Filter" && file.set.rules.length == 2);
    assert(!file.set.rules[0].enabled && file.set.rules[1].enabled);
    assert(fx.filters.sets[0].source == native);

    assert(fx.filters.addRule(0, `{"name": "Session", "conditions": [{"column": "session", "check": "equals", "value": 3}]}`).empty);
    assert(fx.filters.enableSet(0, false).empty);
    const note = fx.filters.exportSet(0, dlf);
    assert(english(note).canFind("Session"), "a .dlf can't hold the session id: " ~ english(note));
    const filters = readDlf(dlf);
    assert(filters.length == 3 && filters[1].appId == "APP2" && !filters[1].enabled,
        "a set switched off is exported off");
    assert(fx.filters.sets[0].name == "filters_export.dlf" && fx.filters.sets[0].rules[1].enabled);

    assert(!fx.filters.exportSet(0, "/nonexistent/dir/x.logfilter").empty);
    assert(!fx.filters.exportSet(3, native).empty);
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
    assert(fx.filters.loadFile(path).empty);
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

@("DocumentFilters: its messages are texts for the user; what it makes as text is put by the text given")
unittest
{
    import std.file : exists, remove, tempDir, write;
    import std.path : buildPath;
    import utils.ui_text : render, UiText;

    string russian(const UiText t) @safe
    {
        return render(t, (string s) {
            switch (s)
            {
            case "Can't load the filter: {reason}": return "Не удалось загрузить фильтр: {reason}";
            case "no column \"{column}\" in this log": return "в журнале нет колонки «{column}»";
            case "New Filter": return "Новый фильтр";
            default: return s;
            }
        });
    }

    auto filters = new DocumentFilters(new DltFormat(), (f) {});
    const broken = buildPath(tempDir, "log_tracy_filters_broken.logfilter");
    scope (exit) if (exists(broken)) remove(broken);
    write(broken, "not json");
    import std.algorithm : startsWith;
    const error = filters.loadFile(broken);
    assert(error.text == "Can't load the filter: {reason}", "the template, translated by the session");
    assert(russian(error).startsWith("Не удалось загрузить фильтр: "));

    assert(filters.newSet(&russian).empty);
    assert(filters.sets[0].name == "Новый фильтр");
    assert(filters.newSet().empty && filters.sets[0].name == "New Filter", "no text given: english");
    assert(filters.addRule(0, `{"name": "x", "enabled": true, "conditions": [{"column": "nosuch", "check": "equals", "value": "1"}]}`).empty);
    assert(filters.toJson(&russian)["sets"][0]["rules"][0]["error"].str == "в журнале нет колонки «nosuch»");
    assert(filters.toJson()["sets"][0]["rules"][0]["error"].str == "no column \"nosuch\" in this log");
}

@("DocumentFilters: a rule fixed by an edit has no problem any more, one broken by it has")
unittest
{
    auto fx = new Fixture;
    assert(fx.filters.newSet().empty);
    const broken = `{"name": "x", "enabled": false, "conditions": [{"column": "nosuch", "check": "equals", "value": "1"}]}`;
    assert(fx.filters.addRule(0, broken).empty, "taken switched off, with its error");
    assert(!fx.filters.problemOf(fx.filters.sets[0].rules[0]).empty);
    assert(fx.filters.updateRule(0, 0, appRule("x", "APP1")).empty);
    assert(fx.filters.problemOf(fx.filters.sets[0].rules[0]).empty, "fixed");
    assert(fx.filters.updateRule(0, 0, broken).empty);
    assert(!fx.filters.problemOf(fx.filters.sets[0].rules[0]).empty, "broken again");
}
