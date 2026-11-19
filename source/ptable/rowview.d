//! How a row of the table is seen by the painter, its columns and the hit tests: the context of a row and of a cell (where it
//! is, what it says), what a column is given to draw a cell (`CellInput`: its data, fragments and lines), the text of a cell for
//! the hit tests, and the cells of the row in focus for `texthit`. It reads what the table is made of (the columns, the space, the
//! cache) through `RowEnv` and keeps nothing of its own. See docs/stories/painted-table.md.
module ptable.rowview;

version (unittest) import ptable.testing : withBoxes;
import ptable.column : CellInput;
import ptable.columnset : ColumnSet;

version (unittest)
{

    private immutable RowRanges noRows;
}
import ptable.layout : Placement;
import ptable.painter : CellContext, Painter, RowContext, RowState;
import ptable.ports : Rect;
import ptable.regions : cellIn;
import ptable.rowcache : Entry, RowCache;
import ptable.rowlayout : RowSlot;
import ptable.tablespace : TableSpace;
import ptable.rowranges : RowRanges;
import ptable.selection : Position, TextRange;
import ptable.texthit : CellText, selectionRects, textPositionAt;

import std.algorithm.comparison : max, min;
import std.math : ceil, round;

/// What a row is made of, the surroundings the table gives the view
struct RowEnv
{
    ColumnSet columns;
    const(TableSpace)* space;
}

final class RowView
{
    private RowEnv _env;

    this(RowEnv env)
    {
        _env = env;
    }

    /// The context of the row `index` standing in `slot`; `selected` are the rows picked
    RowContext rowContextAt(Entry* e, size_t index, ref const RowSlot slot, ref const RowRanges selected)
    {
        RowContext row;
        row.index = index;
        row.data = &e.data;
        // the row stands under its margin, if it begins a group
        row.area = Rect(_env.space.regions.rows.x, round(_env.space.regions.rows.y + slot.top + e.margin), _env.space.regions.rows.w,
            slot.height - e.margin);
        row.state = RowState(selected.has(index), (index & 1) != 0, false, false);
        return row;
    }

    /// The context of a cell of an entry in a row: the painter draws its border by it, the hit tests find it by it
    CellContext cellContextAt(Entry* e, ref const RowContext row, size_t defIndex, Rect area)
    {
        const space = _env.space;
        CellContext ctx;
        ctx.row = &row;
        ctx.column = _env.columns.column(defIndex);
        ctx.columnIndex = defIndex;
        if (defIndex < e.data.cells.length)
            ctx.data = &e.data.cells[defIndex];
        ctx.area = area;
        // the part of the cell on the screen: a column of a tall cell draws only the lines that meet it
        const top = max(area.y, space.regions.rows.y), bottom = min(area.bottom, space.regions.rows.bottom);
        ctx.clip = Rect(area.x, top, area.w, max(0.0, bottom - top));
        return ctx;
    }

    /// What the column of the cell `defIndex` of an entry in a row is given to draw it: its data and its fragments
    CellInput cellInputAt(Entry* e, ref const RowContext row, size_t defIndex)
    {
        CellInput cell;
        cell.row = row.index;
        cell.col = cast(uint) defIndex;
        if (defIndex < e.data.cells.length)
            cell.data = &e.data.cells[defIndex];
        if (defIndex < e.data.fragments.length)
            cell.fragments = e.data.fragments[defIndex];
        return cell;
    }

    /// The context of the title of the column placed at `c`, in the header `row`
    CellContext headerCellAt(ref const RowContext row, ref const Placement c)
    {
        const space = _env.space;
        CellContext ctx;
        ctx.row = &row;
        ctx.column = _env.columns.column(c.defIndex);
        ctx.columnIndex = c.defIndex;
        ctx.data = _env.columns.titlePtr(c.defIndex);
        ctx.area = cellIn(c, space.regions.header, 0);
        ctx.clip = ctx.area;
        ctx.isHeader = true; // the column places its title in the area itself
        return ctx;
    }

    /// The text of the cell placed at `c` as the hit tests see it: its input, its area in the row, its column
    CellText cellText(Entry* e, ref const RowContext row, ref const Placement c)
    {
        return CellText(cellInputAt(e, row, c.defIndex), cellIn(c, row.area, _env.space.fonts.geometry.rowBorder), _env.columns.column(c.defIndex));
    }

    /// The selectable cells `cells` of the row `row` of the entry `e`, for the hit tests and the selection. The texts it
    /// gives are valid until the next `cell` of any `FocusedRow` (the wrapped lines are made in a buffer of the view).
    FocusedRow focused(Entry* e, const RowContext row, const(Placement)[] cells)
    {
        return FocusedRow(this, e, row, cells);
    }

    /// The text position in the row `focused` under (`x`, `y`), in the table's coordinates
    bool hit(ref FocusedRow focused, size_t row, double x, double y, out Position at)
    {
        return textPositionAt(focused, row, x, y, at);
    }

    /// The rectangles `range` takes in the row `focused`
    void selectionRects(ref FocusedRow focused, TextRange range, size_t row, scope void delegate(Rect) emit)
    {
        .selectionRects(focused, range, row, emit);
    }
}

/// The selectable cells of one row, as `texthit` asks about them: made on the spot (a struct, no allocation)
struct FocusedRow
{
    private RowView _view;
    private Entry* _entry;
    private RowContext _row;
    private const(Placement)[] _cells;

    size_t length() { return _cells.length; }
    double right(size_t col) { return _cells[col].x + _cells[col].width; }
    CellText cell(size_t col) { return _view.cellText(_entry, _row, _cells[col]); }
}

@("RowView: a row's state follows the selection and its parity; a title is placed in the header")
unittest
{
    import ptable.layout : ColumnDef, ColumnLayout;
    import ptable.rowcache : Entry;

    auto columns = new ColumnSet(new ColumnLayout);
    columns.refresh(withBoxes([ColumnDef("a", "Alpha"), ColumnDef("b", "Beta")]));
    TableSpace space;
    space.restyle(new Painter);
    bool widthChanged;
    space.resize(300, 200, widthChanged);
    space.refresh();
    auto view = new RowView(RowEnv(columns, &space));

    Entry entry;
    RowRanges three;
    three.only(3);
    const slot = RowSlot(3, 40, 20);
    const selected = view.rowContextAt(&entry, 3, slot, three);
    assert(selected.state.selected && (selected.state.odd) && selected.area == Rect(0, 61, 300, 20), "row 3: selected, odd, 21 + 40");
    const other = view.rowContextAt(&entry, 4, slot, three);
    assert(!other.state.selected && !other.state.odd);

    RowContext header;
    header.area = space.regions.header;
    const placed = Placement("b", 100, 60, Placement.init.area, 1);
    const ctx = view.headerCellAt(header, placed);
    assert(ctx.isHeader && ctx.columnIndex == 1 && ctx.data.text == "Beta" && ctx.area == Rect(100, 0, 60, 21), "the place of the column: the line beside it is apart");
}

@("FocusedRow: the cells of a row are asked on the spot, in a struct, by their placement")
unittest
{
    import ptable.layout : ColumnDef, ColumnLayout;
    import ptable.model : CellData;

    auto columns = new ColumnSet(new ColumnLayout);
    columns.refresh(withBoxes([ColumnDef("a", "A"), ColumnDef("b", "B")]));
    TableSpace space;
    space.restyle(new Painter);
    bool widthChanged;
    space.resize(300, 200, widthChanged);
    space.refresh();
    auto view = new RowView(RowEnv(columns, &space));

    Entry entry;
    entry.data.cells = [CellData("one"w), CellData("two"w)];
    const slot = RowSlot(0, 0, 16);
    const row = view.rowContextAt(&entry, 0, slot, noRows);
    const cells = [Placement("a", 10, 50, Placement.init.area, 0), Placement("b", 60, 80, Placement.init.area, 1)];
    auto focused = view.focused(&entry, row, cells);
    assert(focused.length == 2 && focused.right(0) == 60 && focused.right(1) == 140);
    assert(focused.cell(1).text == "two" && focused.cell(0).text == "one");
}

