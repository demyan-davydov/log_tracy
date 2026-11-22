//! How the log table looks when the log table (ptable) draws it: the fonts, the colors (`LogPalette`) and the
//! spacing (`LogSpacing`) the script reads from the CSS of the themes and of the table (resources/log-table-look.js), the
//! cells of the Index, the levels, the anchor marks, the Payload and the groups of rows (a day), written as a `Painter`. Free of Sciter. See docs/stories/painted-table.md.
module ui.log_table.painter;

import ptable.column : CellInput, CellLayout, DrawState, GroupInput, HeaderState, TableColumn;
import ptable_text.columnstyle : alignedX, CellStyle, ColorId, noColor;
import ptable.layout : ColumnDef;
import ui.log_table.marks;
import ui.log_table.log_look;
import log_core.log_level : LogLevel;
import ptable.model : RowData;
import ptable.painter;
import ptable.ports;
import ptable_text.measurer : FontMetrics, TextMeasurer;
import ptable.scrollbar : Orientation, ScrollBarPainter;

import std.algorithm.searching : canFind;
import std.algorithm.comparison : max;
import std.math : round;

/// The look of the scroll bar over the edge of the log table (ux.md rule 46): a thin rounded thumb at the edge; under the mouse
/// (or held) it is as thick as the strip and a semi-transparent track shows under it. The rows show around it.
final class LogScrollBarPainter : ScrollBarPainter
{
    // Trial values, to be tuned by eye
    private enum double thin = 4; // the thickness of the thumb at rest
    private enum double inset = 2; // the room between the thumb and the edges of the strip
    private enum ubyte thumbAlpha = 77;
    private enum ubyte strongAlpha = 204; // the wide thumb, 0.8 (the user, 2026-11-20)
    private enum ubyte trackAlpha = 26; // the track of the wide bar, 0.1 (the user, 2026-11-20)

    private LogLook _look;

    this(LogLook look)
    {
        _look = look;
    }

    this()
    {
        this(defaultLogLook());
    }

    // The thumb and the track are the ink of the table, see-through: the theme has no color of its own for them
    private Color ink(ubyte alpha) const
    {
        const ink = _look.palette.ink;
        return Color(ink.r, ink.g, ink.b, alpha);
    }

    // The ink of the thumb `wide` of the way from at rest to wide
    private Color thumbInk(double wide) const
    {
        return ink(cast(ubyte)(thumbAlpha + (strongAlpha - thumbAlpha) * wide));
    }

    // How thick the thumb is, `wide` of the way from thin to all of the strip
    private static double thickness(double across, double wide)
    {
        return thin + (across - 2 * inset - thin) * wide;
    }

    // The thumb drawn: thin at the outer edge of the strip, widening inwards
    private static Rect thumbRect(Rect strip, Rect thumb, double wide, bool vertical)
    {
        const across = vertical ? strip.w : strip.h; // the thickness of the strip
        const thick = thickness(across, wide);
        const at = across - inset - thick; // from the strip's start: the thin thumb keeps to the outer edge, it widens inwards
        return vertical ? Rect(strip.x + at, thumb.y, thick, thumb.h) : Rect(thumb.x, strip.y + at, thumb.w, thick);
    }

    override void paint(Canvas canvas, Rect strip, Rect track, Rect thumb, double wide, Orientation orientation)
    {
        if (thumb.w <= 0 || thumb.h <= 0)
            return;
        if (wide > 0)
            canvas.fillRect(track, ink(cast(ubyte)(trackAlpha * wide)));
        const rect = thumbRect(strip, thumb, wide, orientation == Orientation.vertical);
        canvas.fillRoundRect(rect, rect.w < rect.h ? rect.w / 2 : rect.h / 2, thumbInk(wide));
    }

    // The badge of following the end: the letter A in the ink of the thumb, lit with the bar; on, white on a plate of the frame of the current
    // row as wide as the wide thumb. Trial values to be tuned by eye: the plate's radius, where the letter of the 8pt Courier New (about
    // 10.7 dips, a glyph 0.6 em wide) stands
    override void paintBadge(Canvas canvas, Rect area, bool on, double wide)
    {
        if (on)
            canvas.fillRoundRect(plateOf(area), 3, _look.palette.currentRow);
        letter(canvas, area, on ? _look.palette.row : thumbInk(wide));
    }

    // While the table follows its end the thumb is of the color of the plate and runs down into it: one thumb with the A at its bottom; thin at
    // rest it widens into the plate, wide it is the plate's width
    override void paintPinned(Canvas canvas, Rect strip, Rect track, Rect thumb, Rect badge, double wide)
    {
        const blue = _look.palette.currentRow;
        if (thumb.w > 0 && thumb.h > 0)
        {
            if (wide > 0)
                canvas.fillRect(track, ink(cast(ubyte)(trackAlpha * wide)));
            const rect = thumbRect(strip, thumb, wide, true);
            const joined = Rect(rect.x, rect.y, rect.w, badge.y + badge.h / 2 - rect.y); // down to the middle of the plate: no gap between them
            canvas.fillRoundRect(joined, rect.w / 2, blue);
        }
        canvas.fillRoundRect(plateOf(badge), 3, blue);
        letter(canvas, badge, _look.palette.row);
    }

    // The plate of the badge: as wide as the wide thumb, a dip off the ends of the square
    private static Rect plateOf(Rect area)
    {
        return Rect(area.x + inset, area.y + 1, area.w - 2 * inset, area.h - 2);
    }

    private static void letter(Canvas canvas, Rect area, Color color)
    {
        enum double glyph = 6.4, below = 2.5;
        canvas.drawText(LogFont.aux, "A"w, area.x + (area.w - glyph) / 2, area.y + area.h - below, color);
    }
}

/// The painter of the log table
class LogPainter : Painter
{
    private LogLook _look;

    this(LogLook look)
    {
        _look = look;
    }

    this()
    {
        this(defaultLogLook());
    }

    private ref const(LogPalette) _palette() const
    {
        return _look.palette;
    }

    override TableGeometry geometry()
    {
        TableGeometry g;
        g.headerHeight = 0; // the header follows its font
        g.columnBorder = 1; // a line between two columns
        g.groupHeight = -1; // a date over the rows of its day is a plate as high as the header
        g.groupPadTop = _look.spacing.groupPadTop; // with room above it: the groups stand apart
        g.groupPadBottom = _look.spacing.groupPadBottom;
        g.groupOutline = 1; // a line under the row above a margin and one over the rows of the group, under the plate
        g.marginTop = _look.spacing.rowsMarginTop; // room above the first row and under the last one: the background of the table fills it
        g.marginBottom = _look.spacing.rowsMarginBottom;
        return g;
    }

    // The margin of a group is empty, as a row
    override void paintGroupBand(Canvas canvas, Rect area)
    {
        canvas.fillRect(area, _palette.groupBand);
    }

    // The lines of a margin in the color of the lines of a group: one under the row above it, one over the rows of the group (the plate of
    // the heads, painted after, covers its part of it)
    override void paintGroupOutline(Canvas canvas, Rect area, bool top)
    {
        canvas.fillRect(area, _palette.groupLine);
    }

    // A head is a plate in the cell of its column (the line right of it is apart), colored as the header it goes up to. In the
    // margin it reaches the bottom and covers the line there (the outline of the group): it opens onto the rows of its group.
    // Over the header it covers a title, whose line stays beside it
    override void paintGroup(Canvas canvas, ref GroupContext group, bool tableHasFocus)
    {
        const plate = group.cell;
        canvas.fillRect(plate, _palette.groupPlate);
        canvas.pushClip(plate);
        group.column.drawGroup(canvas, GroupInput(group.head), plate); // the head, in the ink and on the back its style gives
        canvas.popClip();
    }

    override void paintBackground(Canvas canvas, Rect area)
    {
        canvas.fillRect(area, _palette.row);
    }

    // A line under the last row (the rows have none between them) and a mark in the middle of the margin under it, scrolled with it: `area`
    // is the part of the margin in view, it starts at the bottom of the last row (the background under it is already the color of the rows)
    override void paintEmpty(Canvas canvas, Rect area, EmptyZone zone)
    {
        if (zone != EmptyZone.marginBottom)
            return;
        enum double halfWidth = 20, radius = 2.5; // in dips, trials: half of the line, the dot on it
        const cx = round(area.x + area.w / 2), cy = round(area.y + _look.spacing.rowsMarginBottom / 2);
        canvas.pushClip(area);
        canvas.fillRect(Rect(area.x, area.y, area.w, 1), _palette.border);
        canvas.fillRect(Rect(cx - halfWidth, cy, 2 * halfWidth, 1), _palette.border);
        canvas.fillCircle(cx, cy + 0.5, radius, _palette.row, _palette.border);
        canvas.popClip();
    }

    override void paintHeader(Canvas canvas, Rect area)
    {
        canvas.fillRect(area, _palette.header);
    }

    override void paintRow(Canvas canvas, ref const RowContext row, bool tableHasFocus)
    {
        const found = row.data !is null && marksOf(row.data.extra).found;
        const color = row.state.selected ? _palette.selected : found ? (row.state.odd ? _palette.foundStripe : _palette.found)
            : (row.state.odd ? _palette.stripe : _palette.row);
        canvas.fillRect(row.area, color);
    }

    // The row the keys move from has a frame over its cells, so the borders of the columns do not cross it; a paler one while the
    // table has not the focus (the keys go to the other table)
    override void paintRowOver(Canvas canvas, ref const RowContext row, bool tableHasFocus)
    {
        if (!row.state.focused)
            return;
        const a = row.area;
        const color = tableHasFocus ? _palette.currentRow : _palette.currentRowInactive;
        canvas.fillRect(Rect(a.x, a.y, a.w, 1), color);
        canvas.fillRect(Rect(a.x, a.bottom - 1, a.w, 1), color);
        canvas.fillRect(Rect(a.x, a.y + 1, 1, a.h - 2), color);
        canvas.fillRect(Rect(a.right - 1, a.y + 1, 1, a.h - 2), color);
    }

    override void paintTextSelection(Canvas canvas, Rect area, bool tableHasFocus)
    {
        canvas.fillRect(area, _palette.textSelected);
    }

    // The line between two columns in the room the table left for it (only between them), in the rows and in the header alike
    override void paintColumnLine(Canvas canvas, Rect area, TableColumn column, bool header)
    {
        canvas.fillRect(area, _palette.border);
    }
}

version (unittest)
{
    import ui.log_table.log_columns : AnchorColumn, IndexColumn, LevelColumn, LevelInkColumn;
    import ui.log_table.text_column : TextColumn;

    // What the frame painter does with a cell the context `ctx` says of: its column draws it, the painter adds its border
    private void paintAll(Canvas canvas, LogPainter painter, ref CellContext ctx)
    {
        if (ctx.data !is null)
        {
            const cell = inputOf(ctx), state = stateOf(ctx);
            ctx.column.draw(canvas, cell, state);
        }
        painter.paintCell(canvas, ctx, true);
    }

    private CellInput inputOf(ref const CellContext ctx)
    {
        import std.algorithm.comparison : max;

        CellInput cell;
        cell.data = ctx.data;

        return cell;
    }

    private DrawState stateOf(ref const CellContext ctx)
    {
        DrawState state;
        state.area = ctx.area;
        state.clip = ctx.clip.h > 0 ? ctx.clip : ctx.area;
        state.row = ctx.row !is null ? ctx.row.state : RowState.init;
        state.hover = ctx.hover;
        state.pressed = ctx.pressed;
        return state;
    }

    private final class Ruler : TextMeasurer
    {
        FontMetrics metrics(FontId font) { return FontMetrics(11, 3, 14); }
        double width(FontId font, const(wchar)[] text) { return text.length * 6.0; }
        int wrappedLines(FontId font, const(wchar)[] text, double width) { return -1; }
    }
}

@("LogPainter: a level is colored and made bold by the level of the row, not by its name; the table never reads the extra data")
unittest
{
    import ptable.model : CellData, Extra, RowData;

    auto canvas = new RecordingCanvas;
    auto painter = new LogPainter;
    auto column = ColumnDef("level", "Level", 24, false, true);
    auto columnColumn = new LevelColumn(column, defaultLogLook());
    RowData data;
    const cell = CellData("Whatever"w, packMarks(LogMarks(LogLevel.Fatal))); // not the name of a level: the cell's marks say it is Fatal
    RowContext row;
    row.data = &data;
    CellContext ctx;
    ctx.row = &row;
    ctx.column = columnColumn;
    ctx.data = &cell;
    ctx.area = Rect(0, 0, 60, 16);
    paintAll(canvas, painter, ctx);
    assert(canvas.calls == ["fill", "text:Whatever"], "the plate of a Fatal and the text: the line right of the cell is not a part of it");
}

@("LevelColumn: a selected row keeps the color of its level and the rounded plate of a Fatal")
unittest
{
    import ptable.model : CellData;

    // a canvas that keeps what it draws and in which color
    static final class Inks : Canvas
    {
        string[] calls;
        Color[] colors;
        void fillRect(Rect area, Color color) { calls ~= "rect"; colors ~= color; }
        void drawText(FontId font, const(wchar)[] text, double x, double baseline, Color color) { calls ~= "text"; colors ~= color; }
        void drawParagraph(FontId font, const(wchar)[] text, double x, double top, double width, Color color) {}
        void fillRoundRect(Rect area, double radius, Color color) { calls ~= "round"; colors ~= color; }
        void fillCircle(double cx, double cy, double radius, Color fill, Color line) {}
        void pushClip(Rect area) {}
        void popClip() {}
    }

    auto look = defaultLogLook();
    auto column = new LevelColumn(ColumnDef("level", "Level"), look, new Ruler);
    RowState selected;
    selected.selected = true;
    const area = Rect(0, 0, 60, 16);
    const state = DrawState(area, area, selected);
    const palette = look.palette;

    auto canvas = new Inks;
    const error = CellData("Error"w, packMarks(LogMarks(LogLevel.Error)));
    CellInput cell;
    cell.data = &error;
    column.draw(canvas, cell, state);
    assert(canvas.calls == ["text"] && canvas.colors == [palette.error], "the red of an Error, not the ink of the selection");

    canvas = new Inks;
    const fatal = CellData("Fatal"w, packMarks(LogMarks(LogLevel.Fatal)));
    cell.data = &fatal;
    column.draw(canvas, cell, state);
    assert(canvas.calls == ["round", "text"] && canvas.colors == [palette.fatalBg, palette.fatalText], "the rounded plate of a Fatal, on a selected row too");
}

@("LevelInkColumn: the text is in the color of the level of its record, the ordinary ink when it has none")
unittest
{
    import ptable.model : CellData;

    static final class Inks : Canvas
    {
        Color[] texts;
        void fillRect(Rect area, Color color) {}
        void drawText(FontId font, const(wchar)[] text, double x, double baseline, Color color) { texts ~= color; }
        void drawParagraph(FontId font, const(wchar)[] text, double x, double top, double width, Color color) {}
        void fillRoundRect(Rect area, double radius, Color color) {}
        void fillCircle(double cx, double cy, double radius, Color fill, Color line) {}
        void pushClip(Rect area) {}
        void popClip() {}
    }

    auto look = defaultLogLook();
    auto column = new LevelInkColumn(ColumnDef("status", "Status"), look, new Ruler);
    const area = Rect(0, 0, 60, 16);
    const state = DrawState(area, area, RowState.init);
    auto canvas = new Inks;
    CellInput cell;
    const error = CellData("500"w, packMarks(LogMarks(LogLevel.Error)));
    cell.data = &error;
    column.draw(canvas, cell, state);
    const none = CellData("200"w, packMarks(LogMarks(LogLevel.None)));
    cell.data = &none;
    column.draw(canvas, cell, state);
    assert(canvas.texts == [look.palette.error, look.palette.ink], "an Error in red, a record of no level in the ink");
}

@("LogPainter: the color of a filter rule is a gradient in the Index cell, a text column shows none (the anchor cell fills with it: AnchorColumn)")
unittest
{
    import log_core.rule_filter : RuleId;
    import ptable.model : CellData, Extra, RowData;

    auto painter = new LogPainter;
    RowData data;
    RowContext row;
    row.data = &data;
    CellContext ctx;
    ctx.row = &row;
    ctx.area = Rect(0, 0, 60, 16);
    auto canvas = new RecordingCanvas;
    auto index = ColumnDef("index", "Index", 24, false, true);
    bool red(RuleId rule, out Color color)
    {
        color = Color(255, 0, 0);
        return rule == RuleId(5);
    }

    auto indexColumn = new IndexColumn(index, null, &red);
    LogMarks marks;
    marks.rule = RuleId(5);
    const colored = CellData("5"w, packMarks(marks));
    ctx.column = indexColumn;
    ctx.data = &colored;
    paintAll(canvas, painter, ctx);
    size_t fills;
    foreach (c; canvas.calls)
        if (c == "fill")
            fills++;
    assert(fills >= 8, "the bands of the gradient");
    auto plain = new RecordingCanvas;
    const none = CellData("5"w);
    ctx.data = &none;
    paintAll(plain, painter, ctx);
    assert(plain.calls == ["text:5"], "no color: the text");
    auto aux = ColumnDef("count", "Count", 24, false, true);
    auto auxColumn = new TextColumn(aux);
    ctx.column = auxColumn;
    ctx.data = &colored;
    auto other = new RecordingCanvas;
    paintAll(other, painter, ctx);
    assert(other.calls == ["text:5"], "a text column does not show the color");
}

@("LogPainter: a group's margin has room above its plate and lines at its top and bottom that take no room; the plate, as high as the header, reaches the bottom")
unittest
{
    auto painter = new LogPainter;
    const g = painter.geometry();
    assert(g.groupHeight < 0 && g.groupPadTop > 0, "the plate left to the header font, room above it");
    assert(g.groupPadBottom == 0 && g.groupOutline == 1, "no room under the plate: the line at the bottom of the margin is under it");
    auto canvas = new RecordingCanvas;
    painter.paintGroupBand(canvas, Rect(0, 40, 300, 28));
    assert(canvas.calls == ["fill"], "the room as a row: the lines are apart");
    canvas.calls = null;
    painter.paintGroupOutline(canvas, Rect(0, 40, 300, 1), true);
    painter.paintGroupOutline(canvas, Rect(0, 67, 300, 1), false);
    assert(canvas.calls == ["fill", "fill"], "the line under the row above and the one over the rows under");
    canvas.calls = null;
    // a canvas that keeps where it fills
    static final class Areas : Canvas
    {
        Rect[] areas;
        void fillRect(Rect area, Color color) { areas ~= area; }
        void drawText(FontId font, const(wchar)[] text, double x, double baseline, Color color) {}
        void drawParagraph(FontId font, const(wchar)[] text, double x, double top, double width, Color color) {}
        void fillRoundRect(Rect area, double radius, Color color) { fillRect(area, color); }
        void fillCircle(double cx, double cy, double radius, Color fill, Color line) {}
        void pushClip(Rect area) {}
        void popClip() {}
    }
    auto areas = new Areas;
    auto margin = GroupContext("2026/11/18"w, Rect(60, 46, 90, 22), false, new TextColumn(ColumnDef("time", "Time")));
    painter.paintGroup(areas, margin, true);
    assert(areas.areas == [Rect(60, 46, 90, 22)], "the plate in the cell of its column, down to the bottom of the margin: it covers the line there");
    canvas.calls = null;
    auto sticky = GroupContext("2026/11/18"w, Rect(60, 0, 90, 22), true, new TextColumn(ColumnDef("time", "Time")));
    painter.paintGroup(canvas, sticky, true);
    assert(canvas.calls == ["fill", "clip", "text:2026/11/18", "unclip"], "over the title: the line of the title is drawn with the header");
}

@("LogPainter: the line between the columns is in the color of the borders wherever the table leaves one; there is no line between the rows")
unittest
{
    static final class Areas : Canvas
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

    auto painter = new LogPainter;
    auto canvas = new Areas;
    painter.paintColumnLine(canvas, Rect(58, 21, 1, 16), new TextColumn(ColumnDef("time", "Time")), false);
    painter.paintColumnLine(canvas, Rect(58, 0, 1, 21), new TextColumn(ColumnDef("time", "Time")), true);
    painter.paintColumnLine(canvas, Rect(398, 21, 1, 16), new TextColumn(ColumnDef("payload", "Payload", 24, true)), false);
    assert(canvas.areas == [Rect(58, 21, 1, 16), Rect(58, 0, 1, 21), Rect(398, 21, 1, 16)], "in the rows and in the header, after the flex column too");
    const border = defaultLogLook().palette.border;
    assert(canvas.colors == [border, border, border]);
    assert(painter.geometry().columnBorder == 1 && painter.geometry().rowBorder == 0, "a line between the columns; the rows are told apart by their backs");
}

@("LogPainter: the background, the header, the rows striped, selected and found and the text selected are its own colors")
unittest
{
    import ptable.model : RowData;

    // a canvas that keeps the colors filled
    static final class Fills : Canvas
    {
        Color[] colors;
        void fillRect(Rect area, Color color) { colors ~= color; }
        void drawText(FontId font, const(wchar)[] text, double x, double baseline, Color color) {}
        void drawParagraph(FontId font, const(wchar)[] text, double x, double top, double width, Color color) {}
        void fillRoundRect(Rect area, double radius, Color color) { fillRect(area, color); }
        void fillCircle(double cx, double cy, double radius, Color fill, Color line) {}
        void pushClip(Rect area) {}
        void popClip() {}
    }

    const palette = LogPalette.init;
    auto painter = new LogPainter;
    auto canvas = new Fills;
    painter.paintBackground(canvas, Rect(0, 0, 10, 10));
    painter.paintHeader(canvas, Rect(0, 0, 10, 10));
    RowData data;
    RowContext row;
    row.data = &data;
    row.state.odd = true;
    painter.paintRow(canvas, row, true);
    row.state.odd = false;
    painter.paintRow(canvas, row, true);
    row.state.selected = true;
    painter.paintRow(canvas, row, true);
    painter.paintTextSelection(canvas, Rect(0, 0, 5, 10), true);
    assert(canvas.colors == [palette.row, palette.header, palette.stripe, palette.row, palette.selected,
        palette.textSelected]);
}

@("LogPainter: the margin of a group, its lines, its plate and the plate's ink are the colors of the group in the palette")
unittest
{
    static final class Fills : Canvas
    {
        Color[] colors;
        void fillRect(Rect area, Color color) { colors ~= color; }
        void drawText(FontId font, const(wchar)[] text, double x, double baseline, Color color) { colors ~= color; }
        void drawParagraph(FontId font, const(wchar)[] text, double x, double top, double width, Color color) {}
        void fillRoundRect(Rect area, double radius, Color color) { fillRect(area, color); }
        void fillCircle(double cx, double cy, double radius, Color fill, Color line) {}
        void pushClip(Rect area) {}
        void popClip() {}
    }

    LogPalette palette;
    palette.groupBand = Color(1, 1, 1);
    palette.groupLine = Color(2, 2, 2);
    palette.groupPlate = Color(3, 3, 3);
    palette.groupInk = Color(4, 4, 4);
    auto look = new LogLook(defaultLogLook().text, palette);
    auto painter = new LogPainter(look);
    auto canvas = new Fills;
    painter.paintGroupBand(canvas, Rect(0, 40, 300, 30));
    painter.paintGroupOutline(canvas, Rect(0, 40, 300, 1), true);
    painter.paintGroupOutline(canvas, Rect(0, 69, 300, 1), false);
    auto margin = GroupContext("2026/11/18"w, Rect(60, 46, 90, 24), false, new TextColumn(ColumnDef("time", "Time"), look)); // the column inks its head
    painter.paintGroup(canvas, margin, true);
    assert(canvas.colors == [palette.groupBand, palette.groupLine, palette.groupLine, palette.groupPlate, palette.groupInk]);
}

@("LogPainter: the room above and under the plate of a group is the look's spacing")
unittest
{
    auto look = defaultLogLook();
    auto painter = new LogPainter(look);
    look.setSpacing(LogSpacing(9, 2));
    assert(painter.geometry().groupPadTop == 9 && painter.geometry().groupPadBottom == 2);
}

@("LogPainter: the margins above and under the rows are the look's spacing")
unittest
{
    auto look = defaultLogLook();
    auto painter = new LogPainter(look);
    LogSpacing spacing;
    spacing.rowsMarginTop = 3;
    spacing.rowsMarginBottom = 8;
    look.setSpacing(spacing);
    assert(painter.geometry().marginTop == 3 && painter.geometry().marginBottom == 8);
}

@("LogPainter: a column's style gives the ink and the background of its cells, a selected row keeps its own colors")
unittest
{
    import ptable.model : CellData;

    static final class Fills : Canvas
    {
        string[] calls;
        Color[] colors;
        void fillRect(Rect area, Color color) { calls ~= "fill"; colors ~= color; }
        void drawText(FontId font, const(wchar)[] text, double x, double baseline, Color color)
        {
            import std.conv : to;

            calls ~= "text:" ~ text.to!string;
            colors ~= color;
        }
        void drawParagraph(FontId font, const(wchar)[] text, double x, double top, double width, Color color) {}
        void fillRoundRect(Rect area, double radius, Color color) { fillRect(area, color); }
        void fillCircle(double cx, double cy, double radius, Color fill, Color line) {}
        void pushClip(Rect area) {}
        void popClip() {}
    }

    auto painter = new LogPainter;
    auto columnColumn = new TextColumn(ColumnDef("count", "Count", 24, false, true));
    columnColumn.style.cell.back = LogColor.found;
    columnColumn.style.cell.ink = LogColor.error;
    const cell = CellData("7"w);
    RowContext row;
    CellContext ctx;
    ctx.row = &row;
    ctx.column = columnColumn;
    ctx.data = &cell;
    ctx.area = Rect(0, 0, 40, 16);
    auto canvas = new Fills;
    paintAll(canvas, painter, ctx);
    assert(canvas.calls == ["fill", "text:7"], "the background and the text");
    assert(canvas.colors[0] == Color(0xee, 0xe6, 0xd4) && canvas.colors[1] == Color(255, 0, 0));
    row.state.selected = true;
    canvas = new Fills;
    paintAll(canvas, painter, ctx);
    assert(canvas.calls == ["text:7"] && canvas.colors[0] == Color(0, 0, 0), "no background over a selected row, its ink");
}

@("LogPainter: the row the keys move from has a frame over its cells in the color of the current row")
unittest
{
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

    LogPalette palette;
    palette.currentRow = Color(1, 2, 3);
    auto painter = new LogPainter(new LogLook(defaultLogLook().text, palette));
    RowContext row;
    row.area = Rect(0, 100, 300, 16);
    auto plain = new Fills;
    painter.paintRow(plain, row, true);
    painter.paintRowOver(plain, row, true);
    assert(plain.areas.length == 1, "the row only");
    row.state.focused = true;
    auto marked = new Fills;
    painter.paintRow(marked, row, true);
    assert(marked.areas.length == 1, "the frame is not under the cells");
    painter.paintRowOver(marked, row, true);
    assert(marked.areas.length == 5 && marked.colors[1] == Color(1, 2, 3) && marked.areas[1] == Rect(0, 100, 300, 1)
        && marked.areas[2] == Rect(0, 115, 300, 1) && marked.areas[3] == Rect(0, 101, 1, 14) && marked.areas[4] == Rect(299, 101, 1, 14),
        "four sides, over the cells");
}

@("LogPainter: an anchored row has a circle with the anchor in it in the anchor column, a row without one has nothing")
unittest
{
    import ptable.model : CellData, Extra, RowData;

    auto painter = new LogPainter;
    RowData data;
    RowContext row;
    row.data = &data;
    CellContext ctx;
    ctx.row = &row;
    ctx.area = Rect(0, 0, 24, 16);
    size_t asked;
    bool full = false; // there is room until a test says there is none
    auto anchor = ColumnDef("anchor", "⚓", 24, false, false);
    auto anchorColumn = new AnchorColumn(anchor, defaultLogLook(), () { ++asked; return full; });
    ctx.column = anchorColumn;
    LogMarks anchored;
    anchored.anchored = true;
    auto cell = CellData(""w, packMarks(anchored)); // the cell's marks say whether the record has an anchor
    ctx.data = &cell;
    auto canvas = new RecordingCanvas;
    paintAll(canvas, painter, ctx);
    assert(canvas.calls == ["circle", "text:⚓"], "the circle under the anchor");
    cell.extra = packMarks(LogMarks.init);
    auto empty = new RecordingCanvas;
    paintAll(empty, painter, ctx);
    assert(empty.calls.length == 0, "no anchor: nothing");
    ctx.hover = true;
    auto faint = new RecordingCanvas;
    paintAll(faint, painter, ctx);
    assert(faint.calls == ["text:⚓"], "the mouse over a cell with no anchor: a faint one, no circle");
    full = true;
    auto refused = new RecordingCanvas;
    paintAll(refused, painter, ctx);
    assert(refused.calls == ["text:⊘"], "no room for another: the sign of a refusal");
    ctx.pressed = true;
    auto big = new RecordingCanvas;
    paintAll(big, painter, ctx);
    assert(big.calls == ["text:⊘"], "the button is down on it: the glyph in the big font, no circle");
    ctx.pressed = false;
    ctx.hover = false;
    auto quiet = new RecordingCanvas;
    paintAll(quiet, painter, ctx);
    assert(quiet.calls.length == 0, "the mouse is elsewhere: nothing");
    const before = asked;
    painter.paintCell(new RecordingCanvas, ctx, true);
    assert(asked == before, "the document is not asked about a cell nobody points at");
    ctx.hover = true;
    full = false;
    auto room = new RecordingCanvas;
    paintAll(room, painter, ctx);
    assert(room.calls == ["text:⚓"], "room again: the faint anchor, as the document says now");
    cell.extra = packMarks(anchored);
    auto anchoredFull = new RecordingCanvas;
    paintAll(anchoredFull, painter, ctx);
    assert(anchoredFull.calls == ["circle", "text:⚓"], "an anchor that is there is shown as before");
}

@("AnchorColumn: the cell of a record that matches a filter rule with a color is filled with it whole, under the anchor, on a selected row too")
unittest
{
    import log_core.rule_filter : RuleId;
    import ptable.column : CellInput, DrawState;
    import ptable.model : CellData;

    static final class Areas : Canvas
    {
        string[] calls;
        Rect[] areas;
        Color[] colors;
        void fillRect(Rect area, Color color) { calls ~= "fill"; areas ~= area; colors ~= color; }
        void drawText(FontId font, const(wchar)[] text, double x, double baseline, Color color) { calls ~= "text"; }
        void drawParagraph(FontId font, const(wchar)[] text, double x, double top, double width, Color color) {}
        void fillRoundRect(Rect area, double radius, Color color) { fillRect(area, color); }
        void fillCircle(double cx, double cy, double radius, Color fill, Color line) { calls ~= "circle"; }
        void pushClip(Rect area) {}
        void popClip() {}
    }

    bool green(RuleId rule, out Color color)
    {
        color = Color(0, 200, 0);
        return rule == RuleId(5);
    }

    auto column = new AnchorColumn(ColumnDef("anchor", "⚓"), defaultLogLook(), null, &green);
    LogMarks marks;
    marks.rule = RuleId(5);
    marks.anchored = true;
    const data = CellData(""w, packMarks(marks));
    const cell = CellInput(0, 0, &data);
    const area = Rect(0, 21, 24, 16);
    auto canvas = new Areas;
    const state = DrawState(area, area);
    column.draw(canvas, cell, state);
    assert(canvas.calls == ["fill", "circle", "text"] && canvas.areas[0] == area && canvas.colors[0] == Color(0, 200, 0),
        "the color of the rule over the whole cell, the anchor over it");
    RowState selected;
    selected.selected = true;
    canvas = new Areas;
    const onSelected = DrawState(area, area, selected);
    column.draw(canvas, cell, onSelected);
    assert(canvas.colors.length && canvas.colors[$ - 1] == Color(0, 200, 0) && canvas.areas[$ - 1] == area, "a selected row keeps the color of its rule");
    marks.rule = RuleId.init;
    const plain = CellData(""w, packMarks(marks));
    const none = CellInput(0, 0, &plain);
    canvas = new Areas;
    column.draw(canvas, none, state);
    assert(canvas.calls == ["circle", "text"], "no rule: the anchor only");
}

@("AnchorColumn: kept in view across, the anchor and its circle stand in the middle of the part of the cell seen")
unittest
{
    import ptable.column : CellInput, DrawState;
    import ptable.model : CellData;
    import ptable.ports : Canvas, Color, FontId;
    import ptable_text.columnstyle : Halign;
    import ptable_text.testing : FakeMeasurer;

    static final class Where : Canvas
    {
        double textX = double.nan, circleX = double.nan;
        void fillRect(Rect area, Color color) {}
        void drawText(FontId font, const(wchar)[] text, double x, double baseline, Color color) { textX = x; }
        void drawParagraph(FontId font, const(wchar)[] text, double x, double top, double width, Color color) {}
        void fillRoundRect(Rect area, double radius, Color color) { fillRect(area, color); }
        void fillCircle(double cx, double cy, double radius, Color fill, Color line) { circleX = cx; }
        void pushClip(Rect area) {}
        void popClip() {}
    }

    auto column = new AnchorColumn(ColumnDef("anchor", "⚓", 24, false, false), defaultLogLook(), null, null, new FakeMeasurer);
    column.style.cell.halign = Halign.center;
    column.lookChanged();
    LogMarks anchored;
    anchored.anchored = true;
    const data = CellData(""w, packMarks(anchored));
    const cell = CellInput(0, 0, &data);
    DrawState state;
    state.area = Rect(100, 100, 60, 16); // the anchor is 10 wide
    state.clip = Rect(130, 100, 30, 16); // the left half is under a pinned strip
    auto plain = new Where;
    column.draw(plain, cell, state);
    assert(plain.textX == 125 && plain.circleX == 130, "not kept in view: the middle of the whole cell");
    column.style.cell.keepInViewX = true;
    auto kept = new Where;
    column.draw(kept, cell, state);
    assert(kept.textX == 140 && kept.circleX == 145, "the middle of the part seen, the circle with it");
}

@("AnchorColumn: the anchor stands in the middle of its circle by its own width, not by the width of a text rounded up to a whole pixel")
unittest
{
    import ptable.column : CellInput, DrawState;
    import ptable.model : CellData;
    import ptable.ports : Canvas, Color, FontId;
    import ptable_text.measurer : FontMetrics;
    import std.math : abs, ceil;

    // As Sciter: a text is as wide as its glyphs, rounded up to a whole pixel; the anchor is 6.43 wide
    static final class Ceiled : TextMeasurer
    {
        FontMetrics metrics(FontId font) { return FontMetrics(11, 3, 14); }
        double width(FontId font, const(wchar)[] text) { return ceil(text.length * 6.43); }
        int wrappedLines(FontId font, const(wchar)[] text, double width) { return -1; }
    }

    static final class Where : Canvas
    {
        double textX = double.nan, circleX = double.nan;
        void fillRect(Rect area, Color color) {}
        void drawText(FontId font, const(wchar)[] text, double x, double baseline, Color color) { textX = x; }
        void drawParagraph(FontId font, const(wchar)[] text, double x, double top, double width, Color color) {}
        void fillRoundRect(Rect area, double radius, Color color) { fillRect(area, color); }
        void fillCircle(double cx, double cy, double radius, Color fill, Color line) { circleX = cx; }
        void pushClip(Rect area) {}
        void popClip() {}
    }

    auto column = new AnchorColumn(ColumnDef("anchor", "⚓", 24, false, false), defaultLogLook(), null, null, new Ceiled);
    column.lookChanged();
    LogMarks anchored;
    anchored.anchored = true;
    const data = CellData(""w, packMarks(anchored));
    const cell = CellInput(0, 0, &data);
    const area = Rect(0, 23, 22.6667, 19); // as the table has it at a text size of 93 %
    auto canvas = new Where;
    const state = DrawState(area, area);
    column.draw(canvas, cell, state);
    assert(abs(canvas.textX + 6.43 / 2 - canvas.circleX) < 0.05, "the middle of the glyph is the middle of the circle");
}
