//! A table to look at the groups of rows with, not a log: its rows are grouped by two columns, a day (a date heads its
//! rows) and a shift, which change one after the other and now and then in the same row. The log table shows it
//! for `logTableCall("demo")` in place of the log (ui/log_table_behavior, ui/table_script). A `ColumnarModel` of numbers, free of
//! Sciter. See docs/backlog.md (grouping by several columns).
module ui.log_table.demo_model;

import ptable.cellparts : HeadedCellPartsExtractor, firstSpace;
import ptable.columnar : Column, ColumnarModel, RowSource;
import ptable.layout : ColumnDef;
import ptable_text.measurer : TextMeasurer;
import ui.log_table.log_look : LogLook;
import ptable.memory : Buffer;
import ptable.model : ModelListener;
import ui.log_table.log_columns : IndexColumn;
import ui.log_table.text_column : TextColumn;
import ui.row_cells : putNumber, putPadded;

/// The rows of the demo, the days and the shifts
enum size_t demoRows = 10_000, rowsADay = 7, rowsAShift = 4;

// The parts of the cells of the day and of the shift: the date, the shift head their rows
private immutable HeadedCellPartsExtractor headed = new immutable HeadedCellPartsExtractor(&firstSpace);

// The rows are their numbers
private final class DemoRows : RowSource!size_t
{
    size_t count() { return demoRows; }

    bool fetch(size_t index, ref size_t row)
    {
        row = index;
        return index < demoRows;
    }

    ulong idOf(ref const size_t row) { return row; }

    bool indexOf(ulong id, out size_t index)
    {
        index = cast(size_t) id;
        return id < demoRows;
    }

    size_t subscribe(ModelListener listener) { return 0; } // nothing changes
    void unsubscribe(size_t handle) {}
}

/// The columns of the demo: the number, the day ("2026/11/18 08:30"), the shift ("Shift-3 #12"), a text
Column!size_t[] demoColumns(LogLook look = null, TextMeasurer measurer = null)
{
    auto columns = new Column!size_t[4];
    columns[0].column = new IndexColumn(ColumnDef("n", "N"), look, measurer);
    columns[0].text = (ref const size_t row, ref Buffer!wchar into) { putNumber(into, row); };
    columns[1].column = new TextColumn(ColumnDef("day", "Day"), look, measurer).withParts(headed);
    columns[1].text = (ref const size_t row, ref Buffer!wchar into) {
        const day = row / rowsADay;
        into.put("2026/"w);
        putPadded(into, 1 + day / 28 % 12, 2);
        into.put('/');
        putPadded(into, 1 + day % 28, 2);
        into.put(' ');
        putPadded(into, row % rowsADay * 3, 2);
        into.put(":00"w);
    };
    columns[2].column = new TextColumn(ColumnDef("shift", "Shift"), look, measurer).withParts(headed);
    columns[2].text = (ref const size_t row, ref Buffer!wchar into) {
        into.put("Shift-"w);
        putNumber(into, row / rowsAShift);
        into.put(" #"w);
        putNumber(into, row % rowsAShift + 1);
    };
    columns[3].column = new TextColumn(ColumnDef("text", "Text", 200, true), look, measurer);
    columns[3].text = (ref const size_t row, ref Buffer!wchar into) {
        into.put("a row of the demo, the day and the shift above it are heads of their groups"w);
    };
    return columns;
}

/// The model of the demo table
ColumnarModel!size_t demoTableModel(LogLook look = null, TextMeasurer measurer = null)
{
    auto columns = demoColumns(look, measurer);
    return new ColumnarModel!size_t(new DemoRows, () => columns);
}

@("demoTableModel: the day and the shift head their rows, they change one after the other and at times in the same row")
unittest
{
    import ptable.model : RowData;

    auto model = demoTableModel();
    assert(model.itemCount == demoRows && model.columns.length == 4);
    const defs = model.columns;
    assert(!defs[0].cellParts.hasHead && defs[1].cellParts.hasHead && defs[2].cellParts.hasHead && !defs[3].cellParts.hasHead);
    RowData row;
    wstring head(size_t index, size_t column) // a copy: the model reuses its buffer
    {
        model.item(index, row, null);
        return defs[column].cellParts.head(row.cells[column].text).idup;
    }

    assert(head(0, 1) == "2026/01/01" && head(6, 1) == "2026/01/01" && head(7, 1) == "2026/01/02", "a day of 7 rows");
    assert(head(3, 2) == "Shift-0" && head(4, 2) == "Shift-1", "a shift of 4 rows");
    assert(head(27, 1) != head(28, 1) && head(27, 2) != head(28, 2), "both change at row 28");
    model.item(5, row, null);
    assert(defs[1].cellParts.body(row.cells[1].text) == "15:00" && defs[2].cellParts.body(row.cells[2].text) == "#2", "the bodies");
}
