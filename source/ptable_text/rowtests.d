//! The rows of a table of text columns: what the style, the fonts and the measurer of a text column make of the height of a row and the width of a
//! column (the cache of the rows is `ptable.rowcache`, which knows no text). Only in a unit test build.
module ptable_text.rowtests;

version (unittest)
{
    import ptable.column : TableColumn;
    import ptable.layout : ColumnDef, ColumnLayout;
    import ptable.memory : mallocAllocator;
    import ptable.model : CellData, ItemKind, ModelListener, NumbersModel, RowData, TableModel;
    import ptable.painter : TableGeometry;
    import ptable.rowcache : RowCache, maxFitWidth;
    import ptable.rowlayout : rowHeight;
    import ptable_text.columnstyle : ColumnStyle;
    import ptable_text.measurer : FontMetrics, TextMeasurer;
    import ptable_text.testing : withText;
    import ptable_text.wrap : maxMeasuredChars;
    import ptable.ports : FontId;

    import std.algorithm.comparison : max;
}

@("RowCache: the wrap width is the flex column's width less the padding of its style")
unittest
{
    import ptable.layout : ColumnDef, ColumnLayout;
    import ptable.model : NumbersModel;
    auto cache = new RowCache(new NumbersModel(5), new ColumnLayout, mallocAllocator());
    ColumnDef[] defs = [ColumnDef("n", "N"), ColumnDef("text", "Text", 24, true)];
    auto styles = new ColumnStyle[defs.length];
    TableGeometry geometry;
    cache.configure(withText(defs, null, styles), 1, geometry);
    cache.setFlexWidth(40); // 40 less 3 on both sides: 3 glyphs of 10 in a line
    const plain = cache.entry(2).height;
    styles[1].cell.padLeft = 33; // 40 - 33 - 3 = 4: a glyph in a line
    cache.configure(withText(defs, null, styles), 1, geometry);
    cache.clear();
    assert(cache.entry(2).height > plain, "a wider padding wraps into more lines: a taller row");
}

@("RowCache: a flex column that does not wrap is one line of its text, up to a hard break, however narrow")
unittest
{
    import ptable.layout : ColumnDef, ColumnLayout;
    import ptable.model : NumbersModel;
    auto cache = new RowCache(new NumbersModel(5), new ColumnLayout, mallocAllocator());
    ColumnDef[] defs = [ColumnDef("n", "N"), ColumnDef("text", "Text", 24, true)];
    auto styles = new ColumnStyle[defs.length];
    TableGeometry geometry;
    cache.configure(withText(defs, null, styles), 1, geometry);
    cache.setFlexWidth(40);
    assert(cache.entry(2).height > rowHeight(1, 14, 1), "it wraps by default: a row of lines");
    styles[1].wrap = false;
    cache.configure(withText(defs, null, styles), 1, geometry);
    cache.setFlexWidth(40);
    const e = cache.entry(2);
    assert(e.height == rowHeight(1, 14, 1));
}

@("RowCache: a flex column that does not wrap needs its longest first line and keeps its rows when it grows")
unittest
{
    import ptable.layout : ColumnDef, ColumnLayout;
    import ptable.model : NumbersModel;
    auto layout = new ColumnLayout;
    auto cache = new RowCache(new NumbersModel(2000), layout, mallocAllocator());
    ColumnDef[] defs = [ColumnDef("n", "N"), ColumnDef("text", "Text", 24, true)];
    auto styles = new ColumnStyle[defs.length];
    TableGeometry geometry;
    cache.configure(withText(defs, null, styles), 1, geometry);
    cache.setFlexWidth(50);
    auto needs = new double[2];
    needs[] = 0;
    cache.needs(*cache.entry(5), needs);
    assert(needs[1] == 0, "a wrapping flex column takes the rest, no text sets its width");

    styles[1].wrap = false;
    cache.configure(withText(defs, null, styles), 1, geometry);
    cache.setFlexWidth(50);
    needs[] = 0;
    cache.needs(*cache.entry(5), needs); // "row 5": 5 glyphs of 10, the padding 3 + 3 and 1
    assert(needs[1] == 5 * 10 + 6 + 1);
    cache.needs(*cache.entry(1234), needs); // "row 1234": 8 glyphs
    assert(needs[1] == 8 * 10 + 6 + 1, "the longest text seen");
    const fetched = cache.fetches;
    cache.setFlexWidth(200); // the width the flex column has changed (it grew)
    cache.entry(1234);
    assert(cache.fetches == fetched, "no row is laid out by that width: they stay");
    cache.setFlexWidth(0);
    cache.entry(1234);
    assert(cache.fetches > fetched, "a column with no width at all is another matter: the rows are made again");
}

@("RowCache: a column that asks for a least height makes the row at least that high, a hidden one does not")
unittest
{
    import ptable.layout : ColumnDef, ColumnLayout;
    import ptable.model : NumbersModel;
    auto cache = new RowCache(new NumbersModel(5), new ColumnLayout, mallocAllocator());
    ColumnDef[] defs = [ColumnDef("n", "N"), ColumnDef("text", "Text", 24, true)];
    auto styles = new ColumnStyle[defs.length];
    styles[0].minHeight = 40;
    TableGeometry geometry;
    cache.configure(withText(defs, null, styles), 1, geometry);
    cache.setFlexWidth(400);
    assert(cache.entry(1).height == 40 + 2, "the least height is of the content, the paddings (1 above, 1 under) come on top");
    cache.setWanted([false, true]);
    assert(cache.entry(1).height == 16, "the column is not shown: it asks for nothing");
}

@("RowCache: a row not read yet is guessed as high as the wanted columns make an empty row")
unittest
{
    import ptable_text.testing : Sized;
    import ptable.layout : ColumnDef, ColumnLayout;
    import ptable.model : NumbersModel;

    auto measurer = new Sized;
    auto cache = new RowCache(new NumbersModel(5), new ColumnLayout, mallocAllocator());
    ColumnDef[] defs = [ColumnDef("n", "N"), ColumnDef("text", "Text", 24, true)];
    auto styles = new ColumnStyle[defs.length];
    styles[0].cell.font = 30;
    styles[1].cell.font = 20;
    TableGeometry geometry;
    cache.configure(withText(defs, measurer, styles), 1, geometry);
    assert(cache.fallbackHeight == 30 + 2, "the taller column");
    cache.setWanted([false, true]);
    assert(cache.fallbackHeight == 20 + 2, "a hidden column makes no part of it");
}

@("RowCache: a row is as high as its tallest cell by the fonts of the columns, the flex cell's lines by its own line")
unittest
{
    import ptable_text.testing : Sized;
    import ptable.layout : ColumnDef, ColumnLayout;
    import ptable.model : NumbersModel;

    auto measurer = new Sized;
    auto cache = new RowCache(new NumbersModel(5), new ColumnLayout, mallocAllocator());
    ColumnDef[] defs = [ColumnDef("n", "N"), ColumnDef("text", "Text", 24, true)];
    auto styles = new ColumnStyle[defs.length];
    styles[0].cell.font = 30;
    styles[1].cell.font = 20;
    TableGeometry geometry;
    cache.configure(withText(defs, measurer, styles), 1, geometry);
    cache.setFlexWidth(400);
    assert(cache.entry(1).height == 30 + 2 * 1, "the other cell is the tallest");
    styles[0].cell.font = 10;
    cache.configure(withText(defs, measurer, styles), 1, geometry);
    cache.setFlexWidth(400);
    assert(cache.entry(1).height == 20 + 2 * 1, "the flex cell is");
    styles[0].cell.padTop = 4;
    styles[0].cell.font = 20;
    cache.configure(withText(defs, measurer, styles), 1, geometry);
    cache.setFlexWidth(400);
    assert(cache.entry(1).height == 20 + 4 + 1, "the room above a cell is its own: 3 more than the flex cell's");
}

@("RowCache: a very long line of the flex column that does not wrap is measured by its first part and the rest is estimated")
unittest
{
    import ptable.layout : ColumnDef, ColumnLayout;
    import ptable.model : CellData, ItemKind, ModelListener, RowData, TableModel;
    static final class Longest : TextMeasurer
    {
        size_t longest;
        FontMetrics metrics(FontId font) { return FontMetrics(11, 3, 14); }
        double width(FontId font, const(wchar)[] text)
        {
            longest = max(longest, text.length);
            return text.length * 10.0;
        }
        int wrappedLines(FontId font, const(wchar)[] text, double width) { return -1; }
    }

    static immutable wstring longText = cast(immutable) (new wchar[10_000]).dup;

    static final class LongLine : TableModel
    {
        size_t itemCount() { return 3; }
        TableColumn[] columns() { return withText([ColumnDef("t", "T", 24, true)]); }
        bool item(size_t index, ref RowData row, const(bool)[] wanted)
        {
            row.id = index;
            row.kind = ItemKind.real_;
            row.cells = [CellData(longText)];
            return true;
        }
        bool indexOf(ulong rowId, out size_t index) { index = cast(size_t) rowId; return rowId < 3; }
        size_t subscribe(ModelListener listener) { return 0; }
        void unsubscribe(size_t handle) {}
    }

    auto layout = new ColumnLayout;
    auto measurer = new Longest;
    auto cache = new RowCache(new LongLine, layout, mallocAllocator());
    ColumnDef[] defs = [ColumnDef("t", "T", 24, true)];
    auto styles = new ColumnStyle[defs.length];
    styles[0].wrap = false;
    TableGeometry geometry;
    cache.configure(withText(defs, measurer, styles), 0, geometry);
    cache.setFlexWidth(100);
    auto needs = new double[1];
    needs[] = 0;
    cache.needs(*cache.entry(0), needs);
    assert(measurer.longest <= maxMeasuredChars, "no more than that is measured");
    assert(needs[0] == 6 + 10_000 * 10 + 1 || needs[0] == maxFitWidth, "estimated by the part: 10 per character, or the cap");
}

@("Table: the style of the flex column says whether it wraps; a change of it with a restyle makes the rows one line, the place kept")
unittest
{
    import ptable.lookchange : LookChange;
    import ptable.painter : Painter, RecordingCanvas;
    import ptable.columnhost : ColumnHost;
    import ptable.table : Table;
    import ptable.testing : portsOf;
    import ptable_text.testing : styleOf;

    static final class Switch : NumbersModel
    {
        bool wrap = true;
        this(size_t count) { super(count); }
        override TableColumn[] columns()
        {
            auto columns = withText([ColumnDef("n", "N"), ColumnDef("text", "Text", 24, true)]);
            styleOf(columns[1]).wrap = wrap;
            return columns;
        }
    }

    auto model = new Switch(1000);
    auto table = new Table(model, new ColumnHost, portsOf(new Painter, null));
    table.resize(70, 121); // the flex column is left with room for a few glyphs: "row 5" wraps
    auto canvas = new RecordingCanvas;
    table.paint(canvas);
    table.scrollTo(300);
    table.paint(canvas);
    const wrapped = table.stats.rowsOnScreen;
    assert(table.position.first == 300 && wrapped < 7, "the rows are taller than a line");
    model.wrap = false;
    table.restyle(LookChange.metrics);
    table.paint(canvas);
    assert(table.stats.rowsOnScreen == 7, "one line each: 100 / 16 rounded up");
    assert(table.position.first == 300, "the place is kept");
}
