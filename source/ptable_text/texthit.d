//! Where a text lies in its cell, as the hit tests of a text column see it: the caret nearest to a point, the rectangles a part of it takes, what a double
//! click selects. Pure.
module ptable_text.texthit;

version (unittest) import ptable_text.testing : TestText;
import ptable.column : Unit;
import ptable.ports : FontId, Rect;
import ptable_text.measurer : TextMeasurer;
import ptable_text.wordpick : caretAt, wordAt;
import ptable_text.wrap : LineSpan;

import std.algorithm.comparison : max, min;
import std.math : floor, round;

/// How a text lies in its cell, as a text column places it: the font, where its lines start, the top of the first, the height of a
/// line and the lines of a wrapped text (none: one line of all of it)
struct TextSpot
{
    FontId font;
    double x = 0, top = 0, line = 0;
    const(LineSpan)[] lines;
}

/// The caret in `text` lying at `spot` nearest to the point (`x`, `y`): in the line the height says, the nearest place between two
/// characters of it; 0 in an empty text
size_t caretInText(const(wchar)[] text, ref const TextSpot spot, TextMeasurer measurer, double x, double y)
{
    if (text.length == 0)
        return 0;
    size_t from = 0, to = text.length;
    if (spot.lines.length)
    {
        const j = cast(size_t) max(0.0, min(cast(double) spot.lines.length - 1, floor((y - spot.top) / spot.line)));
        from = spot.lines[j].start;
        to = spot.lines[j].end;
    }
    return from + caretAt(x - spot.x, to - from, (size_t n) => measurer.width(spot.font, text[from .. from + n]));
}

/// The rectangles the part [`from`, `to`) of `text` lying at `spot` takes: one for a text of one line, one for each line it touches
void rectsInText(const(wchar)[] text, ref const TextSpot spot, TextMeasurer measurer, size_t from, size_t to, scope void delegate(Rect) emit)
{
    if (spot.lines.length == 0)
    {
        const x1 = spot.x + measurer.width(spot.font, text[0 .. from]), x2 = spot.x + measurer.width(spot.font, text[0 .. to]);
        emit(Rect(round(x1), spot.top, max(1.0, round(x2 - x1)), spot.line));
        return;
    }
    foreach (j, span; spot.lines)
    {
        const start = max(span.start, from), end = min(span.end, to);
        if (end <= start)
            continue;
        const x1 = spot.x + measurer.width(spot.font, text[span.start .. start]), x2 = spot.x + measurer.width(spot.font, text[span.start .. end]);
        emit(Rect(round(x1), spot.top + j * spot.line, max(1.0, round(x2 - x1)), spot.line));
    }
}

/// What a double click (`Unit.word`: the word at the caret, or the character after it if it is no word) or a triple click (`Unit.cell`,
/// `Unit.line`: all of it) at the caret `at` of `text` selects, as two carets; none in an empty text
size_t[2] unitInText(const(wchar)[] text, size_t at, Unit unit)
{
    if (text.length == 0)
        return [0, 0];
    if (unit != Unit.word)
        return [0, text.length];
    const part = wordAt(text, cast(long) min(at, text.length - 1));
    return [part.from, part.to];
}

version (unittest)
{
    import ptable.column : CellInput, TableColumn;
    import ptable.layout : ColumnDef;
    import ptable.model : CellData;
    import ptable.selection : Position, TextRange;
    import ptable.texthit : CellText, selectionRects, textPositionAt;
    import ptable_text.columnstyle : Valign;
    import ptable_text.testing : FakeMeasurer, TestText;

    // A plain text column whose text starts at the left top corner of its cell (no room around it), its lines 14 apart (`FakeMeasurer`)
    private TestText flush(TextMeasurer measurer = null, Valign valign = Valign.top, bool flex = false)
    {
        auto column = new TestText(ColumnDef("t", "T", 24, flex), measurer);
        column.style.cell.padLeft = column.style.cell.padRight = column.style.cell.padTop = column.style.cell.padBottom = 0;
        column.style.cell.valign = valign;
        return column;
    }

    // two cells from `top` down: "abc" at x 0..50 and a wrapped one "def ghij" at x 50..90: its lines "def " and "ghij"
    private final class TwoCells
    {
        double top = 0;
        TestText plain, wrapped;
        static immutable CellData abc = CellData("abc"w), defghij = CellData("def ghij"w);

        this(double top = 0)
        {
            this.top = top;
            plain = flush();
            wrapped = flush(null, Valign.top, true);
        }

        size_t length() { return 2; }
        double right(size_t col) { return col == 0 ? 50 : 90; }

        CellText cell(size_t col)
        {
            if (col == 0)
                return CellText(CellInput(0, 0, &abc), Rect(0, top, 50, 28), Rect(0, top, 50, 28), plain);
            return CellText(CellInput(0, 1, &defghij), Rect(50, top, 40, 28), Rect(50, top, 40, 28), wrapped);
        }
    }
}

@("textPositionAt: a point is the caret nearest to it in the cell under it, the line by the height, the ends by the text")
unittest
{
    auto cells = new TwoCells;
    Position at;
    assert(textPositionAt(cells, 7, 12, 0, at) && at == Position(7, 0, 1), "the right half of the first glyph: after it");
    assert(textPositionAt(cells, 7, 49, 0, at) && at == Position(7, 0, 3), "right of the text of the cell: its end");
    assert(textPositionAt(cells, 7, 22, 0, at) && at == Position(7, 0, 2));
    assert(textPositionAt(cells, 7, 200, 0, at) && at.col == 1, "right of the cells is the last one");
    assert(textPositionAt(cells, 7, 63, 0, at) && at == Position(7, 1, 1), "the first line");
    assert(textPositionAt(cells, 7, 63, 15, at) && at == Position(7, 1, 5), "the second line: from its start");
    assert(textPositionAt(cells, 7, 89, 0, at) && at == Position(7, 1, 4), "the end of a line that goes on is the start of the next one");
    assert(textPositionAt(cells, 7, 89, 15, at) && at == Position(7, 1, 8), "past the end of the text: its end");
    assert(textPositionAt(cells, 7, -5, 0, at) && at == Position(7, 0, 0));
}

@("selectionRects: a selected part is a rectangle on its line, a wrapped cell one per line it touches")
unittest
{
    auto cells = new TwoCells(100);
    Rect[] seen;
    // from character 1 of "abc" to character 6 of "def ghij" in row 2
    const range = TextRange(Position(2, 0, 1), Position(2, 1, 6));
    selectionRects(cells, range, 2, (Rect r) { seen ~= r; });
    assert(seen == [Rect(10, 100, 20, 14), Rect(50, 100, 40, 14), Rect(50, 114, 20, 14)], "up to the caret 6: \"gh\" in the second line");
    seen = null;
    selectionRects(cells, range, 5, (Rect r) { seen ~= r; });
    assert(seen.length == 0, "another row");
}

@("selectionRects: a cell that stands lower in its row (its Valign) has its rectangle lower by the same")
unittest
{
    static final class Lowered
    {
        TestText column;
        static immutable CellData data = CellData("abc"w);
        size_t length() { return 1; }
        double right(size_t col) { return 50; }
        CellText cell(size_t col) { return CellText(CellInput(0, 0, &data), Rect(0, 100, 50, 44), Rect(0, 100, 50, 44), column); }
    }
    auto cells = new Lowered;
    cells.column = flush(null, Valign.middle); // (44 - 14) / 2 = 15 lower
    Rect[] seen;
    selectionRects(cells, TextRange(Position(2, 0, 0), Position(2, 0, 1)), 2, (Rect r) { seen ~= r; });
    assert(seen == [Rect(0, 115, 10, 14)]);
}

@("textPositionAt and selectionRects: the lines of a cell stand as far apart as its own font says")
unittest
{
    static final class Big
    {
        TestText column;
        static immutable CellData data = CellData("def ghij"w);
        double top = 0;
        size_t length() { return 1; }
        double right(size_t col) { return 40; }
        CellText cell(size_t col) { return CellText(CellInput(0, 0, &data), Rect(0, top, 40, 40), Rect(0, top, 40, 40), column); }
    }
    auto ruler = new FakeMeasurer;
    ruler.line = 20;
    auto cells = new Big;
    cells.column = flush(ruler, Valign.top, true);
    Position at;
    assert(textPositionAt(cells, 1, 3, 19, at) && at.at == 0, "the first line reaches down to 20");
    assert(textPositionAt(cells, 1, 3, 21, at) && at.at == 4, "then the second one");
    cells.top = 100;
    Rect[] seen;
    selectionRects(cells, TextRange(Position(1, 0, 2), Position(1, 0, 6)), 1, (Rect r) { seen ~= r; });
    assert(seen == [Rect(20, 100, 20, 20), Rect(0, 120, 20, 20)]);
}

@("unitInText: a double click takes the word at the caret, the character after it if that is no word, a triple click all; nothing in no text")
unittest
{
    assert(unitInText("two words, here"w, 0, Unit.word) == [0, 3]);
    assert(unitInText("two words, here"w, 4, Unit.word) == [4, 9], "the caret before a word: that word");
    assert(unitInText("two words, here"w, 3, Unit.word) == [3, 4], "before a space: the space");
    assert(unitInText("two words, here"w, 15, Unit.word) == [11, 15], "at the end: the last word");
    assert(unitInText("two words, here"w, 4, Unit.cell) == [0, 15] && unitInText("ab"w, 1, Unit.line) == [0, 2]);
    assert(unitInText(""w, 0, Unit.word) == [0, 0]);
}
