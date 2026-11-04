module log_core.filter_file;

//! The filter files of DLT Explorer: a filter set (log_core/rule_filter) as
//! JSON, the same for every log format, since the rules refer to the columns
//! of the format by id. The settings keep the sets of a log the same way.
//!
//!   {
//!     "type": "dlt-explorer-filter", "version": 1,
//!     "logFormat": "logcat",            // FormatInfo.id the rules were made for
//!     "name": "Crashes",
//!     "rules": [{
//!       "name": "...", "kind": "include" | "exclude" | "marker",
//!       "enabled": true, "color": "#ff0000",
//!       "conditions": [
//!         {"column": "tag", "check": "equals" | "contains" | "regex", "value": "...", "ignoreCase": true},
//!         {"column": "pid", "check": "equals", "value": "12"},
//!         {"column": "level", "check": "range", "min": "error", "max": "fatal"}
//!       ]
//!     }]
//!   }
//!
//! An equals value is text as it was typed, on any column: a number ("12",
//! "0x1F"), a level ("warn"), an enum label; the column takes it when the rule
//! is applied. The bounds of a range are numbers, levels by name.
//! A file is named <name>.<logFormat>.logfilter: the middle part only tells a
//! person which format it is for, the file says it itself.

import log_core.log_format : ColumnInfo, ColumnKind;
import log_core.rule_filter;

import std.json : JSONValue;

enum string filterFileType = "dlt-explorer-filter";
enum int filterFileVersion = 1;
enum string filterFileExtension = ".logfilter";

//! A filter set read from a file, with the format its rules were made for
struct FilterFile
{
    string logFormat; // FormatInfo.id, "" if the file doesn't say
    FilterSet set;
}

//! The name to offer for the file of a set: <name>.<logFormat>.logfilter
string filterFileName(string name, string logFormat)
{
    return name ~ (logFormat.length ? "." ~ logFormat : "") ~ filterFileExtension;
}

//! The id of the column of the core level in every format: its values are
//! written by name
private enum levelColumn = "level";

//! The words of RuleKind and Check in a file, by their values
immutable string[] kindWords = ["include", "exclude", "marker"];
immutable string[] checkWords = ["equals", "contains", "regex", "range"];

//! The rules of a set as JSON, see the module comment (without "type",
//! "version", "logFormat" and "name": filterFileJson adds them)
JSONValue rulesToJson(const(FilterRule)[] rules)
{
    JSONValue number(string column, long value)
    {
        if (column == levelColumn && value >= 0 && value < levelNames.length)
            return JSONValue(levelNames[value]);
        return JSONValue(value);
    }

    JSONValue[] result;
    foreach (ref rule; rules)
    {
        JSONValue[] conditions;
        foreach (ref c; rule.conditions)
        {
            JSONValue json = ["column": JSONValue(c.columnId), "check": JSONValue(checkWords[c.check])];
            if (c.check == Check.Range)
            {
                json["min"] = number(c.columnId, c.min);
                json["max"] = number(c.columnId, c.max);
            }
            else
                json["value"] = JSONValue(c.text); // as typed, a number or a level too
            if (c.ignoreCase)
                json["ignoreCase"] = JSONValue(true);
            conditions ~= json;
        }
        JSONValue json = [
            "name": JSONValue(rule.name),
            "kind": JSONValue(kindWords[rule.kind]),
            "enabled": JSONValue(rule.enabled),
            "conditions": JSONValue(conditions),
        ];
        if (rule.color.length)
            json["color"] = JSONValue(rule.color);
        result ~= json;
    }
    return JSONValue(result);
}

//! @brief The rules from their JSON
//! @throws Exception if it isn't such a list
FilterRule[] rulesFromJson(const(JSONValue) json)
{
    import std.json : JSONType;

    if (json.type != JSONType.array)
        throw new Exception("the rules are a list");
    FilterRule[] rules;
    foreach (ref item; json.array)
        rules ~= ruleFromJson(item);
    return rules;
}

//! @brief A rule from its JSON, as rulesFromJson reads each
//! @throws Exception if it isn't one
FilterRule ruleFromJson(const(JSONValue) item)
{
    import std.algorithm.searching : countUntil;
    import std.conv : to;
    import std.json : JSONType;
    import std.uni : toLower;

    static string text(const(JSONValue) object, string key, string otherwise = "")
    {
        if (auto value = key in object.object)
            return value.str; // throws on another type
        return otherwise;
    }

    static size_t word(const(JSONValue) object, string key, const(string)[] words, size_t otherwise)
    {
        const value = text(object, key, null);
        if (value is null)
            return otherwise;
        const index = words.countUntil(value);
        if (index < 0)
            throw new Exception("unknown " ~ key ~ " \"" ~ value ~ "\"");
        return index;
    }

    // A bound of a range: a number, one written as text ("0x1F"), or the
    // name of a level
    static long number(const(JSONValue) value, string column)
    {
        if (value.type == JSONType.integer)
            return value.integer;
        if (value.type == JSONType.uinteger)
            return cast(long) value.uinteger;
        const str = value.str; // throws on another type
        if (column == levelColumn)
        {
            const level = levelNames.countUntil(str.toLower);
            if (level >= 0)
                return level;
        }
        return parseNumberText(str, false);
    }

    {
        if (item.type != JSONType.object)
            throw new Exception("a rule is an object");
        FilterRule rule;
        rule.name = text(item, "name");
        rule.kind = cast(RuleKind) word(item, "kind", kindWords, RuleKind.Include);
        if (auto enabled = "enabled" in item.object)
            rule.enabled = enabled.boolean;
        rule.color = text(item, "color");
        if (auto conditions = "conditions" in item.object)
            foreach (ref c; conditions.array)
            {
                if (c.type != JSONType.object)
                    throw new Exception("a condition is an object");
                Condition condition;
                condition.columnId = text(c, "column");
                condition.check = cast(Check) word(c, "check", checkWords, Check.Equals);
                if (auto ignoreCase = "ignoreCase" in c.object)
                    condition.ignoreCase = ignoreCase.boolean;
                if (condition.check == Check.Range)
                {
                    condition.min = number(c["min"], condition.columnId);
                    condition.max = number(c["max"], condition.columnId);
                }
                else if (auto value = "value" in c.object)
                {
                    // As typed: the column takes it (RuleFilter). A number written
                    // as a number is taken in hex with 0x, which a decimal and a
                    // hex column read the same ("31" would be 0x31 in a hex one)
                    import std.format : format;

                    if (value.type == JSONType.integer)
                        condition.text = value.integer < 0 ? value.integer.to!string
                            : format("0x%X", value.integer);
                    else if (value.type == JSONType.uinteger)
                        condition.text = format("0x%X", value.uinteger);
                    else
                        condition.text = value.str; // throws on another type
                }
                rule.conditions ~= condition;
            }
        return rule;
    }
}

//! The content of a filter file of the set
string filterFileJson(const(FilterSet) set, string logFormat)
{
    JSONValue json = [
        "type": JSONValue(filterFileType),
        "version": JSONValue(filterFileVersion),
        "logFormat": JSONValue(logFormat),
        "name": JSONValue(set.name),
        "rules": rulesToJson(set.rules),
    ];
    return json.toPrettyString();
}

//! @brief Parses a filter file
//! @throws Exception if it isn't one, or of a later version
FilterFile parseFilterFile(string content)
{
    import std.conv : to;
    import std.json : JSONType, parseJSON;

    const json = parseJSON(content); // throws JSONException
    if (json.type != JSONType.object || "type" !in json.object
        || json["type"].type != JSONType.string || json["type"].str != filterFileType)
        throw new Exception("not a filter file of DLT Explorer");
    const version_ = "version" in json.object ? json["version"].integer : 0;
    if (version_ > filterFileVersion)
        throw new Exception("made by a later version of DLT Explorer (version "
                ~ version_.to!string ~ ")");

    FilterFile file;
    if (auto logFormat = "logFormat" in json.object)
        file.logFormat = logFormat.str;
    if (auto name = "name" in json.object)
        file.set.name = name.str;
    if (auto rules = "rules" in json.object)
        file.set.rules = rulesFromJson(*rules);
    return file;
}

// ─── Tests ──────────────────────────────────────────────────────────────────

version (unittest)
{
    import log_core.log_level : LogLevel;

    private Condition cond(string column, Check check, string text, long min = 0, long max = 0,
        bool ignoreCase = false)
    {
        return Condition(column, check, text, min, max, ignoreCase);
    }

    private FilterSet sample()
    {
        FilterRule crash;
        crash.name = "Fatal in ActivityManager";
        crash.kind = RuleKind.Include;
        crash.color = "#ff0000";
        crash.conditions = [
            cond("tag", Check.Equals, "ActivityManager"),
            cond("payload", Check.Contains, "FATAL", 0, 0, true),
            cond("pid", Check.Range, "", 100, 200),
            cond("level", Check.Range, "", LogLevel.Fatal, LogLevel.Error),
            cond("id", Check.Equals, "0x1F"),
            cond("type", Check.Equals, "CTRL"),
            cond("level", Check.Equals, "warn"),
            cond("app", Check.Equals, ""),
        ];
        FilterRule noise;
        noise.name = "Noise";
        noise.kind = RuleKind.Exclude;
        noise.enabled = false;
        noise.conditions = [cond("payload", Check.Regex, "^heartbeat")];
        FilterRule marker;
        marker.kind = RuleKind.Marker;

        FilterSet set;
        set.name = "Crashes";
        set.rules = [crash, noise, marker];
        return set;
    }
}

@("filterFileName: the name, the format, the extension")
unittest
{
    assert(filterFileName("Crashes", "logcat") == "Crashes.logcat.logfilter");
    assert(filterFileName("Crashes", "") == "Crashes.logfilter");
}

@("filterFileJson: a set written is read back the same, with its format")
unittest
{
    const set = sample();
    auto file = parseFilterFile(filterFileJson(set, "logcat"));
    assert(file.logFormat == "logcat");
    assert(file.set.name == "Crashes");
    assert(file.set.rules == set.rules);
}

@("filterFileJson: levels by name, kinds and checks by word")
unittest
{
    import std.algorithm.searching : canFind;

    const json = filterFileJson(sample(), "logcat");
    assert(json.canFind(`"type": "dlt-explorer-filter"`) || json.canFind(`"type":"dlt-explorer-filter"`));
    assert(json.canFind(`"min": "fatal"`) || json.canFind(`"min":"fatal"`));
    assert(json.canFind(`"exclude"`) && json.canFind(`"contains"`) && json.canFind(`"range"`));
}

@("rulesToJson: an equals value is always text, an empty one too")
unittest
{
    FilterRule rule;
    rule.conditions = [cond("app", Check.Equals, ""), cond("pid", Check.Equals, "5")];
    const json = rulesToJson([rule]);
    assert(json[0]["conditions"][0]["value"].str == "");
    assert(json[0]["conditions"][1]["value"].str == "5");
}

@("ruleFromJson: an equals value written as a number is taken as its text in hex, which any column reads the same")
unittest
{
    import std.json : parseJSON;

    auto rule = ruleFromJson(parseJSON(`{"conditions": [{"column": "pid", "check": "equals", "value": 31}]}`));
    assert(rule.conditions[0].text == "0x1F");
    assert(parseNumberText(rule.conditions[0].text, true) == 31 && parseNumberText(rule.conditions[0].text, false) == 31);
}

@("parseFilterFile: hex as text, missing fields take the defaults")
unittest
{
    auto file = parseFilterFile(`{"type": "dlt-explorer-filter", "version": 1, "name": "x", "rules": [
        {"conditions": [{"column": "id", "check": "equals", "value": "0x1F"},
                        {"column": "level", "check": "range", "min": "warn", "max": "verbose"}]}]}`);
    assert(file.logFormat == "");
    auto rule = file.set.rules[0];
    assert(rule.kind == RuleKind.Include && rule.enabled && rule.name == "");
    assert(rule.conditions[0].text == "0x1F", "a number column takes it as text");
    assert(rule.conditions[1].min == LogLevel.Warn && rule.conditions[1].max == LogLevel.Verbose);
    auto range = parseFilterFile(`{"type": "dlt-explorer-filter", "version": 1, "rules": [
        {"conditions": [{"column": "id", "check": "range", "min": "0x10", "max": 32}]}]}`).set.rules[0];
    assert(range.conditions[0].min == 0x10 && range.conditions[0].max == 32);
}

@("parseFilterFile: what isn't a filter file of this or an earlier version is refused")
unittest
{
    import std.exception : assertThrown;

    assertThrown(parseFilterFile("not json"));
    assertThrown(parseFilterFile(`{"type": "something else", "version": 1, "rules": []}`));
    assertThrown(parseFilterFile(`{"type": "dlt-explorer-filter", "version": 2, "rules": []}`));
    assertThrown(parseFilterFile(`{"type": "dlt-explorer-filter", "version": 1,
        "rules": [{"conditions": [{"column": "x", "check": "nope", "value": "a"}]}]}`));
    assertThrown(parseFilterFile(`{"type": "dlt-explorer-filter", "version": 1,
        "rules": [{"kind": "sometimes"}]}`));
}
