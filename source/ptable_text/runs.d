//! A line of a text cell as runs: a run is a word, or a gap of spaces or of tabs (a tab is as wide as a space, and drawn as one). A line is
//! drawn run by run, each by a layout of its own, and
//! placed by the widths of the runs before it: what is drawn and what a match, a selection or the caret under the mouse is placed by are
//! the same widths, measured by the same layouts, with the kerning inside a word; and no layout is ever made of the start of a long line,
//! only of its words (the host keeps their widths). Only the runs that cross the part of the line seen are drawn. Pure: the width of a
//! piece of text comes in as a delegate. A long line keeps marks of its runs in the memo of its cell (ptable/cellmemo): a walk begins at the
//! last mark before what it looks for.
module ptable_text.runs;

import ptable.cellmemo : CellMemo, MemoRef, PlaceMark;
import ptable_text.wordpick : caretAt;

/// The width of a piece of a line in the font of the cell (`TextMeasurer.width`)
alias PieceWidth = double delegate(const(wchar)[] piece);

/// A memo marks every so many runs of a line (`CellMemo`): a walk from a mark measures at most so many runs before what it looks for
enum size_t markEvery = 64;

/// A line shorter than this, in units, is walked from its start (a few hundred runs at most): no memo is kept for it
enum size_t memoFrom = 1024;

/// The memo of a cell (`CellInput.memo`) for the walks over the runs of its line that starts at `lineStart`, `length` units long, in
/// `font`: `use`d for that line and font; null for a short line, or a cell without a memo
CellMemo* lineMemo(const MemoRef memo, size_t lineStart, size_t length, uint font)
{
    auto m = memo.get();
    if (m is null || length < memoFrom)
        return null;
    m.use((cast(ulong) font << 40) | lineStart);
    return m;
}

/// The longest run, in units: a word without spaces (a dump of hex, a payload of base64) is cut into runs of it, or one layout would
/// be made of all of it
enum size_t maxRun = 256;

/// Where the run that starts at `start` of `line` ends: a run is a word (no space, no tab in it) or a gap (spaces, or tabs); either
/// ends at `maxRun` units at most, a long word between two characters (`cutsAt`)
size_t runEnd(const(wchar)[] line, size_t start) pure nothrow @nogc @safe
{
    if (start >= line.length)
        return start;
    size_t i = start;
    const c = line[start];
    if (isGap(c))
    {
        while (i < line.length && line[i] == c && i - start < maxRun)
            ++i;
        return i;
    }
    while (i < line.length && !isGap(line[i]) && i - start < maxRun)
        ++i;
    if (i - start < maxRun || i == line.length || isGap(line[i]))
        return i;
    foreach_reverse (cut; start + 1 .. i + 1)
        if (cutsAt(line, cut))
            return cut;
    return i < line.length && isLow(line[i]) ? i + 1 : i; // a run of marks: at the bound, not inside a pair
}

private bool isGap(wchar c) pure nothrow @nogc @safe
{
    return c == ' ' || c == '\t';
}

private bool isLow(wchar c) pure nothrow @nogc @safe
{
    return c >= 0xDC00 && c < 0xE000;
}

// Whether a word may be cut before `line[i]` without splitting a character as it is seen: not inside a surrogate pair, not before a
// combining mark, a variation selector or a skin tone, not on either side of a joiner (Unicode's rules of graphemes, the common cases)
private bool cutsAt(const(wchar)[] line, size_t i) pure nothrow @nogc @safe
{
    const c = line[i];
    if (isLow(c) || line[i - 1] == 0x200D || c == 0x200D)
        return false;
    if ((c >= 0x0300 && c < 0x0370) || (c >= 0x1AB0 && c < 0x1B00) || (c >= 0x1DC0 && c < 0x1E00) || (c >= 0x20D0 && c < 0x2100)
        || (c >= 0xFE00 && c < 0xFE10) || (c >= 0xFE20 && c < 0xFE30))
        return false; // combining marks, variation selectors
    if (i + 1 < line.length)
    {
        const next = line[i + 1];
        if (c == 0xD83C && next >= 0xDFFB && next <= 0xDFFF)
            return false; // U+1F3FB..1F3FF, a skin tone
        if (c == 0xDB40 && next >= 0xDD00 && next <= 0xDDEF)
            return false; // U+E0100..E01EF, a variation selector
    }
    return true;
}

/// The x of the place `at` of `line` from the start of the line: the widths of the runs before it, and of the part of its own run before it.
/// With a `memo` (`use`d for this line), from the last mark before it
double xAt(const(wchar)[] line, size_t at, scope PieceWidth width, CellMemo* memo = null)
{
    auto w = fromPlace(memo, at);
    while (w.start < at)
    {
        const end = runEnd(line, w.start);
        if (end > at)
            return w.x + measure(line[w.start .. at], width);
        step(w, end, measure(line[w.start .. end], width), memo);
    }
    return w.x;
}

/// Calls `visit(start, end, x)` for each run of `line` that crosses [`left`, `right`) (from the start of the line), in order; the runs
/// past `right` are not measured. With a `memo` (`use`d for this line), from the last mark left of `left`
void eachRun(const(wchar)[] line, double left, double right, scope PieceWidth width, scope void delegate(size_t start, size_t end, double x) visit,
    CellMemo* memo = null)
{
    for (auto w = fromX(memo, left); w.start < line.length && w.x < right;)
    {
        const end = runEnd(line, w.start);
        const rw = measure(line[w.start .. end], width);
        if (w.x + rw > left)
            visit(w.start, end, w.x);
        step(w, end, rw, memo);
    }
}

/// The place of `line` nearest to `dx` from its start: right of the middle of a character is after it. With a `memo` (`use`d for this
/// line), from the last mark left of `dx`
size_t placeAt(const(wchar)[] line, double dx, scope PieceWidth width, CellMemo* memo = null)
{
    if (dx <= 0)
        return 0;
    for (auto w = fromX(memo, dx); w.start < line.length;)
    {
        const start = w.start, end = runEnd(line, start);
        const rw = measure(line[start .. end], width);
        if (dx < w.x + rw)
            return start + caretAt(dx - w.x, end - start, (size_t n) => measure(line[start .. start + n], width));
        step(w, end, rw, memo);
    }
    return line.length;
}

// The width of a piece of a run: a gap of tabs is as wide as as many spaces (a tab is drawn as a space: a text engine would lay it out
// to the next stop of its own layout, a run's, not the line's)
private double measure(const(wchar)[] piece, scope PieceWidth width)
{
    if (piece.length && piece[0] == '\t')
        return piece.length * width(" "w);
    return width(piece);
}

// Where a walk over the runs of a line stands: the start of a run, its x, how many runs are before it
private struct Walk
{
    size_t start;
    double x = 0;
    size_t run;
}

// The walk past the run that ends at `end`, `runWidth` wide; the start of every `markEvery`th run not marked yet is marked (the marks
// of a memo are those of runs `markEvery`, 2 `markEvery`... in order: a walk begins at one of them, or at the start)
private void step(ref Walk w, size_t end, double runWidth, CellMemo* memo)
{
    w.x += runWidth;
    w.start = end;
    w.run++;
    if (memo !is null && w.run % markEvery == 0 && w.run / markEvery == memo.marks.length + 1)
        memo.put(PlaceMark(w.start, w.x));
}

// The walk from the last mark at or before the place `at`; from the start without one
private Walk fromPlace(const(CellMemo)* memo, size_t at)
{
    return memo is null ? Walk.init : walkFrom(memo.marks, lastMark(memo.marks, (ref const PlaceMark m) => m.at <= at));
}

// The walk from the last mark at or left of `x`; from the start without one
private Walk fromX(const(CellMemo)* memo, double x)
{
    return memo is null ? Walk.init : walkFrom(memo.marks, lastMark(memo.marks, (ref const PlaceMark m) => m.x <= x));
}

private Walk walkFrom(const(PlaceMark)[] marks, size_t k)
{
    return k == 0 ? Walk.init : Walk(marks[k - 1].at, marks[k - 1].x, k * markEvery);
}

// How many marks are before or at what is looked for (`before` holds for a first part of them): a binary search
private size_t lastMark(const(PlaceMark)[] marks, scope bool delegate(ref const PlaceMark) before)
{
    size_t lo = 0, hi = marks.length;
    while (lo < hi)
    {
        const mid = (lo + hi) / 2;
        if (before(marks[mid]))
            lo = mid + 1;
        else
            hi = mid;
    }
    return lo;
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

@("runEnd: a run is a word or a gap of spaces or of tabs, apart")
unittest
{
    const line = "ab  cd e"w;
    size_t[] ends;
    for (size_t at = 0; at < line.length; at = runEnd(line, at))
        ends ~= runEnd(line, at);
    assert(ends == [2, 4, 6, 7, 8], "ab, two spaces, cd, a space, e");
    assert(runEnd("   "w, 0) == 3, "spaces only");
    assert(runEnd(""w, 0) == 0);
    assert(runEnd("a\t\tb"w, 1) == 3, "two tabs, one gap");
    assert(runEnd("a \tb"w, 1) == 2 && runEnd("a \tb"w, 2) == 3, "a space and a tab: two gaps");
}

@("runEnd: a word or a gap longer than `maxRun` is cut into runs of `maxRun` at most")
unittest
{
    import std.array : replicate;

    const word = "x"w.replicate(3 * maxRun);
    assert(runEnd(word, 0) == maxRun && runEnd(word, maxRun) == 2 * maxRun);
    const gap = " "w.replicate(maxRun + 3);
    assert(runEnd(gap, 0) == maxRun && runEnd(gap, maxRun) == maxRun + 3);
}

@("runEnd: a long word is cut between two characters: not inside a surrogate pair, not before a combining mark, a variation selector or a skin tone, not by a joiner")
unittest
{
    import std.array : replicate;

    const head = "x"w.replicate(maxRun - 1);
    assert(runEnd(head ~ "\U0001F600"w ~ "y"w, 0) == maxRun - 1, "the pair that crosses the cut goes to the next run");
    assert(runEnd(head ~ "e\u0301"w ~ "y"w, 0) == maxRun - 1, "e and its accent stay together");
    assert(runEnd(head ~ "\u2764\uFE0F"w ~ "y"w, 0) == maxRun - 1, "a heart and its selector");
    assert(runEnd("x"w.replicate(maxRun - 2) ~ "\U0001F44D\U0001F3FD"w, 0) == maxRun - 2, "a thumb and its tone");
    assert(runEnd("x"w.replicate(maxRun - 1) ~ "\u200D"w ~ "y"w, 0) == maxRun - 2, "nor on either side of a joiner");
    const marks = "\u0301"w.replicate(3 * maxRun);
    assert(runEnd(marks, 0) == maxRun, "marks only: cut at the bound all the same");
}

@("runs: a tab is as wide as a space: placed, measured and walked so, whatever the measurer makes of a tab")
unittest
{
    // a tab as a text engine lays it out, to the next stop of eight: never asked for
    double width(const(wchar)[] piece)
    {
        double w = 0;
        foreach (c; piece)
            w += c == '\t' ? 80 : 10;
        return w;
    }

    const line = "a\t\tb"w;
    assert(xAt(line, 3, &width) == 30 && xAt(line, 2, &width) == 20);
    assert(placeAt(line, 24, &width) == 2 && placeAt(line, 31, &width) == 3);
    double[] xs;
    eachRun(line, 0, 100, &width, (size_t start, size_t end, double x) { xs ~= x; });
    assert(xs == [0, 10, 30]);
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
    const line = "ab cd ef gh"w; // runs of 20, 10, 20, 10, 20, 10, 20
    size_t[] starts;
    double[] xs;
    eachRun(line, 35, 65, &ruler.width, (size_t start, size_t end, double x) { starts ~= start; xs ~= x; });
    assert(starts == [3, 5, 6] && xs == [30, 50, 60], "\"cd\", \" \", \"ef\"");
    assert(ruler.asked == 5, "the two runs before, the three seen; not the last one");
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

version (unittest)
{
    import ptable.memory : mallocAllocator;

    // A long line of 6000 words and their gaps (\"word \" at ten a unit): 12 000 runs, 300 000 wide
    private const(wchar)[] longLine()
    {
        import std.array : replicate;

        return "word "w.replicate(6000);
    }

    private void walkAll(const(wchar)[] line, Ruler ruler, CellMemo* memo, double right = double.infinity)
    {
        eachRun(line, 0, right, &ruler.width, (size_t start, size_t end, double x) {}, memo);
    }
}

@("eachRun: with a memo, a frame at the right end of a long line measures the runs seen and at most `markEvery` before them")
unittest
{
    auto ruler = new Ruler;
    auto memo = CellMemo(mallocAllocator());
    const line = longLine();
    size_t[] first, second;
    eachRun(line, 299_000, 300_000, &ruler.width, (size_t start, size_t end, double x) { first ~= start; }, &memo);
    ruler.asked = 0;
    eachRun(line, 299_000, 300_000, &ruler.width, (size_t start, size_t end, double x) { second ~= start; }, &memo);
    assert(second == first && first.length == 40, "20 words and their gaps");
    assert(ruler.asked <= markEvery + 40, "summed from the start again");
}

@("runs: with the marks of a memo, xAt, placeAt and eachRun answer as from the start, measuring at most `markEvery` runs before")
unittest
{
    auto ruler = new Ruler;
    auto memo = CellMemo(mallocAllocator());
    const line = longLine();
    walkAll(line, ruler, &memo);
    assert(memo.marks.length > 0);
    foreach (at; [0, 3, 5, 63 * 5, 64 * 5, 64 * 5 + 2, 64 * 5 * 7 - 1, 29_998, 30_000])
    {
        const plain = xAt(line, at, &ruler.width);
        ruler.asked = 0;
        assert(xAt(line, at, &ruler.width, &memo) == plain);
        assert(ruler.asked <= markEvery + 1);
    }
    foreach (dx; [-5.0, 0, 24, 26, 3_199, 3_200, 3_226, 299_990, 400_000])
    {
        const plain = placeAt(line, dx, &ruler.width);
        ruler.asked = 0;
        assert(placeAt(line, dx, &ruler.width, &memo) == plain);
        assert(ruler.asked <= markEvery + 10);
    }
    foreach (left; [0.0, 3_190, 3_200, 150_013])
    {
        size_t[] plain, marked;
        double[] plainX, markedX;
        eachRun(line, left, left + 500, &ruler.width, (size_t start, size_t end, double x) { plain ~= start; plainX ~= x; });
        eachRun(line, left, left + 500, &ruler.width, (size_t start, size_t end, double x) { marked ~= start; markedX ~= x; }, &memo);
        assert(marked == plain && markedX == plainX);
    }
}

@("runs: the marks go as far as a walk went, and a walk further only adds to them")
unittest
{
    auto ruler = new Ruler;
    auto memo = CellMemo(mallocAllocator());
    const line = longLine();
    walkAll(line, ruler, &memo, 150_000); // half: 3000 words and their gaps, 6000 runs
    const half = memo.marks.dup;
    assert(half.length >= 6000 / markEvery - 1 && half.length <= 6000 / markEvery + 1);
    ruler.asked = 0;
    eachRun(line, 299_000, 300_000, &ruler.width, (size_t start, size_t end, double x) {}, &memo); // a frame at the right end
    assert(memo.marks.length >= 12_000 / markEvery - 1 && memo.marks[0 .. half.length] == half);
    assert(ruler.asked <= 6000 + markEvery, "the first half measured again");
}

@("runs: a line of fewer than `markEvery` runs has no marks")
unittest
{
    auto ruler = new Ruler;
    auto memo = CellMemo(mallocAllocator());
    import std.array : replicate;

    walkAll("word "w.replicate(markEvery / 2 - 1), ruler, &memo); // a word and a gap each
    assert(memo.marks.length == 0);
}
