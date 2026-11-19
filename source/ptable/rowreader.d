//! The accessor of the rows: asks the model for an item and gives it as the table lays it out, in an arena the caller
//! owns: the texts copied (the model reuses its buffers), a cell with a head (`CellPartsExtractor`) as its body and its head
//! apart, the fragments moved into the bodies, the flex cell wrapped. It keeps nothing of the row. See docs/stories/painted-table.md.
module ptable.rowreader;

import ptable.memory : Arena;
import ptable.model;
import ptable.rowentry : Entry;
import ptable.rowspec : RowSpec;
import ptable.rowwrap : RowWrap;

import std.algorithm.comparison : max;

final class RowReader
{
    private TableModel _model;
    private const(RowSpec)* _spec;
    private RowWrap _wrap;
    private RowData _scratch; // what the model fills: its arrays are reused

    size_t fetches; /// items read from the model

    this(TableModel model, const(RowSpec)* spec, RowWrap wrap)
    {
        _model = model;
        _spec = spec;
        _wrap = wrap;
    }

    /// The item `index` as the table lays it out, made in `into` (valid as long as that arena is): its height is that of its
    /// text, without a margin of a group
    Entry* read(ref Arena into, size_t index)
    {
        fetches++;
        auto e = into.make!Entry();
        if (_model.item(index, _scratch, _spec.wanted))
        {
            e.valid = true;
            copyData(*e, into);
        }
        _wrap.wrap(*e, into); // a row the model does not have is as high as the columns are with no data
        return e;
    }

    // The data of the model copied into the arena: the model reuses its buffers
    private void copyData(ref Entry e, ref Arena arena)
    {
        const spec = _spec;
        e.data.kind = _scratch.kind;
        e.data.id = _scratch.id;
        e.data.extra = _scratch.extra;
        e.data.span = _scratch.span;
        auto cells = arena.makeArray!CellData(_scratch.cells.length);
        auto heads = spec.groups.columns.length ? arena.makeArray!(const(wchar)[])(spec.groups.columns.length) : null;
        foreach (i, ref cell; _scratch.cells)
        {
            const full = arena.copy(cell.text);
            const parts = i < spec.columns.length ? spec.columns[i].cellParts : null;
            const body = parts is null ? full : parts.body(full);
            cells[i].text = cast(wstring) body; // the cell shows its body, the head stands above the rows of its group
            cells[i].extra = cell.extra;
            const slot = heads.length ? spec.groups.slotOf(i) : size_t.max;
            if (slot != size_t.max && (i >= spec.wanted.length || spec.wanted[i])) // a hidden column groups nothing
                heads[slot] = parts.head(full);
        }
        e.data.cells = cells;
        e.heads = heads;
        if (_scratch.fragments.length)
        {
            auto fragments = arena.makeArray!(Fragment[])(_scratch.fragments.length);
            foreach (i, f; _scratch.fragments)
            {
                // a fragment of a cell with a head is moved into its body; what lies in the head is dropped
                const start = bodyStart(i);
                auto copy = arena.makeArray!Fragment(f.length);
                size_t kept;
                foreach (fragment; f)
                    if (fragment.end > start)
                        copy[kept++] = Fragment(max(fragment.start, start) - start, fragment.end - start, fragment.extra);
                fragments[i] = copy[0 .. kept];
            }
            e.data.fragments = fragments;
        }
    }

    // Where the body of the model's cell `i` begins in its text: 0 for a cell with no head
    private size_t bodyStart(size_t i) const
    {
        if (i >= _spec.columns.length || i >= _scratch.cells.length)
            return 0;
        const text = _scratch.cells[i].text;
        return _spec.columns[i].cellParts.body(text).ptr - text.ptr;
    }
}

@("RowReader: a row is read into the arena given, the cell with a head as its body, the head apart, the fragment moved, the flex cell wrapped")
unittest
{
    import ptable.layout : ColumnDef;
    import ptable.memory : mallocAllocator;
    import ptable.painter : TableGeometry;
    import ptable.testing : DatedModel;

    auto model = new DatedModel(100, 10);
    model.marked = 23;
    RowSpec spec;
    spec.columns = model.columns();
    spec.flexDef = 1;
    spec.groups.configure(spec.columns);
    spec.flexWidth = 400;
    TableGeometry geometry;
    spec.geometry = geometry;
    auto reader = new RowReader(model, &spec, new RowWrap(&spec));
    auto arena = Arena(mallocAllocator());
    auto e = reader.read(arena, 23);
    assert(e.valid && e.data.cells[0].text == "t23"w && e.heads == ["d2"w], "the body and the head");
    assert(e.data.fragments[0].length == 1 && e.data.fragments[0][0].start == 1, "the fragment moved into the body");
    assert(e.height == 14 + 2, "the flex cell laid out, the height of its text");
    assert(reader.fetches == 1);
    assert(!reader.read(arena, 100).valid, "an item the model does not have");
    arena.release();
}
