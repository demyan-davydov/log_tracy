//! The rows the table keeps and what they depend on: the model's columns, the fonts and the layout. It brings them
//! up to date in the order they depend on each other (the fonts and the size, the columns, which are wanted, the
//! width of the flex one) and hands out the rows of the cache with their heights. It knows nothing of the window the
//! rows are shown in: the table lays that out after it. See docs/stories/painted-table.md.
module ptable.rowstore;

version (unittest) import ptable.testing : portsOf;
import std.algorithm.comparison : max;
import ptable.column : GroupInput;
import ptable.columnset : ColumnSet;
import ptable.layout : ColumnLayout, LayoutChange, Placements;
import ptable.memory : mallocAllocator;
import ptable.model : ModelChange, TableModel;
import ptable.painter : CellContext, Painter;
import ptable.rowcache : Entry, RowCache;
import ptable.tablespace : TableSpace;
import ptable.subscriptions : Subscriptions;
import ptable.tableports : TablePorts;

import std.experimental.allocator : RCIAllocator;

final class RowStore
{
    private Subscriptions _ears; // the model and the layout, and the listening to them
    private ColumnSet _columns; // what the model's columns are and where they stand
    private RowCache _cache;
    private Painter _painter;
    private TableSpace _space; // the size, the fonts and the regions: the store makes them current, the others read them

    this(TableModel model, ColumnLayout layout, TablePorts ports)
    {
        _ears = Subscriptions(model, layout);
        _painter = ports.painter;
        _space.restyle(_painter);
        _columns = new ColumnSet(layout);
        _cache = new RowCache(model, layout, ports.memory.isNull ? mallocAllocator() : ports.memory);
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
    ColumnLayout layout() { return _ears.layout; }
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

    /// Lets go of the model and the layout, and of the memory of the rows now, not when the collector gets to them
    void dispose()
    {
        _ears.detach();
        _cache.release();
    }

    /// The look changed (the metrics): what the texts needed in width is forgotten, the painter's geometry, the
    /// fonts and the columns are read again
    void restyle()
    {
        layout.resetFit();
        _space.restyle(_painter);
        _columns.markStale();
    }

    /// The model told a change; true if what was picked in the text is no longer where it was
    bool modelChanged(const ModelChange change)
    {
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
        if (refreshed.regionsMade)
            _columns.invalidatePlaces();
        bool columnsRefreshed;
        if (_columns.stale)
        {
            columnsRefreshed = true;
            refreshColumns();
            if (_space.refresh().regionsMade) // the header may have grown to the font of a title
                _columns.invalidatePlaces();
        }
        bool wantedChanged;
        const wanted = _columns.wanted(wantedChanged);
        if (wantedChanged)
            _cache.setWanted(wanted);
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
        // the titles are a minimum of the widths too (and the border of the column)
        foreach (i, column; _columns.columns)
        {
            const def = &column.def;
            const title = column.measureHeader();
            if (!def.flex && layout.visible(def.id) && title.maxWidth > 0)
                layout.grow(def.id, title.maxWidth + 1);
        }
    }

    /// The place of the columns: made again only when the layout, the width or the columns changed
    ref const(Placements) places()
    {
        return _columns.places(_space.regions.rows.w, _space.regions.rows.x);
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
        auto store = new RowStore(model, layout, portsOf(new Painter));
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

@("RowStore: a change of the layout says the pick is lost when the cells moved, and a restyle forgets the fitted widths")
unittest
{
    auto layout = new ColumnLayout;
    auto store = storeOf(new NumbersModel(10), layout);
    assert(store.layoutChanged(LayoutChange(LayoutChange.Kind.visibility, "n")));
    assert(store.layoutChanged(LayoutChange(LayoutChange.Kind.pin, "n")));
    assert(!store.layoutChanged(LayoutChange(LayoutChange.Kind.width, "n")));
    layout.grow("n", 90);
    store.restyle();
    assert(layout.width("n") == 0 && store.columns.stale, "the fitted width is forgotten");
}
