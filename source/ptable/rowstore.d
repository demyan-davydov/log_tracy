//! The rows the table keeps and what they depend on: the model's columns, the fonts and the layout. It brings them
//! up to date in the order they depend on each other (the fonts and the size, the columns, which are wanted, the
//! width of the flex one) and hands out the rows of the cache with their heights. It knows nothing of the window the
//! rows are shown in: the table lays that out after it. See docs/stories/painted-table.md.
module ptable.rowstore;

version (unittest) import ptable.testing : portsOf;
import std.algorithm.comparison : max;
import ptable.column : GroupInput, TableColumn;
import ptable.columnhost : ColumnClient, ColumnHost;
import ptable.columnset : ColumnSet;
import ptable.layout : ColumnDef, ColumnLayout, LayoutChange, Placements;
import ptable.memory : mallocAllocator;
import ptable.model : ModelChange, TableModel;
import ptable.painter : CellContext, Painter;
import ptable.rowcache : Entry, RowCache;
import ptable.rowlayout : RowSlot;
import ptable.tablespace : TableSpace;
import ptable.subscriptions : Subscriptions;
import ptable.tableports : TablePorts;

import std.experimental.allocator : RCIAllocator;

final class RowStore : ColumnClient
{
    private Subscriptions _ears; // the model and the layout, and the listening to them
    private ColumnSet _columns; // what the model's columns are and where they stand
    private RowCache _cache;
    private Painter _painter;
    private const(RowSlot)[] delegate() _window; // lays out the rows on the screen by the widths now and gives them (the table's)
    private double[] _titles; // what the title of each column needs, measured when the columns are read
    private double[] _needs; // what the rows in the window need of each column (`measure`), kept to allocate once
    private size_t _fitFirst = size_t.max - 1, _fitCount; // the window the widths were fit to
    private bool _detached; // `detachHost`: the store left its host for a while
    private bool _fitDirty = true; // something the widths are fit to changed: the rows, the columns, a width set by the user, the fonts
    private TableSpace _space; // the size, the fonts and the regions: the store makes them current, the others read them

    /// The rows of `model` in the columns of `host`; `window` lays out the rows on the screen by the widths of the host now and gives
    /// them (null: no window, the titles only are measured)
    this(TableModel model, ColumnHost host, TablePorts ports, const(RowSlot)[] delegate() window = null)
    {
        _window = window;
        _ears = Subscriptions(model, host);
        auto layout = host.layout;
        _painter = ports.painter;
        _space.restyle(_painter);
        _columns = new ColumnSet(layout);
        _cache = new RowCache(model, layout, ports.memory.isNull ? mallocAllocator() : ports.memory);
        host.attach(this);
    }

    /// The room the rows have: read only, made current by `ensure`
    const(TableSpace)* space() const
    {
        return &_space;
    }

    /// The size of the table; false if it is the same. `widthChanged` says the width differs
    bool resize(double width, double height, out bool widthChanged)
    {
        return _space.resize(width, height, widthChanged);
    }

    TableModel model() { return _ears.model; }
    ColumnHost host() { return _ears.host; }
    ColumnLayout layout() { return _ears.host.layout; }
    ColumnSet columns() { return _columns; }
    RowCache cache() { return _cache; }

    /// The items the model has now
    size_t itemCount()
    {
        return model.itemCount();
    }

    /// Listens to the model and the layout: what they tell is for `modelChanged` and `layoutChanged` (the caller's
    /// handlers call them)
    void listen(void delegate(const ModelChange) onModel, void delegate(const LayoutChange) onLayout)
    {
        _ears.listen(onModel, onLayout);
    }

    /// Lets go of the model and the host (the other tables of the host settle without it), and of the memory of the rows now, not
    /// when the collector gets to them
    void dispose()
    {
        _ears.detach();
        host.detach(this); // nothing if it was detached
        _cache.release();
    }

    /// The store leaves its host for a while (`Table.detach`): what its rows need and the room it has no longer count, the other
    /// tables of the host settle without it
    void detachHost()
    {
        _detached = true;
        host.detach(this);
    }

    /// The store is back with its host: its room counts again and the widths are fit anew with its rows (at the next layout)
    void attachHost()
    {
        _detached = false;
        host.attach(this);
        _fitDirty = true;
        ensure();
        host.resize(this, _space.regions.rows.w);
    }

    /// The look changed (the metrics): the painter's geometry, the fonts and the columns are read again, and the widths are fit
    /// anew (from the least ones: what the texts needed in the old fonts is not kept)
    void restyle()
    {
        _fitDirty = true;
        _space.restyle(_painter);
        _columns.markStale();
    }

    /// The model told a change; true if what was picked in the text is no longer where it was
    bool modelChanged(const ModelChange change)
    {
        _fitDirty = true;
        final switch (change.kind)
        {
        case ModelChange.Kind.everything:
        case ModelChange.Kind.columns:
            _columns.markStale();
            _cache.clear();
            return true;
        case ModelChange.Kind.count:
            _cache.removeFrom(change.first);
            return false;
        case ModelChange.Kind.rows:
            _cache.removeRange(change.first, change.last);
            return false;
        }
    }

    /// The layout told a change; true if the cells the text is picked by have moved
    bool layoutChanged(const LayoutChange change)
    {
        if (change.kind == LayoutChange.Kind.width)
            _fitDirty = true; // a width set by the user: a fit of the host, a scroll, a pin or a visibility is no change of what they are fit to
        if (change.kind == LayoutChange.Kind.fit)
            _cache.fitted();
        if (change.kind == LayoutChange.Kind.visibility)
            _columns.visibilityChanged(); // the model need not format what is hidden
        return change.kind == LayoutChange.Kind.visibility || change.kind == LayoutChange.Kind.pin;
    }

    /// Brings up to date what a row or a hit needs: the fonts and the regions, the columns, the mask of the wanted
    /// ones, the place of the columns and the width of the flex one. Cheap when nothing changed.
    void ensure()
    {
        const refreshed = _space.refresh();
        if (refreshed.fontsLoaded)
            _columns.markStale();
        bool regionsMade = refreshed.regionsMade;
        bool columnsRefreshed;
        if (_columns.stale)
        {
            columnsRefreshed = true;
            refreshColumns();
            regionsMade = _space.refresh().regionsMade || regionsMade; // the header may have grown to the font of a title
        }
        if (regionsMade && !_detached)
            host.resize(this, _space.regions.rows.w); // the room of the columns is the host's: the least its tables have
        bool wantedChanged;
        const wanted = _columns.wanted(wantedChanged);
        if (wantedChanged)
        {
            _cache.setWanted(wanted);
            _fitDirty = true;
        }
        if (columnsRefreshed)
            _fitDirty = true;
        if (_columns.hasFlex)
            _cache.setFlexWidth(_columns.flexWidth(places()));
    }

    private void refreshColumns()
    {
        _columns.refresh(model.columns());
        foreach (column; _columns.columns)
            column.lookChanged(); // the columns are read again after a change of the look of metrics, of the fonts, or of the columns
        // the header is as high as the tallest title (and group head: the plate of a group is as high as the header)
        double tallest = 0;
        foreach (i, column; _columns.columns)
            tallest = max(tallest, column.measureHeader().height, column.measureGroup(GroupInput.init).height);
        _space.fitHeader(tallest);
        _cache.configure(_columns.columns, _columns.flexIndex, _space.fonts.geometry);
        // the titles are a minimum of the widths too, the flex one's as well (and the line between the columns): told to the host with what
        // the rows need
        _titles.length = _columns.columns.length;
        auto defs = new ColumnDef[_columns.columns.length];
        auto least = new double[_columns.columns.length];
        foreach (i, column; _columns.columns)
        {
            const title = column.measureHeader();
            _titles[i] = title.maxWidth > 0 ? title.maxWidth + _space.fonts.geometry.columnBorder : 0;
            defs[i] = column.def;
            least[i] = column.leastWidth + _space.fonts.geometry.columnBorder; // the column as a whole: the line between the columns too
        }
        host.setColumns(defs, least);
    }

    // What the title of column `i` needs with the line between the columns; 0 for a hidden column and one with no title
    private double titleFit(size_t i)
    {
        return layout.visible(_columns.columns[i].def.id) ? _titles[i] : 0;
    }

    /// What the host is to settle the widths from for the rows on the screen (`slots`): its least widths when the window moved to other
    /// rows or something the widths are fit to changed (the rows, the columns, a width set by the user, the fonts), its fits when the
    /// window only got lower or higher (a bar came or went, the table was resized: the widths only widen, else the bar would come and
    /// go), null when nothing changed. The settling is done at the change, not at every frame.
    const(double)[] fitStart(const(RowSlot)[] slots)
    {
        const first = slots.length ? slots[0].index : size_t.max;
        if (!_fitDirty && first == _fitFirst && slots.length == _fitCount)
            return null;
        return _fitDirty || first != _fitFirst ? host.least : host.fits;
    }

    /// The rows on the screen laid out by the widths of the host now, and what they and the titles need of each column of the host
    /// (`ColumnClient`): a text out of sight no longer holds a column wide, a column no row measured (it wraps) needs its title only
    void measure(double[] needs)
    {
        const slots = _window !is null ? _window() : null;
        ensure();
        _fitDirty = false;
        _fitFirst = slots.length ? slots[0].index : size_t.max;
        _fitCount = slots.length;
        const columns = _columns.columns;
        _needs.length = columns.length;
        _needs[] = 0;
        foreach (slot; slots)
        {
            auto e = entry(slot.index);
            if (e.valid)
                _cache.needs(*e, _needs);
        }
        foreach (i, column; columns)
        {
            const at = host.indexOf(column.def.id); // the host's columns are these (one list), unless another table read new ones first
            if (at < needs.length)
                needs[at] = max(needs[at], _needs[i], titleFit(i));
        }
    }

    /// The place of the columns: made again only when the layout, the width or the columns changed
    ref const(Placements) places()
    {
        return host.places(_space.regions.rows.x);
    }

    /// The row `index` of the pass, read if the pass has not read it. The caller has brought the store up to date (`ensure`, which
    /// `Table.prepare` does at the start of a pass): doing it here could change the width of the flex column in the middle of a
    /// pass and let the rows it holds go.
    Entry* entry(size_t index)
    {
        return _cache.entry(index);
    }

    /// What a row not read yet is guessed to be high: an empty row as the wanted columns make it
    double fallbackHeight()
    {
        ensure();
        return _cache.fallbackHeight;
    }

    /// The height of the row `index`; 1 if it can't be had
    double heightOf(size_t index) nothrow
    {
        try
        {
            ensure();
            return _cache.heightOf(index);
        }
        catch (Exception)
            return 1;
    }
}

version (unittest)
{
    import ptable.layout : LayoutChange;
    import ptable.model : NumbersModel;
    private RowStore storeOf(TableModel model, ColumnLayout layout)
    {
        auto store = new RowStore(model, new ColumnHost(layout), portsOf(new Painter));
        bool widthChanged;
        store.resize(400, 200, widthChanged);
        return store;
    }
}

@("RowStore: ensure reads the model's columns once and gives rows with heights")
unittest
{
    auto store = storeOf(new NumbersModel(1000), new ColumnLayout);
    store.ensure();
    const columns = store.columns.columns;
    assert(columns.length == 2 && !store.columns.stale);
    store.ensure();
    assert(store.columns.columns is columns, "nothing changed: the columns are not read again");
    assert(store.entry(5).valid && store.entry(5).height == 16, "a line of 14 and the padding");
    assert(store.heightOf(5) == 16 && store.itemCount == 1000 && store.fallbackHeight == 16, "an empty row as high as a filled one");
}

@("RowStore: a change of the model drops what depends on it and says whether the text pick is lost")
unittest
{
    auto store = storeOf(new NumbersModel(1000), new ColumnLayout);
    store.ensure();
    store.heightOf(3);
    const fetched = store.cache.fetches;
    assert(!store.modelChanged(ModelChange(ModelChange.Kind.count, 10, 20)), "rows appended: the pick stays");
    store.heightOf(3);
    assert(store.cache.fetches == fetched, "the room of a row before the change is kept");
    assert(store.modelChanged(ModelChange(ModelChange.Kind.everything)) && store.columns.stale, "everything: the columns again");
    store.ensure();
    store.heightOf(3);
    assert(store.cache.fetches > fetched, "and the rows measured again");
}

@("RowStore: it hears the model and the layout until disposed")
unittest
{
    auto model = new NumbersModel(5);
    auto layout = new ColumnLayout;
    auto store = storeOf(model, layout);
    int heardModel, heardLayout;
    store.listen((const ModelChange c) { ++heardModel; }, (const LayoutChange c) { ++heardLayout; });
    model.append(1);
    layout.setWidth("n", 40);
    assert(heardModel == 1 && heardLayout == 1);
    store.dispose();
    model.append(1);
    layout.setWidth("n", 50);
    assert(heardModel == 1 && heardLayout == 1, "nobody listens any more");
    assert(store.model is model && store.layout is layout);
}

@("RowStore: the host settles from the least widths when the window moved or the rows changed, from the fits when only its height changed, not at all when the layout scrolled")
unittest
{
    import ptable.model : CellData, NumbersModel, RowData;
    import ptable.testing : BoxColumn;

    static final class LongRow : NumbersModel
    {
        this() { super(100); }
        override bool item(size_t index, ref RowData row, const(bool)[] wanted)
        {
            const ok = super.item(index, row, wanted);
            if (index == 3)
                row.cells[0] = CellData("0123456789012345678901234567890123456789"w);
            return ok;
        }
    }

    RowSlot[] rows(size_t first, size_t count)
    {
        RowSlot[] slots;
        foreach (i; 0 .. count)
            slots ~= RowSlot(first + i, i * 16.0, 16);
        return slots;
    }

    RowSlot[] window;
    auto host = new ColumnHost;
    auto store = new RowStore(new LongRow, host, portsOf(new Painter), () => cast(const(RowSlot)[]) window);
    bool widthChanged;
    store.resize(400, 200, widthChanged);
    store.ensure();
    void show(size_t first, size_t count)
    {
        window = rows(first, count);
        if (auto start = store.fitStart(window))
            host.settle(start);
    }

    assert(store.fitStart(rows(0, 7)) is host.least, "nothing fit yet: from the least widths");
    show(0, 7);
    const wide = host.layout.width("n");
    assert(wide > 400, "row 3 is in the window: the column grows to its text");
    assert(store.fitStart(rows(0, 2)) is host.fits, "the window got lower (a bar came, the window was made smaller): the same rows, only widened");
    show(0, 2);
    assert(host.layout.width("n") == wide, "no narrowing");
    show(0, 7);
    const column = cast(BoxColumn) store.columns.columns[0];
    const measured = column.measures;
    store.layoutChanged(LayoutChange(LayoutChange.Kind.scroll, ""));
    show(0, 7);
    assert(column.measures == measured, "a scroll of the layout is no change of what the widths are fit to: nothing measured again");
    assert(store.fitStart(rows(5, 7)) is host.least, "the window moved: from the least widths");
    show(5, 7);
    assert(host.layout.width("n") < wide, "the column narrows to the rows now in it");
}

@("RowStore: a change of the layout says the pick is lost when the cells moved; a restyle and a width set by the user fit the widths anew")
unittest
{
    auto host = new ColumnHost;
    auto store = new RowStore(new NumbersModel(10), host, portsOf(new Painter));
    bool widthChanged;
    store.resize(400, 200, widthChanged);
    assert(store.layoutChanged(LayoutChange(LayoutChange.Kind.visibility, "n")));
    assert(store.layoutChanged(LayoutChange(LayoutChange.Kind.pin, "n")));
    assert(!store.layoutChanged(LayoutChange(LayoutChange.Kind.width, "n")));
    store.ensure();
    host.settle(host.least);
    assert(store.fitStart(null) is null, "settled: nothing to do");
    store.restyle();
    assert(store.fitStart(null) is host.least && store.columns.stale, "the fonts changed: from the least widths, the columns read again");
    host.settle(host.least);
    store.layoutChanged(LayoutChange(LayoutChange.Kind.width, "n"));
    assert(store.fitStart(null) is host.least, "a width set by the user");
    host.settle(host.least);
    store.layoutChanged(LayoutChange(LayoutChange.Kind.fit, ""));
    assert(store.fitStart(null) is null, "a fit of the host is no change of what the widths are fit to");
}

@("RowStore: the titles need their column with the line the geometry of the painter gives, the flex one too")
unittest
{
    import ptable.painter : TableGeometry;

    static final class Bordered : Painter
    {
        override TableGeometry geometry()
        {
            TableGeometry g;
            g.columnBorder = 3;
            return g;
        }
    }

    auto host = new ColumnHost;
    auto store = new RowStore(new NumbersModel(0), host, portsOf(new Bordered));
    bool widthChanged;
    store.resize(400, 200, widthChanged);
    store.ensure();
    auto needs = new double[2];
    needs[] = 0;
    store.measure(needs);
    assert(needs[0] == 3 + 1 * 10 + 3 + 3, "the title N, its paddings and a line of 3");
    assert(needs[1] == 3 + 4 * 10 + 3 + 3, "the title of the flex column holds it as wide too");
}

@("RowStore: the host is told the least widths of the columns as a whole: of the column and the line the geometry of the painter gives")
unittest
{
    import ptable.painter : TableGeometry;

    static final class Bordered : Painter
    {
        override TableGeometry geometry()
        {
            TableGeometry g;
            g.columnBorder = 3;
            return g;
        }
    }

    auto host = new ColumnHost;
    auto store = new RowStore(new NumbersModel(0), host, portsOf(new Bordered));
    bool widthChanged;
    store.resize(400, 200, widthChanged);
    store.ensure();
    const columns = store.columns.columns;
    assert(host.least == [columns[0].leastWidth + 3, columns[1].leastWidth + 3]);
}
