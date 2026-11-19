//! Draws one frame of the table: the background and the padding, the rows on the screen (each by the painter, with
//! the text selected and the pinned columns over the scrolling ones), the header over them, the margins of the groups
//! with the heads that changed in the cells of their columns (over the header only in those cells: a margin going up
//! covers their titles, the heads of the rows on top stay there), and the footer. It
//! draws what the table gives it (the slots, the places of the columns, what is picked) and changes nothing but the
//! rows the cache keeps (a row is read when it is first painted, the row above the screen for its head). See
//! docs/stories/painted-table.md.
module ptable.framepainter;

version (unittest) import ptable.testing : portsOf;
import ptable.column : DrawState, HeaderState;
import ptable.layout : Pin, Placement, Placements;
import ptable.model : ItemKind;
import ptable.painter : EmptyZone, GroupContext, Painter, RowContext;
import ptable.ports : Canvas, Rect;
import ptable.regions : cellIn, columnLineOf, rowLineOf;
import ptable.rowcache : Entry;
import ptable.rowlayout : RowSlot;
import ptable.rowstore : RowStore;
import ptable.rowview : RowView;
import ptable.rowranges : RowRanges;
import ptable.selection : Position, TextRange;
import ptable.tablespace : TableSpace;

import std.algorithm.comparison : max, min;

/// What is picked in the frame: the rows selected and the text selected, if any
struct Picked
{
    const(RowRanges) rows;
    long current = -1; /// the row the keys move from (it need not be picked): `RowState.focused`
    bool hasText;
    TextRange text;
    long hoverRow = -1; /// the row under the mouse: `RowState.hover`
    size_t hoverColumn; /// the column of the model under it: with the row, `CellContext.hover`
    long pressedRow = -1; /// the row of the cell a button is down on (a clickable column): `CellContext.pressed`
    size_t pressedColumn;
    bool tableHasFocus = true; /// the table has the focus (the host says it): told to the painter with every hook that may draw by it
}

final class FramePainter
{
    private Painter _painter;
    private RowStore _store;
    private RowView _rows;
    private const(TableSpace)* _space;
    private size_t _frames;

    this(Painter painter, RowStore store, RowView rows, const(TableSpace)* space)
    {
        _painter = painter;
        _store = store;
        _rows = rows;
        _space = space;
    }

    /// The frames drawn so far
    size_t frames() const
    {
        return _frames;
    }

    /// Draws the background of the table only (a table detached from its host shows none of its rows)
    void paintBlank(Canvas canvas)
    {
        ++_frames;
        _painter.paintBackground(canvas, Rect(0, 0, _space.width, _space.height));
    }

    /// Draws the table: the whole of it is (0, 0, width, height) of `canvas`
    void paint(Canvas canvas, const(RowSlot)[] slots, ref const Placements p, ref const Picked picked)
    {
        ++_frames;
        const regions = _space.regions;
        _painter.beginFrame(canvas, slots.length ? slots[0].index : 0, slots.length);
        _painter.paintBackground(canvas, Rect(0, 0, _space.width, _space.height));
        if (regions.padAbove.h > 0)
            _painter.paintEmpty(canvas, regions.padAbove, EmptyZone.above);
        if (regions.padBelow.h > 0)
            _painter.paintEmpty(canvas, regions.padBelow, EmptyZone.below);
        if (regions.marginLeft.w > 0)
            _painter.paintEmpty(canvas, regions.marginLeft, EmptyZone.marginLeft);
        if (regions.marginRight.w > 0)
            _painter.paintEmpty(canvas, regions.marginRight, EmptyZone.marginRight);
        canvas.pushClip(Rect(regions.rows.x, regions.rows.y, regions.rows.w, regions.rows.h));
        foreach (ref slot; slots)
            paintRow(canvas, slot, p, picked);
        canvas.popClip();
        _painter.endFrame(canvas); // the rows were given top down: what the painter learned of them is complete
        paintHeader(canvas, p, picked.tableHasFocus);
        paintGroups(canvas, slots, p, picked.tableHasFocus);
        if (regions.footer.h > 0)
            _painter.paintFooter(canvas, regions.footer);
    }

    // The groups: the margins across the rows, with the heads that changed in the cells of their columns; then, over the
    // title of each column that groups, only in its cell, the head of the rows on top and the margins going up over it
    private void paintGroups(Canvas canvas, const(RowSlot)[] slots, ref const Placements p, bool tableHasFocus)
    {
        import std.math : round;

        const height = _space.fonts.geometry.groupHeight;
        const groups = _store.cache.groups.columns;
        if (height <= 0 || slots.length == 0 || groups.length == 0)
            return;
        const rows = _space.regions.rows, header = _space.regions.header;
        const pad = _space.fonts.geometry.groupPadTop; // the plate of the heads is the lower part of a margin
        // the place of the column that groups `k`th over the header, cut by its area as the titles are (the middle, or its pinned strip: a
        // column scrolled under a pinned one never covers it); empty if it is not shown or scrolled out of its area
        Rect placeOf(size_t k)
        {
            import std.algorithm.comparison : max, min;

            foreach (c; p.columns)
                if (c.defIndex == groups[k])
                {
                    const area = areaOf(c.area, p, rows.x, rows.w);
                    const left = max(c.x, area.x), right = min(c.x + c.width, area.x + area.w); // in the cell, not on the line beside it
                    return right > left ? Rect(left, header.y, right - left, header.h) : Rect.init;
                }
            return Rect.init;
        }

        void paintHead(size_t k, const(wchar)[] head, Rect column, double top, double h, bool sticky)
        {
            auto group = GroupContext(head, Rect(column.x, top, column.w, h), sticky, _store.columns.column(groups[k]));
            _painter.paintGroup(canvas, group, tableHasFocus);
        }

        canvas.pushClip(rows);
        foreach (ref slot; slots)
        {
            auto e = _store.entry(slot.index);
            const top = round(rows.y + slot.top);
            if (e.margin <= 0 || top + e.margin <= rows.y)
                continue;
            _painter.paintGroupBand(canvas, Rect(rows.x, top, rows.w, e.margin));
            const outline = min(_space.fonts.geometry.groupOutline, e.margin / 2); // in the room of the margin: it takes none of its own
            if (outline > 0)
            {
                _painter.paintGroupOutline(canvas, Rect(rows.x, top, rows.w, outline), true);
                _painter.paintGroupOutline(canvas, Rect(rows.x, top + e.margin - outline, rows.w, outline), false);
            }
            foreach (k; 0 .. groups.length)
            {
                const column = placeOf(k);
                if (column.w > 0 && (e.changed >> k & 1) && e.heads[k].length)
                {
                    canvas.pushClip(Rect(column.x, rows.y, column.w, rows.h)); // the head in its column's area only
                    paintHead(k, e.heads[k], column, top + pad, height, false);
                    canvas.popClip();
                }
            }
        }
        canvas.popClip();

        foreach (k; 0 .. groups.length)
        {
            const column = placeOf(k);
            if (column.w <= 0)
                continue;
            canvas.pushClip(column);
            auto first = _store.entry(slots[0].index);
            const firstTop = round(rows.y + slots[0].top) + pad; // of its plate
            // while the first margin is not up yet, the head of its column that changed there is the one above it
            const(wchar)[] head = first.heads.length > k ? first.heads[k] : null;
            if (first.margin > 0 && firstTop > header.y && (first.changed >> k & 1))
            {
                const above = slots[0].index > 0 ? _store.cache.headsOf(slots[0].index - 1) : null;
                head = above.length > k ? above[k] : null;
            }
            if (head.length)
                paintHead(k, head, column, header.y, height, true);
            foreach (i, ref slot; slots)
            {
                auto e = _store.entry(slot.index);
                const top = round(rows.y + slot.top) + pad; // of its plate
                if (e.margin > 0 && top < rows.y && (i > 0 || top > header.y) && (e.changed >> k & 1))
                    paintHead(k, e.heads[k], column, top, height, false); // a plate going up over the title
            }
            canvas.popClip();
        }
    }

    private void paintHeader(Canvas canvas, ref const Placements p, bool tableHasFocus)
    {
        const header = _space.regions.header, rows = _space.regions.rows;
        _painter.paintHeader(canvas, header);
        RowContext row;
        row.area = header;
        // the titles stand as the cells do: the middle ones in the middle (scrolled out of it they are not drawn over the margins nor
        // under a pinned strip), the pinned ones over them on their strips, with the edge of the strip
        foreach (area; [Pin.none, Pin.left, Pin.right])
        {
            const strip = areaOf(area, p, rows.x, rows.w);
            if (strip.w <= 0)
                continue;
            canvas.pushClip(Rect(strip.x, header.y, strip.w, header.h));
            foreach (c; p.columns)
                if (c.area == area)
                {
                    auto ctx = _rows.headerCellAt(row, c);
                    ctx.column.drawHeader(canvas, ctx.area, HeaderState(ctx.hover, ctx.pressed));
                    _painter.paintCell(canvas, ctx, tableHasFocus);
                    if (c.lineAfter > 0 || c.lineBefore > 0)
                        _painter.paintColumnLine(canvas, columnLineOf(c, header, 0), ctx.column, true);
                }
            canvas.popClip();
            if (area != Pin.none)
                _painter.paintPinnedEdge(canvas, Rect(area == Pin.left ? strip.right : strip.x - 1, header.y, 1, header.h), area == Pin.left);
        }
    }

    // Where the columns of `area` stand across the block of the columns that starts at `x`, `width` wide: the middle between the pinned
    // strips, or a strip; no width if it has none
    private static Rect areaOf(Pin area, ref const Placements p, double x, double width)
    {
        final switch (area)
        {
        case Pin.none: return Rect(x + p.leftWidth, 0, p.middleWidth, 0);
        case Pin.left: return Rect(x, 0, p.leftWidth, 0);
        case Pin.right: return Rect(x + width - p.rightWidth, 0, p.rightWidth, 0);
        }
    }

    private void paintRow(Canvas canvas, ref const RowSlot slot, ref const Placements p, ref const Picked picked)
    {
        auto e = _store.entry(slot.index);
        auto row = _rows.rowContextAt(e, slot.index, slot, picked.rows);
        row.state.focused = cast(long) slot.index == picked.current;
        row.state.hover = cast(long) slot.index == picked.hoverRow;
        _painter.paintRow(canvas, row, picked.tableHasFocus);
        if (!e.valid)
            return;
        const rowBorder = _space.fonts.geometry.rowBorder;
        if (e.data.kind == ItemKind.virtual_)
        {
            if (_store.columns.length)
                paintCellAt(canvas, e, row, 0, Rect(row.area.x, row.area.y, row.area.w, max(0.0, row.area.h - rowBorder)), false, false,
                    picked.tableHasFocus); // one cell across the row
            if (rowBorder > 0)
                _painter.paintRowLine(canvas, rowLineOf(row.area, rowBorder), row);
            return;
        }
        paintRowCells(canvas, e, row, p, picked);
        if (rowBorder > 0)
            _painter.paintRowLine(canvas, rowLineOf(row.area, rowBorder), row);
        _painter.paintRowOver(canvas, row, picked.tableHasFocus);
    }

    // The cells of a row of data: the middle, then the pinned strips over it
    private void paintRowCells(Canvas canvas, Entry* e, ref const RowContext row, ref const Placements p, ref const Picked picked)
    {
        const pinned = p.leftWidth > 0 || p.rightWidth > 0;
        const clipped = Rect(_space.regions.rows.x + p.leftWidth, row.area.y, p.middleWidth, row.area.h);
        if (pinned)
            canvas.pushClip(clipped);
        paintCellBacks(canvas, e, row, p, Pin.none);
        if (pinned)
            canvas.popClip();
        if (picked.hasText)
            paintSelectedText(canvas, e, row, p, picked.text, picked.tableHasFocus);
        if (pinned)
            canvas.pushClip(clipped);
        foreach (c; p.columns)
            if (c.area == Pin.none)
                paintCellOf(canvas, e, row, c, picked);
        if (!pinned)
            return;
        canvas.popClip();
        foreach (side; 0 .. 2)
        {
            const area = side == 0 ? Pin.left : Pin.right;
            const width = side == 0 ? p.leftWidth : p.rightWidth;
            if (width <= 0)
                continue;
            const x = side == 0 ? _space.regions.rows.x : _space.regions.rows.x + _space.regions.rows.w - width;
            RowContext strip = row;
            strip.area = Rect(x, row.area.y, width, row.area.h);
            _painter.paintRow(canvas, strip, picked.tableHasFocus); // opaque: the middle goes under it
            paintCellBacks(canvas, e, row, p, area);
            foreach (c; p.columns)
                if (c.area == area)
                    paintCellOf(canvas, e, row, c, picked);
            _painter.paintPinnedEdge(canvas, Rect(side == 0 ? x + width : x - 1, row.area.y, 1, row.area.h), side == 0);
        }
    }

    // The backs of the cells in `area` that have fragments, the others are not even given a context
    private void paintCellBacks(Canvas canvas, Entry* e, ref const RowContext row, ref const Placements p, Pin area)
    {
        if (e.data.fragments.length == 0)
            return;
        foreach (c; p.columns)
            if (c.area == area && c.defIndex < e.data.fragments.length && e.data.fragments[c.defIndex].length)
            {
                const cell = _rows.cellInputAt(e, row, c.defIndex);
                const place = cellIn(c, row.area, _space.fonts.geometry.rowBorder);
                const state = DrawState(place, clipOf(place), row.state);
                _store.columns.column(c.defIndex).drawBack(canvas, cell, state);
            }
    }

    private void paintCellOf(Canvas canvas, Entry* e, ref const RowContext row, ref const Placement c, ref const Picked picked)
    {
        const rowBorder = _space.fonts.geometry.rowBorder;
        paintCellAt(canvas, e, row, c.defIndex, cellIn(c, row.area, rowBorder),
            row.state.hover && c.defIndex == picked.hoverColumn, cast(long) row.index == picked.pressedRow && c.defIndex == picked.pressedColumn,
            picked.tableHasFocus);
        if (c.lineAfter > 0 || c.lineBefore > 0)
            _painter.paintColumnLine(canvas, columnLineOf(c, row.area, rowBorder), _store.columns.column(c.defIndex), false);
    }

    // The cell `defIndex` of the row in `area`: its column draws it, the painter adds its border
    private void paintCellAt(Canvas canvas, Entry* e, ref const RowContext row, size_t defIndex, Rect area, bool hover, bool pressed, bool tableHasFocus)
    {
        auto ctx = _rows.cellContextAt(e, row, defIndex, area);
        ctx.hover = hover;
        ctx.pressed = pressed;
        if (ctx.data !is null)
        {
            const cell = _rows.cellInputAt(e, row, defIndex);
            const state = DrawState(area, ctx.clip, row.state, hover, pressed);
            ctx.column.draw(canvas, cell, state);
        }
        _painter.paintCell(canvas, ctx, tableHasFocus);
    }

    // The part of a cell's `area` on the screen: a column of a tall cell draws only the lines that meet it
    private Rect clipOf(Rect area) const
    {
        const rows = _space.regions.rows;
        const top = max(area.y, rows.y), bottom = min(area.bottom, rows.bottom);
        return Rect(area.x, top, area.w, max(0.0, bottom - top));
    }

    private void paintSelectedText(Canvas canvas, Entry* e, ref const RowContext row, ref const Placements p, TextRange text, bool tableHasFocus)
    {
        if (row.index < text.start.row || row.index > text.end.row)
            return; // the cells are not even looked at for a row the selection does not touch
        auto focused = _rows.focused(e, row, _store.columns.selectable(p));
        _rows.selectionRects(focused, text, row.index, (Rect area) { _painter.paintTextSelection(canvas, area, tableHasFocus); });
    }
}

version (unittest)
{
    import ptable.layout : ColumnLayout;
    import ptable.columnhost : ColumnHost;
    import ptable.model : NumbersModel, TableModel;
    import ptable.painter : CellContext, RecordingCanvas, RowContext, TableGeometry;
    import ptable.ports : Color, FontId;
    import ptable.rowview : RowEnv;
    import ptable.tableports : TablePorts;
    import std.conv : to;

    // writes down what the painter is asked, in order
    private final class Noting : Painter
    {
        string[] calls;

        override void beginFrame(Canvas canvas, size_t firstRow, size_t rowCount) { calls ~= "begin " ~ firstRow.to!string ~ " " ~ rowCount.to!string; }
        override void endFrame(Canvas canvas) { calls ~= "end"; }
        override void paintBackground(Canvas canvas, Rect area) { calls ~= "background"; }
        override void paintRow(Canvas canvas, ref const RowContext row, bool tableHasFocus) { calls ~= "row"; }
        override void paintRowOver(Canvas canvas, ref const RowContext row, bool tableHasFocus) { calls ~= "over"; }
        override void paintCell(Canvas canvas, ref CellContext cell, bool tableHasFocus) { calls ~= cell.isHeader ? "title" : "cell"; }
        override void paintHeader(Canvas canvas, Rect area) { calls ~= "header"; }
        override void paintPinnedEdge(Canvas canvas, Rect area, bool leftEdge) { calls ~= leftEdge ? "edge-left" : "edge-right"; }
        override void paintTextSelection(Canvas canvas, Rect area, bool tableHasFocus) { calls ~= "selected"; }
    }

    private struct Frame
    {
        Noting painter;
        RowStore store;
        FramePainter painterOfFrame;
        ColumnLayout layout;
    }

    private Frame frameOf(size_t rows)
    {
        Frame f;
        f.painter = new Noting;
        f.layout = new ColumnLayout;
        f.store = new RowStore(new NumbersModel(rows), new ColumnHost(f.layout), portsOf(f.painter));
        bool widthChanged;
        f.store.resize(400, 200, widthChanged);
        f.store.ensure();
        auto view = new RowView(RowEnv(f.store.columns, f.store.space));
        f.painterOfFrame = new FramePainter(f.painter, f.store, view, f.store.space);
        return f;
    }
}

@("FramePainter: a frame is the background, the rows with their cells, then the header over them")
unittest
{
    auto f = frameOf(10);
    const slots = [RowSlot(0, 0, 16), RowSlot(1, 16, 16)];
    const p = f.store.places();
    const picked = Picked.init;
    f.painterOfFrame.paint(new RecordingCanvas, slots, p, picked);
    assert(f.painter.calls == ["begin 0 2", "background", "row", "cell", "cell", "over", "row", "cell", "cell", "over", "end", "header", "title", "title"],
        "the rows come top down between the begin and the end of the frame, each over its cells, the header after them");
    assert(f.painterOfFrame.frames == 1);
}

@("FramePainter: a row that is not there is only its background, a pinned column is drawn over the others with an edge")
unittest
{
    auto f = frameOf(10);
    const none = Picked.init;
    const gone = [RowSlot(5000, 0, 16)]; // the model has no such row
    const p = f.store.places();
    f.painterOfFrame.paint(new RecordingCanvas, gone, p, none);
    assert(f.painter.calls[0 .. 3] == ["begin 5000 1", "background", "row"] && f.painter.calls[3] == "end", "no cells for a lost row");

    f.painter.calls = null;
    f.layout.setPin("n", Pin.left);
    const slots = [RowSlot(0, 0, 16)];
    f.store.ensure();
    const pinned = f.store.places();
    f.painterOfFrame.paint(new RecordingCanvas, slots, pinned, none);
    // the scrolling cells, then the strip of the pinned area (opaque row), its cell and its edge
    assert(f.painter.calls[1 .. 9] == ["background", "row", "cell", "row", "cell", "edge-left", "over", "end"], "got ");
}

@("FramePainter: the row under the mouse and the cell under it are told to the painter, the others are not")
unittest
{
    static final class Hovering : Painter
    {
        string[] seen;
        override void paintRow(Canvas canvas, ref const RowContext row, bool tableHasFocus) { if (row.state.hover) seen ~= "row " ~ row.index.to!string; }
        override void paintCell(Canvas canvas, ref CellContext cell, bool tableHasFocus)
        {
            if (!cell.isHeader && cell.hover)
                seen ~= "cell " ~ cell.row.index.to!string ~ "," ~ cell.columnIndex.to!string;
            if (!cell.isHeader && cell.pressed)
                seen ~= "pressed " ~ cell.row.index.to!string ~ "," ~ cell.columnIndex.to!string;
        }
    }

    auto painter = new Hovering;
    auto store = new RowStore(new NumbersModel(10), new ColumnHost, portsOf(painter));
    bool widthChanged;
    store.resize(400, 200, widthChanged);
    store.ensure();
    auto view = new RowView(RowEnv(store.columns, store.space));
    auto frame = new FramePainter(painter, store, view, store.space);
    const slots = [RowSlot(0, 0, 16), RowSlot(1, 16, 16)];
    const p = store.places();
    Picked picked;
    picked.hoverRow = 1;
    picked.hoverColumn = 1;
    frame.paint(new RecordingCanvas, slots, p, picked);
    assert(painter.seen == ["row 1", "cell 1,1"], "one row, one cell of it");
    painter.seen = null;
    picked.pressedRow = 0;
    picked.pressedColumn = 0;
    frame.paint(new RecordingCanvas, slots, p, picked);
    assert(painter.seen == ["pressed 0,0", "row 1", "cell 1,1"], "the cell a button is down on, apart from the one the mouse is over");
    painter.seen = null;
    const nothing = Picked.init;
    frame.paint(new RecordingCanvas, slots, p, nothing);
    assert(painter.seen.length == 0, "no mouse over the table");
}

@("FramePainter: the back of a cell with fragments is painted after the row and before the text selected and the cells; the others have none")
unittest
{
    import ptable.model : Fragment, RowData;

    import ptable.column : CellInput, DrawState, TableColumn;
    import ptable.layout : ColumnDef;
    import ptable.testing : BoxColumn;

    // a column that writes down that the table asked it for the back of a cell, among the calls of the painter
    final class Backs : BoxColumn
    {
        string[]* calls;
        this(ColumnDef def, string[]* calls) { super(def); this.calls = calls; }
        override void drawBack(Canvas canvas, ref const CellInput cell, ref const DrawState state) { *calls ~= "back"; }
    }

    // the second cell of the rows with an even index has a fragment
    final class Marked : NumbersModel
    {
        TableColumn[] fixed;
        this(size_t count, string[]* calls)
        {
            super(count);
            fixed = [new Backs(ColumnDef("n", "N"), calls), new Backs(ColumnDef("text", "Text", 24, true), calls)];
        }

        override TableColumn[] columns() { return fixed; }

        override bool item(size_t index, ref RowData row, const(bool)[] wanted)
        {
            const found = super.item(index, row, wanted);
            row.fragments = found && index % 2 == 0 ? [null, [Fragment(0, 1)]] : null; // the row is reused: say it every time
            return found;
        }
    }

    auto f = frameOf(10);
    f.store = new RowStore(new Marked(10, &f.painter.calls), new ColumnHost(f.layout), portsOf(f.painter));
    bool widthChanged;
    f.store.resize(400, 200, widthChanged);
    f.store.ensure();
    auto view = new RowView(RowEnv(f.store.columns, f.store.space));
    f.painterOfFrame = new FramePainter(f.painter, f.store, view, f.store.space);
    const slots = [RowSlot(0, 0, 16), RowSlot(1, 16, 16)];
    const p = f.store.places();
    Picked picked;
    picked.hasText = true;
    picked.text = TextRange(Position(0, 0, 0), Position(0, 1, 2));
    f.painterOfFrame.paint(new RecordingCanvas, slots, p, picked);
    const calls = f.painter.calls;
    assert(calls[0 .. 3] == ["begin 0 2", "background", "row"]);
    assert(calls[3] == "back", "right after the row's background");
    assert(calls[4] == "selected");
    size_t backs;
    foreach (call; calls)
        backs += call == "back";
    assert(backs == 1, "row 1 has no fragments: " ~ calls.to!string);
}

@("FramePainter: the text selected is drawn on the rows it touches only")
unittest
{
    auto f = frameOf(10);
    const slots = [RowSlot(0, 0, 16), RowSlot(1, 16, 16), RowSlot(2, 32, 16)];
    const p = f.store.places();
    Picked picked;
    picked.hasText = true;
    picked.text = TextRange(Position(1, 0, 0), Position(1, 1, 2));
    f.painterOfFrame.paint(new RecordingCanvas, slots, p, picked);
    size_t selected;
    foreach (call; f.painter.calls)
        selected += call == "selected";
    assert(selected >= 1 && selected <= 2, "only row 1: its two cells at most");
}

version (unittest)
{
    import ptable.ports : Color, FontId;

    // a canvas that knows the clip it draws in
    private final class ClipCanvas : Canvas
    {
        Rect[] stack;

        void fillRect(Rect area, Color color) {}
        void drawText(FontId font, const(wchar)[] text, double x, double baseline, Color color) {}
        void drawParagraph(FontId font, const(wchar)[] text, double x, double top, double width, Color color) {}
        void fillCircle(double cx, double cy, double radius, Color fill, Color line) {}
        void pushClip(Rect area) { stack ~= area; }
        void popClip() { stack = stack[0 .. $ - 1]; }
    }
}

@("FramePainter: a cell is drawn in its area, the lines between the columns and under the rows apart in their own room; none right of the last column")
unittest
{
    import ptable.column : TableColumn;
    import ptable.painter : TableGeometry;

    static final class Lined : Painter
    {
        Rect[] cells, titles, columnLines, titleLines, rowLines;

        override TableGeometry geometry()
        {
            auto g = super.geometry();
            g.columnBorder = 2;
            g.rowBorder = 3;
            return g;
        }

        override void paintCell(Canvas canvas, ref CellContext cell, bool tableHasFocus)
        {
            if (cell.isHeader)
                titles ~= cell.area;
            else
                cells ~= cell.area;
        }

        override void paintColumnLine(Canvas canvas, Rect area, TableColumn column, bool header)
        {
            if (header)
                titleLines ~= area;
            else
                columnLines ~= area;
        }

        override void paintRowLine(Canvas canvas, Rect area, ref const RowContext row) { rowLines ~= area; }
    }

    auto painter = new Lined;
    auto layout = new ColumnLayout;
    auto store = new RowStore(new NumbersModel(10), new ColumnHost(layout), portsOf(painter));
    bool widthChanged;
    store.resize(400, 121, widthChanged);
    layout.setWidth("n", 60);
    store.ensure();
    auto view = new RowView(RowEnv(store.columns, store.space));
    auto frame = new FramePainter(painter, store, view, store.space);
    const slots = [RowSlot(0, 0, 16)];
    const none = Picked.init;
    frame.paint(new ClipCanvas, slots, store.places(), none);
    const rows = store.space.regions.rows, header = store.space.regions.header;
    assert(painter.cells == [Rect(0, rows.y, 60, 13), Rect(62, rows.y, 338, 13)], "the cells of the row, the line between them, the row's under them");
    assert(painter.columnLines == [Rect(60, rows.y, 2, 13)], "the line between the cells, as high as they; none right of the last");
    assert(painter.rowLines == [Rect(rows.x, rows.y + 13, rows.w, 3)], "the line under the row, across the block of the columns");
    assert(painter.titles == [Rect(0, header.y, 60, header.h), Rect(62, header.y, 338, header.h)], "the titles and the line between them");
    assert(painter.titleLines == [Rect(60, header.y, 2, header.h)], "the line of the header");
}

@("FramePainter: with margins and a scroll the titles are drawn as the cells are: the middle ones in the middle, the pinned ones over them on their strip, its edge in the header too")
unittest
{
    import ptable.painter : TableGeometry;

    class Margined : Painter
    {
        Rect[] titleClips, cellAreas, edges;
        string[] zones;

        override TableGeometry geometry()
        {
            auto g = super.geometry();
            g.marginLeft = 20;
            g.marginRight = 10;
            return g;
        }

        override void paintCell(Canvas canvas, ref CellContext cell, bool tableHasFocus)
        {
            auto clips = cast(ClipCanvas) canvas;
            if (cell.isHeader)
                titleClips ~= clips.stack[$ - 1];
            else
                cellAreas ~= cell.area;
        }

        override void paintEmpty(Canvas canvas, Rect area, EmptyZone zone) { zones ~= zone == EmptyZone.marginLeft ? "left" : zone == EmptyZone.marginRight ? "right" : "other"; }
        override void paintPinnedEdge(Canvas canvas, Rect area, bool leftEdge) { edges ~= area; }
    }

    auto painter = new Margined;
    auto layout = new ColumnLayout;
    auto store = new RowStore(new NumbersModel(10), new ColumnHost(layout), portsOf(painter));
    bool widthChanged;
    store.resize(400, 121, widthChanged);
    layout.setWidth("n", 60);
    layout.setWidth("text", 500);
    layout.setPin("n", Pin.left);
    layout.setScrollX(100); // the middle column scrolled left under the pinned one
    store.ensure();
    auto view = new RowView(RowEnv(store.columns, store.space));
    auto frame = new FramePainter(painter, store, view, store.space);
    const slots = [RowSlot(0, 0, 16)];
    const p = store.places();
    const none = Picked.init;
    frame.paint(new ClipCanvas, slots, p, none);
    assert(painter.zones == ["left", "right"], "the margins are their own zones");
    assert(painter.titleClips == [Rect(20 + 60, 0, 370 - 60, 21), Rect(20, 0, 60, 21)],
        "the scrolled title in the middle, not over the pinned one; the pinned title after it on its strip");
    assert(painter.edges.length == 2 && painter.edges[0].x == 20 + 60 && painter.edges[1] == Rect(20 + 60, 0, 1, 21),
        "the edge of the pinned strip in the row and in the header (painted after the rows)");
    assert(p.columns[0].x == 20 && p.columns[1].x == 20 + 60 - 100, "pinned at the origin, the middle one scrolled");
}

version (unittest)
{
    // keeps the clip a head is painted in
    private final class Clips : Canvas
    {
        Rect[] stack;
        void fillRect(Rect area, Color color) {}
        void drawText(FontId font, const(wchar)[] text, double x, double baseline, Color color) {}
        void drawParagraph(FontId font, const(wchar)[] text, double x, double top, double width, Color color) {}
        void fillCircle(double cx, double cy, double radius, Color fill, Color line) {}
        void pushClip(Rect area) { stack ~= area; }
        void popClip() { stack = stack[0 .. $ - 1]; }
    }

    // writes down the bands and the heads, their tops from the top of the rows, and the clips
    private final class Groups : Painter
    {
        string[] seen;
        Rect[] clips, places;
        double rowsTop;
        override TableGeometry geometry() { TableGeometry g; g.groupHeight = 20; return g; }
        override void paintGroupBand(Canvas canvas, Rect area)
        {
            seen ~= "band " ~ (area.y - rowsTop).to!string;
            clips ~= (cast(Clips) canvas).stack[$ - 1];
            places ~= area;
        }
        override void paintGroup(Canvas canvas, ref GroupContext group, bool tableHasFocus)
        {
            seen ~= (group.sticky ? "sticky " : "") ~ group.head.to!string ~ " " ~ (group.cell.y - rowsTop).to!string;
            clips ~= (cast(Clips) canvas).stack[$ - 1];
            places ~= group.cell;
        }
    }

    private struct GroupFrame
    {
        Groups painter;
        RowStore store;
        FramePainter frame;
        const(Placements)* p;

        // paints the rows from `first` on, the first one `top` from the top of the rows
        void paint(size_t first, double top)
        {
            painter.seen = null;
            painter.clips = painter.places = null;
            RowSlot[] slots;
            foreach (i; first .. first + 6)
            {
                const h = store.heightOf(i);
                slots ~= RowSlot(i, top, h);
                top += h;
            }
            const none = Picked.init;
            frame.paint(new Clips, slots, *p, none);
        }
    }

    private GroupFrame groupFrameOf(TableModel model, ColumnLayout layout = null, double width = 400)
    {
        GroupFrame f;
        f.painter = new Groups;
        f.store = new RowStore(model, new ColumnHost(layout !is null ? layout : new ColumnLayout), portsOf(f.painter));
        bool widthChanged;
        f.store.resize(width, 300, widthChanged);
        f.store.ensure();
        f.painter.rowsTop = f.store.space.regions.rows.y;
        f.frame = new FramePainter(f.painter, f.store, new RowView(RowEnv(f.store.columns, f.store.space)), f.store.space);
        f.p = &f.store.places();
        return f;
    }
}

@("FramePainter: a margin is a band across the rows with its head in its column's cell; over the header only that cell, where the head of the rows on top stands")
unittest
{
    import ptable.testing : DatedModel;

    auto f = groupFrameOf(new DatedModel(100, 3));
    const rows = f.store.space.regions.rows, header = f.store.space.regions.header;
    assert(header.y == 0 && rows.y == 21, "a header of 21 over the rows");
    const time = f.p.columns[0]; // the column whose heads group the rows

    // rows of 16, the first of a later day (3, 6) 20 more; the header is 21 over the rows (-21 from their top)
    f.paint(0, 0);
    assert(f.painter.seen == ["band 48", "d1 48", "sticky d0 -21"], "the first row has no margin: from the start its head is over the title");
    assert(f.painter.places[0] == Rect(rows.x, rows.y + 48, rows.w, 20) && f.painter.places[1] == Rect(time.x, rows.y + 48, time.width, 20),
        "the band across the rows, the head in the cell of its column");
    assert(f.painter.clips[0] == rows && f.painter.clips[1] == Rect(time.x, rows.y, time.width, rows.h), "in the rows, the head in its column");
    assert(f.painter.clips[2] == Rect(time.x, header.y, time.width, header.h), "only over the column's title, not over the line right of it");

    f.paint(1, -5);
    assert(f.painter.seen == ["band 27", "d1 27", "band 95", "d2 95", "sticky d0 -21"]);

    f.paint(3, -8);
    assert(f.painter.seen == ["band -8", "d1 -8", "band 60", "d2 60", "sticky d0 -21", "d1 -8"], "the next margin goes up over the title");

    f.paint(3, -30);
    assert(f.painter.seen == ["band 38", "d2 38", "sticky d1 -21"], "at the top it stays over the title");
}

@("FramePainter: rows grouped by two columns: a margin has the heads of the columns that changed, the header the head of each over its title")
unittest
{
    import ptable.testing : TwoHeadsModel;

    auto f = groupFrameOf(new TwoHeadsModel(100));
    const header = f.store.space.regions.header;

    // the day changes every 5 rows, the shift every 3; rows of 16, a margin of 20
    f.paint(0, 0);
    assert(f.painter.seen == ["band 48", "S1 48", "band 100", "D1 100", "sticky D0 -21", "sticky S0 -21"],
        "the shift alone at row 3, the day alone at row 5; each title its own head");
    assert(f.painter.clips[4] == Rect(f.p.columns[0].x, header.y, f.p.columns[0].width, header.h)
        && f.painter.clips[5] == Rect(f.p.columns[1].x, header.y, f.p.columns[1].width, header.h));

    f.paint(15, 0);
    assert(f.painter.seen == ["band 0", "D3 0", "S5 0", "band 68", "S6 68", "band 120", "D4 120", "sticky D2 -21", "sticky S4 -21"],
        "both at row 15, under the heads of the rows above it, still on the titles");

    f.paint(15, -8);
    assert(f.painter.seen == ["band -8", "D3 -8", "S5 -8", "band 60", "S6 60", "band 112", "D4 112",
        "sticky D2 -21", "D3 -8", "sticky S4 -21", "S5 -8"], "the margin goes up over both titles");
}

@("FramePainter: with room above the plate, the band is the whole margin and the head's plate its lower part, as high as the header")
unittest
{
    import ptable.testing : DatedModel;

    static final class Padded : Painter
    {
        Rect[] bands, plates;
        override TableGeometry geometry() { TableGeometry g; g.groupHeight = 20; g.groupPadTop = 6; return g; }
        override void paintGroupBand(Canvas canvas, Rect area) { bands ~= area; }
        override void paintGroup(Canvas canvas, ref GroupContext group, bool tableHasFocus) { if (!group.sticky) plates ~= group.cell; }
    }

    auto painter = new Padded;
    auto store = new RowStore(new DatedModel(100, 3), new ColumnHost, portsOf(painter));
    bool widthChanged;
    store.resize(400, 300, widthChanged);
    store.ensure();
    auto frame = new FramePainter(painter, store, new RowView(RowEnv(store.columns, store.space)), store.space);
    const p = store.places();
    RowSlot[] slots;
    double top = 0;
    foreach (i; 0 .. 6)
    {
        slots ~= RowSlot(i, top, store.heightOf(i));
        top += store.heightOf(i);
    }
    const none = Picked.init;
    frame.paint(new RecordingCanvas, slots, p, none);
    const rows = store.space.regions.rows;
    assert(painter.bands == [Rect(rows.x, rows.y + 48, rows.w, 26)], "the margin of row 3: the room and the plate");
    assert(painter.plates == [Rect(p.columns[0].x, rows.y + 48 + 6, p.columns[0].width, 20)], "the plate at its bottom, in the cell");
}

@("FramePainter: the lines of a margin are at its top and its bottom, in its room: after the band, before the plates, the margin as high as without them")
unittest
{
    import ptable.testing : DatedModel;

    static final class Outlined : Painter
    {
        string[] calls;
        Rect[] lines;
        Rect band;
        override TableGeometry geometry() { TableGeometry g; g.groupHeight = 20; g.groupPadTop = 6; g.groupOutline = 2; return g; }
        override void paintGroupBand(Canvas canvas, Rect area) { calls ~= "band"; band = area; }
        override void paintGroupOutline(Canvas canvas, Rect area, bool top) { calls ~= top ? "top" : "bottom"; lines ~= area; }
        override void paintGroup(Canvas canvas, ref GroupContext group, bool tableHasFocus) { if (!group.sticky) calls ~= "plate"; }
    }

    auto painter = new Outlined;
    auto store = new RowStore(new DatedModel(100, 3), new ColumnHost, portsOf(painter));
    bool widthChanged;
    store.resize(400, 300, widthChanged);
    store.ensure();
    auto frame = new FramePainter(painter, store, new RowView(RowEnv(store.columns, store.space)), store.space);
    RowSlot[] slots;
    double top = 0;
    foreach (i; 0 .. 6)
    {
        slots ~= RowSlot(i, top, store.heightOf(i));
        top += store.heightOf(i);
    }
    const none = Picked.init;
    frame.paint(new RecordingCanvas, slots, store.places(), none);
    const rows = store.space.regions.rows;
    assert(painter.band == Rect(rows.x, rows.y + 48, rows.w, 26), "the margin of row 3 as high as without the lines: they take no room");
    assert(painter.lines == [Rect(rows.x, rows.y + 48, rows.w, 2), Rect(rows.x, rows.y + 48 + 26 - 2, rows.w, 2)], "at its top and its bottom");
    assert(painter.calls == ["band", "top", "bottom", "plate"], "over the band, under the plate");
}

@("FramePainter: the head of a group of a column scrolled under a pinned one is cut by the middle: it never covers the pinned column")
unittest
{
    import ptable.column : TableColumn;
    import ptable.layout : ColumnDef;
    import ptable.model : CellData, ModelListener, RowData;
    import ptable.testing : DatedModel, withBoxes;

    // the rows of a `DatedModel` with a column of numbers before them
    static final class Numbered : TableModel
    {
        DatedModel dated;
        TableColumn[] all;
        this()
        {
            dated = new DatedModel(100, 3);
            all = withBoxes([ColumnDef("n", "N")]) ~ dated.columns();
        }
        size_t itemCount() { return dated.itemCount; }
        TableColumn[] columns() { return all; }
        bool item(size_t index, ref RowData row, const(bool)[] wanted)
        {
            if (!dated.item(index, row, wanted.length > 1 ? wanted[1 .. $] : null))
                return false;
            row.cells = [CellData("1"w)] ~ row.cells;
            row.fragments = null;
            return true;
        }
        bool indexOf(ulong rowId, out size_t index) { return dated.indexOf(rowId, index); }
        size_t subscribe(ModelListener listener) { return 0; }
        void unsubscribe(size_t handle) {}
    }

    auto layout = new ColumnLayout;
    auto painter = new Groups;
    auto store = new RowStore(new Numbered, new ColumnHost(layout), portsOf(painter));
    bool widthChanged;
    store.resize(400, 300, widthChanged);
    layout.setWidth("n", 40);
    layout.setWidth("time", 100);
    layout.setPin("n", Pin.left);
    layout.setScrollX(50); // the time column starts 10 under the pinned one
    store.ensure();
    painter.rowsTop = store.space.regions.rows.y;
    auto frame = new FramePainter(painter, store, new RowView(RowEnv(store.columns, store.space)), store.space);
    RowSlot[] slots;
    double top = 0;
    foreach (i; 0 .. 6)
    {
        slots ~= RowSlot(i, top, store.heightOf(i));
        top += store.heightOf(i);
    }
    const none = Picked.init;
    frame.paint(new Clips, slots, store.places(), none);
    const rows = store.space.regions.rows;
    assert(painter.places.length > 1, "heads were drawn");
    foreach (i, place; painter.places)
        if (painter.seen[i].length < 4 || painter.seen[i][0 .. 4] != "band")
        {
            assert(place.x >= rows.x + 40, "a head is in the middle, right of the pinned column: " ~ painter.seen[i]);
            assert(painter.clips[i].x >= rows.x + 40, "and cut there: " ~ painter.seen[i]);
        }
}

@("FramePainter: a head scrolled sideways out of the block of the columns is cut by it, over the header as its title")
unittest
{
    import ptable.testing : DatedModel;

    auto layout = new ColumnLayout;
    auto f = groupFrameOf(new DatedModel(100, 3), layout, 60); // narrower than the columns: they scroll
    f.paint(0, 0);
    f.store.host.settle(f.store.host.least); // the titles widen the columns (no table here settles them)
    layout.setScrollX(15);
    f.store.ensure();
    f.p = &f.store.places();
    const rows = f.store.space.regions.rows, header = f.store.space.regions.header;
    const time = f.p.columns[0];
    assert(time.x < rows.x, "the time column scrolled out of the block on the left");
    f.paint(1, -5);
    const sticky = f.painter.clips[$ - 1];
    assert(sticky == Rect(rows.x, header.y, time.x + time.width - rows.x, header.h), "the head over the title is cut at the block's edge");
}

@("FramePainter: a hidden column that groups gives no margins: its cells have no text, so no heads")
unittest
{
    import ptable.testing : TwoHeadsModel;

    auto layout = new ColumnLayout;
    layout.setVisible("shift", false);
    auto f = groupFrameOf(new TwoHeadsModel(100), layout);
    f.paint(0, 0);
    assert(f.painter.seen == ["band 80", "D1 80", "sticky D0 -21"], "the day's margins alone");
}

@("FramePainter: under a margin the strip of a pinned column stands where its row does, no higher, no taller")
unittest
{
    import ptable.testing : DatedModel;

    static final class Rows : Painter
    {
        Rect[] areas;
        override TableGeometry geometry() { TableGeometry g; g.groupHeight = 20; return g; }
        override void paintRow(Canvas canvas, ref const RowContext row, bool tableHasFocus) { areas ~= row.area; }
        override void paintPinnedEdge(Canvas canvas, Rect area, bool leftEdge) { areas ~= area; }
    }

    auto painter = new Rows;
    auto layout = new ColumnLayout;
    auto store = new RowStore(new DatedModel(100, 3), new ColumnHost(layout), portsOf(painter));
    bool widthChanged;
    store.resize(400, 300, widthChanged);
    layout.setPin("time", Pin.left);
    store.ensure();
    auto frame = new FramePainter(painter, store, new RowView(RowEnv(store.columns, store.space)), store.space);
    const p = store.places();
    const slots = [RowSlot(3, 0, store.heightOf(3))]; // the first row of day 1: a margin of 20 over its 16
    const none = Picked.init;
    frame.paint(new RecordingCanvas, slots, p, none);
    const rowsTop = store.space.regions.rows.y;
    assert(painter.areas.length == 4, "the row, the strip of the pinned column, its edge, and the edge in the header");
    foreach (area; painter.areas[0 .. 3])
        assert(area.y == rowsTop + 20 && area.h == 16, "under the margin, as high as the row");
    assert(painter.areas[3].y == store.space.regions.header.y, "the edge of the strip goes on in the header");
}
