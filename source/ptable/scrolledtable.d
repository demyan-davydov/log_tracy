//! A table with its scroll bars: one at the right edge for the rows and, when the columns need more room than the table has,
//! one at the bottom for them. Gives the table the room the bars leave, draws the bars after it and sends the mouse to the one
//! it is over. The host talks to this as it would to a `Table`. See docs/stories/painted-table.md.
module ptable.scrolledtable;

version (unittest) import ptable.testing : portsOf;
import ptable.layout : ColumnLayout;
import ptable.ports;
import ptable.rowpicks : Pick;
import ptable.scrollbar : Orientation, ScrollBar;
import ptable.table : Table, TableEvents, TablePorts;
import ptable.scrollplace : ScrollPosition;
import ptable.viewport : ScrollMetrics;

import std.algorithm.comparison : max;

final class ScrolledTable
{
    Table table;
    ScrollBar bar; /// at the right edge: the rows
    ScrollBar across; /// at the bottom, only while the columns do not fit; null: the columns have no bar of their own
    /// What the host listens to: the events of the table and of the bars come out here
    TableEvents events;

    private double _width = 0, _height = 0;
    private bool _acrossShown; // the columns did not fit at the last paint: the table is as high as the bar leaves

    this(Table table, ScrollBar bar, ScrollBar across = null)
    {
        this.table = table;
        this.bar = bar;
        this.across = across;
        if (across !is null)
            across.orientation = Orientation.horizontal;
        table.events.invalidate = () { if (events.invalidate !is null) events.invalidate(); };
        table.events.invalidateArea = (Rect area) { if (events.invalidateArea !is null) events.invalidateArea(area); else if (events.invalidate !is null) events.invalidate(); };
        table.events.rowSelected = (size_t item, ulong id) { if (events.rowSelected !is null) events.rowSelected(item, id); };
        table.events.cellClicked = (size_t item, size_t column) { if (events.cellClicked !is null) events.cellClicked(item, column); };
        table.events.capture = (bool on) { if (events.capture !is null) events.capture(on); };
        table.events.needFrame = () { if (events.needFrame !is null) events.needFrame(); };
        table.events.scrolled = (ScrollMetrics m) { bar.update(m); if (events.scrolled !is null) events.scrolled(m); };
        table.events.scrolledX = (ScrollMetrics m) {
            if (across !is null)
                across.update(m);
            if (events.scrolledX !is null)
                events.scrolledX(m);
        };
        bar.events.scrollTo = (double position) { table.scrollToItem(position); };
        bar.events.capture = (bool on) { if (events.capture !is null) events.capture(on); };
        bar.events.invalidate = () { if (events.invalidate !is null) events.invalidate(); };
        if (across !is null)
        {
            across.events.scrollTo = (double position) { table.scrollToPosition(ScrollPosition.ofX(position)); };
            across.events.capture = (bool on) { if (events.capture !is null) events.capture(on); };
            across.events.invalidate = () { if (events.invalidate !is null) events.invalidate(); };
        }
    }

    void resize(double width, double height)
    {
        _width = width;
        _height = height;
        relayout();
    }

    // The table is as wide as the vertical bar leaves and as high as the bar below leaves, if there is one
    private void relayout()
    {
        table.resize(max(0.0, _width - bar.width), max(0.0, _height - belowHeight));
    }

    private double belowHeight() const
    {
        return _acrossShown ? across.width : 0;
    }

    // The strip and the track of the bar at the right: the track is the rows' height of the table
    private Rect strip() const
    {
        return Rect(_width - bar.width, 0, bar.width, _height - belowHeight);
    }

    private Rect track()
    {
        const rows = table.rowsArea;
        return Rect(_width - bar.width, rows.y, bar.width, rows.h);
    }

    // The strip of the bar at the bottom, under the table; its track is all of it
    private Rect belowStrip() const
    {
        return Rect(0, _height - belowHeight, _width - bar.width, belowHeight);
    }

    private Rect corner() const
    {
        return Rect(_width - bar.width, _height - belowHeight, bar.width, belowHeight);
    }

    // Whether the columns need the bar below; if that changed the table gets the other height. True if it did
    private bool fitBelow()
    {
        if (across is null)
            return false;
        const m = table.scrollMetricsX();
        const need = m.total > m.visible;
        if (need == _acrossShown)
            return false;
        _acrossShown = need;
        relayout();
        return true;
    }

    void paint(Canvas canvas)
    {
        fitBelow(); // before the table is painted: a window or a column that changed does not cost a frame without the bar
        table.paint(canvas);
        bar.paint(canvas, strip, track);
        if (across is null)
            return;
        if (fitBelow())
        {
            // what the table learned while it was painted (a column grew to a text) changed it: painted again at the next frame
            if (events.invalidate !is null)
                events.invalidate();
            return;
        }
        if (_acrossShown)
        {
            across.paint(canvas, belowStrip, belowStrip);
            across.paintCorner(canvas, corner);
        }
    }

    /// Whether the point is on a bar or in the corner where they meet
    bool onBar(double x, double y) const
    {
        return onVertical(x, y) || onBelow(x, y) || onCorner(x, y);
    }

    private bool onCorner(double x, double y) const
    {
        return _acrossShown && x >= _width - bar.width && y >= _height - belowHeight;
    }

    private bool onVertical(double x, double y) const
    {
        return x >= _width - bar.width && y < _height - belowHeight;
    }

    private bool onBelow(double x, double y) const
    {
        return _acrossShown && y >= _height - belowHeight && x < _width - bar.width;
    }

    bool mouseDown(double x, double y, Pick mode = Pick.replace)
    {
        if (onVertical(x, y))
            return bar.mouseDown(y, track);
        if (onBelow(x, y))
            return across.mouseDown(x, belowStrip);
        if (onCorner(x, y))
            return true; // the corner is nobody's: the press is taken, nothing happens
        return table.mouseDown(x, y, mode);
    }

    bool mouseMove(double x, double y)
    {
        if (bar.dragging)
            return bar.mouseMove(y, track);
        if (across !is null && across.dragging)
            return across.mouseMove(x, belowStrip);
        return table.mouseMove(x, y);
    }

    bool mouseUp(double x, double y)
    {
        if (bar.dragging)
            return bar.mouseUp();
        if (across !is null && across.dragging)
            return across.mouseUp();
        return table.mouseUp(x, y);
    }

    /// The mouse is over the point (or left the table: `x` and `y` NaN): the bar under it is lit
    void mouseOver(double x, double y)
    {
        table.hoverAt(onBar(x, y) ? double.nan : x, y);
        bar.hover(onVertical(x, y));
        if (across !is null)
            across.hover(onBelow(x, y));
    }
}

version (unittest)
{
    import ptable.model : NumbersModel;
    import ptable.painter : Painter, RecordingCanvas;
}

@("ScrolledTable: the table gets the width the bar leaves, a press on the bar scrolls the table, one on the rows selects")
unittest
{
    auto model = new NumbersModel(1000);
    auto table = new Table(model, new ColumnLayout, portsOf(new Painter));
    auto scrolled = new ScrolledTable(table, new ScrollBar);
    scrolled.resize(410, 121);
    auto canvas = new RecordingCanvas;
    scrolled.paint(canvas); // the table paints, tells its metrics, the bar paints the thumb
    assert(table.scrollMetrics.total == 1000);
    // the strip is x 400..410; a press at the middle of the track jumps the thumb there
    assert(scrolled.mouseDown(405, 21 + 50));
    assert(scrolled.bar.dragging && table.position.first > 300, "the table scrolled to about the middle");
    scrolled.mouseUp(405, 21 + 50);
    assert(!scrolled.bar.dragging);
    assert(scrolled.mouseDown(100, 21 + 3) && scrolled.mouseUp(100, 21 + 3));
    assert(table.selected >= 0, "a press on the rows is the table's");
}

@("ScrolledTable: a bar at the bottom comes when the columns do not fit, cuts the table's height, scrolls the columns, and goes")
unittest
{
    auto layout = new ColumnLayout;
    auto table = new Table(new NumbersModel(1000), layout, portsOf(new Painter));
    auto scrolled = new ScrolledTable(table, new ScrollBar, new ScrollBar);
    int frames;
    scrolled.events.invalidate = () { ++frames; };
    scrolled.resize(210, 121);
    auto canvas = new RecordingCanvas;
    scrolled.paint(canvas);
    assert(!scrolled.onBar(100, 118) && table.rowsArea.h == 100, "the columns fit (the flex one takes the rest): no bar");
    layout.setWidth("text", 400); // 24 + 400 wide in 200: they do not fit
    scrolled.paint(canvas);
    assert(frames > 0, "the table is painted again at its new height");
    scrolled.paint(canvas);
    assert(table.rowsArea.h == 100 - 10 && scrolled.onBar(100, 118) && !scrolled.onBar(100, 50), "the bar takes its height from the table");
    assert(scrolled.across.dragging == false);
    // a press at the middle of the strip jumps the columns about to the middle
    assert(scrolled.mouseDown(100, 118) && scrolled.across.dragging && table.scrollMetricsX().position > 50);
    scrolled.mouseMove(150, 118);
    scrolled.mouseUp(150, 118);
    assert(!scrolled.across.dragging && table.scrollMetricsX().position > 100, "dragged on");
    layout.setWidth("text", 100); // fit again
    scrolled.paint(canvas);
    scrolled.paint(canvas);
    assert(!scrolled.onBar(100, 118) && table.rowsArea.h == 100, "the bar went, the table is high as before");
}

@("ScrolledTable: the corner where the bars meet takes a press and does nothing; the bar below does not wait a frame after a column grew")
unittest
{
    auto layout = new ColumnLayout;
    auto table = new Table(new NumbersModel(1000), layout, portsOf(new Painter));
    auto scrolled = new ScrolledTable(table, new ScrollBar, new ScrollBar);
    scrolled.resize(210, 121);
    auto canvas = new RecordingCanvas;
    scrolled.paint(canvas);
    layout.setWidth("text", 400); // the columns do not fit now
    scrolled.paint(canvas); // the bar is fitted before the table is painted: the table has its height already
    assert(table.rowsArea.h == 100 - 10, "no frame with the old height");
    assert(scrolled.onBar(205, 118), "the corner (x 200..210, y 111..121) is on the bars' place");
    table.select(3);
    const selected = table.selected;
    assert(scrolled.mouseDown(205, 118) && table.selected == selected, "a press in the corner is taken and the table is left alone");
}
