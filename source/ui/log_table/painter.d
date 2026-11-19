//! How the log table looks when the log table (ptable) draws it: the fonts, the colors (`LogPalette`) and the
//! spacing (`LogSpacing`) the script reads from the CSS of the themes and of the table (resources/log-table-look.js), the
//! cells of the Index, the levels, the anchor marks, the Payload and the groups of rows (a day). The look the DOM table
//! has in resources/table.css, written as a `Painter`. Free of Sciter. See docs/stories/painted-table.md.
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

/// The look of the scroll bar beside the log table: the header's color above the track, the rows' below, the thumb
final class LogScrollBarPainter : ScrollBarPainter
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

    // The thumb is the ink of the table, thin until the mouse is on it: the theme has no color of its own for it
    private Color thumbColor(bool strong) const
    {
        const ink = _palette.ink;
        return Color(ink.r, ink.g, ink.b, strong ? 179 : 115);
    }

    override void paint(Canvas canvas, Rect strip, Rect track, Rect thumb, bool hover, bool dragging, Orientation orientation)
    {
        if (orientation == Orientation.vertical)
        {
            canvas.fillRect(Rect(strip.x, strip.y, strip.w, track.y - strip.y), _palette.header);
            canvas.fillRect(track, _palette.row);
            if (thumb.h > 0)
                canvas.fillRect(Rect(thumb.x + 2, thumb.y, thumb.w - 4, thumb.h), thumbColor(hover || dragging));
            return;
        }
        canvas.fillRect(strip, _palette.row);
        if (thumb.w > 0)
            canvas.fillRect(Rect(thumb.x, thumb.y + 2, thumb.w, thumb.h - 4), thumbColor(hover || dragging));
    }

    override void paintCorner(Canvas canvas, Rect corner)
    {
        canvas.fillRect(corner, _palette.row);
    }
}

/// The painter of the log table
class LogPainter : Painter
{
    /// Whether no room is left for another anchor, asked of the document each time it matters (a cell with none under the mouse or pressed),
    /// so what it answers is always the truth. Null: there is always room
    bool delegate() anchorsFull;

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
        g.groupHeight = -1; // a date over the rows of its day is a plate as high as the header
        g.groupPadTop = _look.spacing.groupPadTop; // with room above it: the groups stand apart
        g.groupPadBottom = _look.spacing.groupPadBottom; // the line under the margin, which the plate opens through
        return g;
    }

    // The margin of a group is empty, as a row, between two lines in the color of the borders of the columns: one under
    // the row above it, one over the rows of the group (the plate of the heads, painted after, covers its part of it)
    override void paintGroupBand(Canvas canvas, Rect area)
    {
        canvas.fillRect(area, _palette.groupBand);
        canvas.fillRect(Rect(area.x, area.y, area.w, 1), _palette.groupLine);
        canvas.fillRect(Rect(area.x, area.bottom - 1, area.w, 1), _palette.groupLine);
    }

    // A head is a plate in the cell of its column, colored as the header it goes up to. In the margin it stands left of
    // the border of its column and opens onto the rows of its group: under it the line under the margin is the room's
    // ground. Over the header it is a title, with a title's border
    override void paintGroup(Canvas canvas, ref GroupContext group)
    {
        const cell = group.cell;
        const plate = group.sticky ? cell : Rect(cell.x, cell.y, cell.w - 1, cell.h);
        canvas.fillRect(plate, _palette.groupPlate);
        if (!group.sticky)
            canvas.fillRect(Rect(plate.x, plate.bottom, plate.w, geometry().groupPadBottom), _palette.groupBand);
        canvas.pushClip(plate);
        group.column.drawGroup(canvas, GroupInput(group.head), plate); // the head, in the ink and on the back its style gives
        canvas.popClip();
        if (group.sticky)
            canvas.fillRect(Rect(cell.right - 1, cell.y, 1, cell.h), _palette.border);
    }

    override void paintBackground(Canvas canvas, Rect area)
    {
        canvas.fillRect(area, _palette.row);
    }

    override void paintHeader(Canvas canvas, Rect area)
    {
        canvas.fillRect(area, _palette.header);
    }

    override void paintRow(Canvas canvas, ref const RowContext row)
    {
        const found = row.data !is null && (row.data.extra.bits & foundMark) != 0;
        const color = row.state.selected ? _palette.selected : found ? (row.state.odd ? _palette.foundStripe : _palette.found)
            : (row.state.odd ? _palette.stripe : _palette.row);
        canvas.fillRect(row.area, color);
        if (row.state.focused) // the row the keys move from: a line over it and one under it
        {
            canvas.fillRect(Rect(row.area.x, row.area.y, row.area.w, 1), _palette.currentRow);
            canvas.fillRect(Rect(row.area.x, row.area.bottom - 1, row.area.w, 1), _palette.currentRow);
        }
    }

    override void paintPinnedEdge(Canvas canvas, Rect area, bool leftEdge)
    {
        canvas.fillRect(area, _palette.border);
    }

    override void paintTextSelection(Canvas canvas, Rect area)
    {
        canvas.fillRect(area, _palette.textSelected);
    }

    // A cell is drawn by its column (`TableColumn.draw`, `drawHeader`); the painter adds its right border (the row's own look is `paintRow`)
    override void paintCell(Canvas canvas, ref CellContext cell)
    {
        if (!cell.isHeader && cell.data is null)
            return;
        const area = cell.area;
        if (!cell.column.def.flex)
            canvas.fillRect(Rect(area.right - 1, area.y, 1, area.h), _palette.border);
    }
}

version (unittest)
{
    import ui.log_table.log_columns : AnchorColumn, IndexColumn, LevelColumn;
    import ui.log_table.text_column : TextColumn;

    // What the frame painter does with a cell the context `ctx` says of: its column draws it, the painter adds its border
    private void paintAll(Canvas canvas, LogPainter painter, ref CellContext ctx)
    {
        if (ctx.data !is null)
        {
            const cell = inputOf(ctx), state = stateOf(ctx);
            ctx.column.draw(canvas, cell, state);
        }
        painter.paintCell(canvas, ctx);
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
    const cell = CellData("Whatever"w, Extra(cast(ulong) LogLevel.Fatal)); // not the name of a level: the cell's data says it is Fatal
    RowContext row;
    row.data = &data;
    CellContext ctx;
    ctx.row = &row;
    ctx.column = columnColumn;
    ctx.data = &cell;
    ctx.area = Rect(0, 0, 60, 16);
    paintAll(canvas, painter, ctx);
    assert(canvas.calls == ["fill", "text:Whatever", "fill"], "the plate of a Fatal, the text, the border of the cell");
}

@("LogPainter: the color of a filter rule is a gradient in the Index cell only, the other cells have none")
unittest
{
    import ptable.model : CellData, Extra, RowData;
    import ui.log_table.marks : ruleColorBits;

    auto painter = new LogPainter;
    RowData data;
    RowContext row;
    row.data = &data;
    CellContext ctx;
    ctx.row = &row;
    ctx.area = Rect(0, 0, 60, 16);
    auto canvas = new RecordingCanvas;
    auto index = ColumnDef("index", "Index", 24, false, true);
    auto indexColumn = new IndexColumn(index);
    const colored = CellData("5"w, Extra(ruleColorBits("#ff0000")));
    ctx.column = indexColumn;
    ctx.data = &colored;
    paintAll(canvas, painter, ctx);
    size_t fills;
    foreach (c; canvas.calls)
        if (c == "fill")
            fills++;
    assert(fills >= 9, "the bands of the gradient and the border of the cell");
    auto plain = new RecordingCanvas;
    const none = CellData("5"w);
    ctx.data = &none;
    paintAll(plain, painter, ctx);
    assert(plain.calls == ["text:5", "fill"], "no color: the text and the border");
    auto aux = ColumnDef("count", "Count", 24, false, true);
    auto auxColumn = new TextColumn(aux);
    ctx.column = auxColumn;
    ctx.data = &colored;
    auto other = new RecordingCanvas;
    paintAll(other, painter, ctx);
    assert(other.calls == ["text:5", "fill"], "only the Index cell shows the color");
}

@("LogPainter: a group's margin has room above its plate, a line over it under the row above and one under it over the rows of the group; the plate, as high as the header, borders a title only over the header")
unittest
{
    auto painter = new LogPainter;
    const g = painter.geometry();
    assert(g.groupHeight < 0 && g.groupPadTop > 0, "the plate left to the header font, room above it");
    assert(g.groupPadBottom == 1, "a pixel under the plate, for the line under the margin");
    auto canvas = new RecordingCanvas;
    painter.paintGroupBand(canvas, Rect(0, 40, 300, 28));
    assert(canvas.calls == ["fill", "fill", "fill"], "the room as a row, the line under the row above, the line over the rows under");
    canvas.calls = null;
    // a canvas that keeps where it fills
    static final class Areas : Canvas
    {
        Rect[] areas;
        void fillRect(Rect area, Color color) { areas ~= area; }
        void drawText(FontId font, const(wchar)[] text, double x, double baseline, Color color) {}
        void drawParagraph(FontId font, const(wchar)[] text, double x, double top, double width, Color color) {}
        void fillCircle(double cx, double cy, double radius, Color fill, Color line) {}
        void pushClip(Rect area) {}
        void popClip() {}
    }
    auto areas = new Areas;
    auto margin = GroupContext("2026/11/18"w, Rect(60, 46, 90, 22), false, new TextColumn(ColumnDef("time", "Time")));
    painter.paintGroup(areas, margin);
    assert(areas.areas == [Rect(60, 46, 89, 22), Rect(60, 68, 89, 1)],
        "the plate left of the border of its column; under it the line is the room's ground: the plate opens onto its rows");
    canvas.calls = null;
    auto sticky = GroupContext("2026/11/18"w, Rect(60, 0, 90, 22), true, new TextColumn(ColumnDef("time", "Time")));
    painter.paintGroup(canvas, sticky);
    assert(canvas.calls == ["fill", "clip", "text:2026/11/18", "unclip", "fill"], "over the title: the border of a title");
}

@("LogPainter: the background, the header, the rows striped, selected and found, the edge of a pinned area and the text selected are its own colors")
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
    painter.paintRow(canvas, row);
    row.state.odd = false;
    painter.paintRow(canvas, row);
    row.state.selected = true;
    painter.paintRow(canvas, row);
    painter.paintPinnedEdge(canvas, Rect(0, 0, 1, 10), true);
    painter.paintTextSelection(canvas, Rect(0, 0, 5, 10));
    assert(canvas.colors == [palette.row, palette.header, palette.stripe, palette.row, palette.selected, palette.border,
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
    auto margin = GroupContext("2026/11/18"w, Rect(60, 46, 90, 23), false, new TextColumn(ColumnDef("time", "Time"), look)); // the column inks its head
    painter.paintGroup(canvas, margin);
    assert(canvas.colors == [palette.groupBand, palette.groupLine, palette.groupLine, palette.groupPlate, palette.groupBand,
        palette.groupInk]);
}

@("LogPainter: the room above and under the plate of a group is the look's spacing")
unittest
{
    auto look = defaultLogLook();
    auto painter = new LogPainter(look);
    look.setSpacing(LogSpacing(9, 2));
    assert(painter.geometry().groupPadTop == 9 && painter.geometry().groupPadBottom == 2);
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
    assert(canvas.calls == ["fill", "text:7", "fill"], "the background, the text, the border");
    assert(canvas.colors[0] == Color(0xee, 0xe6, 0xd4) && canvas.colors[1] == Color(255, 0, 0));
    row.state.selected = true;
    canvas = new Fills;
    paintAll(canvas, painter, ctx);
    assert(canvas.calls == ["text:7", "fill"] && canvas.colors[0] == Color(0, 0, 0), "no background over a selected row, its ink");
}

@("LogPainter: the row the keys move from has a line over it and one under it in the color of the current row")
unittest
{
    static final class Fills : Canvas
    {
        Rect[] areas;
        Color[] colors;
        void fillRect(Rect area, Color color) { areas ~= area; colors ~= color; }
        void drawText(FontId font, const(wchar)[] text, double x, double baseline, Color color) {}
        void drawParagraph(FontId font, const(wchar)[] text, double x, double top, double width, Color color) {}
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
    painter.paintRow(plain, row);
    assert(plain.areas.length == 1, "the row only");
    row.state.focused = true;
    auto marked = new Fills;
    painter.paintRow(marked, row);
    assert(marked.areas.length == 3 && marked.colors[1] == Color(1, 2, 3) && marked.areas[1] == Rect(0, 100, 300, 1)
        && marked.areas[2] == Rect(0, 115, 300, 1));
}

@("LogPainter: an anchored row has a circle with the anchor in it in the anchor column, a row without one has nothing")
unittest
{
    import ptable.model : CellData, Extra, RowData;
    import ui.log_table.marks : anchoredMark;

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
    auto cell = CellData(""w, Extra(anchoredMark)); // the cell's data says whether the record has an anchor
    ctx.data = &cell;
    auto canvas = new RecordingCanvas;
    paintAll(canvas, painter, ctx);
    assert(canvas.calls == ["circle", "text:⚓", "fill"], "the circle under the anchor, then the border of the cell");
    cell.extra = Extra(0);
    auto empty = new RecordingCanvas;
    paintAll(empty, painter, ctx);
    assert(empty.calls == ["fill"]);
    ctx.hover = true;
    auto faint = new RecordingCanvas;
    paintAll(faint, painter, ctx);
    assert(faint.calls == ["text:⚓", "fill"], "the mouse over a cell with no anchor: a faint one, no circle");
    full = true;
    auto refused = new RecordingCanvas;
    paintAll(refused, painter, ctx);
    assert(refused.calls == ["text:⊘", "fill"], "no room for another: the sign of a refusal");
    ctx.pressed = true;
    auto big = new RecordingCanvas;
    paintAll(big, painter, ctx);
    assert(big.calls == ["text:⊘", "fill"], "the button is down on it: the glyph in the big font, no circle");
    ctx.pressed = false;
    ctx.hover = false;
    auto quiet = new RecordingCanvas;
    paintAll(quiet, painter, ctx);
    assert(quiet.calls == ["fill"], "the mouse is elsewhere: nothing");
    const before = asked;
    painter.paintCell(new RecordingCanvas, ctx);
    assert(asked == before, "the document is not asked about a cell nobody points at");
    ctx.hover = true;
    full = false;
    auto room = new RecordingCanvas;
    paintAll(room, painter, ctx);
    assert(room.calls == ["text:⚓", "fill"], "room again: the faint anchor, as the document says now");
    cell.extra = Extra(anchoredMark);
    auto anchoredFull = new RecordingCanvas;
    paintAll(anchoredFull, painter, ctx);
    assert(anchoredFull.calls == ["circle", "text:⚓", "fill"], "an anchor that is there is shown as before");
}
