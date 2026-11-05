//! The columns the log tables show for a document: the columns of its format
//! as the layout of the format arranges them (see log_core.column_layout).
//! A row is built with them for every row shown, so they are kept per format
//! and its columns (a variant may have other ones), not arranged again.
module ui.table_columns;

import log_core.column_layout : ColumnState, arrangeColumns;
import log_core.log_format : ColumnInfo;

//! @brief The arranged columns of the formats seen, until the layouts change
final class TableColumns
{
    private static struct Entry
    {
        string formatId;
        const(ColumnInfo)[] columns; // of the format, as the document has them
        const(ColumnInfo)[] arranged;
    }

    private Entry[] _entries;

    //! @returns `columns` of the format `formatId` as `layouts` (by format id)
    //! arranges them; the same array while neither changes
    const(ColumnInfo)[] of(const(ColumnInfo)[] columns, string formatId,
        const(ColumnState[][string]) layouts)
    {
        foreach (ref entry; _entries)
            if (entry.formatId == formatId && entry.columns is columns)
                return entry.arranged;
        const layout = formatId in layouts;
        const arranged = arrangeColumns(columns, layout is null ? null : *layout);
        _entries ~= Entry(formatId, columns, arranged);
        return arranged;
    }

    //! The layouts have changed: every format is arranged again
    void reset()
    {
        _entries = null;
    }
}

version (unittest)
{
    import log_core.log_format : ColumnKind;

    private const(ColumnInfo)[] sampleColumns()
    {
        return [
            ColumnInfo("time", "Time", ColumnKind.Time, 0, 80),
            ColumnInfo("app", "App", ColumnKind.Text, 1, 50),
            ColumnInfo("payload", "Payload", ColumnKind.Payload, -1, 0),
        ];
    }
}

@("TableColumns: arranged by the layout of the format")
unittest
{
    const columns = sampleColumns();
    ColumnState[][string] layouts = ["fmt": [ColumnState("app"), ColumnState("time", false)]];
    auto table = new TableColumns();
    const arranged = table.of(columns, "fmt", layouts);
    assert(arranged.length == 2, "time is hidden");
    assert(arranged[0].id == "app" && arranged[1].id == "payload");
}

@("TableColumns: two formats are kept side by side")
unittest
{
    const columns = sampleColumns();
    ColumnState[][string] layouts = ["a": [ColumnState("app"), ColumnState("time")]];
    auto table = new TableColumns();
    const a = table.of(columns, "a", layouts);
    const b = table.of(columns, "b", layouts);
    assert(a[0].id == "app", "the layout of a");
    assert(b[0].id == "time", "b has no layout: the order of the format");
    assert(table.of(columns, "a", layouts) is a, "a is not arranged again after b");
    assert(table.of(columns, "b", layouts) is b);
}

@("TableColumns: another variant of a format, with other columns, is arranged on its own")
unittest
{
    const columns = sampleColumns();
    const(ColumnInfo)[] other = [columns[1], columns[2]]; // another array
    ColumnState[][string] layouts;
    auto table = new TableColumns();
    const first = table.of(columns, "fmt", layouts);
    const second = table.of(other, "fmt", layouts);
    assert(first.length == 3 && second.length == 2);
    assert(table.of(columns, "fmt", layouts) is first);
}

@("TableColumns: arranged again once the layouts change")
unittest
{
    const columns = sampleColumns();
    ColumnState[][string] layouts;
    auto table = new TableColumns();
    const before = table.of(columns, "fmt", layouts);
    assert(before[0].id == "time");
    layouts["fmt"] = [ColumnState("app"), ColumnState("time")];
    table.reset();
    const after = table.of(columns, "fmt", layouts);
    assert(after[0].id == "app");
}
