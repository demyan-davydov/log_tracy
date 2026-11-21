//! What a cell of a column consists of: its text may have a head, the part rows are grouped by and shown above them
//! (a date over the rows of its day), and a body, what the cell shows. A column gives its `CellPartsExtractor`
//! (`TableColumn.parts`, `TableColumn.cellParts`); a plain column has `trivialCellParts`, whose body is all of the text. Both parts are slices of
//! the text: nothing is copied or allocated. See docs/backlog.md (the date of the time column over its rows).
module ptable.cellparts;

/// What a cell of a column consists of
interface CellPartsExtractor
{
    /// Whether the cells of the column have heads at all: the rows are grouped by them
    bool hasHead() const pure nothrow @nogc @safe;

    /// The head of `text`: a slice of it, empty if this cell has none
    const(wchar)[] head(return scope const(wchar)[] text) const pure nothrow @nogc @safe;

    /// What the cell shows: a slice of `text` after its head, all of it if it has none
    const(wchar)[] body(return scope const(wchar)[] text) const pure nothrow @nogc @safe;
}

/// A cell that is all body: the text as it is
final class TrivialCellPartsExtractor : CellPartsExtractor
{
    bool hasHead() const pure nothrow @nogc @safe
    {
        return false;
    }

    const(wchar)[] head(return scope const(wchar)[] text) const pure nothrow @nogc @safe
    {
        return text[0 .. 0];
    }

    const(wchar)[] body(return scope const(wchar)[] text) const pure nothrow @nogc @safe
    {
        return text;
    }
}

/// The parts of a plain cell, shared by every column that has no head (made when the program is compiled)
immutable TrivialCellPartsExtractor trivialCellParts = new immutable TrivialCellPartsExtractor;

/// Where the head of a text ends and its body begins; `headEnd` 0: no head
struct HeadCut
{
    size_t headEnd, bodyStart;
}

/// The rule of a head: where it ends in a text
alias HeadRule = HeadCut function(const(wchar)[] text) pure nothrow @nogc @safe;

/// The head is the text up to its first space, the body what follows the space; no space, no head
/// ("2026/11/18 12:34:56" → "2026/11/18" and "12:34:56")
HeadCut firstSpace(const(wchar)[] text) pure nothrow @nogc @safe
{
    foreach (i, c; text)
        if (c == ' ')
            return i == 0 ? HeadCut(0, 0) : HeadCut(i, i + 1);
    return HeadCut(0, 0);
}

/// A cell with a head by a rule
final class HeadedCellPartsExtractor : CellPartsExtractor
{
    private immutable HeadRule _rule;

    this(HeadRule rule) immutable pure nothrow @nogc @safe
    {
        _rule = rule;
    }

    bool hasHead() const pure nothrow @nogc @safe
    {
        return true;
    }

    const(wchar)[] head(return scope const(wchar)[] text) const pure nothrow @nogc @safe
    {
        return text[0 .. cut(text).headEnd];
    }

    const(wchar)[] body(return scope const(wchar)[] text) const pure nothrow @nogc @safe
    {
        return text[cut(text).bodyStart .. $];
    }

    // The rule's cut, kept within the text whatever the rule says
    private HeadCut cut(const(wchar)[] text) const pure nothrow @nogc @safe
    {
        auto c = _rule(text);
        if (c.headEnd == 0 || c.headEnd > text.length || c.bodyStart < c.headEnd || c.bodyStart > text.length)
            return HeadCut(0, 0);
        return c;
    }
}

@("TrivialCellPartsExtractor: no head, the body is the text")
unittest
{
    assert(!trivialCellParts.hasHead);
    const text = "2026/11/18 12:34:56"w;
    assert(trivialCellParts.head(text).length == 0 && trivialCellParts.body(text) is text);
}

@("HeadedCellPartsExtractor: the head and the body are slices of the text by its rule")
unittest
{
    auto parts = new immutable HeadedCellPartsExtractor(&firstSpace);
    assert(parts.hasHead);
    const text = "2026/11/18 12:34:56.789"w;
    assert(parts.head(text) == "2026/11/18" && parts.head(text).ptr is text.ptr);
    assert(parts.body(text) == "12:34:56.789" && parts.body(text).ptr is text.ptr + 11);
}

@("HeadedCellPartsExtractor: a text with no head is all body (no space, a space first, empty)")
unittest
{
    auto parts = new immutable HeadedCellPartsExtractor(&firstSpace);
    foreach (text; ["12.345678"w, "-"w, " 12:00"w, ""w])
        assert(parts.head(text).length == 0 && parts.body(text) == text, "no head");
}

@("HeadedCellPartsExtractor: a rule that cuts outside the text gives no head")
unittest
{
    static HeadCut wild(const(wchar)[] text) pure nothrow @nogc @safe { return HeadCut(50, 60); }
    static HeadCut backwards(const(wchar)[] text) pure nothrow @nogc @safe { return HeadCut(3, 1); }
    foreach (rule; [&wild, &backwards])
    {
        auto parts = new immutable HeadedCellPartsExtractor(rule);
        assert(parts.head("abc def"w).length == 0 && parts.body("abc def"w) == "abc def");
    }
}
