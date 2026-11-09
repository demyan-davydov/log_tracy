module log_core.search_filter;

import log_core.log_filter;
import log_core.log_message;

import std.regex : Regex, regex, matchFirst;
import utils.text_search : TextPattern;
import std.typecons : Nullable;

//! One condition of a search query (a chip of the search editor): a text or a
//! regular expression to find in the payload, with its own letter case.
struct SearchChip
{
    string text;
    bool isRegex;
    bool ignoreCase;
}

//! A fragment of the payload a chip found: [start, end) in UTF-16 code units of
//! the payload, `chip` is the place of the chip in the query (empty chips counted)
struct MatchRange
{
    uint start;
    uint end;
    uint chip;
}

//! @brief The most fragments of one payload shown highlighted, in the rows of
//! both tables. A payload with more matches shows the first ones in the order
//! of the chips (see SearchFilter.matchRanges) and the rest of it plain: this
//! bounds the work and the cell sent to the script for a row with thousands of
//! matches. Nothing else depends on the number: the script shows as many as
//! the row has, so it can be changed here alone (MatchBuffer follows it).
//! matchRanges itself has no limit of its own, the length of the buffer it is
//! given is: another use may pass a buffer of any size.
enum maxMatchRanges = 20;

//! The fragments of one payload: a caller keeps one (on the stack) and lets
//! SearchFilter.matchRanges write into it, so finding them allocates nothing
alias MatchBuffer = MatchRange[maxMatchRanges];

//! @brief Checks a regular expression of a chip with the engine the search uses.
//! @return the error message, "" for a valid one
string checkRegex(const(char)[] pattern, bool ignoreCase)
{
    try
    {
        new SearchFilter().addRegex(pattern, ignoreCase);
        return "";
    }
    catch (Exception e)
        return e.msg;
}

//! Search over the message payload. A message matches if any rule matches.
final class SearchFilter : LogFilter!wchar
{
    private static struct Rule
    {
        TextPattern text; // plain text rule
        Regex!wchar regex; // regex rule, compiled once when the rule is added
        bool isRegex;
        uint chip; // the place of its chip in the query
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

    //! @brief Builds the filter for the chips of a query: a message matches if any
    //! chip does. Empty chips are skipped.
    //! @return null if no chip is left, which means "no search"
    //! @throws RegexException if a regex chip is not a valid regular expression
    static SearchFilter fromChips(const(SearchChip)[] chips)
    {
        auto filter = new SearchFilter();
        foreach (i, const ref chip; chips)
        {
            if (chip.text.length == 0)
                continue;
            if (chip.isRegex)
                filter.addRegex(chip.text, chip.ignoreCase);
            else
                filter.addText(chip.text, chip.ignoreCase);
            filter._rules[$ - 1].chip = cast(uint) i;
        }
        return filter._rules.length ? filter : null;
    }

    //! @brief Adds a rule matching payloads that contain `text`.
    void addText(const(char)[] textUtf8, bool caseInsensitive)
    {
        import std.utf : toUTF16;

        Rule rule;
        rule.text = TextPattern(textUtf8.toUTF16(), caseInsensitive);
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
        _rules ~= rule;
    }

    private static bool matches(scope ref const(Rule) rule, scope ref const(Message) msg)
    {
        if (rule.isRegex)
            return !matchFirst(msg.payloadText, rule.regex).empty;
        return rule.text.foundIn(msg.payloadText);
    }

    //! @brief The fragments of the payload of `msg` the chips found, to show them:
    //! the chips in their order, each over the whole payload; the part of a match
    //! already found by an earlier chip is left out, the rest of it is kept.
    //! Empty matches are skipped. Allocates nothing for text chips (a regex
    //! chip's matcher may).
    //! @param buffer - where the fragments are written (usually a MatchBuffer);
    //! its length is the most fragments: once it is full the chips left and the
    //! matches left are not looked for, so it holds the first ones in the order
    //! of the chips. That is not an error: the rest of the payload is shown plain.
    //! @return the fragments by their start: the start of `buffer`
    MatchRange[] matchRanges(scope ref const(Message) msg, return scope MatchRange[] buffer) const
    {
        import std.regex : matchAll;

        size_t count; // buffer[0 .. count], kept by start: they never overlap
        const text = msg.payloadText;

        // Adds the parts of [start, end) no fragment covers yet, each at its place
        // by start (no sort); false once the buffer is full
        bool add(size_t start, size_t end, uint chip)
        {
            size_t from = start, i = 0;
            while (from < end)
            {
                while (i < count && buffer[i].end <= from)
                    i++; // before the part left
                const covering = i < count && buffer[i].start < end;
                const gapEnd = covering ? buffer[i].start : end;
                if (gapEnd > from)
                {
                    foreach_reverse (j; i .. count)
                        buffer[j + 1] = buffer[j]; // room at i: count < buffer.length here
                    buffer[i] = MatchRange(cast(uint) from, cast(uint) gapEnd, chip);
                    i++;
                    if (++count == buffer.length)
                        return false;
                }
                if (!covering)
                    break;
                from = buffer[i].end; // the covered part is the earlier chip's
            }
            return true;
        }

        rules: foreach (const ref rule; _rules)
        {
            if (count == buffer.length)
                break;
            if (rule.isRegex)
            {
                foreach (m; matchAll(text, rule.regex))
                {
                    const start = m.pre.length, end = start + m.hit.length;
                    if (end > start && !add(start, end, rule.chip))
                        break rules;
                }
            }
            else
            {
                if (rule.text.isEmpty)
                    continue; // only empty matches
                size_t end;
                for (ptrdiff_t at = rule.text.find(text, 0, end); at >= 0;
                    at = rule.text.find(text, end, end))
                {
                    if (!add(at, end, rule.chip))
                        break rules;
                }
            }
        }
        return buffer[0 .. count];
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

    /// The fragments matchRanges writes to a buffer of `size`, copied out of it
    private MatchRange[] matchesIn(const SearchFilter filter, ref const(LogMessage!wchar) msg,
        size_t size = maxMatchRanges)
    {
        auto buffer = new MatchRange[size];
        return filter.matchRanges(msg, buffer).dup;
    }
}

@("SearchFilter: a text chip, with and without case")
unittest
{
    auto msg = messageWithPayload("Connection Timeout after 30s");

    assert(SearchFilter.fromChips([SearchChip("Timeout", false, false)]).matches(msg));
    assert(!SearchFilter.fromChips([SearchChip("timeout", false, false)]).matches(msg), "case-sensitive by default");
    assert(SearchFilter.fromChips([SearchChip("timeout", false, true)]).matches(msg));
    assert(!SearchFilter.fromChips([SearchChip("refused", false, true)]).matches(msg));

    // Regex metacharacters are plain text in a text search
    assert(!SearchFilter.fromChips([SearchChip("Time.*", false, false)]).matches(msg));
    assert(SearchFilter.fromChips([SearchChip("30s", false, false)]).matches(msg));
}

@("SearchFilter: a regex chip, with and without case")
unittest
{
    auto msg = messageWithPayload("Connection Timeout after 30s");

    assert(SearchFilter.fromChips([SearchChip(`Time\w+ after \d+s`, true, false)]).matches(msg));
    assert(!SearchFilter.fromChips([SearchChip(`^Timeout`, true, false)]).matches(msg), "anchors work");
    assert(!SearchFilter.fromChips([SearchChip(`timeout`, true, false)]).matches(msg), "case-sensitive by default");
    assert(SearchFilter.fromChips([SearchChip(`timeout`, true, true)]).matches(msg));
    assert(SearchFilter.fromChips([SearchChip(`refused|timeout`, true, true)]).matches(msg));
}

@("SearchFilter: an invalid regex is reported when the filter is built")
unittest
{
    import std.exception : assertThrown;
    import std.regex : RegexException;

    assertThrown!RegexException(SearchFilter.fromChips([SearchChip("(unclosed", true, false)]));
    assert(SearchFilter.fromChips([SearchChip("(unclosed", false, false)]) !is null, "fine as plain text");
}

@("SearchFilter: a chip query matches a message if any chip does")
unittest
{
    auto msg = messageWithPayload("Connection Timeout after 30s");
    const chips = [SearchChip("refused"), SearchChip(`time\w+`, true, true), SearchChip("Conn")];
    auto filter = SearchFilter.fromChips(chips);
    assert(filter.matches(msg));
    assert(filter.matchIndex(msg).get == 1, "the first chip that matches");

    assert(!SearchFilter.fromChips([SearchChip("timeout"), SearchChip("^after", true)]).matches(msg),
        "each chip keeps its own case and type");
    assert(SearchFilter.fromChips([SearchChip("timeout", false, true)]).matches(msg));
    assert(!SearchFilter.fromChips([SearchChip("Time.*")]).matches(msg), "a text chip is plain text");
}

@("SearchFilter: empty chips are skipped, no chips means no search")
unittest
{
    auto msg = messageWithPayload("disk error");
    assert(SearchFilter.fromChips(null) is null);
    assert(SearchFilter.fromChips([SearchChip(""), SearchChip("", true)]) is null);

    auto filter = SearchFilter.fromChips([SearchChip(""), SearchChip("error")]);
    assert(filter.matchIndex(msg).get == 0, "the empty chip is not a rule");
    assert(!SearchFilter.fromChips([SearchChip(""), SearchChip("warning")]).matches(msg),
        "an empty chip doesn't match everything");
    auto spaced = messageWithPayload("a b");
    assert(SearchFilter.fromChips([SearchChip(" ")]).matches(spaced),
        "a chip of spaces is not empty");
}

@("SearchFilter: an invalid regex chip is reported when the filter is built")
unittest
{
    import std.exception : assertThrown;
    import std.regex : RegexException;

    assertThrown!RegexException(SearchFilter.fromChips([SearchChip("ok"), SearchChip("(unclosed", true)]));
}

@("checkRegex: the error of an invalid regex, nothing for a valid one")
unittest
{
    assert(checkRegex(`time(out|d)\s+\d`, false) == "");
    assert(checkRegex(`(?=.*a)(?!.*b)`, true) == "", "lookarounds express AND and NOT");
    assert(checkRegex("(unclosed", false).length > 0);
    assert(checkRegex("[a-", true).length > 0);
}

@("matchRanges: every match of every chip, by its start")
unittest
{
    auto msg = messageWithPayload("error: disk error, net ok");
    const filter = SearchFilter.fromChips([SearchChip("error"), SearchChip(`n\w+`, true)]);
    assert(matchesIn(filter, msg) == [MatchRange(0, 5, 0), MatchRange(12, 17, 0), MatchRange(19, 22, 1)]);
}

@("matchRanges: an earlier chip wins, a later one keeps only what is left")
unittest
{
    auto msg = messageWithPayload("timeout after 30s");
    // "time" first; "timeout" is shown only for "out"; "after 30s" is whole
    const filter = SearchFilter.fromChips([SearchChip("time"), SearchChip("timeout"), SearchChip(`after \d+s`, true)]);
    assert(matchesIn(filter, msg) == [MatchRange(0, 4, 0), MatchRange(4, 7, 1), MatchRange(8, 17, 2)]);

    // a later match covered in the middle is split around it
    const inside = SearchFilter.fromChips([SearchChip("out"), SearchChip("timeout after")]);
    assert(matchesIn(inside, msg) == [MatchRange(0, 4, 1), MatchRange(4, 7, 0), MatchRange(7, 13, 1)]);

    // a later match covered whole is not shown
    const covered = SearchFilter.fromChips([SearchChip("timeout"), SearchChip("time")]);
    assert(matchesIn(covered, msg) == [MatchRange(0, 7, 0)]);
}

@("matchRanges: a regex sees the whole payload, its anchors too")
unittest
{
    auto msg = messageWithPayload("foo bar foo");
    // "bar" is found first; ^foo is still the foo at the start only
    const filter = SearchFilter.fromChips([SearchChip("bar"), SearchChip("^foo", true)]);
    assert(matchesIn(filter, msg) == [MatchRange(0, 3, 1), MatchRange(4, 7, 0)]);
}

@("matchRanges: the case of each chip, empty regex matches skipped")
unittest
{
    auto msg = messageWithPayload("Error ERROR error");
    assert(matchesIn(SearchFilter.fromChips([SearchChip("error", false, true)]), msg)
        == [MatchRange(0, 5, 0), MatchRange(6, 11, 0), MatchRange(12, 17, 0)]);
    assert(matchesIn(SearchFilter.fromChips([SearchChip("error")]), msg) == [MatchRange(12, 17, 0)]);
    assert(matchesIn(SearchFilter.fromChips([SearchChip("x*", true)]), msg).length == 0, "only empty matches");
}

@("matchRanges: the chip is its place in the query, empty chips counted")
unittest
{
    auto msg = messageWithPayload("abc");
    const filter = SearchFilter.fromChips([SearchChip(""), SearchChip("b")]);
    assert(matchesIn(filter, msg) == [MatchRange(1, 2, 1)]);
}

@("matchRanges: as many fragments as the buffer holds, the earlier chips first")
unittest
{
    auto msg = messageWithPayload("a a a b");
    const filter = SearchFilter.fromChips([SearchChip("a"), SearchChip("b")]);
    assert(matchesIn(filter, msg, 2) == [MatchRange(0, 1, 0), MatchRange(2, 3, 0)]);
    assert(matchesIn(filter, msg, 0).length == 0, "no room, nothing found");
    assert(matchesIn(filter, msg).length == 4);

    // a later chip found earlier in the payload is inserted before the rest:
    // what is left out is still the end of the order of the chips
    auto late = messageWithPayload("b a a");
    assert(matchesIn(filter, late, 2) == [MatchRange(2, 3, 0), MatchRange(4, 5, 0)]);
    assert(matchesIn(filter, late, 3) == [MatchRange(0, 1, 1), MatchRange(2, 3, 0), MatchRange(4, 5, 0)]);
}

@("matchRanges: a payload with more matches than maxMatchRanges shows the first of them")
unittest
{
    import std.array : replicate;

    auto msg = messageWithPayload("x ".replicate(maxMatchRanges + 5));
    MatchBuffer buffer;
    const found = SearchFilter.fromChips([SearchChip("x")]).matchRanges(msg, buffer[]);
    assert(found.length == maxMatchRanges);
    assert(found[$ - 1] == MatchRange(2 * (maxMatchRanges - 1), 2 * maxMatchRanges - 1, 0), "the first ones, in order");
    assert(found.ptr == buffer.ptr, "written to the caller's buffer");
}

@("matchRanges: text chips allocate nothing")
unittest
{
    import core.memory : GC;

    auto msg = messageWithPayload("error: disk error, net ok");
    const filter = SearchFilter.fromChips([SearchChip("error"), SearchChip("ok")]);
    MatchBuffer buffer;
    const before = GC.stats().allocatedInCurrentThread;
    const found = filter.matchRanges(msg, buffer[]);
    assert(GC.stats().allocatedInCurrentThread == before, "no GC memory");
    assert(found.length == 3);
}

@("matchRanges: positions in UTF-16 code units, as the script counts them")
unittest
{
    LogMessage!wchar wide;
    wide.beginRecord();
    auto builder = wide.payloadBuilder();
    builder.appendUtf8("щит 😀 ok");
    builder.storePayload();
    // "щит " is 4 units, the emoji 2, then a space
    assert(matchesIn(SearchFilter.fromChips([SearchChip("ok")]), wide) == [MatchRange(7, 9, 0)]);
}

@("SearchFilter: dup keeps the rules")
unittest
{
    auto msg = messageWithPayload("disk error");
    const filter = SearchFilter.fromChips([SearchChip("ERROR", true, true)]);
    assert(filter.dup().matches(msg));
}

@("matchRanges: an empty text rule finds nothing")
unittest
{
    auto filter = new SearchFilter();
    filter.addText("", true);
    filter.addText("b", false);
    auto msg = messageWithPayload("abc");
    assert(matchesIn(filter, msg) == [MatchRange(1, 2, 0)]); // added without a chip
}
