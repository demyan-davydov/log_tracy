//! A line of a text cell as runs: a run is a word and the spaces after it. A line is drawn run by run, each by a layout of its own, and
//! placed by the widths of the runs before it: what is drawn and what a match, a selection or the caret under the mouse is placed by are
//! the same widths, measured by the same layouts, with the kerning inside a word; and no layout is ever made of the start of a long line,
//! only of its words (the host keeps their widths). Only the runs that cross the part of the line seen are drawn. Pure: the width of a
//! piece of text comes in as a delegate.
module ptable_text.runs;

import ptable_text.wordpick : caretAt;

/// The width of a piece of a line in the font of the cell (`TextMeasurer.width`)
alias PieceWidth = double delegate(const(wchar)[] piece);

/// The longest run, in units: a word without spaces (a dump of hex, a payload of base64) is cut into runs of it, or one layout would
/// be made of all of it
enum size_t maxRun = 256;

/// Where the run that starts at `start` of `line` ends: past its word and the spaces after it (a line of spaces is one run); a word
/// longer than `maxRun` ends at `maxRun` (after the surrogate pair that crosses it)
size_t runEnd(const(wchar)[] line, size_t start) pure nothrow @nogc @safe
{
    size_t i = start;
    while (i < line.length && line[i] != ' ' && i - start < maxRun)
        ++i;
    if (i - start == maxRun && i < line.length && line[i] >= 0xDC00 && line[i] < 0xE000)
        ++i; // the low half of a pair cut at the bound
    if (i - start >= maxRun && i < line.length && line[i] != ' ')
        return i; // a long word goes on in the next run
    while (i < line.length && line[i] == ' ')
        ++i;
    return i;
}

/// The x of the place `at` of `line` from the start of the line: the widths of the runs before it, and of the part of its own run before it
double xAt(const(wchar)[] line, size_t at, scope PieceWidth width)
{
    double x = 0;
    size_t start = 0;
    while (start < at)
    {
        const end = runEnd(line, start);
        if (end > at)
            return x + width(line[start .. at]);
        x += width(line[start .. end]);
        start = end;
    }
    return x;
}

/// Calls `visit(start, end, x)` for each run of `line` that crosses [`left`, `right`) (from the start of the line), in order; the runs
/// past `right` are not measured
void eachRun(const(wchar)[] line, double left, double right, scope PieceWidth width, scope void delegate(size_t start, size_t end, double x) visit)
{
    double x = 0;
    for (size_t start = 0; start < line.length && x < right;)
    {
        const end = runEnd(line, start);
        const w = width(line[start .. end]);
        if (x + w > left)
            visit(start, end, x);
        x += w;
        start = end;
    }
}

/// The place of `line` nearest to `dx` from its start: right of the middle of a character is after it
size_t placeAt(const(wchar)[] line, double dx, scope PieceWidth width)
{
    if (dx <= 0)
        return 0;
    double x = 0;
    for (size_t start = 0; start < line.length;)
    {
        const end = runEnd(line, start);
        const w = width(line[start .. end]);
        if (dx < x + w)
            return start + caretAt(dx - x, end - start, (size_t n) => width(line[start .. start + n]));
        x += w;
        start = end;
    }
    return line.length;
}

version (unittest)
{
    // Ten a unit, and the widths asked of it (what was measured)
    private final class Ruler
    {
        size_t longest;
        size_t asked;

        double width(const(wchar)[] piece)
        {
            ++asked;
            if (piece.length > longest)
                longest = piece.length;
            return piece.length * 10.0;
        }
    }
}

@("runEnd: a run is a word and the spaces after it; a line of spaces is one run")
unittest
{
    const line = "ab  cd e"w;
    assert(runEnd(line, 0) == 4 && runEnd(line, 4) == 7 && runEnd(line, 7) == 8);
    assert(runEnd("   "w, 0) == 3, "spaces only");
    assert(runEnd(""w, 0) == 0);
}

@("runEnd: a word longer than `maxRun` is cut into runs of `maxRun`, never inside a surrogate pair")
unittest
{
    import std.array : replicate;

    const word = "x"w.replicate(3 * maxRun);
    assert(runEnd(word, 0) == maxRun && runEnd(word, maxRun) == 2 * maxRun);
    auto paired = "x"w.replicate(maxRun - 1) ~ "\U0001F600"w ~ "y"w;
    assert(runEnd(paired, 0) == maxRun + 1, "the pair that crosses the cut stays in its run");
}

@("xAt: the widths of the runs before a place and the part of its run before it")
unittest
{
    auto ruler = new Ruler;
    const line = "ab  cd e"w;
    assert(xAt(line, 0, &ruler.width) == 0);
    assert(xAt(line, 5, &ruler.width) == 50, "\"ab  \" then \"c\"");
    assert(xAt(line, 8, &ruler.width) == 80, "the end");
}

@("xAt: a place far into a long line measures its words, never the start of the line")
unittest
{
    import std.array : replicate;

    auto ruler = new Ruler;
    const line = "word "w.replicate(12_000); // 60 000 units
    assert(xAt(line, 59_002, &ruler.width) == 590_020);
    assert(ruler.longest <= 5, "a run at most");
}

@("eachRun: the runs that cross the part seen, with their x; those past it are not measured")
unittest
{
    auto ruler = new Ruler;
    const line = "ab cd ef gh"w; // runs of 30, 30, 30, 20
    size_t[] starts;
    double[] xs;
    eachRun(line, 35, 65, &ruler.width, (size_t start, size_t end, double x) { starts ~= start; xs ~= x; });
    assert(starts == [3, 6] && xs == [30, 60], "\"cd \" and \"ef \"");
    assert(ruler.asked == 3, "the run before, the two seen; not the last one");
}

@("placeAt: the run under the point, then the place in it nearest to the point; the ends outside the line")
unittest
{
    auto ruler = new Ruler;
    const line = "ab cd"w;
    assert(placeAt(line, 34, &ruler.width) == 3, "left of the middle of the c: before it");
    assert(placeAt(line, 36, &ruler.width) == 4, "right of it: after it");
    assert(placeAt(line, -5, &ruler.width) == 0 && placeAt(line, 500, &ruler.width) == 5);
}
