//! A table with its scroll bars: one over the right edge of its body for the rows and, when the columns need more room than
//! the table has, one over the bottom of its body for them. The bars take no room from the table: it draws them after it
//! and sends the mouse to the one it is over. The host talks to this as it would to a `Table`. See docs/stories/painted-table.md.
module ptable.scrolledtable;

version (unittest) import ptable.testing : portsOf;
import ptable.layout : ColumnLayout;
import ptable.columnhost : ColumnHost;
import ptable.ports;
import ptable.rowpicks : Pick;
import ptable.scrollbar : Orientation, ScrollBar;
import ptable.table : Table, TableEvents, TablePorts;
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
    private bool _acrossShown; // the columns did not fit at the last paint: the bar at the bottom is shown
    private bool _tablePressed; // a press of the table's own is on (a selection dragged): the bars do not widen under it

    this(Table table, ScrollBar bar, ScrollBar across = null)
    {
        this.table = table;
        this.bar = bar;
        this.across = across;
        if (across !is null)
            across.orientation = Orientation.horizontal;
        table.events.invalidate = () { if (events.invalidate !is null) events.invalidate(); };
        table.events.invalidateArea = (Rect area) { if (events.invalidateArea !is null) events.invalidateArea(area); else if (events.invalidate !is null) events.invalidate(); };
        table.events.rowSelected = (size_t item, ulong id, bool delayed) { if (events.rowSelected !is null) events.rowSelected(item, id, delayed); };
        table.events.cellClicked = (size_t item, size_t column) { if (events.cellClicked !is null) events.cellClicked(item, column); };
        table.events.capture = (bool on) { if (events.capture !is null) events.capture(on); };
        table.events.needFrame = () { if (events.needFrame !is null) events.needFrame(); };
        table.events.followingEnd = (bool on) { if (events.followingEnd !is null) events.followingEnd(on); };
        table.events.scrolled = (ScrollMetrics m) { bar.update(m); if (events.scrolled !is null) events.scrolled(m); };
        table.events.scrolledX = (ScrollMetrics m) {
            if (across !is null)
                across.update(m);
            if (events.scrolledX !is null)
                events.scrolledX(m);
        };
        bar.events.scrollTo = (double fraction) { table.scrollToFraction(fraction); };
        bar.events.capture = (bool on) {
            table.holdScale(on); // the scale of the bar does not change under the drag of its thumb
            if (events.capture !is null)
                events.capture(on);
        };
        bar.events.invalidate = () { invalidateArea(strip); };
        bar.events.needFrame = () { if (events.needFrame !is null) events.needFrame(); };
        if (across !is null)
        {
            across.events.scrollTo = (double fraction) { table.scrollToFractionX(fraction); };
            across.events.capture = (bool on) { if (events.capture !is null) events.capture(on); };
            across.events.invalidate = () { invalidateArea(belowStrip); };
            across.events.needFrame = () { if (events.needFrame !is null) events.needFrame(); };
        }
    }

    // A bar looks another way (it widens, its thumb was let go of): only its strip is painted again
    private void invalidateArea(Rect area)
    {
        if (events.invalidateArea !is null)
            events.invalidateArea(area);
        else if (events.invalidate !is null)
            events.invalidate();
    }

    void resize(double width, double height)
    {
        _width = width;
        _height = height;
        table.resize(width, height); // the bars lie over the edges of the rows: the table has all of the room
    }

    // How high the bar at the bottom is while it is shown
    private double belowHeight() const
    {
        return _acrossShown ? across.width : 0;
    }

    // The strip of the bar at the right, over the right edge of the body (the margins around the rows are no matter of the bar), ending
    // where the bar at the bottom begins; its track is all of it
    private Rect strip()
    {
        return stripOf(table.bodyArea);
    }

    private Rect stripOf(Rect body) const
    {
        return Rect(_width - bar.width, body.y, bar.width, max(0.0, body.h - belowHeight));
    }

    // The strip of the bar at the bottom, over the bottom of the body, ending where the bar at the right begins; its track is all of it
    private Rect belowStrip()
    {
        return belowOf(table.bodyArea);
    }

    private Rect belowOf(Rect body) const
    {
        return Rect(0, body.y + body.h - belowHeight, max(0.0, _width - rightWidth), belowHeight);
    }

    // Where the two bars meet: neither runs under the other
    private Rect cornerOf(Rect body) const
    {
        return Rect(_width - bar.width, body.y + body.h - belowHeight, bar.width, belowHeight);
    }

    // How wide the bar at the right is while it is there
    private double rightWidth() const
    {
        return bar.shown ? bar.width : 0;
    }

    // Whether the bar at the bottom is there (the columns need it, as the table has learned them at its paint)
    private void fitBelow()
    {
        if (across is null)
            return;
        _acrossShown = across.shown; // the table told it its metrics at this paint
    }

    /// A frame of the host at `timestampMs`: the table scrolls on by itself, the bars widen or narrow on. True while any of
    /// them wants the next frame
    bool tick(double timestampMs)
    {
        bool more = table.tick(timestampMs);
        more = bar.tick(timestampMs) || more;
        if (across !is null)
            more = across.tick(timestampMs) || more;
        return more;
    }

    void paint(Canvas canvas)
    {
        table.paint(canvas);
        fitBelow(); // after the table: a column that grew to a text at this paint has the bar at once
        bar.paint(canvas, strip, strip);
        if (_acrossShown)
            across.paint(canvas, belowStrip, belowStrip);
    }

    /// Whether the point is on a bar or in the corner where they meet
    bool onBar(double x, double y)
    {
        return placesNow.onBar(x, y);
    }

    // Where the bars are now, of one read of the table's body: a host asks on every event of the mouse
    private Places placesNow()
    {
        const body = table.bodyArea;
        return Places(stripOf(body), belowOf(body), cornerOf(body), bar.shown, _acrossShown);
    }

    private static struct Places
    {
        Rect strip, below, corner;
        bool right, bottom; // the bar at the right, the one at the bottom are there

        private static bool inside(Rect r, double x, double y)
        {
            return x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h;
        }

        bool onVertical(double x, double y) const { return right && inside(strip, x, y); }
        bool onBelow(double x, double y) const { return bottom && inside(below, x, y); }
        bool onCorner(double x, double y) const { return right && bottom && inside(corner, x, y); }
        bool onBar(double x, double y) const { return onVertical(x, y) || onBelow(x, y) || onCorner(x, y); }
    }

    bool mouseDown(double x, double y, Pick mode = Pick.replace)
    {
        const at = placesNow;
        if (at.onVertical(x, y))
            return bar.mouseDown(y, at.strip);
        if (at.onBelow(x, y))
            return across.mouseDown(x, at.below);
        if (at.onCorner(x, y))
            return true; // the corner is nobody's: the press is taken, nothing happens
        _tablePressed = true; // until the release the mouse is the table's: no bar widens under it
        return table.mouseDown(x, y, mode);
    }

    bool mouseMove(double x, double y)
    {
        if (bar.dragging)
            return bar.mouseMove(y, strip);
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
        _tablePressed = false;
        return table.mouseUp(x, y);
    }

    /// The window lost the mouse or the focus with a button down: a press of the table is over
    void cancelPress()
    {
        _tablePressed = false;
        table.cancelPress();
    }

    /// The mouse is over the point (or left the table: `x` and `y` NaN): the bar under it is lit
    void mouseOver(double x, double y)
    {
        const at = placesNow;
        table.hoverAt(at.onBar(x, y) ? double.nan : x, y);
        bar.hover(!_tablePressed && at.onVertical(x, y));
        if (across !is null)
            across.hover(!_tablePressed && at.onBelow(x, y));
    }
}

version (unittest)
{
    import ptable.model : NumbersModel;
    import ptable.painter : Painter, RecordingCanvas;
}

@("ScrolledTable: the table gets all of the room, the bar lies over the right edge of its body: a press on it scrolls, one beside it selects")
unittest
{
    auto model = new NumbersModel(1000);
    auto table = new Table(model, new ColumnHost, portsOf(new Painter));
    auto scrolled = new ScrolledTable(table, new ScrollBar);
    scrolled.resize(410, 121);
    auto canvas = new RecordingCanvas;
    scrolled.paint(canvas); // the table paints, tells its metrics, the bar paints the thumb
    assert(table.bodyArea.w == 410, "no room is taken from the table");
    assert(table.scrollMetrics.shown > 0 && table.scrollMetrics.shown < 0.01, "a few rows of 1000 in view");
    assert(!scrolled.onBar(405, 10), "the header is no bar's");
    // the strip is x 400..410 over the body; a press at the middle of the track jumps the thumb there
    assert(scrolled.mouseDown(405, 21 + 50));
    assert(scrolled.bar.dragging && table.position.first > 300, "the table scrolled to about the middle");
    scrolled.mouseUp(405, 21 + 50);
    assert(!scrolled.bar.dragging);
    assert(scrolled.mouseDown(395, 21 + 3) && scrolled.mouseUp(395, 21 + 3));
    assert(table.selected >= 0, "a press beside the strip is the table's");
}

@("ScrolledTable: the bars are the table's, the margins around the rows do not change them: the track runs along the body")
unittest
{
    import ptable.painter : TableGeometry;
    import ptable.regions : SideMargins;
    import ptable.scrollbar : ScrollBarPainter;

    static class Spaced : Painter
    {
        override TableGeometry geometry()
        {
            auto g = super.geometry();
            g.marginTop = 4;
            g.marginBottom = 10;
            return g;
        }
    }

    static class Tracks : ScrollBarPainter
    {
        Rect[] tracks;
        override void paint(Canvas canvas, Rect strip, Rect track, Rect thumb, double wide, Orientation orientation = Orientation.vertical)
        {
            tracks ~= track;
        }
    }

    Rect trackOf(Painter painter, SideMargins sides)
    {
        auto host = new ColumnHost;
        host.setMargins(sides);
        auto tracks = new Tracks;
        auto scrolled = new ScrolledTable(new Table(new NumbersModel(1000), host, portsOf(painter)), new ScrollBar(tracks));
        scrolled.resize(410, 121);
        scrolled.paint(new RecordingCanvas);
        return tracks.tracks[$ - 1];
    }

    const plain = trackOf(new Painter, SideMargins.init);
    assert(plain == Rect(400, 21, 10, 100), "under the header, all of the body, over its right edge");
    assert(trackOf(new Spaced, SideMargins(20, 10)) == plain, "the margins are room of the rows, not of the bar");
}

@("ScrolledTable: a bar at the bottom comes over the bottom of the body when the columns do not fit, scrolls the columns, and goes; the table keeps its height")
unittest
{
    auto layout = new ColumnLayout;
    auto table = new Table(new NumbersModel(1000), new ColumnHost(layout), portsOf(new Painter));
    auto scrolled = new ScrolledTable(table, new ScrollBar, new ScrollBar);
    scrolled.resize(210, 121);
    auto canvas = new RecordingCanvas;
    scrolled.paint(canvas);
    assert(!scrolled.onBar(100, 118) && table.rowsArea.h == 100, "the columns fit (the flex one takes the rest): no bar");
    layout.setWidth("text", 400); // 24 + 400 wide in 210: they do not fit
    scrolled.paint(canvas);
    assert(table.rowsArea.h == 100 && scrolled.onBar(100, 118) && !scrolled.onBar(100, 50), "the bar lies over the rows' bottom");
    assert(scrolled.across.dragging == false);
    // a press at the middle of the strip jumps the columns about to the middle
    assert(scrolled.mouseDown(100, 118) && scrolled.across.dragging && layout.scrollX > 50);
    scrolled.mouseMove(150, 118);
    scrolled.mouseUp(150, 118);
    assert(!scrolled.across.dragging && layout.scrollX > 100, "dragged on");
    layout.setWidth("text", 100); // fit again
    scrolled.paint(canvas);
    assert(!scrolled.onBar(100, 118) && table.rowsArea.h == 100, "the bar went");
}

@("ScrolledTable: neither bar runs under the other: the corner where they meet takes a press and does nothing")
unittest
{
    import ptable.scrollbar : ScrollBarPainter;

    static class Tracks : ScrollBarPainter
    {
        Rect[] tracks;
        override void paint(Canvas canvas, Rect strip, Rect track, Rect thumb, double wide, Orientation orientation = Orientation.vertical)
        {
            tracks ~= track;
        }
    }

    auto layout = new ColumnLayout;
    auto table = new Table(new NumbersModel(1000), new ColumnHost(layout), portsOf(new Painter));
    auto down = new Tracks, below = new Tracks;
    auto scrolled = new ScrolledTable(table, new ScrollBar(down), new ScrollBar(below));
    scrolled.resize(210, 121);
    layout.setWidth("text", 400); // the columns do not fit
    auto canvas = new RecordingCanvas;
    scrolled.paint(canvas);
    assert(down.tracks[$ - 1] == Rect(200, 21, 10, 90) && below.tracks[$ - 1] == Rect(0, 111, 200, 10), "each ends where the other begins");
    assert(scrolled.onBar(205, 118), "the corner (x 200..210, y 111..121) is the bars'");
    table.select(3);
    const selected = table.selected;
    assert(scrolled.mouseDown(205, 118) && table.selected == selected, "a press in the corner is taken and the table is left alone");
}

@("ScrolledTable: a bar turned off or with nothing to scroll is not drawn and leaves the mouse to the rows; the other then runs to the edge")
unittest
{
    import ptable.scrollbar : ScrollBarPainter;

    static class Count : ScrollBarPainter
    {
        int paints;
        override void paint(Canvas canvas, Rect strip, Rect track, Rect thumb, double wide, Orientation orientation = Orientation.vertical)
        {
            ++paints;
        }
    }

    auto canvas = new RecordingCanvas;
    // nothing to scroll: 3 rows in 100 of body
    auto few = new Count;
    auto fit = new ScrolledTable(new Table(new NumbersModel(3), new ColumnHost, portsOf(new Painter)), new ScrollBar(few));
    fit.resize(410, 121);
    fit.paint(canvas);
    fit.paint(canvas);
    assert(few.paints == 0 && !fit.onBar(405, 21 + 3), "no bar, the edge is the rows'");
    assert(fit.mouseDown(405, 21 + 3) && fit.mouseUp(405, 21 + 3) && fit.table.selected == 0, "a press there selects the row");

    // turned off: 1000 rows, still no bar
    auto off = new Count;
    auto many = new ScrolledTable(new Table(new NumbersModel(1000), new ColumnHost, portsOf(new Painter)), new ScrollBar(off));
    many.bar.enabled = false;
    many.resize(410, 121);
    many.paint(canvas);
    assert(off.paints == 0 && !many.onBar(405, 21 + 50), "a bar turned off is not there");
    many.bar.enabled = true;
    many.paint(canvas);
    assert(off.paints == 1 && many.onBar(405, 21 + 50), "turned on again");

    // the columns do not fit, the rows do: the bar at the bottom runs to the right edge, no corner
    auto layout = new ColumnLayout;
    auto wide = new ScrolledTable(new Table(new NumbersModel(3), new ColumnHost(layout), portsOf(new Painter)), new ScrollBar, new ScrollBar);
    layout.setWidth("text", 400);
    wide.resize(210, 121);
    wide.paint(canvas);
    wide.paint(canvas);
    assert(wide.onBar(205, 118) && wide.mouseDown(205, 118) && wide.across.dragging, "the right end of the strip is the bar's own");
}

@("ScrolledTable: the mouse over a bar asks the host for frames, and its tick widens the bar")
unittest
{
    import ptable.scrollbar : ScrollBarPainter;

    static class Wide : ScrollBarPainter
    {
        double wide = -1;
        override void paint(Canvas canvas, Rect strip, Rect track, Rect thumb, double wide, Orientation orientation = Orientation.vertical)
        {
            this.wide = wide;
        }
    }

    auto look = new Wide;
    auto scrolled = new ScrolledTable(new Table(new NumbersModel(1000), new ColumnHost, portsOf(new Painter)), new ScrollBar(look));
    int frames;
    scrolled.events.needFrame = () { ++frames; };
    scrolled.resize(410, 121);
    auto canvas = new RecordingCanvas;
    scrolled.paint(canvas);
    scrolled.mouseOver(405, 21 + 50);
    assert(frames > 0, "a frame is asked for");
    foreach (now; [0.0, 100])
        assert(scrolled.tick(now), "on its way");
    assert(!scrolled.tick(200), "there in its time");
    scrolled.paint(canvas);
    assert(look.wide == 1);
}

@("ScrolledTable: a bar widening or narrowing repaints its strip only, not the table")
unittest
{
    auto scrolled = new ScrolledTable(new Table(new NumbersModel(1000), new ColumnHost, portsOf(new Painter)), new ScrollBar);
    int whole;
    Rect[] areas;
    scrolled.resize(410, 121);
    scrolled.paint(new RecordingCanvas);
    scrolled.events.invalidate = () { ++whole; };
    scrolled.events.invalidateArea = (Rect area) { areas ~= area; };
    scrolled.mouseOver(405, 21 + 50);
    foreach (now; [0.0, 100, 200, 300])
        scrolled.tick(now);
    assert(whole == 0 && areas.length > 0, "the strip is painted again");
    foreach (area; areas)
        assert(area == Rect(400, 21, 10, 100), "the strip of the bar");
}

@("ScrolledTable: a drag of the table's own over the strip (a selection reaching the edge) does not widen the bar")
unittest
{
    import ptable.scrollbar : ScrollBarPainter;

    static class Wide : ScrollBarPainter
    {
        double wide = -1;
        override void paint(Canvas canvas, Rect strip, Rect track, Rect thumb, double wide, Orientation orientation = Orientation.vertical)
        {
            this.wide = wide;
        }
    }

    auto look = new Wide;
    auto scrolled = new ScrolledTable(new Table(new NumbersModel(1000), new ColumnHost, portsOf(new Painter)), new ScrollBar(look));
    scrolled.resize(410, 121);
    auto canvas = new RecordingCanvas;
    scrolled.paint(canvas);
    assert(scrolled.mouseDown(100, 21 + 3)); // a press on the rows
    scrolled.mouseOver(405, 21 + 50);
    scrolled.mouseMove(405, 21 + 50);
    foreach (now; [0.0, 100, 200, 300])
        scrolled.tick(now);
    scrolled.paint(canvas);
    assert(look.wide == 0, "thin while the rows are dragged over");
    scrolled.mouseUp(405, 21 + 50);
    scrolled.mouseOver(405, 21 + 51);
    foreach (now; [400.0, 500, 600, 700])
        scrolled.tick(now);
    scrolled.paint(canvas);
    assert(look.wide == 1, "released: the mouse over the strip widens it");
}

@("ScrolledTable: a drag of the thumb ends when there is nothing to scroll anymore, the mouse and the scale let go")
unittest
{
    auto table = new Table(new NumbersModel(10), new ColumnHost, portsOf(new Painter));
    auto scrolled = new ScrolledTable(table, new ScrollBar);
    bool captured;
    scrolled.events.capture = (bool on) { captured = on; };
    scrolled.resize(410, 121); // 10 rows of 16 in 100: something to scroll
    auto canvas = new RecordingCanvas;
    scrolled.paint(canvas);
    assert(scrolled.mouseDown(405, 21 + 5) && scrolled.bar.dragging && captured);
    scrolled.resize(410, 400); // all of them fit now
    scrolled.paint(canvas);
    assert(!scrolled.bar.dragging && !captured, "the drag is over");
    assert(scrolled.mouseDown(405, 21 + 5) && scrolled.mouseUp(405, 21 + 5) && table.selected >= 0, "the edge is the rows' again");
}
