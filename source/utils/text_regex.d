//! Regular expressions over UTF-16 texts: the one module that uses the regex
//! engine (std.regex). The rest of the code sees TextRegex (one expression)
//! and RegexSet (any of several), so the engine can be replaced here alone
//! (docs/backlog.md, docs/experiments/2026-11-10-regex-matcher-cache.md).
module utils.text_regex;

import std.regex : Regex;

//! A regular expression that is not valid; its message says why
class RegexError : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

//! @brief One regular expression, compiled once for many texts.
//! Matching only reads it: one may be used from many threads at once, its
//! copies too (they share the compiled expression).
struct TextRegex
{
    private Regex!wchar _regex;
    private immutable(wchar)[] _pattern;
    private bool _ignoreCase;

    //! @throws RegexError if `pattern` is not a valid regular expression
    this(const(wchar)[] pattern, bool ignoreCase)
    {
        _pattern = pattern.idup;
        _ignoreCase = ignoreCase;
        _regex = compile(_pattern, ignoreCase ? "i" : "");
    }

    //! @return true if the expression matches somewhere in `text`
    bool foundIn(const(wchar)[] text) const
    {
        import std.regex : matchFirst;

        return !matchFirst(text, _regex).empty;
    }

    //! @brief Calls `sink(start, end)` for each match in `text`, in order and
    //! not overlapping, empty ones too, until it returns false.
    void forEachMatch(const(wchar)[] text, scope bool delegate(size_t start, size_t end) sink) const
    {
        import std.regex : matchAll;

        foreach (m; matchAll(text, _regex))
        {
            const start = m.pre.length;
            if (!sink(start, start + m.hit.length))
                return;
        }
    }
}

//! @brief Tells whether any of several expressions matches a text, in one
//! pass where it can: std.regex keeps one matcher per thread, so expressions
//! tried by turns on each text rebuild it every time, under the GC lock.
//! Expressions are joined into one alternation, each with its own case;
//! the ones that can't be joined (inline flags, back-references, a join that
//! doesn't compile) are tried apart: next to the joined ones they alternate
//! again on each text. Matching only reads it: one may be used from many
//! threads at once, its copies too.
struct RegexSet
{
    private Regex!wchar _join; // the joined expressions, if _joined
    private bool _joined;
    private const(TextRegex)[] _apart; // tried one by one

    //! @param all - the expressions; none: the set matches nothing
    this(const(TextRegex)[] all)
    {
        import std.array : appender;

        const(TextRegex)[] joinable;
        foreach (ref one; all)
        {
            if (canJoin(one._pattern))
                joinable ~= one;
            else
                _apart ~= one;
        }
        if (joinable.length < 2)
        {
            _apart ~= joinable;
            return;
        }
        // An inline flag holds to the end of the expression, not of its group:
        // each alternative sets its case
        auto text = appender!(wchar[]);
        foreach (i, ref one; joinable)
        {
            if (i > 0)
                text ~= "|";
            text ~= one._ignoreCase ? "(?:(?i)"w : "(?:(?-i)"w;
            text ~= one._pattern;
            text ~= ")";
        }
        try
        {
            _join = compile(text[].idup, "");
            _joined = true;
        }
        catch (RegexError) // e.g. a group name used twice
            _apart ~= joinable;
    }

    //! @return true if any of the expressions matches somewhere in `text`
    bool foundIn(const(wchar)[] text) const
    {
        import std.regex : matchFirst;

        if (_joined && !matchFirst(text, _join).empty)
            return true;
        foreach (ref one; _apart)
            if (one.foundIn(text))
                return true;
        return false;
    }
}

//! @throws RegexError if `pattern` is not valid
private Regex!wchar compile(immutable(wchar)[] pattern, const(char)[] flags)
{
    import std.regex : regex, RegexException;

    try
        return regex(pattern, flags);
    catch (RegexException e)
        throw new RegexError(e.msg);
}

//! @return false if `pattern` changes its flags inline (they would hold for
//!   the expressions after it) or refers to its groups by number (the numbers
//!   change in a join)
private bool canJoin(const(wchar)[] pattern) pure nothrow @nogc
{
    for (size_t i = 0; i + 1 < pattern.length; ++i)
    {
        const next = pattern[i + 1];
        if (pattern[i] == '\\')
        {
            if ((next >= '1' && next <= '9') || next == 'k')
                return false;
            ++i; // the escaped unit
        }
        else if (pattern[i] == '(' && next == '?' && i + 2 < pattern.length)
        {
            const flag = pattern[i + 2];
            if (flag == 'i' || flag == 'm' || flag == 's' || flag == 'x' || flag == '-')
                return false;
        }
    }
    return true;
}

version (unittest)
{
    private TextRegex re(wstring pattern, bool ignoreCase = false)
    {
        return TextRegex(pattern, ignoreCase);
    }
}

@("TextRegex: found with and without case")
unittest
{
    assert(re(`time\w+ \d+`).foundIn("a timeout 30s"w));
    assert(!re(`^timeout`).foundIn("a timeout"w), "anchors work");
    assert(!re(`Timeout`).foundIn("a timeout"w), "in its case by default");
    assert(re(`Timeout`, true).foundIn("a TIMEOUT"w));
    assert(re(`ошибка`, true).foundIn("ОШИБКА"w), "beyond ASCII");
}

@("TextRegex: an invalid expression is an error that says why")
unittest
{
    import std.exception : collectException;

    auto e = collectException!RegexError(re(`(unclosed`));
    assert(e !is null && e.msg.length > 0);
    assert(collectException!RegexError(re(`[a-`, true)) !is null);
}

@("TextRegex: every match, in order, until the sink stops")
unittest
{
    size_t[2][] all;
    re(`a+`).forEachMatch("xaayax"w, (size_t start, size_t end) { all ~= [start, end]; return true; });
    assert(all == [[1, 3], [4, 5]]);

    all = null;
    re(`a`).forEachMatch("aaa"w, (size_t start, size_t end) { all ~= [start, end]; return all.length < 2; });
    assert(all == [[0, 1], [1, 2]], "stops when the sink says so");
}

@("RegexSet: found if any expression is, each in its own case")
unittest
{
    // Expressions that can be joined, ones that can't, and texts to try them on
    const patterns = [
        re(`err\w+ \d`), re(`FAIL`, true), re(`^start`), re(`end$`, true), re(`(?=.*a)(?!.*b)x`),
        re(`a|b`), re(`(?i)mixed`), re(`(a)\1`), re(`(?P<n>q)`), re(`(?P<n>z)`), re(`Case`),
        re(`ж+`, true),
    ];
    const texts = ["error 1"w, "a fail"w, "fail"w, "the start"w, "start"w, "THE END"w, "end x"w,
        "xa"w, "xab"w, "b"w, "MIXED"w, "aa"w, "q"w, "z"w, "case"w, "Case"w, "ЖЖ"w, ""w, "nothing"w];

    // Every subset of up to three expressions: the set is found as one of them is
    foreach (i; 0 .. patterns.length)
        foreach (j; i .. patterns.length)
            foreach (k; j .. patterns.length)
            {
                const chosen = [patterns[i], patterns[j], patterns[k]];
                const set = RegexSet(chosen);
                foreach (text; texts)
                {
                    bool any = false;
                    foreach (ref one; chosen)
                        any = any || one.foundIn(text);
                    assert(set.foundIn(text) == any);
                }
            }
    assert(!RegexSet(null).foundIn("anything"w), "no expression matches nothing");
}

@("RegexSet: expressions without inline flags or back-references are tried as one")
unittest
{
    const set = RegexSet([re(`err\w+`), re(`FAIL`, true), re(`(?i)x`), re(`(a)\1`), re(`b`)]);
    assert(set._joined, "the plain ones are joined");
    assert(set._apart.length == 2, "the others are tried apart");
}
