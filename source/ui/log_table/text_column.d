//! The column of the log table that shows text: a `TextCell` that knows the colors of the log (its palette, the ink of a selected row, the chips
//! behind the matches of a search) and draws its title and the heads of its groups by them. The measuring, the lines and the hit tests are
//! the text column's of `ptable_text`.
module ui.log_table.text_column;

import ptable.column : CellInput, DrawState, GroupInput, HeaderState;
import ptable.layout : ColumnDef;
import ptable.ports : Canvas, Color, FontId, Rect;
import ptable_text.columnstyle : Halign, alignedX, noColor;
import ptable_text.measurer : TextMeasurer;
import ptable_text.textcell : TextCell;
import ui.log_table.log_look : LogFont, LogLook, defaultLogLook, pick;

import std.algorithm.comparison : max, min;
import std.math : round;

version (unittest)
{
    import ptable.column : TableColumn, Unit;
    import ptable.memory : Arena;
    import ptable_text.measurer : FontMetrics;

    // a measurer that wraps by itself: two lines for any text
    final class Paragraphs : TextMeasurer
    {
        FontMetrics metrics(FontId font) { return FontMetrics(11, 3, 14); }
        double width(FontId font, const(wchar)[] text) { return text.length * 10.0; }
        int wrappedLines(FontId font, const(wchar)[] text, double width) { return 2; }
    }
}

/// A column of text in the colors of a look: its cells are broken into lines by the advances of the glyphs, or the measurer of the host wraps them
class TextColumn : TextCell
{
    protected LogLook look; /// the colors its style names and the fonts it is set in

    /// `look` null: the default one; `measurer` null: a column of a test that measures nothing
    this(ColumnDef def, LogLook look = null, TextMeasurer measurer = null)
    {
        super(def, measurer);
        this.look = look !is null ? look : defaultLogLook();
    }

    protected override FontId defaultCellFont() const nothrow { return LogFont.body; }

    protected override FontId defaultHeaderFont() const nothrow { return LogFont.header; }

    protected override FontId defaultGroupFont() const nothrow { return LogFont.header; }

    /// The title: the color behind it if the style gives one, then its text aligned by the style and centered in the height of the header,
    /// in the ink of the style
    override void drawHeader(Canvas canvas, Rect area, in HeaderState state)
    {
        const style = this.style.header;
        const palette = look.palette;
        if (style.back != noColor)
            canvas.fillRect(area, pick(palette, style.back, palette.header));
        const font = headerFont;
        const width = style.halign == Halign.left || style.halign == Halign.inherit || measurer is null ? 0.0 : measurer.width(font, title);
        const x = alignedX(style.halign, area.x, area.w, width, style.left(sidePad), style.right(sidePad));
        const baseline = area.y + round((area.h - headerMetrics.lineHeight) / 2 + headerMetrics.ascent);
        canvas.drawText(font, title, x, baseline, pick(palette, style.ink, palette.ink));
    }

    /// The head of a group on the plate the painter drew: the color behind it if the style gives one, its text aligned by the style and centered
    /// in the plate, in the ink of the style or of the groups
    override void drawGroup(Canvas canvas, in GroupInput group, Rect area)
    {
        const style = this.style.group;
        const palette = look.palette;
        if (style.back != noColor)
            canvas.fillRect(area, pick(palette, style.back, palette.groupPlate));
        const font = groupFont;
        const width = style.halign == Halign.left || style.halign == Halign.inherit || measurer is null ? 0.0 : measurer.width(font, group.head);
        const x = alignedX(style.halign, area.x, area.w, width, style.left(sidePad), style.right(sidePad));
        const baseline = area.y + round((area.h - groupMetrics.lineHeight) / 2 + groupMetrics.ascent);
        canvas.drawText(font, group.head, x, baseline, pick(palette, style.ink, palette.groupInk));
    }

    /// The color behind the cell its style gives, none in a selected row (the row's own color shows)
    protected final void fillBack(Canvas canvas, ref const DrawState state)
    {
        const back = style.cell.back;
        if (back != noColor && !state.row.selected)
            canvas.fillRect(state.area, pick(look.palette, back, look.palette.row));
    }

    /// The ink of the text of a cell: the selected row's, else the style's, else the theme's
    protected final Color inkOf(bool selected) const
    {
        const palette = look.palette;
        return selected ? palette.selectedInk : pick(palette, style.cell.ink, palette.ink);
    }

    /// The cell: the color behind it its style gives, then its text
    override void draw(Canvas canvas, ref const CellInput cell, ref const DrawState state)
    {
        fillBack(canvas, state);
        drawText(canvas, cell, state, inkOf(state.row.selected));
    }

    /// The text of the cell in `ink` (a paragraph in the theme's ink)
    protected final void drawText(Canvas canvas, ref const CellInput cell, ref const DrawState state, Color ink)
    {
        TextCell.drawText(canvas, cell, state, ink, look.palette.ink);
    }

    /// The back of the text the fragments mark (a search's matches): a rectangle in the color of the chip behind each part of each line it
    /// takes; the number of the chip is the fragment's `extra`. A paragraph the host wraps has no rectangles to give: none there.
    override void drawBack(Canvas canvas, ref const CellInput cell, ref const DrawState state)
    {
        if (paragraph || cell.fragments.length == 0 || cell.data is null || measurer is null)
            return;
        const chips = look.palette.match[];
        const text = cell.data.text;
        const lines = linesOf(cell, state.area.w);
        const spot = spotOf(cell, state.area, state.clip, lines.length);
        foreach (fragment; cell.fragments)
        {
            const color = chips[fragment.extra.bits % chips.length];
            foreach (j; 0 .. max(1, lines.length)) // a cell that has no lines is one
            {
                const lineTop = spot.top + j * spot.line;
                if (lineTop + spot.line < state.clip.y)
                    continue;
                if (lineTop > state.clip.bottom)
                    break;
                const lineStart = lines.length ? lines[j].start : 0;
                size_t lineEnd = lines.length ? lines[j].end : text.length;
                while (lineEnd > lineStart && text[lineEnd - 1] == ' ')
                    lineEnd--;
                const start = max(lineStart, fragment.start), end = min(lineEnd, fragment.end);
                if (end <= start)
                    continue;
                const x1 = spot.x + measurer.width(spot.font, text[lineStart .. start]);
                const x2 = spot.x + measurer.width(spot.font, text[lineStart .. end]);
                canvas.fillRect(Rect(x1, lineTop, max(1.0, x2 - x1), spot.line), color);
            }
        }
    }
}

@("TextColumn: a flex cell is laid out in the lines of its width, or is one line cut at a hard break; the row is as high as its lines")
unittest
{
    import ptable.memory : mallocAllocator;
    import ptable.model : CellData, ItemKind;
    import ptable.painter : TableGeometry;
    import ptable.rowentry : Entry;
    import ptable.rowspec : RowSpec;
    import ptable.rowwrap : RowWrap;
    import ptable_text.testing : FakeMeasurer;

    foreach (wrap; [true, false])
    {
        auto text = new TextColumn(ColumnDef("t", "T", 24, true), null, new FakeMeasurer);
        text.style.wrap = wrap;
        TableColumn[] columns = [new TextColumn(ColumnDef("n", "N"), null, new FakeMeasurer), text];
        foreach (column; columns)
            column.lookChanged();
        RowSpec spec;
        spec.columns = columns;
        spec.flexDef = 1;
        spec.flexWidth = 46; // four glyphs of 10 in a line
        TableGeometry geometry;
        spec.geometry = geometry;
        auto rows = new RowWrap(&spec);
        auto arena = Arena(mallocAllocator());
        Entry made;
        made.data.kind = ItemKind.real_;
        made.data.cells = [CellData("1"w), CellData("aaaabbbb cc\nd"w)];
        rows.wrap(made, arena);
        assert(made.height == (wrap ? 4 : 1) * 14 + 2, "the lines it wraps into or one line, the room around them");
        arena.release();
    }
}

@("TextColumn: a payload that ends with a line break is as high as one that does not: the break ends its last line")
unittest
{
    import ptable.model : CellData;
    import ptable_text.testing : FakeMeasurer;

    auto column = new TextColumn(ColumnDef("t", "T", 24, true), null, new FakeMeasurer);
    column.lookChanged();
    Arena arena;
    const plain = CellData("aaaabbbb cc\nd"w), ended = CellData("aaaabbbb cc\nd\n"w), twice = CellData("aaaabbbb cc\nd\n\n"w);
    double heightOf(ref const CellData data)
    {
        const input = CellInput(0, 0, &data);
        return column.layout(input, 46, arena).height;
    }

    assert(heightOf(plain) == heightOf(ended), "the same lines");
    assert(heightOf(twice) == heightOf(plain) + 14, "a second break is an empty line");
}

@("TextColumn.draw: a line of text, the lines of a wrapped cell without the spaces at their ends and only those on the screen, a paragraph")
unittest
{
    import ptable.model : CellData;
    import ptable.painter : CellContext;
    import ptable.ports : Color, FontId, Rect;

    final class Noted : Canvas
    {
        string[] calls;

        void fillRect(Rect area, Color color) {}
        void drawText(FontId font, const(wchar)[] text, double x, double baseline, Color color)
        {
            import std.conv : to;
            import std.format : format;

            calls ~= format("%s@%s,%s:%s", text.to!string, x, baseline, color.r);
        }

        void drawParagraph(FontId font, const(wchar)[] text, double x, double top, double width, Color color)
        {
            import std.conv : to;
            import std.format : format;

            calls ~= format("paragraph %s@%s,%s w%s:%s", text.to!string, x, top, width, color.r);
        }

        void fillRoundRect(Rect area, double radius, Color color) { fillRect(area, color); }
        void fillCircle(double cx, double cy, double radius, Color fill, Color line) {}
        void pushClip(Rect area) {}
        void popClip() {}
    }

    import ptable_text.columnstyle : Valign;
    import ptable_text.testing : FakeMeasurer;
    import ui.log_table.log_look : LogColor;

    auto def = ColumnDef("t", "T", 24, true);
    auto column = new TextColumn(def, null, new FakeMeasurer);
    column.style.cell.padLeft = 5;
    column.style.cell.padTop = 2;
    column.style.cell.valign = Valign.top; // the first line at 2, its baseline 11 under it (`FakeMeasurer`: a line of 14)
    column.style.cell.ink = LogColor.error; // the text in red, a paragraph in the theme's ink
    column.lookChanged();
    const data = CellData("ab cd ef "w);
    auto input = CellInput(0, 0, &data);
    DrawState state;
    state.area = Rect(0, 0, 100, 60);
    state.clip = state.area;
    auto canvas = new Noted;
    column.draw(canvas, input, state);
    assert(canvas.calls == ["ab cd ef@5,13:255"], "it fits: one line, without the space that ends it");
    canvas.calls = null;
    state.area = Rect(0, 0, 68, 60); // 68 - 5 - 3 = 60: six glyphs of 10 in a line
    state.clip = state.area;
    column.draw(canvas, input, state);
    assert(canvas.calls == ["ab cd@5,13:255", "ef@5,27:255"], "the space that ends a line is not drawn");
    canvas.calls = null;
    state.clip = Rect(0, 0, 100, 10); // only the first line is on the screen: the second starts at 16
    column.draw(canvas, input, state);
    assert(canvas.calls == ["ab cd@5,13:255"]);
    canvas.calls = null;
    auto host = new Paragraphs;
    column = new TextColumn(def, null, host); // the host wraps: the column asks it when it lays a cell out
    column.style.cell.padLeft = 5;
    column.style.cell.padTop = 2;
    column.style.cell.valign = Valign.top;
    column.lookChanged();
    Arena arena;
    column.layout(input, 68, arena);
    column.draw(canvas, input, state);
    assert(canvas.calls.length == 1 && canvas.calls[0][0 .. 9] == "paragraph" && canvas.calls[0][$ - 3 .. $] == ":51", "a paragraph is the host's");
}

@("TextColumn.drawBack: a rectangle in the chip's color behind each part of each line a fragment takes, none for a paragraph")
unittest
{
    import ptable.model : CellData, Extra, Fragment;
    import ptable.painter : CellContext;
    import ptable.ports : Color, FontId;
    import ptable_text.testing : FakeMeasurer;

    static final class Fills : Canvas
    {
        Rect[] areas;
        Color[] colors;
        void fillRect(Rect area, Color color) { areas ~= area; colors ~= color; }
        void drawText(FontId font, const(wchar)[] text, double x, double baseline, Color color) {}
        void drawParagraph(FontId font, const(wchar)[] text, double x, double top, double width, Color color) {}
        void fillRoundRect(Rect area, double radius, Color color) { fillRect(area, color); }
        void fillCircle(double cx, double cy, double radius, Color fill, Color line) {}
        void pushClip(Rect area) {}
        void popClip() {}
    }

    import ptable_text.columnstyle : Valign;
    import ui.log_table.log_look : LogLook, LogPalette, defaultLogLook;

    LogPalette palette;
    palette.match[1] = Color(20, 0, 0);
    palette.match[2] = Color(30, 0, 0);
    auto def = ColumnDef("t", "T", 24, true);
    auto column = new TextColumn(def, new LogLook(defaultLogLook().text, palette), new FakeMeasurer);
    column.style.cell.padLeft = 5;
    column.style.cell.padTop = 2;
    column.style.cell.valign = Valign.top;
    column.lookChanged();
    const data = CellData("ab cd ef gh"w); // lines "ab cd " (6) and "ef gh" (5), ten per glyph
    auto input = CellInput(0, 0, &data);
    input.fragments = [Fragment(3, 8, Extra(1)), Fragment(0, 2, Extra(18))]; // "cd ef" over the break, "ab" with a chip past the colors
    DrawState state;
    state.area = Rect(0, 0, 68, 40); // 68 - 5 - 3 = 60: six glyphs of 10 in a line
    state.clip = state.area;
    auto canvas = new Fills;
    column.drawBack(canvas, input, state);
    // "cd" (the space that ends the line is not covered) in line 0, "ef" in line 1, then "ab" in the chip 18 % 16 = 2
    assert(canvas.areas == [Rect(35, 2, 20, 14), Rect(5, 16, 20, 14), Rect(5, 2, 20, 14)], "the parts by lines");
    assert(canvas.colors == [Color(20, 0, 0), Color(20, 0, 0), Color(30, 0, 0)]);
    canvas.areas = null;
    state.clip = Rect(0, 0, 68, 10); // only the first line shows
    column.drawBack(canvas, input, state);
    assert(canvas.areas.length == 2 && canvas.areas[0].y == 2 && canvas.areas[1].y == 2);
    state.clip = state.area;
    input.fragments = [Fragment(3, 5, Extra(1))];
    canvas.areas = null;
    column.drawBack(canvas, input, state);
    assert(canvas.areas == [Rect(35, 2, 20, 14)]);
    auto wrapping = new TextColumn(def, new LogLook(defaultLogLook().text, palette), new Paragraphs);
    Arena arena;
    wrapping.layout(input, 68, arena);
    canvas.areas = null;
    wrapping.drawBack(canvas, input, state);
    assert(canvas.areas.length == 0, "no rectangles of a range in a paragraph");
}

@("TextColumn: a double click takes the word at the caret, a triple one the whole text; the text cut for the clipboard is what the table did itself")
unittest
{
    import ptable.model : CellData;

    auto column = new TextColumn(ColumnDef("t", "T"));
    auto plain = new TableColumn(ColumnDef("p", "P")); // the table's own rules of the clipboard
    const data = CellData("two words, here"w);
    const cell = CellInput(0, 0, &data);
    assert(column.expand(cell, 0, Unit.word) == [0, 3] && column.expand(cell, 2, Unit.word) == [0, 3]);
    assert(column.expand(cell, 4, Unit.word) == [4, 9], "the caret before a word: that word");
    assert(column.expand(cell, 3, Unit.word) == [3, 4], "before a space: the space");
    assert(column.expand(cell, 15, Unit.word) == [11, 15], "at the end: the last word");
    assert(column.expand(cell, 4, Unit.cell) == [0, 15]);
    const empty = CellInput.init;
    assert(column.expand(empty, 0, Unit.word) == [0, 0], "no text: nothing");
    const full = "2026/11/18 12:34"w;
    foreach (inFull; [false, true])
    {
        assert(column.copyCell(full, 11, inFull) == plain.copyCell(full, 11, inFull));
        foreach (range; [[0, 5], [0, 4], [1, 3], [2, 2]])
            assert(column.copyPart(full, 11, range[0], range[1], inFull) == plain.copyPart(full, 11, range[0], range[1], inFull));
    }
    assert(column.copyPart(full, 11, 0, 5, true) == full && column.copyPart(full, 11, 0, 5, false) == "12:34"w, "a cell selected whole is full");
}


@("TextColumn.measure: a cell is a line of its font and the room above and under it high, as wide as its text and paddings: what the table measured itself")
unittest
{
    import ptable_text.columnstyle : Halign;
    import ptable.model : CellData;
    import ptable.painter : CellContext;
    import ptable.ports : FontId;
    import ptable_text.measurer : FontMetrics;
    import ui.log_table.log_look : LogFont, defaultLogLook;
    import ui.log_table.painter : LogPainter;

    static final class Ruler : TextMeasurer
    {
        FontMetrics metrics(FontId font) { return FontMetrics(11, 3, font == LogFont.aux ? 12 : 14); }
        double width(FontId font, const(wchar)[] text) { return text.length * (font == LogFont.aux ? 5.0 : 6.0); }
        int wrappedLines(FontId font, const(wchar)[] text, double width) { return -1; }
    }

    auto measurer = new Ruler;
    auto painter = new LogPainter;
    const data = CellData("12345"w);
    foreach (halign; [Halign.left, Halign.right, Halign.center])
        foreach (font; [cast(FontId) LogFont.body, cast(FontId) LogFont.aux])
        {
            auto def = ColumnDef("n", "N");
            auto column = new TextColumn(def, defaultLogLook(), measurer);
            column.style.cell.halign = halign;
            column.style.cell.font = font;
            column.style.cell.padLeft = 5;
            column.lookChanged();
            const cell = CellInput(0, 0, &data);
            const measured = column.measure(cell, 100, true);
            assert(measured.maxWidth == 5 + 5 * (font == LogFont.aux ? 5.0 : 6.0) + 3, "the text and the paddings: what the table measured");
            assert(measured.minWidth == measured.maxWidth, "one line: it does not break");
            assert(measured.height == (font == LogFont.aux ? 12 : 14) + 2, "a line and the room of 1 above and under it");
        }
    auto column = new TextColumn(ColumnDef("n", "N"), defaultLogLook(), measurer);
    column.style.cell.padTop = 4;
    column.lookChanged();
    const cell = CellInput(0, 0, &data);
    assert(column.measure(cell, 100, true).height == 14 + 4 + 1, "the room above is the style's");
    assert(column.measure(cell, 100, false).maxWidth == 0, "no widths asked: none measured");
}

@("TextColumn.measure: the least width of the column is that of its text, the paddings come on top, in a cell and in the title alike")
unittest
{
    import ptable.model : CellData;
    import ptable.ports : FontId;
    import ptable_text.measurer : FontMetrics;
    import ui.log_table.log_look : LogFont, defaultLogLook;

    static final class Ruler : TextMeasurer
    {
        FontMetrics metrics(FontId font) { return FontMetrics(11, 3, 14); }
        double width(FontId font, const(wchar)[] text) { return text.length * (font == LogFont.header ? 7.0 : 6.0); }
        int wrappedLines(FontId font, const(wchar)[] text, double width) { return -1; }
    }

    auto column = new TextColumn(ColumnDef("time", "Time", 60), defaultLogLook(), new Ruler);
    column.style.cell.padLeft = column.style.header.padLeft = 5;
    column.lookChanged();
    const short_ = CellData("12345"w), long_ = CellData("123456789012345"w);
    const shortCell = CellInput(0, 0, &short_), longCell = CellInput(0, 0, &long_);
    assert(column.measure(shortCell, 100, true).maxWidth == 5 + 60 + 3, "a short text: the least width and the paddings");
    assert(column.measure(longCell, 100, true).maxWidth == 5 + 15 * 6.0 + 3, "a longer text than the least width: the text");
    assert(column.measureHeader().maxWidth == 5 + 60 + 3, "a short title: the least width and the paddings of the header");
}

@("TextColumn.leastWidth: the least width of the content and the wider paddings of a cell and of the title")
unittest
{
    import ui.log_table.log_look : defaultLogLook;

    auto column = new TextColumn(ColumnDef("time", "Time", 60), defaultLogLook(), null);
    column.style.cell.padLeft = 5;
    column.style.header.padLeft = 8;
    column.lookChanged();
    assert(column.leastWidth == 8 + 60 + 3, "the paddings of the title are wider: 8 left and the 3 of the table right");
}

@("TextColumn: a title stands where the painter and the table placed it, by the header style of the column, and measures what they measured")
unittest
{
    import ptable.column : HeaderState;
    import ptable_text.columnstyle : Halign, alignedX;
    import ptable.model : CellData;
    import ptable.painter : CellContext;
    import ptable.ports : Color, FontId;
    import ptable_text.measurer : FontMetrics;
    import ui.log_table.log_look : LogColor, LogFont, defaultLogLook;
    import ui.log_table.painter : LogPainter;
    import std.format : format;

    static final class Ruler : TextMeasurer
    {
        FontMetrics metrics(FontId font) { return font == LogFont.header ? FontMetrics(9, 3, 12) : FontMetrics(11, 3, 14); }
        double width(FontId font, const(wchar)[] text) { return text.length * (font == LogFont.header ? 7.0 : 6.0); }
        int wrappedLines(FontId font, const(wchar)[] text, double width) { return -1; }
    }

    static final class Noted : Canvas
    {
        string[] calls;
        void fillRect(Rect area, Color color) { calls ~= format("fill %s", color); }
        void drawText(FontId font, const(wchar)[] text, double x, double baseline, Color color)
        {
            calls ~= format("%s f%s %s,%s %s", text, font, x, baseline, color);
        }
        void drawParagraph(FontId font, const(wchar)[] text, double x, double top, double width, Color color) {}
        void fillRoundRect(Rect area, double radius, Color color) { fillRect(area, color); }
        void fillCircle(double cx, double cy, double radius, Color fill, Color line) {}
        void pushClip(Rect area) {}
        void popClip() {}
    }

    auto measurer = new Ruler;
    auto look = defaultLogLook();
    const palette = look.palette;
    Color ink = palette.ink, found = palette.found, error = palette.error; // mutable copies: they format without "const"
    const area = Rect(40, 0, 90, 24);
    HeaderState none;
    foreach (halign; [Halign.inherit, Halign.center, Halign.right])
    {
        auto def = ColumnDef("time", "Time");
        auto column = new TextColumn(def, look, measurer);
        column.style.header.halign = halign;
        column.style.header.padLeft = 5;
        column.lookChanged();
        auto canvas = new Noted;
        column.drawHeader(canvas, area, none);
        const x = alignedX(halign, area.x, area.w, 4 * 7.0, 5, 3); // the painter's `textX` in the header font
        const baseline = round((area.h - 12) / 2.0 + 9); // centered by the font of the title
        assert(canvas.calls == [format("Time f%s %s,%s %s", cast(FontId) LogFont.header, x, baseline, ink)], canvas.calls[0]);
        const measured = column.measureHeader();
        assert(measured.maxWidth == 5 + 4 * 7.0 + 3, "the title in the header font and its paddings: what the table measured");
        assert(measured.height == 12 + 2 * (1 + 2), "the line of the title and the room of the header: what the table made of the fonts");
    }
    auto def = ColumnDef("time", "Time");
    auto column = new TextColumn(def, look, measurer);
    column.style.header.back = LogColor.found;
    column.style.header.ink = LogColor.error;
    column.lookChanged();
    auto canvas = new Noted;
    column.drawHeader(canvas, area, none);
    assert(canvas.calls.length == 2 && canvas.calls[0] == format("fill %s", found) && canvas.calls[1][$ - format("%s", error).length .. $]
        == format("%s", error), "the back and the ink of the style");
}

@("TextColumn: the head of a group stands where the table placed it, by the group style of the column, in the ink of the groups, and measures what the table measured")
unittest
{
    import ptable.column : GroupInput;
    import ptable_text.columnstyle : Halign, alignedX;
    import ptable.ports : Color, FontId;
    import ptable_text.measurer : FontMetrics;
    import ui.log_table.log_look : LogColor, LogFont, defaultLogLook;
    import std.format : format;

    static final class Ruler : TextMeasurer
    {
        FontMetrics metrics(FontId font) { return font == LogFont.header ? FontMetrics(9, 3, 12) : FontMetrics(11, 3, 14); }
        double width(FontId font, const(wchar)[] text) { return text.length * (font == LogFont.header ? 7.0 : 6.0); }
        int wrappedLines(FontId font, const(wchar)[] text, double width) { return -1; }
    }

    static final class Noted : Canvas
    {
        string[] calls;
        void fillRect(Rect area, Color color) { calls ~= format("fill %s", color); }
        void drawText(FontId font, const(wchar)[] text, double x, double baseline, Color color)
        {
            calls ~= format("%s f%s %s,%s %s", text, font, x, baseline, color);
        }
        void drawParagraph(FontId font, const(wchar)[] text, double x, double top, double width, Color color) {}
        void fillRoundRect(Rect area, double radius, Color color) { fillRect(area, color); }
        void fillCircle(double cx, double cy, double radius, Color fill, Color line) {}
        void pushClip(Rect area) {}
        void popClip() {}
    }

    auto measurer = new Ruler;
    auto look = defaultLogLook();
    Color ink = look.palette.groupInk, error = look.palette.error, found = look.palette.found; // mutable: they format without "const"
    const plate = Rect(40, 60, 90, 24);
    const head = GroupInput("2026/11/18"w);
    foreach (halign; [Halign.inherit, Halign.center, Halign.right])
    {
        auto def = ColumnDef("time", "Time");
        auto column = new TextColumn(def, look, measurer);
        column.style.group.halign = halign;
        column.lookChanged();
        auto canvas = new Noted;
        column.drawGroup(canvas, head, plate);
        const x = alignedX(halign, plate.x, plate.w, 10 * 7.0, 3, 3); // the table's `groupTextX`, in the header font
        const baseline = plate.y + round((plate.h - 12) / 2.0 + 9); // centered by the font of the head
        assert(canvas.calls == [format("2026/11/18 f%s %s,%s %s", cast(FontId) LogFont.header, x, baseline, ink)], canvas.calls[0]);
        const measured = column.measureGroup(head);
        assert(measured.maxWidth == 10 * 7.0 + 2 * 3, "the head in the header font and the paddings of the table: what a head grew its column to");
        assert(measured.height == 12 + 2 * (1 + 2), "as high as a title of its font");
    }
    auto def = ColumnDef("time", "Time");
    auto column = new TextColumn(def, look, measurer);
    column.style.group.back = LogColor.found;
    column.style.group.ink = LogColor.error;
    column.lookChanged();
    auto canvas = new Noted;
    column.drawGroup(canvas, head, plate);
    assert(canvas.calls.length == 2 && canvas.calls[0] == format("fill %s", found) && canvas.calls[1][$ - format("%s", error).length .. $]
        == format("%s", error), "the back and the ink of the style");
}
