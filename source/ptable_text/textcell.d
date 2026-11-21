//! The column of text: its cells are lines of a font in a style (`ColumnStyle`), broken by the advances of the glyphs or wrapped by the
//! host's text engine (a paragraph). It lays its cell out, measures it, draws its text, answers where a point is in it, which rectangles
//! a part of it takes and what a double click selects; its title and the heads of its groups are measured here, drawn by a column that
//! knows colors (a log's `TextColumn`). The table keeps no line of it: the column breaks the text again where it draws and hit-tests.
//! The look of the colors is not here: `inkOf` and the title and group drawing are for the subclass. See docs/stories/painted-table.md.
module ptable_text.textcell;

import ptable.cellmemo : CellMemo;
import ptable.column : CellInput, CellLayout, DrawState, GroupInput, Measured, TableColumn, Unit;
import ptable.layout : ColumnDef;
import ptable.memory : Arena;
import ptable.ports : Canvas, Color, FontId, Rect, Span;
import ptable_text.columnstyle : ColumnStyle, Halign, alignOffset, alignedTopInView, alignedX, alignedXInView, noFont;
import ptable_text.measurer : FontMetrics, TextMeasurer;
import ptable_text.runs : eachRun, lineMemo, lineWidth, shown, xAt;
import ptable_text.texthit : TextSpot, caretInText, rectsInText, unitInText;
import ptable_text.wrap : LineSpan, firstLineWidth, glyphWidth, maxMeasuredChars, wrapLines;

import std.algorithm.comparison : max;
import std.conv : to;
import std.math : ceil, round;

/// A column of text. `measurer` null: a column that measures nothing (its widths are 0, its metrics too)
class TextCell : TableColumn
{
    /// The room left and right of a text, above and under the line of a cell, above and under a title, where the style leaves it
    enum double sidePad = 3, linePad = 1, titlePad = 3;

    ColumnStyle style; /// how its cells, its title and the heads of its groups look
    private TextMeasurer _measurer;
    private Metrics _metrics; // of its fonts, measured at `lookChanged`
    private wstring _title;
    private double[256] _lowAdvances = -1; // the widths of the first 256 glyphs in the font of the cells, -1 not measured yet: most of a log
    private double[dchar] _advances; // of the others (metrics of the font, not content: both kept until the look changes)
    private LineSpan[] _lines; // the lines of the last text wrapped: the scratch of the wrap and its answer
    private LineSpan[1] _one; // the one line of a cell that is not wrapped
    private wchar[] _wrapped; // that text, the width it was wrapped in and whether `_lines` are its lines: a cell is drawn, hit and drawn again
    private double _wrappedIn = -1; // in a row, and the same text would be wrapped again by each (a copy: the memory of the pass is reused)
    private bool _paragraph; // the host wraps the cells (what its measurer said when the last cell was laid out)

    private struct Metrics
    {
        FontMetrics cell, header, group;
    }

    this(ColumnDef def, TextMeasurer measurer = null)
    {
        super(def);
        _measurer = measurer;
        _title = def.title.to!wstring;
    }

    /// The fonts of the cells, of the title, of the heads of groups where the style names none
    protected FontId defaultCellFont() const nothrow { return 0; }

    /// ditto
    protected FontId defaultHeaderFont() const nothrow { return 0; }

    /// ditto
    protected FontId defaultGroupFont() const nothrow { return 0; }

    /// The font of its cells, of its title, of the heads of its groups: the style's, else the default one
    final FontId cellFont() const nothrow
    {
        return style.cell.font != noFont ? style.cell.font : defaultCellFont;
    }

    /// ditto
    final FontId headerFont() const nothrow
    {
        return style.header.font != noFont ? style.header.font : defaultHeaderFont;
    }

    /// ditto
    final FontId groupFont() const nothrow
    {
        return style.group.font != noFont ? style.group.font : defaultGroupFont;
    }

    /// The fonts may have changed: their metrics are read again
    override void lookChanged()
    {
        _advances = null;
        _lowAdvances[] = -1;
        _wrappedIn = -1;
        if (_measurer is null)
            return;
        _metrics = Metrics(_measurer.metrics(cellFont), _measurer.metrics(headerFont), _measurer.metrics(groupFont));
    }

    /// What its cells are measured by (null: nothing)
    protected final TextMeasurer measurer() { return _measurer; }

    /// The metrics of the fonts of the cells, of the title, of the heads of groups, as they were at the last `lookChanged`
    protected final FontMetrics cellMetrics() const { return _metrics.cell; }

    /// ditto
    protected final FontMetrics headerMetrics() const { return _metrics.header; }

    /// ditto
    protected final FontMetrics groupMetrics() const { return _metrics.group; }

    /// The title of the column as text
    protected final wstring title() const { return _title; }

    /// What a pixel of the design is in the font now: the line of the font of the cells over the 14 px it was drawn for
    protected final double unit() const
    {
        return _metrics.cell.lineHeight > 0 ? ceil(_metrics.cell.lineHeight) / 14.0 : 1.0;
    }

    /// One line of the text of the cell in its font with the room around it the style gives, at least the least height of the column; the
    /// widths if asked: of the whole text, or of the first line for the flex column that does not wrap (the flex column that wraps is laid out
    /// by `layout`)
    override Measured measure(ref const CellInput cell, double width, bool widths)
    {
        Measured m;
        m.height = heightOf(1);
        if (widths && cell.data !is null && _measurer !is null)
        {
            const style = this.style.cell;
            const font = fontOf(cell);
            const text = cell.data.text;
            // as the line is drawn: by its runs (a whole layout would lay a tab out to its stop, and round once, not by the word)
            double runs(const(wchar)[] t) { return lineWidth(t, (const(wchar)[] piece) => _measurer.width(font, piece)); }
            const textWidth = def.flex ? firstLineWidth(text, &runs) : runs(text);
            m.maxWidth = m.minWidth = style.left(sidePad) + max(textWidth, def.minWidth) + style.right(sidePad); // the least width is of the text
        }
        return m;
    }

    /// The flex column breaks its cells into lines unless its style says it does not (the single-line view)
    /// The least width of the content and the paddings of a cell or of the title, the wider: the column holds both
    override double leastWidth() const
    {
        const cell = style.cell.left(sidePad) + style.cell.right(sidePad), title = style.header.left(sidePad) + style.header.right(sidePad);
        return max(cell, title) + def.minWidth;
    }

    override bool wraps() const
    {
        return def.flex && style.wrap;
    }

    // A cell of `lines` lines and the room the style gives above and under them, at least the least height of the column
    private double heightOf(size_t lines) const
    {
        const style = this.style.cell;
        return max(this.style.minHeight, lines * ceil(_metrics.cell.lineHeight)) + style.top(linePad) + style.bottom(linePad); // the least height is of the lines
    }

    /// The title: one line in the header font of the style, with the room of the header around it
    override Measured measureHeader()
    {
        const style = this.style.header;
        const textWidth = _measurer !is null ? _measurer.width(headerFont, _title) : 0;
        Measured m;
        m.maxWidth = m.minWidth = style.left(sidePad) + max(textWidth, def.minWidth) + style.right(sidePad); // the least width of the column, as a cell
        m.height = ceil(_metrics.header.lineHeight) + style.top(titlePad) + style.bottom(titlePad);
        return m;
    }

    /// The head of a group: one line in the group font of the style, with the room of a title around it
    override Measured measureGroup(in GroupInput group)
    {
        const style = this.style.group;
        const textWidth = _measurer !is null ? _measurer.width(groupFont, group.head) : 0;
        Measured m;
        m.maxWidth = m.minWidth = style.left(sidePad) + textWidth + style.right(sidePad);
        m.height = ceil(_metrics.group.lineHeight) + style.top(titlePad) + style.bottom(titlePad);
        return m;
    }

    /// Where the text of a cell stands in its area: the font, where its lines start, the top and the baseline of the first, the height of a line
    protected struct Spot
    {
        FontId font;
        double x = 0, top = 0, baseline = 0, line = 0;
    }

    /// The font the text of the cell is set in: the column's (a level is bold by the data of its cell)
    protected FontId fontOf(ref const CellInput cell) const
    {
        return cellFont;
    }

    /// The text of the cell in `area` with `lines` lines: aligned by the style between its paddings, its lines in the middle of the room above and
    /// under them unless the style puts them at the top or the bottom; aligned in the part `view` of the cell that is seen (`DrawState.clip`)
    /// on an axis the style keeps in view
    protected final Spot spotOf(ref const CellInput cell, Rect area, Rect view, size_t lines = 1)
    {
        const style = this.style.cell;
        Spot spot;
        spot.font = fontOf(cell);
        spot.line = ceil(_metrics.cell.lineHeight);
        const text = cell.data !is null ? cell.data.text : ""w;
        const atLeft = style.halign == Halign.left || style.halign == Halign.inherit;
        const width = atLeft && !style.keepInViewX || _measurer is null ? 0.0
            : lineWidth(text, (const(wchar)[] piece) => _measurer.width(spot.font, piece)); // as drawn; kept in view: it stops at the far side
        spot.x = alignedAcross(width, area, view);
        const above = style.top(linePad), under = style.bottom(linePad);
        // a paragraph's lines are the host's: asked only where they move it, so a column not kept in view stands as it did
        const paragraphLines = _paragraph && style.keepInViewY && _measurer !is null ? _measurer.wrappedLines(spot.font, text, style.inner(area.w, sidePad)) : 0;
        const content = max(1, lines, paragraphLines) * spot.line;
        spot.top = style.keepInViewY ? alignedTopInView(style.valign, area.y, area.h, content, above, under, view.down)
            : area.y + above + alignOffset(style.valign, area.h - above - under, content);
        spot.baseline = spot.top + round(_metrics.cell.ascent);
        return spot;
    }

    /// Where a content `width` wide starts across the cell `area` seen in `view`: by the alignment of the style between its paddings, in the
    /// part seen if the style keeps it in view across. The text of the cell stands so (`spotOf`); a column that draws marks of its own places
    /// them by it
    protected final double alignedAcross(double width, Rect area, Rect view) const
    {
        const style = this.style.cell;
        const left = style.left(sidePad), right = style.right(sidePad);
        return style.keepInViewX ? alignedXInView(style.halign, area.x, area.w, width, left, right, view.across)
            : alignedX(style.halign, area.x, area.w, width, left, right);
    }

    /// Whether the host wraps the cells (a paragraph, drawn by `Canvas.drawParagraph`): its lines are not the column's to know
    protected final bool paragraph() const { return _paragraph; }

    /// The lines of the text of the cell in a cell `cellWidth` wide: the column's own wrap for the flex column that wraps, one line cut at a hard
    /// break for the one that does not, none for another column (all of its text is one line); none for a paragraph (the host wraps it). They
    /// are in a scratch of the column, valid until its next call
    protected final const(LineSpan)[] linesOf(ref const CellInput cell, double cellWidth)
    {
        if (!def.flex || _measurer is null || cell.data is null || _paragraph)
            return null;
        const text = cell.data.text;
        if (!style.wrap)
        {
            size_t end = 0;
            while (end < text.length && text[end] != '\n')
                ++end;
            _one[0] = LineSpan(0, end);
            return _one[];
        }
        wrap(text, style.cell.inner(cellWidth, sidePad));
        return _lines;
    }

    // `text` in `width` into `_lines`, unless they are those of the text wrapped last
    private void wrap(const(wchar)[] text, double width)
    {
        if (_wrappedIn == width && _wrapped == text)
            return;
        wrapLines(_lines, text, width, &advanceOf);
        _wrapped.length = 0;
        assumeSafeAppend(_wrapped);
        _wrapped ~= text;
        _wrappedIn = width;
    }

    /// The text of the cell in `ink`, in a paragraph drawn in `paragraphInk`: a paragraph the host wraps, or each line of it where the column broke
    /// it; a line that is not on the screen is not drawn (a record of hundreds of lines draws only those it shows)
    protected final void drawText(Canvas canvas, ref const CellInput cell, ref const DrawState state, Color ink, Color paragraphInk)
    {
        const text = cell.data !is null ? cell.data.text : ""w;
        if (text.length == 0)
            return;
        const lines = linesOf(cell, state.area.w);
        const spot = spotOf(cell, state.area, state.clip, lines.length);
        if (_paragraph)
        {
            canvas.drawParagraph(spot.font, text, spot.x, spot.top, style.cell.inner(state.area.w, sidePad), paragraphInk);
            return;
        }
        if (lines.length == 0)
        {
            drawLine(canvas, text, spot.font, spot.x, spot.baseline, state.clip, ink, lineMemo(cell.memo, 0, text.length, spot.font));
            return;
        }
        if (!style.wrap && drawCutLine(canvas, text[lines[0].start .. lines[0].end], cell, state, spot, ink))
            return;
        foreach (j, line; lines)
        {
            const lineTop = spot.top + j * spot.line;
            if (lineTop + spot.line < state.clip.y)
                continue;
            if (lineTop > state.clip.bottom)
                break;
            drawLine(canvas, text[line.start .. line.end], spot.font, spot.x, spot.baseline + j * spot.line, state.clip, ink,
                lineMemo(cell.memo, line.start, line.end - line.start, spot.font));
        }
    }

    // The one line of the flex column that does not wrap, if the right side of its cell is seen and the line runs past it (wider than the
    // widest column, `maxFitWidth`, or wider than measured): cut before an ellipsis at the right padding. False: it is not cut there. Only
    // the end of the line is walked, from the last mark of the memo; a line measured whole (`measure`) is never: its column is as wide as it
    private bool drawCutLine(Canvas canvas, const(wchar)[] line, ref const CellInput cell, ref const DrawState state, ref const Spot spot, Color ink)
    {
        const limit = state.area.right - style.cell.right(sidePad);
        if (line.length <= maxMeasuredChars || state.clip.right < limit)
            return false;
        auto memo = lineMemo(cell.memo, 0, line.length, spot.font);
        const font = spot.font;
        if (xAt(line, line.length, (const(wchar)[] piece) => _measurer.width(font, piece), memo, limit - spot.x) <= limit - spot.x)
            return false;
        enum wstring ellipsis = "…";
        const dots = _measurer.width(font, ellipsis);
        const room = Rect(state.clip.x, state.clip.y, max(0.0, limit - dots - state.clip.x), state.clip.h);
        canvas.pushClip(room);
        drawLine(canvas, line, font, spot.x, spot.baseline, room, ink, memo);
        canvas.popClip();
        canvas.drawText(font, ellipsis, limit - dots, spot.baseline, ink);
        return true;
    }

    // A line run by run (ptable_text/runs): each word and each gap by a layout of its own at the widths of those before it, only those
    // that cross the part seen, from the last mark of `memo` before it; a gap of tabs as as many spaces (a tab is drawn as a space)
    private void drawLine(Canvas canvas, const(wchar)[] line, FontId font, double x, double baseline, Rect clip, Color ink, CellMemo* memo)
    {
        if (_measurer is null)
        {
            canvas.drawText(font, line, x, baseline, ink);
            return;
        }
        eachRun(line, clip.x - x, clip.right - x, (const(wchar)[] piece) => _measurer.width(font, piece), (size_t start, size_t end, double at) {
            const run = line[start .. end];
            canvas.drawText(font, shown(run), x + at, baseline, ink);
        }, memo);
    }

    /// The text of the cell in black (a column that knows colors draws it in its own ink)
    override void draw(Canvas canvas, ref const CellInput cell, ref const DrawState state)
    {
        drawText(canvas, cell, state, Color(0, 0, 0), Color(0, 0, 0));
    }

    /// Where the text of the cell lies in `area` seen in `view`, for the hit tests and the selection
    private TextSpot textSpotOf(ref const CellInput cell, Rect area, Rect view)
    {
        const lines = linesOf(cell, area.w);
        const spot = spotOf(cell, area, view, lines.length);
        return TextSpot(spot.font, spot.x, spot.top, spot.line, lines);
    }

    /// The caret nearest to the point in the text of the cell: in the line the height says, between the two characters nearest to it
    override size_t hitTest(ref const CellInput cell, Rect area, Rect view, double x, double y)
    {
        const text = cell.data !is null ? cell.data.text : ""w;
        if (_measurer is null)
            return 0;
        const spot = textSpotOf(cell, area, view);
        return caretInText(text, spot, _measurer, x, y, cell.memo);
    }

    /// The rectangles of a part of the text: one for a cell of one line, one for each line a part of a wrapped cell touches
    override void rects(ref const CellInput cell, Rect area, Rect view, size_t from, size_t to, scope void delegate(Rect) emit)
    {
        if (_measurer is null || cell.data is null)
            return;
        const spot = textSpotOf(cell, area, view);
        rectsInText(cell.data.text, spot, _measurer, from, to, emit, cell.memo);
    }

    /// What a double click (the word at the caret) or a triple click (the whole text) selects
    override size_t[2] expand(ref const CellInput cell, size_t at, Unit unit)
    {
        return unitInText(cell.data !is null ? cell.data.text : ""w, at, unit);
    }

    /// The height of the cell in `width`: one line cut where the cell ends (and at a hard break: the rest is no part of the row) for a
    /// column that does not wrap, else its lines in `width`, or as many as the measurer says it wraps itself (a paragraph)
    override CellLayout layout(ref const CellInput cell, double width, ref Arena arena)
    {
        CellLayout done;
        _paragraph = false;
        if (!style.wrap || _measurer is null)
        {
            done.height = heightOf(1);
            return done;
        }
        const text = cell.data.text;
        const inner = style.cell.inner(width, sidePad);
        const own = _measurer.wrappedLines(cellFont, text, inner);
        if (own >= 0)
        {
            _paragraph = true;
            done.height = heightOf(max(1, own));
            return done;
        }
        wrap(text, inner);
        done.height = heightOf(_lines.length);
        return done;
    }

    // The width of a glyph in the font of the cells, measured once until the look changes
    private double advanceOf(dchar glyph) nothrow
    {
        if (glyph < _lowAdvances.length)
        {
            if (_lowAdvances[glyph] < 0)
                _lowAdvances[glyph] = glyphWidth(_measurer, cellFont, glyph);
            return _lowAdvances[glyph];
        }
        if (auto known = glyph in _advances)
            return *known;
        const width = glyphWidth(_measurer, cellFont, glyph);
        try
            _advances[glyph] = width;
        catch (Exception)
        {
        }
        return width;
    }
}

@("TextCell: a text kept in view aligns in the part of the cell seen, on each axis on its own; the hit test finds it where it is drawn")
unittest
{
    import ptable.model : CellData;
    import ptable_text.columnstyle : Valign;
    import ptable_text.testing : TestText;

    auto column = new TestText(ColumnDef("c", "C"));
    column.style.cell.halign = Halign.center;
    column.style.cell.valign = Valign.middle;
    const data = CellData("ab"w); // 20 wide, a line of 14, 1 above and under it
    const cell = CellInput(0, 0, &data);
    const area = Rect(100, 100, 60, 60), cut = Rect(130, 130, 30, 30); // the left and the top of the cell are not seen
    Rect where(Rect view)
    {
        Rect r;
        column.rects(cell, area, view, 0, 2, (Rect got) { r = got; });
        return r;
    }

    assert(where(area) == Rect(120, 123, 20, 14) && where(cut) == Rect(120, 123, 20, 14), "not kept in view: where it is");
    column.style.cell.keepInViewX = true;
    assert(where(area) == Rect(120, 123, 20, 14), "seen whole: where it is");
    assert(where(cut) == Rect(135, 123, 20, 14), "across only: the middle of the part seen, the same height");
    column.style.cell.keepInViewY = true;
    assert(where(cut) == Rect(135, 138, 20, 14), "both");
    assert(column.hitTest(cell, area, cut, 145, 140) == 1, "between the two glyphs where they are drawn");
    column.style.cell.halign = Halign.left;
    assert(where(cut) == Rect(133, 138, 20, 14), "the left one stays at the left of the part seen");
}

@("TextCell: a paragraph the host wraps is kept in view by all of its lines, not as one")
unittest
{
    import ptable.memory : Arena;
    import ptable.model : CellData;
    import ptable_text.columnstyle : Valign;
    import ptable_text.measurer : FontMetrics;
    import ptable_text.testing : TestText;

    static final class Wraps : TextMeasurer // the host wraps every text into 3 lines of 14
    {
        FontMetrics metrics(FontId font) { return FontMetrics(11, 3, 14); }
        double width(FontId font, const(wchar)[] text) { return text.length * 10.0; }
        int wrappedLines(FontId font, const(wchar)[] text, double width) { return 3; }
    }

    static final class Top : Canvas
    {
        double top = double.nan;
        void fillRect(Rect area, Color color) {}
        void drawText(FontId font, const(wchar)[] text, double x, double baseline, Color color) {}
        void drawParagraph(FontId font, const(wchar)[] text, double x, double top, double width, Color color) { this.top = top; }
        void fillRoundRect(Rect area, double radius, Color color) { fillRect(area, color); }
        void fillCircle(double cx, double cy, double radius, Color fill, Color line) {}
        void pushClip(Rect area) {}
        void popClip() {}
    }

    auto column = new TestText(ColumnDef("text", "Text", 24, true), new Wraps);
    column.style.cell.valign = Valign.middle;
    column.style.cell.keepInViewY = true;
    const data = CellData("a long text"w);
    const cell = CellInput(0, 0, &data);
    Arena arena;
    column.layout(cell, 60, arena); // 3 lines: a paragraph of the host
    auto canvas = new Top;
    DrawState state;
    state.area = Rect(100, 100, 60, 60); // the room 101..159, the paragraph 42 high
    state.clip = Rect(100, 130, 60, 30); // the top of the cell is not seen
    column.draw(canvas, cell, state);
    assert(canvas.top == 159 - 42, "it stops at the bottom padding with all of its lines in the cell");
}

@("TextCell: a line is drawn by its words and its gaps, each at the widths of those before it; a tab as a space")
unittest
{
    import ptable.model : CellData;
    import ptable_text.measurer : FontMetrics;
    import ptable_text.testing : TestText;

    static final class Tabs : TextMeasurer // a tab as a text engine lays it out: to its stop
    {
        FontMetrics metrics(FontId font) { return FontMetrics(11, 3, 14); }
        double width(FontId font, const(wchar)[] text)
        {
            double w = 0;
            foreach (c; text)
                w += c == '\t' ? 80 : 10;
            return w;
        }
        int wrappedLines(FontId font, const(wchar)[] text, double width) { return -1; }
    }

    static final class Texts : Canvas
    {
        wstring[] texts;
        double[] xs;
        void fillRect(Rect area, Color color) {}
        void drawText(FontId font, const(wchar)[] text, double x, double baseline, Color color) { texts ~= text.idup; xs ~= x; }
        void drawParagraph(FontId font, const(wchar)[] text, double x, double top, double width, Color color) {}
        void fillRoundRect(Rect area, double radius, Color color) {}
        void fillCircle(double cx, double cy, double radius, Color fill, Color line) {}
        void pushClip(Rect area) {}
        void popClip() {}
    }

    auto column = new TestText(ColumnDef("text", "Text"), new Tabs);
    const data = CellData("ab  c\td"w);
    const cell = CellInput(0, 0, &data);
    auto canvas = new Texts;
    DrawState state;
    state.area = Rect(0, 0, 500, 20);
    state.clip = state.area;
    column.draw(canvas, cell, state);
    assert(canvas.texts == ["ab"w, "  "w, "c"w, " "w, "d"w]);
    const x0 = canvas.xs[0];
    assert(canvas.xs == [x0, x0 + 20, x0 + 40, x0 + 50, x0 + 60]);
}

@("TextCell: a line of the flex column that does not wrap, cut by the right side of its cell, ends in an ellipsis where that side is seen")
unittest
{
    import ptable.model : CellData;
    import ptable_text.testing : TestText;

    static final class Texts : Canvas
    {
        wstring[] texts;
        double[] xs;
        Rect[] clips;
        void fillRect(Rect area, Color color) {}
        void drawText(FontId font, const(wchar)[] text, double x, double baseline, Color color) { texts ~= text.idup; xs ~= x; }
        void drawParagraph(FontId font, const(wchar)[] text, double x, double top, double width, Color color) {}
        void fillRoundRect(Rect area, double radius, Color color) {}
        void fillCircle(double cx, double cy, double radius, Color fill, Color line) {}
        void pushClip(Rect area) { clips ~= area; }
        void popClip() {}
    }

    Texts drawn(bool flex, wstring text, Rect clip)
    {
        auto column = new TestText(ColumnDef("text", "Text", 24, flex)); // a glyph 10 wide, the text 3 from each side
        column.style.wrap = false;
        const data = CellData(text);
        const cell = CellInput(0, 0, &data);
        auto canvas = new Texts;
        DrawState state;
        state.area = Rect(0, 0, 60, 20);
        state.clip = clip;
        column.draw(canvas, cell, state);
        return canvas;
    }

    import std.array : replicate;
    import ptable_text.runs : maxRun;
    import ptable_text.wrap : maxMeasuredChars;

    const whole = Rect(0, 0, 60, 20);
    const long_ = "a"w.replicate(maxMeasuredChars + 1); // wider than measured: its column may be narrower than it
    auto cut = drawn(true, long_, whole);
    assert(cut.texts == [long_[0 .. maxRun], "…"w] && cut.xs == [3, 47], "the line, then the ellipsis at the right padding");
    assert(cut.clips == [Rect(0, 0, 47, 20)], "the line stops where the ellipsis begins");
    assert(drawn(true, long_, Rect(0, 0, 30, 20)).texts == [long_[0 .. maxRun]], "the right side not seen: no ellipsis");
    assert(drawn(true, "abcdefghij"w, whole).texts == ["abcdefghij"w],
        "a line measured whole: its column is as wide as it (here it is not), it is not walked to its end for the ellipsis");
    assert(drawn(false, long_, whole).texts.length == 1, "another column: none (it grows to its text)");
}

@("TextCell.measure: the width of a cell is that of its runs as they are drawn: a tab as a space")
unittest
{
    import ptable.model : CellData;
    import ptable_text.measurer : FontMetrics;
    import ptable_text.testing : TestText;

    static final class Tabs : TextMeasurer // a tab as a text engine lays it out: to its stop
    {
        FontMetrics metrics(FontId font) { return FontMetrics(11, 3, 14); }
        double width(FontId font, const(wchar)[] text)
        {
            double w = 0;
            foreach (c; text)
                w += c == '\t' ? 80 : 10;
            return w;
        }
        int wrappedLines(FontId font, const(wchar)[] text, double width) { return -1; }
    }

    foreach (flex; [false, true])
    {
        auto column = new TestText(ColumnDef("text", "Text", 24, flex), new Tabs);
        column.style.wrap = false;
        const tabbed = CellData("ab\tcd"w), spaced = CellData("ab cd"w);
        const ca = CellInput(0, 0, &tabbed), cb = CellInput(0, 0, &spaced);
        const a = column.measure(ca, 0, true), b = column.measure(cb, 0, true);
        assert(a.maxWidth == b.maxWidth, "a tab measured to its stop, drawn as a space");
    }
}

@("TextCell: a short cell drawn takes no memo of its row; a long line does")
unittest
{
    import std.array : replicate;
    import ptable.cellmemo : CellMemos, MemoRef;
    import ptable.memory : mallocAllocator;
    import ptable.model : CellData;
    import ptable_text.testing : TestText;

    static final class Nothing : Canvas
    {
        void fillRect(Rect area, Color color) {}
        void drawText(FontId font, const(wchar)[] text, double x, double baseline, Color color) {}
        void drawParagraph(FontId font, const(wchar)[] text, double x, double top, double width, Color color) {}
        void fillRoundRect(Rect area, double radius, Color color) {}
        void fillCircle(double cx, double cy, double radius, Color fill, Color line) {}
        void pushClip(Rect area) {}
        void popClip() {}
    }

    auto memos = new CellMemos(mallocAllocator());
    memos.fit(64);
    auto column = new TestText(ColumnDef("text", "Text"));
    const short_ = CellData("07:16:22.000000"w), long_ = CellData("word "w.replicate(2000));
    DrawState state;
    state.area = Rect(0, 0, 500, 20);
    state.clip = state.area;
    foreach (uint col; 0 .. 6) // five short cells drawn before the Payload, as a row of the log is
    {
        auto cell = CellInput(7, col, col < 5 ? &short_ : &long_);
        cell.memo = MemoRef(memos, 7, col);
        column.draw(new Nothing, cell, state);
    }
    assert(memos.count == 1, "the short cells took places of the row");
}
