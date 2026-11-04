module domain.search_filter;

import log_core.log_filter;
import log_core.log_message;

import std.regex : Regex, regex, matchFirst;
import std.typecons : Nullable;

//! Search over the message payload. A message matches if any rule matches.
final class SearchFilter : LogFilter!wchar
{
    private static struct Rule
    {
        const(wchar)[] text; // plain text rule
        Regex!wchar regex; // regex rule, compiled once when the rule is added
        bool isRegex;
        bool caseInsensitive;
    }

    alias Message = LogMessage!wchar;

    private Rule[] _rules;

    this()
    {
    }

    this(const typeof(this) other) pure
    {
        import std.algorithm : map;
        import std.array : array;

        // Regex is not const-copyable: copy rule by rule
        _rules = other._rules.map!(r => cast(Rule) r).array;
    }

    //! @brief Builds the filter for a search query typed by the user.
    //! @param query - text to find in the payload, or a regular expression
    //! @param isRegex - treat `query` as a regular expression
    //! @param caseInsensitive - ignore letter case (both for text and regex)
    //! @return null for an empty query, which means "no search"
    //! @throws RegexException if `query` is not a valid regular expression
    static SearchFilter fromQuery(const(char)[] query, bool isRegex, bool caseInsensitive)
    {
        if (query.length == 0)
            return null;

        auto filter = new SearchFilter();
        if (isRegex)
            filter.addRegex(query, caseInsensitive);
        else
            filter.addText(query, caseInsensitive);
        return filter;
    }

    //! @brief Adds a rule matching payloads that contain `text`.
    void addText(const(char)[] textUtf8, bool caseInsensitive)
    {
        import std.utf : toUTF16;

        Rule rule;
        rule.text = textUtf8.toUTF16();
        rule.caseInsensitive = caseInsensitive;
        _rules ~= rule;
    }

    //! @brief Adds a rule matching payloads with a match of `patternUtf8`.
    //! The pattern is compiled here, on the calling thread, so an invalid one
    //! is reported right away instead of failing the background search.
    //! @throws RegexException if the pattern is invalid
    void addRegex(const(char)[] patternUtf8, bool caseInsensitive)
    {
        import std.utf : toUTF16;

        Rule rule;
        rule.regex = regex(patternUtf8.toUTF16(), caseInsensitive ? "i" : "");
        rule.isRegex = true;
        rule.caseInsensitive = caseInsensitive;
        _rules ~= rule;
    }

    private static bool matches(scope ref const(Rule) rule, scope ref const(Message) msg)
    {
        import std.string : CaseSensitive, indexOf;

        if (rule.isRegex)
            return !matchFirst(msg.payloadText, rule.regex).empty;

        const cs = rule.caseInsensitive ? CaseSensitive.no : CaseSensitive.yes;
        return msg.payloadText.indexOf(rule.text, cs) != -1;
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

version (unittest)
{
    private LogMessage!wchar messageWithPayload(string payload)
    {
        LogMessage!wchar msg;
        msg.beginRecord();
        auto builder = msg.payloadBuilder();
        builder.appendAscii(payload);
        builder.storePayload();
        return msg;
    }
}

@("SearchFilter: an empty query means no search")
unittest
{
    assert(SearchFilter.fromQuery("", false, false) is null);
    assert(SearchFilter.fromQuery("", true, true) is null);
}

@("SearchFilter: text search, with and without case")
unittest
{
    auto msg = messageWithPayload("Connection Timeout after 30s");

    assert(SearchFilter.fromQuery("Timeout", false, false).matches(msg));
    assert(!SearchFilter.fromQuery("timeout", false, false).matches(msg), "case-sensitive by default");
    assert(SearchFilter.fromQuery("timeout", false, true).matches(msg));
    assert(!SearchFilter.fromQuery("refused", false, true).matches(msg));

    // Regex metacharacters are plain text in a text search
    assert(!SearchFilter.fromQuery("Time.*", false, false).matches(msg));
    assert(SearchFilter.fromQuery("30s", false, false).matches(msg));
}

@("SearchFilter: regex search, with and without case")
unittest
{
    auto msg = messageWithPayload("Connection Timeout after 30s");

    assert(SearchFilter.fromQuery(`Time\w+ after \d+s`, true, false).matches(msg));
    assert(!SearchFilter.fromQuery(`^Timeout`, true, false).matches(msg), "anchors work");
    assert(!SearchFilter.fromQuery(`timeout`, true, false).matches(msg), "case-sensitive by default");
    assert(SearchFilter.fromQuery(`timeout`, true, true).matches(msg));
    assert(SearchFilter.fromQuery(`refused|timeout`, true, true).matches(msg));
}

@("SearchFilter: an invalid regex is reported when the filter is built")
unittest
{
    import std.exception : assertThrown;
    import std.regex : RegexException;

    assertThrown!RegexException(SearchFilter.fromQuery("(unclosed", true, false));
    assert(SearchFilter.fromQuery("(unclosed", false, false) !is null, "fine as plain text");
}

@("SearchFilter: dup keeps the rules")
unittest
{
    auto msg = messageWithPayload("disk error");
    const filter = SearchFilter.fromQuery("ERROR", true, true);
    assert(filter.dup().matches(msg));
}
