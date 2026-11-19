//! What a table is given to show: the model of its rows (`TableModel`), the data of a row (`RowData`)
//! and what a model tells when it changes. The table asks, it keeps no rows: the cells are read again
//! by their row. Nothing here knows of logs: a row is cells of text and *extra data*, an opaque pair
//! of a number and a pointer the table carries from the model to the painter without reading it. See docs/stories/painted-table.md.
module ptable.model;

import ptable.column : TableColumn;
import ptable.layout : ColumnDef;

/// A real row of the data, or one the model adds (a separator with a date, a mark of a gap)
enum ItemKind : ubyte
{
    real_,
    virtual_,
}

/// A part of a cell's text with data for the painter (what a search found and by which chip, a link)
struct Fragment
{
    size_t start, end; /// UTF-16 units of the cell's text
    Extra extra;
}

/// What the model attaches to a row, a cell or a column for the painter, and the table never reads:
/// flags, a kind, a level, a pointer to something of the application's own. The two sides agree on what
/// it means; for the table it is only carried.
struct Extra
{
    ulong bits;
    const(void)* pointer;
}

/// The text of a cell and what the model attaches to it
struct CellData
{
    wstring text;
    Extra extra;
}

/// What a model gives for an item
struct RowData
{
    ItemKind kind;
    /// Stable while the data lives: the same row has the same id after the model changed, a table keeps
    /// its selection and its place by it. Virtual items have ids of their own.
    ulong id;
    Extra extra; /// whatever the painter needs to know of the row: its level, a mark of the application
    CellData[] cells; /// in the order of `TableModel.columns`; a virtual item may have fewer
    Fragment[][] fragments; /// by cell, for the cells that have some; may be empty
    size_t span; /// the columns a virtual item's first cell spans, 0: all
}

/// What changed in a model
struct ModelChange
{
    enum Kind : ubyte
    {
        everything, /// start again: the data, the columns, the count; the table is at its top (the columns stay where they are)
        count, /// items were added or removed from `first` on
        rows, /// the items from `first` to `last` (not including) changed, their count did not
        columns, /// the columns changed
    }

    Kind kind;
    size_t first, last;
}

alias ModelListener = void delegate(const ModelChange change);

/// The rows of a table. Called on the thread of the window only.
interface TableModel
{
    /// The items to show: rows and virtual items, all of them, hidden ones are not here (that is the
    /// model's to decide)
    size_t itemCount();

    /// The columns, in their order; the payload column that takes the rest is the `flex` one
    TableColumn[] columns();

    /// Fills `row` with the item `index`; false if there is none (the data changed since the count
    /// was read, the file is lost): the table shows an empty row. The arrays of `row` are the model's
    /// to reuse and the texts in it only have to live until the next call: the table copies what it keeps.
    /// `wanted[i]` says whether the cell of the column `i` is needed (a hidden column is not): the model
    /// need not format the others and leaves them empty; a `wanted` shorter than the columns means yes.
    bool item(size_t index, ref RowData row, const(bool)[] wanted);

    /// The index of the item with `rowId`, false if the model has none
    bool indexOf(ulong rowId, out size_t index);

    /// Calls `listener` when the model changes; the handle is for `unsubscribe`
    size_t subscribe(ModelListener listener);
    void unsubscribe(size_t handle);
}

version (unittest)
{
    /// A model of rows made of the numbers: for the tests of the tables
    class NumbersModel : TableModel
    {
        size_t count;
        double line = 14; /// the height of the text of its columns
        ModelListener[size_t] listeners;
        size_t nextHandle;

        this(size_t count)
        {
            this.count = count;
        }

        size_t itemCount() { return count; }

        TableColumn[] columns()
        {
            import ptable.testing : withBoxes;

            return withBoxes([ColumnDef("n", "N"), ColumnDef("text", "Text", 24, true)], line);
        }

        bool item(size_t index, ref RowData row, const(bool)[] wanted)
        {
            import std.conv : to;

            if (index >= count)
                return false;
            row.id = index;
            row.kind = ItemKind.real_;
            row.cells = [CellData(index.to!wstring), CellData("row "w ~ index.to!wstring)];
            return true;
        }

        bool indexOf(ulong rowId, out size_t index)
        {
            index = cast(size_t) rowId;
            return rowId < count;
        }

        size_t subscribe(ModelListener listener)
        {
            listeners[nextHandle] = listener;
            return nextHandle++;
        }

        void unsubscribe(size_t handle)
        {
            listeners.remove(handle);
        }

        /// Tells the listeners `change`
        void tell(ModelChange change)
        {
            foreach (l; listeners.values)
                l(change);
        }

        /// The model grows: tells the table
        void append(size_t more)
        {
            const first = count;
            count += more;
            foreach (l; listeners.values)
                l(ModelChange(ModelChange.Kind.count, first, count));
        }
    }
}

@("TableModel: a table asks an item by its index and finds it again by its id")
unittest
{
    auto model = new NumbersModel(5);
    RowData row;
    assert(model.item(3, row, null) && row.id == 3 && row.cells[1].text == "row 3");
    assert(!model.item(5, row, null), "no such row");
    size_t index;
    assert(model.indexOf(row.id, index) && index == 3);
    assert(!model.indexOf(99, index));
}

@("TableModel: the listeners hear the model grow until they unsubscribe")
unittest
{
    auto model = new NumbersModel(2);
    ModelChange[] seen;
    const handle = model.subscribe((const ModelChange c) { seen ~= c; });
    model.append(3);
    model.unsubscribe(handle);
    model.append(1);
    assert(seen == [ModelChange(ModelChange.Kind.count, 2, 5)]);
}
