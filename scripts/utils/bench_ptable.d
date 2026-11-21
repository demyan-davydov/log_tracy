//! A measure of the log table: the time of a jump and a frame while jumping through 200 000 rows, the frames of a wheel and of a
//! scroll by pixels with the rows read from the model per frame, and two tables of one column host while one of them scrolls (the rows
//! of a real document go through `AppSession`, which needs the whole build: not measured here). Not a part of the build: run it as one module,
//! node scripts/test.mjs --module scripts/utils/bench_ptable.d, and compare the "BENCH" lines before and after a change (a
//! unittest build: only the comparison means something). The numbers of a run are in docs/performance.md.
module bench_ptable;
version (unittest)
{
    import ptable;
    import ui.log_table.log_look : LogFont, defaultLogLook;
    import ui.log_table.log_columns : AnchorColumn, IndexColumn, LevelColumn;
    import ui.log_table.text_column : TextColumn;
    import ui.log_table.painter : LogPainter;
    import ptable_text.columnstyle : Halign;
    import ptable_text.measurer : FontMetrics, TextMeasurer;
    import std.datetime.stopwatch : StopWatch, AutoStart;
    import std.stdio : writefln;
    import std.conv : to;

    final class Measurer : TextMeasurer
    {
        FontMetrics metrics(FontId font) { return FontMetrics(11, 3, 14); }
        double width(FontId font, const(wchar)[] text)
        {
            double w = 0;
            foreach (c; text)
                w += c == ' ' ? 3 : c < 'a' ? 7 : 6; // a measure that costs a pass over the text, as a host's does
            return w;
        }
        int wrappedLines(FontId font, const(wchar)[] text, double width) { return -1; }
    }

    final class NullCanvas : Canvas
    {
        size_t calls;
        void fillRect(Rect area, Color color) { ++calls; }
        void drawText(FontId font, const(wchar)[] text, double x, double baseline, Color color) { ++calls; }
        void drawParagraph(FontId font, const(wchar)[] text, double x, double top, double width, Color color) { ++calls; }
        void fillCircle(double cx, double cy, double radius, Color fill, Color line) { ++calls; }
        void fillRoundRect(Rect area, double radius, Color color) { ++calls; }
        void pushClip(Rect area) {}
        void popClip() {}
    }

    final class Log : TableModel
    {
        TableColumn[] made;
        wstring[] payloads;
        size_t reads; /// rows given to the table
        this(TextMeasurer measurer)
        {
            auto look = defaultLogLook();
            auto anchor = ColumnDef("anchor", "A", 24), index = ColumnDef("index", "Index"), time = ColumnDef("time", "Time");
            auto level = ColumnDef("level", "Level"), ctx = ColumnDef("ctx", "Context"), payload = ColumnDef("payload", "Payload", 200, true);
            TextColumn[] columns = [new AnchorColumn(anchor, look, null, null, measurer), new IndexColumn(index, look, null, measurer),
                new TextColumn(time, look, measurer), new LevelColumn(level, look, measurer), new TextColumn(ctx, look, measurer),
                new TextColumn(payload, look, measurer)];
            foreach (k; [0, 1, 2, 4]) // the anchor, the Index, the time and the context: small and at the right, as in the log
            {
                columns[k].style.cell.halign = Halign.right;
                columns[k].style.cell.font = LogFont.aux;
            }
            foreach (column; columns)
                made ~= column;
            foreach (i; 0 .. 64)
            {
                wstring p = "a record of the log number "w ~ i.to!wstring ~ " with some words in it";
                foreach (k; 0 .. i % 9)
                    p ~= " and more words to wrap the line of the payload"w;
                payloads ~= p;
            }
        }
        size_t itemCount() { return 200_000; }
        TableColumn[] columns() { return made; }
        bool item(size_t index, ref RowData row, const(bool)[] wanted)
        {
            if (index >= 200_000)
                return false;
            ++reads;
            row.id = index;
            row.kind = ItemKind.real_;
            row.cells = [CellData(""w), CellData(index.to!wstring), CellData("2026/11/18 12:34:56.000001"w, Extra(3)), CellData("Info"w),
                CellData("CTX1"w), CellData(payloads[index % 64])];
            row.fragments = null;
            return true;
        }
        bool indexOf(ulong rowId, out size_t index) { index = cast(size_t) rowId; return rowId < 200_000; }
        size_t subscribe(ModelListener listener) { return 0; }
        void unsubscribe(size_t handle) {}
    }

    Table tableOf(Log log, ColumnHost host)
    {
        auto table = new Table(log, host, TablePorts(new LogPainter));
        table.resize(1200, 900);
        return table;
    }
}

@("bench: frames while jumping through the rows of a log")
unittest
{
    auto log = new Log(new Measurer);
    auto table = tableOf(log, new ColumnHost);
    auto canvas = new NullCanvas;
    table.paint(canvas);
    foreach (round; 0 .. 3)
    {
        auto watch = StopWatch(AutoStart.yes);
        foreach (i; 0 .. 400)
        {
            table.scrollTo(cast(size_t)(i * 487) % 199_000);
            table.paint(canvas);
        }
        writefln("BENCH jump round %s: %.1f us a jump and a frame", round, watch.peek.total!"usecs" / 400.0);
    }
}

@("bench: the frames of a wheel and of a scroll by pixels, and the rows read per frame")
unittest
{
    auto log = new Log(new Measurer);
    auto table = tableOf(log, new ColumnHost);
    table.events.needFrame = () {};
    auto canvas = new NullCanvas;
    table.scrollTo(1000);
    table.paint(canvas);
    const onScreen = table.stats.rowsOnScreen;
    double t = 0;
    foreach (round; 0 .. 3)
    {
        enum frames = 400;
        log.reads = 0;
        auto watch = StopWatch(AutoStart.yes);
        foreach (i; 0 .. frames)
        {
            if (i % 8 == 0)
                table.wheel(i % 16 ? -120 : 120, t);
            t += 16;
            table.tick(t);
            table.paint(canvas);
        }
        writefln("BENCH wheel round %s: %.1f us a frame, %.1f rows read a frame (%s on the screen)", round,
            watch.peek.total!"usecs" / cast(double) frames, log.reads / cast(double) frames, onScreen);
        log.reads = 0;
        watch.reset();
        foreach (i; 0 .. frames)
        {
            table.queueScroll(i % 2 ? 37 : -25);
            table.paint(canvas);
        }
        writefln("BENCH scroll round %s: %.1f us a frame, %.1f rows read a frame", round,
            watch.peek.total!"usecs" / cast(double) frames, log.reads / cast(double) frames);
        watch.reset();
        foreach (i; 0 .. frames)
        {
            table.repaint(); // a hover, a rule's color: the same rows drawn again, read again
            table.paint(canvas);
        }
        writefln("BENCH repaint round %s: %.1f us a frame", round, watch.peek.total!"usecs" / cast(double) frames);
    }
}

@("bench: two tables of one column host, one of them scrolled")
unittest
{
    auto host = new ColumnHost;
    auto scrolled = new Log(new Measurer), still = new Log(new Measurer);
    auto a = tableOf(scrolled, host), b = tableOf(still, host);
    auto canvas = new NullCanvas;
    a.scrollTo(1000);
    b.scrollTo(5000);
    a.paint(canvas);
    b.paint(canvas);
    foreach (round; 0 .. 3)
    {
        enum frames = 400;
        scrolled.reads = still.reads = 0;
        auto watch = StopWatch(AutoStart.yes);
        foreach (i; 0 .. frames)
        {
            a.queueScroll(40);
            a.paint(canvas);
        }
        writefln("BENCH host round %s: %.1f us a frame of A, rows read a frame: A %.1f, B (not moved) %.1f", round,
            watch.peek.total!"usecs" / cast(double) frames, scrolled.reads / cast(double) frames, still.reads / cast(double) frames);
    }
}
