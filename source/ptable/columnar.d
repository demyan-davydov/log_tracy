//! The second layer of the package: a `TableModel` made of rows of one type and columns that know how to
//! write their cell out of such a row (`Column!Row`), so a host describes its data by a source of rows and
//! a list of columns instead of writing a model. An extractor writes into a buffer the model reuses, and
//! only for the columns the table wants. The core knows nothing of this layer: it is one more `TableModel`.
module ptable.columnar;

version (unittest) import ptable.testing : BoxColumn;
import ptable.column : TableColumn;
import ptable.layout : ColumnDef;
import ptable.listeners : Listeners;
import ptable.memory : Buffer, mallocAllocator;
import ptable.model;

import std.experimental.allocator : RCIAllocator;

/// A column of rows of type `Row`: the column of the table (it lays out and draws the cell) and how its cell is made of a row
struct Column(Row)
{
    TableColumn column;
    /// Appends the text of the cell of `row` to `into`; called for the columns the table wants only
    void delegate(ref const Row row, ref Buffer!wchar into) text;
    /// What the painter is to know of the cell (the core never reads it); unset: nothing
    Extra delegate(ref const Row row) extra;
    /// Appends the parts of the text of the cell the painter marks (a search's matches) to `into`, in the units of its text;
    /// called for the columns the table wants only; unset: none
    void delegate(ref const Row row, ref Buffer!Fragment into) fragments;
}

/// Where the rows come from: a view of a document, a list. Called on the thread of the window only.
interface RowSource(Row)
{
    size_t count();

    /// Fills `row` with the item `index`; false if there is none (the data changed meanwhile)
    bool fetch(size_t index, ref Row row);

    /// The stable id of a row (the table finds its selection and its place by it)
    ulong idOf(ref const Row row);

    bool indexOf(ulong id, out size_t index);

    /// What happened to the rows: as for a `TableModel`
    size_t subscribe(ModelListener listener);
    void unsubscribe(size_t handle);
}

/// A model of the rows of `source` in the columns `columns` gives. `columns` is asked every time the table
/// asks for them and must give the same array while they have not changed (a change is told by the source with
/// `ModelChange.columns`).
final class ColumnarModel(Row) : TableModel
{
    private RowSource!Row _source;
    private Column!Row[] delegate() _columns;
    private Extra delegate(ref const Row row) _rowExtra;
    private Row _row;
    private Buffer!wchar _chars;
    private size_t[2][] _spans;
    private Buffer!Fragment _fragments; // of the cells of a row, like `_chars`
    private size_t[2][] _fragmentSpans;
    private const(Column!Row)* _madeOf; // the array `_tableColumns` was made of
    private size_t _madeLength = size_t.max;
    private TableColumn[] _tableColumns;
    private size_t _sourceHandle;
    private Listeners!ModelChange _listeners;

    this(RowSource!Row source, Column!Row[] delegate() columns, Extra delegate(ref const Row row) rowExtra = null,
        RCIAllocator memory = mallocAllocator())
    {
        _source = source;
        _columns = columns;
        _rowExtra = rowExtra;
        _chars = Buffer!wchar(memory);
        _fragments = Buffer!Fragment(memory);
        _sourceHandle = source.subscribe((const ModelChange change) { changed(change); });
    }

    /// The table is gone: the model stops hearing the source
    void dispose()
    {
        _source.unsubscribe(_sourceHandle);
        _listeners.clear();
    }

    size_t itemCount()
    {
        return _source.count();
    }

    TableColumn[] columns()
    {
        auto now = _columns();
        if (now.ptr !is _madeOf || now.length != _madeLength)
        {
            _madeOf = now.ptr;
            _madeLength = now.length;
            _tableColumns.length = now.length;
            foreach (i, ref column; now)
                _tableColumns[i] = column.column;
        }
        return _tableColumns;
    }

    bool item(size_t index, ref RowData row, const(bool)[] wanted)
    {
        const columns = _columns();
        if (!_source.fetch(index, _row))
            return false;
        row.kind = ItemKind.real_;
        row.id = _source.idOf(_row);
        row.extra = _rowExtra !is null ? _rowExtra(_row) : Extra.init;
        _chars.clear();
        _spans.length = columns.length;
        foreach (i, ref column; columns)
        {
            const from = _chars.length;
            if ((i >= wanted.length || wanted[i]) && column.text !is null)
                column.text(_row, _chars);
            _spans[i] = [from, _chars.length];
        }
        row.cells.length = columns.length;
        const chars = _chars[]; // the buffer has stopped growing: slices are safe now
        foreach (i, ref column; columns)
            row.cells[i] = CellData(cast(wstring) chars[_spans[i][0] .. _spans[i][1]],
                column.extra !is null ? column.extra(_row) : Extra.init);
        fillFragments(row, columns, wanted);
        return true;
    }

    // The fragments of the wanted cells that have a column giving them; none at all leaves the row without the array
    private void fillFragments(ref RowData row, const(Column!Row)[] columns, const(bool)[] wanted)
    {
        _fragments.clear();
        _fragmentSpans.length = columns.length;
        bool any;
        foreach (i, ref column; columns)
        {
            const from = _fragments.length;
            if ((i >= wanted.length || wanted[i]) && column.fragments !is null)
            {
                column.fragments(_row, _fragments);
                any = any || _fragments.length > from;
            }
            _fragmentSpans[i] = [from, _fragments.length];
        }
        if (!any)
        {
            row.fragments.length = 0;
            return;
        }
        row.fragments.length = columns.length;
        const parts = _fragments[]; // the buffer has stopped growing: slices are safe now
        foreach (i; 0 .. columns.length)
            row.fragments[i] = cast(Fragment[]) parts[_fragmentSpans[i][0] .. _fragmentSpans[i][1]];
    }

    bool indexOf(ulong rowId, out size_t position)
    {
        return _source.indexOf(rowId, position);
    }

    size_t subscribe(ModelListener listener)
    {
        return _listeners.add(listener);
    }

    void unsubscribe(size_t handle)
    {
        _listeners.remove(handle);
    }

    private void changed(const ModelChange change)
    {
        _listeners.tell(change);
    }
}

version (unittest)
{
    private struct Person
    {
        int age;
        string name;
    }

    private final class People : RowSource!Person
    {
        Person[] people;
        ModelListener[size_t] listeners;
        size_t fetched;

        size_t count() { return people.length; }

        bool fetch(size_t index, ref Person row)
        {
            ++fetched;
            if (index >= people.length)
                return false;
            row = people[index];
            return true;
        }

        ulong idOf(ref const Person row) { return row.age; }

        bool indexOf(ulong id, out size_t index)
        {
            foreach (i, ref p; people)
                if (p.age == id)
                {
                    index = i;
                    return true;
                }
            return false;
        }

        size_t subscribe(ModelListener l)
        {
            listeners[listeners.length] = l;
            return listeners.length - 1;
        }

        void unsubscribe(size_t handle) { listeners.remove(handle); }

        void tell(ModelChange c)
        {
            foreach (l; listeners.values)
                l(c);
        }
    }

    private size_t writes; // the cells the extractors wrote

    private Column!Person[] personColumns()
    {
        static Column!Person[] columns;
        if (columns.length == 0)
        {
            columns = [
                Column!Person(new BoxColumn(ColumnDef("age", "Age")), (ref const Person p, ref Buffer!wchar b) { ++writes; b.put(p.age < 100 ? "young"w : "old"w); },
                    (ref const Person p) => Extra(p.age)),
                Column!Person(new BoxColumn(ColumnDef("name", "Name", 40, true)), (ref const Person p, ref Buffer!wchar b) { ++writes; foreach (c; p.name) b.put(cast(wchar) c); }),
            ];
        }
        return columns;
    }
}

@("ColumnarModel: the cells are written by the columns into a reused buffer, with the extra data they give")
unittest
{
    auto people = new People;
    people.people = [Person(30, "Ann"), Person(150, "Bo")];
    auto model = new ColumnarModel!Person(people, () => personColumns(), (ref const Person p) => Extra(p.age + 1));
    assert(model.itemCount() == 2 && model.columns().length == 2 && model.columns()[1].def.flex);
    RowData row;
    assert(model.item(1, row, null));
    assert(row.id == 150 && row.extra.bits == 151);
    assert(row.cells[0].text == "old" && row.cells[0].extra.bits == 150 && row.cells[1].text == "Bo");
    assert(model.item(0, row, null) && row.cells[0].text == "young" && row.cells[1].text == "Ann");
    assert(!model.item(5, row, null), "no such row");
    size_t at;
    assert(model.indexOf(150, at) && at == 1);
}

@("ColumnarModel: only the wanted columns are written; the others are empty")
unittest
{
    auto people = new People;
    people.people = [Person(30, "Ann")];
    auto model = new ColumnarModel!Person(people, () => personColumns());
    RowData row;
    writes = 0;
    assert(model.item(0, row, [false, true]));
    assert(writes == 1 && row.cells[0].text.length == 0 && row.cells[1].text == "Ann");
}

@("ColumnarModel: a column gives the fragments of its cell; a column without them, or one not wanted, has none")
unittest
{
    static size_t asked;
    auto people = new People;
    people.people = [Person(30, "Ann")];
    Column!Person[] columns = [
        Column!Person(new BoxColumn(ColumnDef("age", "Age")), (ref const Person p, ref Buffer!wchar b) { b.put("young"w); }),
        Column!Person(new BoxColumn(ColumnDef("name", "Name", 40, true)), (ref const Person p, ref Buffer!wchar b) { b.put("Ann"w); },
            null, (ref const Person p, ref Buffer!Fragment into) {
                ++asked;
                into.put(Fragment(0, 1, Extra(7)));
                into.put(Fragment(2, 3, Extra(8)));
            }),
    ];
    auto model = new ColumnarModel!Person(people, () => columns);
    RowData row;
    asked = 0;
    assert(model.item(0, row, null));
    assert(row.fragments.length == 2 && row.fragments[0].length == 0, "none for a column without fragments");
    assert(row.fragments[1] == [Fragment(0, 1, Extra(7)), Fragment(2, 3, Extra(8))]);
    assert(model.item(0, row, null) && row.fragments[1].length == 2, "a second read starts the buffer again");
    asked = 0;
    assert(model.item(0, row, [true, false]));
    assert(asked == 0 && row.fragments.length == 0, "a column not wanted is not asked");
}

@("ColumnarModel: it passes on what the source tells and stops when it is disposed")
unittest
{
    auto people = new People;
    auto model = new ColumnarModel!Person(people, () => personColumns());
    ModelChange[] seen;
    model.subscribe((const ModelChange c) { seen ~= c; });
    people.tell(ModelChange(ModelChange.Kind.count, 3, 9));
    assert(seen == [ModelChange(ModelChange.Kind.count, 3, 9)]);
    model.dispose();
    people.tell(ModelChange(ModelChange.Kind.everything));
    assert(seen.length == 1);
}

@("ColumnarModel: a row that is read again after the buffer grew keeps its texts")
unittest
{
    auto people = new People;
    string long_;
    foreach (i; 0 .. 500)
        long_ ~= "abcdefghij";
    people.people = [Person(1, long_)];
    auto model = new ColumnarModel!Person(people, () => personColumns());
    RowData row;
    assert(model.item(0, row, null));
    assert(row.cells[0].text == "young" && row.cells[1].text.length == 5000, "the early cell is not left on a freed block");
}
