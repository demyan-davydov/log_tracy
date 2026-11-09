module log_core.rule_filter;

//! Filter rules of a log of any format, as in dlt-viewer: rules made of
//! conditions on the columns of the format, grouped in sets (a set is what one
//! filter file holds), and the filter of the main view compiled from them.
//!
//! A record is shown if it matches an enabled include rule (any record if
//! there is none) and no enabled exclude rule. Marker rules don't change what
//! is shown: they are for highlighting. A rule matches when all its conditions
//! do; a rule without conditions matches every record.

import log_core.log_filter;
import log_core.log_format : ColumnInfo, ColumnKind;
import log_core.log_message;

import std.algorithm.iteration : map;
import std.algorithm.searching : countUntil;
import std.array : array;
import std.format : format;
import std.regex : matchFirst, regex, Regex;
import std.typecons : Nullable;
import std.uni : icmp;
import std.utf : toUTF16;
import utils.text_search : TextPattern;
import utils.ui_text : english, uiText, uiTextOf, UiText, UiTextException;

//! What a rule does with the records it matches
enum RuleKind : ubyte
{
    Include, // shown (dlt-viewer: positive)
    Exclude, // hidden (dlt-viewer: negative)
    Marker, // highlighted, doesn't change what is shown
}

//! How a condition checks the value of its column
enum Check : ubyte
{
    Equals, // `text`: the whole text (ignoreCase), a number (in hex for a hex column),
            // a level (name or number), an enum label

    Contains, // text: a substring (ignoreCase)
    Regex, // text: a regular expression found in it (ignoreCase)
    Range, // number or level: min <= value <= max
}

//! A condition on one column of the format
struct Condition
{
    string columnId;
    Check check;
    string text; // Equals, Contains, Regex: the value as typed, on any column
    long min, max; // Range on numbers and levels
    bool ignoreCase;
}

//! A rule: all its conditions must match
struct FilterRule
{
    string name;
    RuleKind kind;
    bool enabled = true;
    string color; // "#rrggbb" or empty
    Condition[] conditions;
    //! Who the rule is in its document while it is open (see RuleId); not
    //! saved, not written to the files
    RuleId id;
}

//! A group of rules switched on and off together: what one filter file holds
struct FilterSet
{
    string name;
    string source; // the file the rules were loaded from; "" if none
    bool enabled = true;
    FilterRule[] rules;
}

//! @returns why `rule` can't be applied to a log with `columns` (an unknown
//! column, a check the column doesn't take, an invalid regular expression or
//! enum label), empty if it can: a text for the user
UiText ruleError(const(ColumnInfo)[] columns, ref const(FilterRule) rule)
{
    try
    {
        foreach (ref condition; rule.conditions)
            compileCondition(columns, condition);
        return UiText.init;
    }
    catch (Exception e)
        return uiTextOf(e);
}

//! A condition resolved against the columns of the format
private struct CompiledCondition
{
    ColumnKind kind;
    int field = -1;
    Check check;
    wstring text; // Equals and Regex on texts
    long min, max; // Equals (min) and Range on numbers, levels and enums
    bool ignoreCase;
    //! Contains on texts: looked for by code units, cheap for every row shown
    //! and every record a filter goes through
    TextPattern substring;
    Regex!wchar regex;

    //! How much a check costs, roughly: a number, a field, the payload, a
    //! regular expression
    int cost() const pure nothrow @nogc
    {
        if (kind != ColumnKind.Text && kind != ColumnKind.Payload)
            return 0;
        const payload = kind == ColumnKind.Payload ? 1 : 0;
        final switch (check)
        {
        case Check.Equals:
            return 1 + payload;
        case Check.Contains:
            return 2 + payload;
        case Check.Regex:
            return 4 + payload;
        case Check.Range:
            return 0; // rejected by compileCondition
        }
    }

    bool matches(scope ref const(LogMessage!wchar) item) const
    {
        final switch (kind)
        {
        case ColumnKind.Text:
            return item.hasField(field) && matchesText(item.text(field));
        case ColumnKind.Payload:
            return matchesText(item.payloadText);
        case ColumnKind.Level:
            return matchesNumber(item.level);
        case ColumnKind.Integer:
        case ColumnKind.Hex:
        case ColumnKind.Duration:
        case ColumnKind.Enum:
            return item.hasField(field) && matchesNumber(item.number(field));
        case ColumnKind.Time:
            assert(false, "rejected by compileCondition");
        }
    }

    private bool matchesText(const(wchar)[] value) const
    {
        switch (check)
        {
        case Check.Equals:
            return ignoreCase ? icmp(value, text) == 0 : value == text;
        case Check.Contains:
            return substring.foundIn(value);
        case Check.Regex:
            return !matchFirst(value, regex).empty;
        default:
            assert(false, "rejected by compileCondition");
        }
    }

    private bool matchesNumber(long value) const pure nothrow @nogc
    {
        // Equals sets max = min
        return value >= min && value <= max;
    }
}

//! @throws Exception if the condition can't be applied to the columns
private CompiledCondition compileCondition(const(ColumnInfo)[] columns, ref const(Condition) condition)
{
    const index = columns.countUntil!(c => c.id == condition.columnId);
    if (index < 0)
        throw new UiTextException(uiText("no column \"{column}\" in this log", "column", condition.columnId));
    const column = &columns[index];

    CompiledCondition compiled;
    compiled.kind = column.kind;
    compiled.field = column.field;
    compiled.check = condition.check;
    compiled.ignoreCase = condition.ignoreCase;

    // The check is said in words, as the rule editor shows it: one text per check
    Exception unsupported()
    {
        final switch (condition.check)
        {
        case Check.Equals:
            return new UiTextException(uiText("{column}: can't be compared to a value", "column", column.title));
        case Check.Contains:
            return new UiTextException(uiText("{column}: can't contain a text", "column", column.title));
        case Check.Regex:
            return new UiTextException(uiText("{column}: can't match a regular expression", "column", column.title));
        case Check.Range:
            return new UiTextException(uiText("{column}: has no range of values", "column", column.title));
        }
    }

    final switch (column.kind)
    {
    case ColumnKind.Time:
        throw new UiTextException(uiText("{column}: can't be filtered", "column", column.title));
    case ColumnKind.Text:
    case ColumnKind.Payload:
        if (condition.check == Check.Contains)
            compiled.substring = TextPattern(condition.text.toUTF16, condition.ignoreCase);
        else
            compiled.text = condition.text.toUTF16;
        if (condition.check == Check.Regex)
            compiled.regex = regex(compiled.text, condition.ignoreCase ? "i" : ""); // throws
        else if (condition.check == Check.Range)
            throw unsupported();
        break;
    case ColumnKind.Enum:
        if (condition.check != Check.Equals)
            throw unsupported();
        const label = column.labels.countUntil!(l => icmp(l, condition.text) == 0);
        if (label < 0)
            throw new UiTextException(uiText("{column}: unknown value \"{value}\", expected one of {values}",
                "column", column.title, "value", condition.text, "values", format("%-(%s, %)", column.labels)));
        compiled.min = compiled.max = label;
        break;
    case ColumnKind.Level:
    case ColumnKind.Integer:
    case ColumnKind.Hex:
    case ColumnKind.Duration:
        if (condition.check == Check.Equals)
            compiled.min = compiled.max = column.kind == ColumnKind.Level
                ? parseLevel(*column, condition.text) : parseNumber(*column, condition.text);
        else if (condition.check == Check.Range)
        {
            if (condition.min > condition.max)
                throw new UiTextException(uiText("{column}: the range is empty, its start is above its end",
                    "column", column.title));
            compiled.min = condition.min;
            compiled.max = condition.max;
        }
        else
            throw unsupported();
        break;
    }
    return compiled;
}

//! @brief A number typed for a number column: in hex for a hex column (with
//! or without 0x), read as the 64 bits of an ID
//! @throws Exception if it isn't one
private long parseNumber(ref const(ColumnInfo) column, string text)
{
    try
        return parseNumberText(text, column.kind == ColumnKind.Hex);
    catch (Exception e)
        throw new UiTextException(uiText("{column}: {reason}", "column", column.title, "reason", uiTextOf(e)));
}

//! The names of the levels, by their LogLevel value: how filter files and the
//! rule editor write them
immutable string[] levelNames = ["none", "fatal", "error", "warn", "info", "debug", "verbose"];

//! @brief A level typed for the level column: its name (any case) or its number
//! @throws Exception if it isn't one
private long parseLevel(ref const(ColumnInfo) column, string text)
{
    import std.string : strip;

    const index = levelNames.countUntil!(name => icmp(name, text.strip) == 0);
    if (index >= 0)
        return index;
    try
    {
        const level = parseNumberText(text, false);
        if (level >= 0 && level < levelNames.length)
            return level;
    }
    catch (Exception)
    {
    }
    throw new UiTextException(uiText("{column}: \"{value}\" is not a level, expected one of {levels}",
        "column", column.title, "value", text, "levels", format("%-(%s, %)", levelNames[1 .. $])));
}

//! @brief A number typed as text: decimal, or hex with 0x (always hex in a
//! hex column, with or without it), read as the 64 bits of an ID
//! @throws Exception if it isn't one
long parseNumberText(string text, bool hex)
{
    import std.conv : ConvException, to;
    import std.string : strip;

    auto value = text.strip;
    if (value.length >= 2 && (value[0 .. 2] == "0x" || value[0 .. 2] == "0X"))
    {
        value = value[2 .. $];
        hex = true;
    }
    try
    {
        if (value.length == 0)
            throw new ConvException("empty");
        return hex ? cast(long) value.to!ulong(16) : value.to!long;
    }
    catch (ConvException)
        throw new UiTextException(hex ? uiText("\"{value}\" is not a hex number", "value", text)
            : uiText("\"{value}\" is not a number", "value", text));
}

//! @returns what is wrong with each condition of the rule, "" for the right
//! ones: an unknown column, a check it doesn't take, a value it can't read, an
//! empty range, an invalid regular expression
UiText[] conditionErrors(const(ColumnInfo)[] columns, ref const(FilterRule) rule)
{
    UiText[] errors;
    foreach (ref condition; rule.conditions)
    {
        try
        {
            compileCondition(columns, condition);
            errors ~= UiText.init;
        }
        catch (Exception e)
            errors ~= uiTextOf(e);
    }
    return errors;
}

//! A rule that can be applied, resolved against the columns of the format
private struct CompiledRule
{
    CompiledCondition[] conditions; // the cheapest first, see CompiledCondition.cost
    RuleKind kind;
    RuleId id;
}

//! @returns the rules of the enabled sets that are enabled, can be applied
//! (see ruleError) and are taken by `take`, in their order, compiled
private CompiledRule[] compileApplicable(alias take)(const(ColumnInfo)[] columns,
    const(FilterSet)[] sets)
{
    import std.algorithm.sorting : sort;
    import std.algorithm.mutation : SwapStrategy;

    CompiledRule[] rules;
    foreach (ref set; sets)
    {
        if (!set.enabled)
            continue;
        foreach (ref rule; set.rules)
        {
            if (!rule.enabled || !take(rule))
                continue;
            CompiledRule compiled;
            compiled.kind = rule.kind;
            compiled.id = rule.id;
            try
                foreach (ref condition; rule.conditions)
                    compiled.conditions ~= compileCondition(columns, condition);
            catch (Exception)
                continue; // see ruleError
            // All of them must match: the cheap ones first spare the others
            compiled.conditions.sort!((a, b) => a.cost < b.cost, SwapStrategy.stable);
            rules ~= compiled;
        }
    }
    return rules;
}

//! @returns true if the record matches all the conditions
private bool allMatch(const(CompiledCondition)[] conditions, scope ref const(LogMessage!wchar) item)
{
    foreach (ref condition; conditions)
        if (!condition.matches(item))
            return false;
    return true;
}

//! The filter of the main view compiled from the enabled rules of the enabled
//! sets; rules with an error (see ruleError) are skipped
final class RuleFilter : LogFilter!wchar
{
    private alias Rule = CompiledCondition[];

    private Rule[] _includes;
    private Rule[] _excludes;

    private this(Rule[] includes, Rule[] excludes) pure
    {
        _includes = includes;
        _excludes = excludes;
    }

    //! @returns null if there is no enabled include or exclude rule to apply
    static RuleFilter compile(const(ColumnInfo)[] columns, const(FilterSet)[] sets)
    {
        Rule[] includes, excludes;
        foreach (ref rule; compileApplicable!(r => r.kind != RuleKind.Marker)(columns, sets))
        {
            if (rule.kind == RuleKind.Include)
                includes ~= rule.conditions;
            else
                excludes ~= rule.conditions;
        }
        return includes.length || excludes.length ? new RuleFilter(includes, excludes) : null;
    }

    override bool matches(scope ref const(LogMessage!wchar) item) const
    {
        return !matchIndex(item).isNull;
    }

    //! @returns the index of the first matching include rule among the
    //! compiled ones, 0 for a record shown with no include rule
    override Nullable!uint matchIndex(scope ref const(LogMessage!wchar) item) const
    {
        Nullable!uint found;
        if (_includes.length == 0)
            found = 0;
        foreach (i, rule; _includes)
            if (allMatch(rule, item))
            {
                found = cast(uint) i;
                break;
            }
        if (found.isNull)
            return found;
        foreach (rule; _excludes)
            if (allMatch(rule, item))
                return Nullable!uint.init;
        return found;
    }

    override immutable(LogFilter!wchar) idup() const pure
    {
        // Cast mutable duplicate to immutable — safe because we own the new object
        return cast(immutable) dup();
    }

    override LogFilter!wchar dup() const pure
    {
        // Regex is not const-copyable: the conditions are copied one by one
        static Rule[] copy(const(Rule)[] rules) pure
        {
            return rules.map!(r => r.map!(c => cast(CompiledCondition) c).array).array;
        }

        return new RuleFilter(copy(_includes), copy(_excludes));
    }
}

//! @returns true if `color` is "#rrggbb"
bool isRuleColor(string color) pure nothrow @nogc
{
    import std.ascii : isHexDigit;

    if (color.length != 7 || color[0] != '#')
        return false;
    foreach (c; color[1 .. $])
        if (!isHexDigit(c))
            return false;
    return true;
}

//! The identity of a rule among the rules of a document while it is open: a
//! row of the table refers to the rule it matches by it. Not saved: a rule
//! gets a new one each time it is loaded.
struct RuleId
{
    private uint _id; // 0: no rule

    this(uint id) pure nothrow @nogc
    {
        _id = id;
    }

    bool isValid() const pure nothrow @nogc
    {
        return _id != 0;
    }

    uint toInt() const pure nothrow @nogc
    {
        return _id;
    }
}

//! Gives the rules of a document their ids, each one new
struct RuleIdGenerator
{
    private uint _last;

    RuleId popId() pure nothrow @nogc
    {
        return RuleId(++_last);
    }
}

//! Finds the rule a record matches, for the table to show it by its color (as
//! dlt-viewer colors the rows): the first one that matches among the enabled
//! rules of the enabled sets that have a color, of any kind (an excluded
//! record is seen when anchored). Rules with an error (see ruleError) and
//! colors that aren't "#rrggbb" are skipped.
final class RuleMatcher
{
    private CompiledRule[] _rules; // in the order of the sets and their rules

    private this(CompiledRule[] rules) pure
    {
        _rules = rules;
    }

    //! @returns null if there is no rule with a color
    static RuleMatcher compile(const(ColumnInfo)[] columns, const(FilterSet)[] sets)
    {
        auto rules = compileApplicable!(r => isRuleColor(r.color))(columns, sets);
        return rules.length ? new RuleMatcher(rules) : null;
    }

    //! @returns the id of the first rule with a color the record matches, an
    //! invalid one if none
    RuleId firstMatch(scope ref const(LogMessage!wchar) item) const
    {
        foreach (ref rule; _rules)
            if (allMatch(rule.conditions, item))
                return rule.id;
        return RuleId.init;
    }
}

// ─── Tests ──────────────────────────────────────────────────────────────────

version (unittest)
{
    import log_core.log_level : LogLevel;

    private static immutable ColumnInfo[] testColumns = [
        ColumnInfo("time", "Time", ColumnKind.Time),
        ColumnInfo("tag", "Tag", ColumnKind.Text, 0),
        ColumnInfo("pid", "PID", ColumnKind.Integer, 1),
        ColumnInfo("id", "ID", ColumnKind.Hex, 2),
        ColumnInfo("type", "Type", ColumnKind.Enum, 3, TimeKind.None, 0, ["LOG", "CTRL"]),
        ColumnInfo("level", "Level", ColumnKind.Level),
        ColumnInfo("payload", "Message", ColumnKind.Payload),
    ];

    private struct Record
    {
        string tag = "Tag";
        long pid = 1;
        long id = 2;
        long type = 0;
        LogLevel level = LogLevel.Info;
        string text = "text";
    }

    private void make(ref LogMessage!wchar msg, Record r)
    {
        msg.beginRecord();
        msg.setText(0, r.tag);
        msg.setNumber(1, r.pid);
        msg.setNumber(2, r.id);
        msg.setNumber(3, r.type);
        msg.level = r.level;
        auto builder = msg.payloadBuilder();
        builder.appendUtf8(r.text);
        builder.storePayload();
    }

    private Condition text(string columnId, Check check, string value, bool ignoreCase = false)
    {
        Condition c;
        c.columnId = columnId;
        c.check = check;
        c.text = value;
        c.ignoreCase = ignoreCase;
        return c;
    }

    private Condition number(string columnId, Check check, long min, long max = 0)
    {
        Condition c;
        c.columnId = columnId;
        c.check = check;
        c.min = min;
        c.max = max;
        return c;
    }

    private FilterRule rule(RuleKind kind, Condition[] conditions...)
    {
        FilterRule r;
        r.kind = kind;
        r.conditions = conditions.dup;
        return r;
    }

    private RuleFilter compileRules(FilterRule[] rules...)
    {
        FilterSet set;
        set.rules = rules.dup;
        return RuleFilter.compile(testColumns, [set]);
    }

    //! Whether a single include rule of `c` matches the record `r`
    private bool conditionMatches(Condition c, Record r)
    {
        LogMessage!wchar msg;
        make(msg, r);
        auto filter = compileRules(rule(RuleKind.Include, c));
        assert(filter !is null, "the condition compiles");
        return filter.matches(msg);
    }
}

@("RuleFilter: a text condition: the whole text, a substring or a regex, in any case if asked")
unittest
{
    assert(conditionMatches(text("tag", Check.Equals, "Tag"), Record()));
    assert(!conditionMatches(text("tag", Check.Equals, "Ta"), Record()), "not a substring");
    assert(!conditionMatches(text("tag", Check.Equals, "tag"), Record()));
    assert(conditionMatches(text("tag", Check.Equals, "tag", true), Record()));

    assert(conditionMatches(text("tag", Check.Contains, "a"), Record()));
    assert(!conditionMatches(text("tag", Check.Contains, "TA"), Record()));
    assert(conditionMatches(text("tag", Check.Contains, "TA", true), Record()));

    assert(conditionMatches(text("tag", Check.Regex, "^T.g$"), Record()));
    assert(!conditionMatches(text("tag", Check.Regex, "^t"), Record()));
    assert(conditionMatches(text("tag", Check.Regex, "^t", true), Record()));
}

@("RuleFilter: a record without the field of a condition doesn't match it")
unittest
{
    LogMessage!wchar msg;
    msg.beginRecord(); // no fields
    auto filter = compileRules(rule(RuleKind.Include, text("tag", Check.Contains, "")));
    assert(!filter.matches(msg));
}

@("RuleFilter: the payload is matched as a text")
unittest
{
    Record r;
    r.text = "Engine started with an error";
    assert(conditionMatches(text("payload", Check.Contains, "with an"), r));
    assert(!conditionMatches(text("payload", Check.Contains, "ERROR"), r));
    assert(conditionMatches(text("payload", Check.Contains, "ERROR", true), r));
    assert(conditionMatches(text("payload", Check.Regex, "st.*err"), r));
    assert(!conditionMatches(text("payload", Check.Equals, "Engine"), r));
}

@("RuleFilter: number columns take a value or a range, enums a label in any case")
unittest
{
    Record r;
    r.pid = 1234;
    r.id = 0x1F;
    r.type = 1;
    assert(conditionMatches(text("pid", Check.Equals, "1234"), r));
    assert(!conditionMatches(text("pid", Check.Equals, "123"), r));
    assert(conditionMatches(number("pid", Check.Range, 1000, 1234), r), "inclusive");
    assert(!conditionMatches(number("pid", Check.Range, 1235, 2000), r));
    assert(conditionMatches(text("id", Check.Equals, "1F"), r));
    assert(conditionMatches(text("type", Check.Equals, "ctrl"), r));
    assert(!conditionMatches(text("type", Check.Equals, "LOG"), r));
}

@("RuleFilter: a number column takes its value as text too, in hex for a hex column")
unittest
{
    Record r;
    r.pid = 1234;
    r.id = 0x1F;
    assert(conditionMatches(text("pid", Check.Equals, "1234"), r));
    assert(conditionMatches(text("id", Check.Equals, "1F"), r));
    assert(conditionMatches(text("id", Check.Equals, "0x1f"), r));
    assert(!conditionMatches(text("id", Check.Equals, "20"), r));

    FilterRule bad;
    bad.conditions = [text("pid", Check.Equals, "12x")];
    assert(!ruleError(testColumns, bad).empty, "not a number");
    bad.conditions = [text("pid", Check.Equals, "")];
    assert(!ruleError(testColumns, bad).empty, "no number at all");
    bad.conditions = [text("id", Check.Equals, "0x")];
    assert(!ruleError(testColumns, bad).empty, "no hex digits either");
    bad.conditions = [text("level", Check.Equals, "loud")];
    assert(!ruleError(testColumns, bad).empty, "not a level");
}

@("RuleFilter: a level range, a record without a level is out of any")
unittest
{
    Record r;
    r.level = LogLevel.Warn;
    assert(conditionMatches(number("level", Check.Range, LogLevel.Fatal, LogLevel.Warn), r));
    assert(!conditionMatches(number("level", Check.Range, LogLevel.Info, LogLevel.Verbose), r));
    assert(conditionMatches(text("level", Check.Equals, "warn"), r), "a level by its name");
    assert(conditionMatches(text("level", Check.Equals, "3"), r), "or its number");
    r.level = LogLevel.None;
    assert(!conditionMatches(number("level", Check.Range, LogLevel.Fatal, LogLevel.Verbose), r));
}

@("ruleError: a range that is empty, its minimum above its maximum, says so")
unittest
{
    import std.algorithm.searching : canFind;

    FilterRule r;
    r.conditions = [number("level", Check.Range, LogLevel.Verbose, LogLevel.Error)];
    assert(english(ruleError(testColumns, r)).canFind("empty"));
    r.conditions = [number("pid", Check.Range, 10, 5)];
    assert(english(ruleError(testColumns, r)).canFind("empty"));
    r.conditions = [number("pid", Check.Range, 5, 5)];
    assert(ruleError(testColumns, r).empty);
}

@("conditionErrors: what is wrong with each condition, \"\" for the right ones")
unittest
{
    import std.algorithm.searching : canFind;

    FilterRule r;
    r.conditions = [text("tag", Check.Equals, "A"), number("level", Check.Range, LogLevel.Verbose, LogLevel.Error),
        text("payload", Check.Regex, "(unclosed"), text("nope", Check.Equals, "x")];
    const errors = conditionErrors(testColumns, r);
    assert(errors.length == 4);
    assert(errors[0].empty && english(errors[1]).canFind("empty") && !errors[2].empty && english(errors[3]).canFind("nope"));
}

@("parseNumberText: decimal, hex with 0x or in a hex column, nothing else")
unittest
{
    import std.exception : assertThrown;

    assert(parseNumberText("12", false) == 12);
    assert(parseNumberText(" 0x1f ", false) == 0x1F);
    assert(parseNumberText("1F", true) == 0x1F);
    assert(parseNumberText("FFFFFFFFFFFFFFFF", true) == -1, "the 64 bits of an ID");
    assertThrown(parseNumberText("", false));
    assertThrown(parseNumberText("0x", false));
    assertThrown(parseNumberText("1F", false));
}

@("RuleFilter: a rule needs all its conditions, a rule without any matches every record")
unittest
{
    assert(conditionMatches(text("tag", Check.Equals, "Tag"), Record()));
    LogMessage!wchar msg;
    make(msg, Record());
    auto both = compileRules(rule(RuleKind.Include,
            text("tag", Check.Equals, "Tag"), text("pid", Check.Equals, "1")));
    assert(both.matches(msg));
    auto one = compileRules(rule(RuleKind.Include,
            text("tag", Check.Equals, "Tag"), text("pid", Check.Equals, "2")));
    assert(!one.matches(msg));
    assert(compileRules(rule(RuleKind.Include)).matches(msg));
}

@("RuleFilter: shown if an include rule matches, or there is none, and no exclude rule does")
unittest
{
    LogMessage!wchar a, b, c;
    make(a, Record("A"));
    make(b, Record("B"));
    make(c, Record("C"));
    auto isA = text("tag", Check.Equals, "A");
    auto isB = text("tag", Check.Equals, "B");

    auto includes = compileRules(rule(RuleKind.Include, isA), rule(RuleKind.Include, isB));
    assert(includes.matches(a) && includes.matches(b) && !includes.matches(c));
    assert(includes.matchIndex(a) == 0 && includes.matchIndex(b) == 1);
    assert(includes.matchIndex(c).isNull);

    auto excludes = compileRules(rule(RuleKind.Exclude, isA));
    assert(!excludes.matches(a) && excludes.matches(b) && excludes.matches(c),
        "no include rule: all but the excluded");

    auto both = compileRules(rule(RuleKind.Include, isA), rule(RuleKind.Include, isB),
        rule(RuleKind.Exclude, isB));
    assert(both.matches(a) && !both.matches(b) && !both.matches(c), "exclude wins");
}

@("RuleFilter: marker rules, disabled rules and disabled sets don't filter")
unittest
{
    LogMessage!wchar a, b;
    make(a, Record("A"));
    make(b, Record("B"));
    auto isA = text("tag", Check.Equals, "A");

    assert(compileRules(rule(RuleKind.Marker, isA)) is null, "nothing to filter with");

    auto disabled = rule(RuleKind.Include, isA);
    disabled.enabled = false;
    assert(compileRules(disabled) is null);
    auto filter = compileRules(disabled, rule(RuleKind.Exclude, isA));
    assert(!filter.matches(a) && filter.matches(b));

    FilterSet off;
    off.enabled = false;
    off.rules = [rule(RuleKind.Include, isA)];
    FilterSet on;
    on.rules = [rule(RuleKind.Exclude, text("tag", Check.Equals, "B"))];
    filter = RuleFilter.compile(testColumns, [off, on]);
    assert(filter.matches(a) && !filter.matches(b), "only the rules of enabled sets");
}

@("RuleFilter: the rules of all enabled sets are applied together")
unittest
{
    LogMessage!wchar a, b, c;
    make(a, Record("A"));
    make(b, Record("B"));
    make(c, Record("C"));
    FilterSet first, second;
    first.rules = [rule(RuleKind.Include, text("tag", Check.Equals, "A"))];
    second.rules = [rule(RuleKind.Include, text("tag", Check.Equals, "B"))];
    auto filter = RuleFilter.compile(testColumns, [first, second]);
    assert(filter.matches(a) && filter.matches(b) && !filter.matches(c));
}

@("ruleError: names what can't be applied, and such rules are skipped")
unittest
{
    import std.algorithm.searching : canFind;

    string errorOf(FilterRule r)
    {
        return english(ruleError(testColumns, r));
    }

    assert(errorOf(rule(RuleKind.Include, text("tag", Check.Equals, "A"))) == "");
    assert(errorOf(rule(RuleKind.Include)) == "");
    assert(errorOf(rule(RuleKind.Include, text("nope", Check.Equals, "A"))).canFind("nope"));
    assert(errorOf(rule(RuleKind.Include, text("time", Check.Equals, "1"))).length,
        "time can't be filtered");
    assert(errorOf(rule(RuleKind.Include, text("tag", Check.Regex, "(unclosed"))).length);
    assert(errorOf(rule(RuleKind.Include, text("type", Check.Equals, "APP"))).canFind("APP"));
    assert(errorOf(rule(RuleKind.Include, number("tag", Check.Range, 1, 2))).length,
        "no range of texts");
    assert(errorOf(rule(RuleKind.Include, text("pid", Check.Contains, "1"))).length,
        "no substring of numbers");

    LogMessage!wchar a, b;
    make(a, Record("A"));
    make(b, Record("B"));
    auto filter = compileRules(rule(RuleKind.Include, text("tag", Check.Regex, "(unclosed")),
        rule(RuleKind.Exclude, text("tag", Check.Equals, "A")));
    assert(!filter.matches(a) && filter.matches(b), "only the exclude rule is applied");
}

@("RuleFilter: a copy matches like the original")
unittest
{
    LogMessage!wchar a, b;
    make(a, Record("A"));
    make(b, Record("B"));
    auto filter = compileRules(rule(RuleKind.Include, text("tag", Check.Regex, "^A")));
    assert(filter.dup().matches(a) && !filter.dup().matches(b));
    assert(filter.idup().matches(a) && !filter.idup().matches(b));
}

@("isRuleColor: only #rrggbb")
unittest
{
    assert(isRuleColor("#ff0000") && isRuleColor("#00FF7f"));
    assert(!isRuleColor("") && !isRuleColor("red") && !isRuleColor("#f00"));
    assert(!isRuleColor("#ff00000") && !isRuleColor("#ff00g0") && !isRuleColor("#ff0000;"));
}

@("RuleFilter: a substring beyond ASCII, in any case if asked")
unittest
{
    Record r;
    r.text = "Ошибка: Größe 😀 überschritten";
    assert(conditionMatches(text("payload", Check.Contains, "Größe 😀"), r));
    assert(!conditionMatches(text("payload", Check.Contains, "größe"), r), "the case counts");
    assert(conditionMatches(text("payload", Check.Contains, "ОШИБКА: GRÖ", true), r));
    assert(conditionMatches(text("payload", Check.Contains, "😀 ÜBER", true), r));
    assert(!conditionMatches(text("payload", Check.Contains, "😁", true), r));

    r.text = "temperature 300 \u212A, Hot";
    assert(conditionMatches(text("payload", Check.Contains, "300 k", true), r),
        "the Kelvin sign is a K in lower case");
    assert(conditionMatches(text("payload", Check.Contains, "k, hOT", true), r));
    assert(conditionMatches(text("payload", Check.Contains, "", true), r), "an empty text is in any");
    assert(!conditionMatches(text("payload", Check.Contains, "hot!", true), r), "longer than what is left");
}

@("RuleFilter: in any case, the first letter is compared as the others")
unittest
{
    Record r;
    r.text = "Id";
    assert(!conditionMatches(text("payload", Check.Contains, "ıd", true), r),
        "the dotless i is I in upper case, but I is i in lower case");
    assert(conditionMatches(text("payload", Check.Contains, "id", true), r));
    r.text = "Sun";
    assert(!conditionMatches(text("payload", Check.Contains, "ſun", true), r), "the long s");
}

@("RuleFilter: in any case, beyond the BMP")
unittest
{
    Record r;
    r.text = "word \U00010400 here"; // DESERET CAPITAL LETTER LONG I
    assert(conditionMatches(text("payload", Check.Contains, "\U00010428 HERE", true), r),
        "its small letter, in any case");
    assert(!conditionMatches(text("payload", Check.Contains, "\U00010428", false), r), "the case counts");
}

@("RuleIdGenerator: every id is new and valid; the default one is not")
unittest
{
    RuleIdGenerator ids;
    const a = ids.popId(), b = ids.popId();
    assert(a.isValid() && b.isValid() && a != b);
    assert(!RuleId.init.isValid());
}

@("RuleMatcher: the first matching rule that has a color, of any kind")
unittest
{
    LogMessage!wchar a, b, c;
    make(a, Record("A"));
    make(b, Record("B", 7));
    make(c, Record("C"));
    auto isA = text("tag", Check.Equals, "A");

    auto plainA = rule(RuleKind.Include, isA); // matches first, but without a color
    plainA.id = RuleId(1);
    auto markA = rule(RuleKind.Marker, isA);
    markA.id = RuleId(2);
    markA.color = "#ff0000";
    auto pid7 = rule(RuleKind.Exclude, text("pid", Check.Equals, "7"));
    pid7.id = RuleId(3);
    pid7.color = "#0000ff";
    auto all = rule(RuleKind.Include);
    all.id = RuleId(4);
    all.color = "#00ff00";
    auto invalid = rule(RuleKind.Include, isA);
    invalid.id = RuleId(5);
    invalid.color = "red"; // not #rrggbb: as none

    FilterSet first, second;
    first.rules = [invalid, plainA, markA];
    second.rules = [pid7, all];
    auto matcher = RuleMatcher.compile(testColumns, [first, second]);
    assert(matcher !is null);
    assert(matcher.firstMatch(a) == RuleId(2), "the rules without a color are passed by");
    assert(matcher.firstMatch(b) == RuleId(3), "an exclude rule, across the sets");
    assert(matcher.firstMatch(c) == RuleId(4), "a rule without conditions matches every record");

    second.rules = [pid7];
    matcher = RuleMatcher.compile(testColumns, [first, second]);
    assert(!matcher.firstMatch(c).isValid(), "no rule matches");
}

@("RuleMatcher: disabled rules and sets, rules with an error don't match")
unittest
{
    LogMessage!wchar a;
    make(a, Record("A"));
    FilterRule numbered(uint id, Condition[] conditions...)
    {
        auto r = rule(RuleKind.Marker, conditions);
        r.id = RuleId(id);
        r.color = "#ff0000";
        return r;
    }

    FilterSet set;
    assert(RuleMatcher.compile(testColumns, [set]) is null, "no rules");
    set.rules = [rule(RuleKind.Marker)];
    assert(RuleMatcher.compile(testColumns, [set]) is null, "no rule with a color");

    auto disabled = numbered(1);
    disabled.enabled = false;
    auto withError = numbered(2, text("nope", Check.Equals, "A"));
    set.rules = [disabled, withError];
    assert(RuleMatcher.compile(testColumns, [set]) is null, "no rule can be matched");

    set.rules = [numbered(4)];
    set.enabled = false;
    assert(RuleMatcher.compile(testColumns, [set]) is null, "a disabled set");
    set.enabled = true;
    assert(RuleMatcher.compile(testColumns, [set]).firstMatch(a) == RuleId(4));
}

@("ruleError, conditionErrors: what is wrong is a text for the user, its parameters apart")
unittest
{
    import utils.ui_text : english;

    FilterRule r;
    r.conditions = [Condition("nosuch", Check.Equals, "x")];
    const error = ruleError(testColumns, r);
    assert(error.text == "no column \"{column}\" in this log");
    assert(english(error) == "no column \"nosuch\" in this log");
    assert(conditionErrors(testColumns, r)[0] == error);
}
