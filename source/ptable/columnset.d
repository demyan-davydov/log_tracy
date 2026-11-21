//! The columns a table shows now: the column objects the model gave, their titles, which one is the flex
//! one, which are wanted (visible), and what of their placements (made by the column host for all its
//! tables) a cell is found by. Free of the table: what the table does with them (the row cache, the
//! painter) is its own.
module ptable.columnset;

version (unittest) import ptable.testing : withBoxes;
import ptable.column : TableColumn;
import ptable.layout : ColumnDef, ColumnLayout, Placement, Placements;
import ptable.model : CellData;

import std.conv : to;

final class ColumnSet
{
    private ColumnLayout _layout;
    private TableColumn[] _columns;
    private CellData[] _titles;
    private size_t[string] _defIndex;
    private size_t _flexDef = size_t.max;
    private bool[] _wanted;
    private bool _wantedDirty = true;
    private bool _stale = true; // the model's columns are to be read again
    private Placement[] _selectable;

    this(ColumnLayout layout)
    {
        _layout = layout;
    }

    /// The model's columns (or the fonts their titles are measured in) changed: the next `refresh` is due
    void markStale()
    {
        _stale = true;
    }

    /// Whether `refresh` is due
    bool stale() const
    {
        return _stale;
    }

    /// The columns the model gives now: the others are forgotten
    void refresh(TableColumn[] columns)
    {
        _stale = false;
        _columns = columns.dup;
        _titles.length = _columns.length;
        _defIndex = null;
        _flexDef = size_t.max;
        foreach (i, column; _columns)
        {
            const def = &column.def;
            _defIndex[def.id] = i;
            _titles[i] = CellData(def.title.to!wstring);
            if (def.flex)
                _flexDef = i;
        }
        _wantedDirty = true;
    }

    /// The columns, in the order of the model
    TableColumn[] columns() { return _columns; }
    size_t length() const { return _columns.length; }

    /// The id of the column `defIndex` of the model, "" if there is none
    string idOf(size_t defIndex) const
    {
        return defIndex < _columns.length ? _columns[defIndex].def.id : "";
    }
    ref const(ColumnDef) def(size_t index) const { return _columns[index].def; }
    TableColumn column(size_t index) { return _columns[index]; }
    ref const(CellData) title(size_t index) const { return _titles[index]; }
    const(ColumnDef)* defPtr(size_t index) const { return &_columns[index].def; }
    const(CellData)* titlePtr(size_t index) const { return &_titles[index]; }

    /// The index of the column `id` among the columns of the model
    size_t indexOf(string id) const
    {
        return _defIndex[id];
    }

    bool hasFlex() const { return _flexDef != size_t.max; }
    size_t flexIndex() const { return _flexDef; }

    /// The mask of the columns the model need format (the visible ones); `changed` says it was made again
    const(bool)[] wanted(out bool changed)
    {
        changed = _wantedDirty;
        if (_wantedDirty)
        {
            _wantedDirty = false;
            _wanted.length = _columns.length;
            foreach (i, column; _columns)
                _wanted[i] = _layout.visible(column.def.id);
        }
        return _wanted;
    }

    /// Visibility changed in the layout: the mask is made again
    void visibilityChanged()
    {
        _wantedDirty = true;
    }

    /// The width the flex column has in `p`, 0 with none
    double flexWidth(ref const Placements p) const
    {
        if (!hasFlex)
            return 0;
        foreach (c; p.columns)
            if (c.id == _columns[_flexDef].def.id)
                return c.width;
        return 0;
    }

    /// The column of the model under x: left of the columns the first, right of them the last
    size_t columnAt(ref const Placements p, double x) const
    {
        if (p.columns.length == 0)
            return 0;
        foreach (c; p.columns)
            if (x < c.x + c.width + c.lineAfter) // the line right of a cell is hit as the cell
                return c.defIndex;
        return p.columns[$ - 1].defIndex;
    }

    /// The cells whose text can be selected, in the order they stand on the screen (in a buffer that is reused)
    const(Placement)[] selectable(ref const Placements p)
    {
        _selectable.length = 0;
        assumeSafeAppend(_selectable);
        foreach (c; p.columns)
            if (_columns[c.defIndex].def.selectable)
                _selectable ~= c;
        return _selectable;
    }
}

version (unittest)
{
    import ptable.layout : placeColumns;

    private TableColumn[] sample()
    {
        auto mark = ColumnDef("mark", "M", 20);
        mark.selectable = false;
        return withBoxes([mark, ColumnDef("a", "Alpha", 40), ColumnDef("text", "Text", 50, true)]);
    }
}

@("ColumnSet: the flex column and the index of a column are found by the definitions")
unittest
{
    auto set = new ColumnSet(new ColumnLayout);
    assert(!set.hasFlex);
    set.refresh(sample());
    assert(set.length == 3 && set.hasFlex && set.flexIndex == 2);
    assert(set.indexOf("a") == 1);
    assert(set.title(1).text == "Alpha");
}

@("ColumnSet: the model is asked for the visible columns only; the selectable ones skip the marks")
unittest
{
    auto layout = new ColumnLayout;
    auto set = new ColumnSet(layout);
    set.refresh(sample());
    bool changed;
    assert(set.wanted(changed) == [true, true, true] && changed);
    set.wanted(changed);
    assert(!changed);
    layout.setVisible("a", false);
    set.visibilityChanged();
    assert(set.wanted(changed) == [true, false, true] && changed);
    layout.setVisible("a", true);
    set.visibilityChanged();
    const p = placeColumns(set.columns, layout, 300, 0, [20, 40, 50]); // the least widths of the columns as a whole
    assert(set.selectable(p).length == 2 && set.selectable(p)[0].id == "a");
    assert(set.columnAt(p, 5) == 0 && set.columnAt(p, 10_000) == 2);
    assert(set.idOf(1) == "a" && set.idOf(2) == "text" && set.idOf(3) == "", "no column: no id");
}

@("ColumnSet: it is stale until refreshed, and again when marked")
unittest
{
    auto set = new ColumnSet(new ColumnLayout);
    assert(set.stale, "nothing read yet");
    set.refresh(sample());
    assert(!set.stale);
    set.markStale();
    assert(set.stale);
    set.refresh(sample());
    assert(!set.stale);
}

@("ColumnSet: a point on the line right of a cell hits the cell")
unittest
{
    import ptable.layout : ColumnLayout, placeColumns;

    auto layout = new ColumnLayout;
    auto set = new ColumnSet(layout);
    set.refresh(sample());
    const p = placeColumns(set.columns, layout, 300, 0, [20, 40, 50], 2);
    assert(set.columnAt(p, 20.5) == 0 && set.columnAt(p, 21.9) == 0, "the line right of the first cell is of the first column");
    assert(set.columnAt(p, 22) == 1, "the next cell begins after the line");
}
