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
import std.algorithm.searching : canFind, countUntil;
import std.array : array;
import std.format : format;
import std.regex : matchFirst, regex, Regex;
import std.typecons : Nullable;
import std.uni : icmp, toLower;
import std.utf : toUTF16;

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
    Equals, // text: the whole text (ignoreCase); number: min; enum: the label in `text`
    Contains, // text: a substring (ignoreCase)
    Regex, // text: a regular expression found in it (ignoreCase)
    Range, // number or level: min <= value <= max
}

//! A condition on one column of the format
struct Condition
{
    string columnId;
    Check check;
    string text; // Equals on text and enum columns, Contains, Regex
    long min, max; // Equals (min) and Range on numbers and levels
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
    //! Why the rule can't be applied, set by an importer for what the model
    //! can't express (e.g. the header text of a .dlf); "" if it can
    string problem;
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
//! enum label), "" if it can
string ruleError(const(ColumnInfo)[] columns, ref const(FilterRule) rule)
{
    if (rule.problem.length)
        return rule.problem;
    try
    {
        foreach (ref condition; rule.conditions)
            compileCondition(columns, condition);
        return "";
    }
    catch (Exception e)
        return e.msg;
}

//! A condition resolved against the columns of the format
private struct CompiledCondition
{
    ColumnKind kind;
    int field = -1;
    Check check;
    wstring text; // Equals and Contains on texts
    long min, max; // Equals (min) and Range on numbers, levels and enums
    bool ignoreCase;
    Regex!wchar regex;

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
            return ignoreCase
                ? value.canFind!((a, b) => toLower(a) == toLower(b))(text) : value.canFind(text);
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
        throw new Exception(format("no column \"%s\" in this log", condition.columnId));
    const column = &columns[index];

    CompiledCondition compiled;
    compiled.kind = column.kind;
    compiled.field = column.field;
    compiled.check = condition.check;
    compiled.ignoreCase = condition.ignoreCase;

    Exception unsupported()
    {
        return new Exception(format("%s: can't check %s", column.title, condition.check));
    }

    final switch (column.kind)
    {
    case ColumnKind.Time:
        throw new Exception(format("%s: can't be filtered", column.title));
    case ColumnKind.Text:
    case ColumnKind.Payload:
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
            throw new Exception(format("%s: unknown value \"%s\", expected one of %-(%s, %)",
                column.title, condition.text, column.labels));
        compiled.min = compiled.max = label;
        break;
    case ColumnKind.Level:
    case ColumnKind.Integer:
    case ColumnKind.Hex:
    case ColumnKind.Duration:
        if (condition.check == Check.Equals)
            compiled.min = compiled.max = condition.min;
        else if (condition.check == Check.Range)
        {
            compiled.min = condition.min;
            compiled.max = condition.max;
        }
        else
            throw unsupported();
        break;
    }
    return compiled;
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
        foreach (ref set; sets)
        {
            if (!set.enabled)
                continue;
            foreach (ref rule; set.rules)
            {
                if (!rule.enabled || rule.kind == RuleKind.Marker || rule.problem.length)
                    continue;
                Rule compiled;
                try
                    foreach (ref condition; rule.conditions)
                        compiled ~= compileCondition(columns, condition);
                catch (Exception)
                    continue; // see ruleError
                if (rule.kind == RuleKind.Include)
                    includes ~= compiled;
                else
                    excludes ~= compiled;
            }
        }
        return includes.length || excludes.length ? new RuleFilter(includes, excludes) : null;
    }

    private static bool ruleMatches(const(CompiledCondition)[] rule,
        scope ref const(LogMessage!wchar) item)
    {
        foreach (ref condition; rule)
            if (!condition.matches(item))
                return false;
        return true;
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
            if (ruleMatches(rule, item))
            {
                found = cast(uint) i;
                break;
            }
        if (found.isNull)
            return found;
        foreach (rule; _excludes)
            if (ruleMatches(rule, item))
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

// ─── Tests ──────────────────────────────────────────────────────────────────

version (unittest)
{
    import log_core.log_level : LogLevel;

    private static immutable ColumnInfo[] testColumns = [
        ColumnInfo("time", "Time", ColumnKind.Time),
        ColumnInfo("tag", "Tag", ColumnKind.Text, 0),
        ColumnInfo("pid", "PID", ColumnKind.Integer, 1),
        ColumnInfo("id", "ID", ColumnKind.Hex, 2),
        ColumnInfo("type", "Type", ColumnKind.Enum, 3, 0, TimeKind.None, 0, ["LOG", "CTRL"]),
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
    assert(conditionMatches(number("pid", Check.Equals, 1234), r));
    assert(!conditionMatches(number("pid", Check.Equals, 123), r));
    assert(conditionMatches(number("pid", Check.Range, 1000, 1234), r), "inclusive");
    assert(!conditionMatches(number("pid", Check.Range, 1235, 2000), r));
    assert(conditionMatches(number("id", Check.Equals, 0x1F), r));
    assert(conditionMatches(text("type", Check.Equals, "ctrl"), r));
    assert(!conditionMatches(text("type", Check.Equals, "LOG"), r));
}

@("RuleFilter: a level range, a record without a level is out of any")
unittest
{
    Record r;
    r.level = LogLevel.Warn;
    assert(conditionMatches(number("level", Check.Range, LogLevel.Fatal, LogLevel.Warn), r));
    assert(!conditionMatches(number("level", Check.Range, LogLevel.Info, LogLevel.Verbose), r));
    assert(conditionMatches(number("level", Check.Equals, LogLevel.Warn), r));
    r.level = LogLevel.None;
    assert(!conditionMatches(number("level", Check.Range, LogLevel.Fatal, LogLevel.Verbose), r));
}

@("RuleFilter: a rule needs all its conditions, a rule without any matches every record")
unittest
{
    assert(conditionMatches(text("tag", Check.Equals, "Tag"), Record()));
    LogMessage!wchar msg;
    make(msg, Record());
    auto both = compileRules(rule(RuleKind.Include,
            text("tag", Check.Equals, "Tag"), number("pid", Check.Equals, 1)));
    assert(both.matches(msg));
    auto one = compileRules(rule(RuleKind.Include,
            text("tag", Check.Equals, "Tag"), number("pid", Check.Equals, 2)));
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
        return ruleError(testColumns, r);
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

    auto withProblem = rule(RuleKind.Include);
    withProblem.problem = "header text is not supported";
    assert(errorOf(withProblem) == withProblem.problem);

    LogMessage!wchar a, b;
    make(a, Record("A"));
    make(b, Record("B"));
    auto filter = compileRules(rule(RuleKind.Include, text("tag", Check.Regex, "(unclosed")),
        withProblem, rule(RuleKind.Exclude, text("tag", Check.Equals, "A")));
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
