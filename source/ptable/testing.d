//! What the tests of the package share: a column of boxes with fixed sizes (`BoxColumn`), so a test of a unit does not make its own,
//! the format of a copy, and models whose rows are grouped by day (`DatedModel`, `TwoHeadsModel`). Only in a unit test build.
module ptable.testing;

version (unittest)
{
    import ptable.ports : Rect;
    import ptable.cellparts : HeadedCellPartsExtractor, firstSpace;
    import ptable.column : CellInput, CellLayout, GroupInput, Measured, TableColumn;
    import ptable.painter : Painter;
    import ptable.selection : CopyFormat;
    import ptable.tableports : TablePorts;
    import ptable.layout : ColumnDef;
    import ptable.memory : Arena;
    import ptable.model;

    /// A column of fixed boxes for the tests of the package, which knows nothing of text: a cell is `glyph` dips wide for each unit of its text
    /// between `pad` dips on both sides and `line` + 2 high (the room 1 above and under it), its title and group head likewise but 3 above and
    /// under; it never breaks a cell into lines; a caret is a unit of the text, a part is one rectangle, it draws nothing
    class BoxColumn : TableColumn
    {
        double line = 14; /// the height of its text; a test makes it taller to make a row taller
        enum double glyph = 10, pad = 3;
        int measures, layouts; /// how many times a cell was measured, laid out
        bool wrapping = true; /// whether it says its cells break into lines (the flex column that does, does not grow to its texts)

        this(ColumnDef def)
        {
            super(def);
        }

        override Measured measureHeader()
        {
            import std.conv : to;

            Measured m;
            m.maxWidth = m.minWidth = pad + def.title.to!wstring.length * glyph + pad;
            m.height = line + 2 * 3;
            return m;
        }

        override Measured measureGroup(in GroupInput group)
        {
            Measured m;
            m.maxWidth = m.minWidth = pad + group.head.length * glyph + pad;
            m.height = line + 2 * 3;
            return m;
        }

        override Measured measure(ref const CellInput cell, double width, bool widths)
        {
            ++measures;
            Measured m;
            m.height = line + 2;
            if (widths && cell.data !is null)
                m.maxWidth = m.minWidth = pad + cell.data.text.length * glyph + pad;
            return m;
        }

        /// A cell of a flex column is as high as any other
        override CellLayout layout(ref const CellInput cell, double width, ref Arena arena)
        {
            ++layouts;
            CellLayout done;
            done.height = line + 2;
            return done;
        }

        override bool wraps() const
        {
            return def.flex && wrapping;
        }

        override size_t hitTest(ref const CellInput cell, Rect area, Rect view, double x, double y)
        {
            import std.algorithm.comparison : max, min;
            import std.math : round;

            const length = cell.data !is null ? cell.data.text.length : 0;
            return cast(size_t) max(0.0, min(cast(double) length, round((x - area.x - pad) / glyph)));
        }

        override void rects(ref const CellInput cell, Rect area, Rect view, size_t from, size_t to, scope void delegate(Rect) emit)
        {
            emit(Rect(area.x + pad + from * glyph, area.y, (to - from) * glyph, area.h));
        }
    }

    /// One `BoxColumn` for the tests that need a column and no def of their own
    TableColumn plainText()
    {
        static TableColumn column;
        if (column is null)
            column = new BoxColumn(ColumnDef("plain", "Plain"));
        return column;
    }

    /// A `BoxColumn` of each of `defs`, in their order, `line` high
    TableColumn[] withBoxes(const(ColumnDef)[] defs, double line = 14)
    {
        auto columns = new TableColumn[defs.length];
        foreach (i, ref def; defs)
        {
            auto column = new BoxColumn(def);
            column.line = line;
            columns[i] = column;
        }
        return columns;
    }

    /// The format of a copy in the tests: tabs between the cells, new lines between the rows, a million characters at most
    enum CopyFormat tabbed = CopyFormat("\t"w, "\n"w, 1_000_000);

    /// The same, at most `limit` characters
    CopyFormat tabbedUpTo(size_t limit)
    {
        return CopyFormat("\t"w, "\n"w, limit);
    }

    /// The ports of a table of a test: `painter` and copies `tabbed`
    TablePorts portsOf(Painter painter)
    {
        auto ports = TablePorts(painter);
        ports.copyFormat = tabbed;
        return ports;
    }

    /// Rows with a time column whose head is the day ("d<day> t<index>", `perDay` rows a day) and a text column; counts
    /// the reads of each item; the time cell of item `marked` has a fragment over its body
    final class DatedModel : TableModel
    {
        size_t count, perDay;
        wstring dayPrefix = "d"; /// the head is the prefix and the day
        size_t[size_t] reads;
        size_t marked = size_t.max;
        ModelListener[size_t] listeners;
        private TableColumn[] _columns;
        private Fragment[][] _fragments;

        this(size_t count, size_t perDay)
        {
            this.count = count;
            this.perDay = perDay;
            _columns = withBoxes([ColumnDef("time", "Time"), ColumnDef("text", "Text", 24, true)]);
            _columns[0].parts = new immutable HeadedCellPartsExtractor(&firstSpace);
        }

        size_t itemCount() { return count; }
        TableColumn[] columns() { return _columns; }

        bool item(size_t index, ref RowData row, const(bool)[] wanted)
        {
            import std.conv : to;

            if (index >= count)
                return false;
            reads[index] = reads.get(index, 0) + 1;
            row.id = index;
            row.kind = ItemKind.real_;
            const time = wanted.length == 0 || wanted[0] ? dayPrefix ~ (index / perDay).to!wstring ~ " t"w ~ index.to!wstring : ""w;
            const text = wanted.length < 2 || wanted[1] ? "row "w ~ index.to!wstring : ""w;
            row.cells = [CellData(time), CellData(text)];
            if (index == marked)
            {
                const body = time.length - 2; // the fragment covers "t" and the first digit
                _fragments = [[Fragment(body, body + 2)], []];
                row.fragments = _fragments;
            }
            else
                row.fragments = null;
            return true;
        }

        bool indexOf(ulong rowId, out size_t index)
        {
            index = cast(size_t) rowId;
            return rowId < count;
        }

        size_t subscribe(ModelListener listener)
        {
            listeners[listeners.length] = listener;
            return listeners.length - 1;
        }

        void unsubscribe(size_t handle) { listeners.remove(handle); }
    }

    /// Rows grouped by two columns: "day" (head "D<index / 5>"), "shift" (head "S<index / 3>": now and then both change in
    /// one row) and a text column
    final class TwoHeadsModel : TableModel
    {
        size_t count;
        private TableColumn[] _columns;

        this(size_t count)
        {
            this.count = count;
            _columns = withBoxes([ColumnDef("day", "Day"), ColumnDef("shift", "Shift"), ColumnDef("text", "Text", 24, true)]);
            _columns[0].parts = new immutable HeadedCellPartsExtractor(&firstSpace);
            _columns[1].parts = _columns[0].parts;
        }

        size_t itemCount() { return count; }
        TableColumn[] columns() { return _columns; }

        bool item(size_t index, ref RowData row, const(bool)[] wanted)
        {
            import std.conv : to;

            if (index >= count)
                return false;
            row.id = index;
            row.kind = ItemKind.real_;
            row.cells = [CellData("D"w ~ (index / 5).to!wstring ~ " d"w ~ index.to!wstring),
                CellData("S"w ~ (index / 3).to!wstring ~ " s"w ~ index.to!wstring), CellData("row "w ~ index.to!wstring)];
            row.fragments = null;
            return true;
        }

        bool indexOf(ulong rowId, out size_t index)
        {
            index = cast(size_t) rowId;
            return rowId < count;
        }

        size_t subscribe(ModelListener listener) { return 0; }
        void unsubscribe(size_t handle) {}
    }
}
