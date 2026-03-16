module domain.search_filter;

import dlt_core.log_filter;
import dlt_core.decoded_message;

import std.typecons : Nullable;

final class SearchFilter : LogFilter!wchar
{
    private enum CompareType
    {
        CaseSensetive,
        CaseInsensetive,
        Regex,
    }

    private static struct Record
    {
        const(wchar)[] pattern;
        CompareType compareType;
    }

    alias Message = DecodedMessage!wchar;

    private Record[] _rules;

    this()
    {
    }

    this(const typeof(this) other) pure
    {
        _rules = other._rules.dup();
    }

    private static bool matches(scope ref const(Record) record, scope ref const(Message) msg)
    {
        import std.regex;
        import std.algorithm : canFind;
        import std.string : CaseSensitive, indexOf;

        final switch (record.compareType)
        {
        case SearchFilter.CompareType.CaseSensetive:
            return msg.payloadText.indexOf(record.pattern, CaseSensitive.yes) != -1;
        case SearchFilter.CompareType.CaseInsensetive:
            return msg.payloadText.indexOf(record.pattern, CaseSensitive.no) != -1;
        case SearchFilter.CompareType.Regex:
            return !matchFirst(msg.payloadText, record.pattern).empty;
        }

        return false;
    }

    private void addRule(const(wchar)[] pattern, const CompareType ct)
    {
        _rules ~= Record(pattern, ct);
    }

    private void addRule(const(char)[] patternUtf8, const CompareType ct)
    {
        import std.utf : toUTF16;

        addRule(patternUtf8.toUTF16(), ct);
    }

    void addRegex(const(wchar)[] pattern)
    {
        addRule(pattern, CompareType.Regex);
    }

    void addRegex(const(char)[] patternUtf8)
    {
        addRule(patternUtf8, CompareType.Regex);
    }

    void addCaseInsensetive(const(wchar)[] pattern)
    {
        addRule(pattern, CompareType.CaseInsensetive);
    }

    void addCaseInsensetive(const(char)[] patternUtf8)
    {
        addRule(patternUtf8, CompareType.CaseInsensetive);
    }

    void addCaseSensetive(const(wchar)[] pattern)
    {
        addRule(pattern, CompareType.CaseSensetive);
    }

    void addCaseSensetive(const(char)[] patternUtf8)
    {
        addRule(patternUtf8, CompareType.CaseSensetive);
    }

    // implement LogFilter
    bool matches(scope ref const(Message) item) const
    {
        return !matchIndex(item).isNull;
    }

    //! Scan all of rules and return index of first matched record or Nullable.init if no match
    Nullable!uint matchIndex(scope ref const(Message) item) const
    {
        foreach (i, const ref r; _rules)
        {
            if (matches(r, item))
                return Nullable!uint(cast(uint) i);
        }

        return Nullable!uint.init;
    }

    immutable(LogFilter!CharType) idup() const pure
    {
        return cast(immutable) dup();
    }

    LogFilter!CharType dup() const pure
    {
        return new SearchFilter(this);
    }
}
