//! The rows and the columns of the log tables as the script gets them, free
//! of Sciter: what each cell of a row holds (see rowLayout in
//! resources/cell-format.js), written through a cell writer the window makes
//! of Sciter values, and the columns as JSON. The values of the columns are read
//! by log_core/column_values.
module ui.table_rows;

import log_core.column_values : writeColumnValues;
import log_core.log_format : ColumnInfo, ColumnKind;
import log_core.log_level : LogLevel;
import log_core.log_message : LogMessage, TimeKind;
import log_core.rule_filter : RuleId;
import log_core.search_filter : MatchRange;

import std.json : JSONValue;

/// The cells of a row before those of the columns: anchored, rule id, view
/// index, message index, level, found
enum fixedCells = 6;

/// Whether W can write the cells of a row: W.nothing(cell), W.boolean(cell,
/// bool), W.integer(cell, int), W.number(cell, double), W.text(cell, wchar[] or
/// char[]: a text made here, e.g. hex, is UTF-8 and goes as it is),
/// W.time(cell, microseconds, TimeKind), W.matches(cell, MatchRange[])
enum isCellWriter(W) = __traits(compiles, (ref W w, const(wchar)[] s, const(char)[] n, const(MatchRange)[] m) {
    w.nothing(0);
    w.boolean(0, true);
    w.integer(0, 0);
    w.number(0, 0.0);
    w.text(0, s);
    w.text(0, n);
    w.time(0, 0.0, TimeKind.None);
    w.matches(0, m);
});

/// The number of cells of a row with `columnCount` columns: the fixed ones,
/// the columns, what the chips found
size_t rowLength(size_t columnCount) pure nothrow @nogc
{
    return fixedCells + columnCount + 1;
}

/// Writes a row of the log table: anchored, rule id, view index, message index,
/// level, found, then a cell per column. The level colors the cells of the columns
/// that ask for it (ColumnInfo.byLevel, done by the script).
/// @param index - the position of the row in its view
/// @param found - the current search found the record (DocumentItem.found)
/// @param rule - the first filter rule with a color the record matches (the
/// script shows it by its color); none is written as nothing
/// @param matches - after the cells comes what the chips of the search found in
/// the payload, [[start, end, chip]] (see MatchRange); none is written as nothing
void writeRow(W)(ref W writer, int index, ref const(LogMessage!wchar) msg, bool anchored, bool found, size_t messageIndex,
    const(ColumnInfo)[] columns, RuleId rule, const(MatchRange)[] matches)
    if (isCellWriter!W)
{
    writer.boolean(0, anchored);
    if (rule.isValid())
        writer.number(1, cast(double) rule.toInt());
    else
        writer.nothing(1);
    writer.integer(2, index);
    writer.number(3, cast(double) messageIndex);
    writer.integer(4, cast(int) msg.level);
    writer.boolean(5, found);

    auto values = ColumnCells!W(&writer);
    writeColumnValues(values, msg, columns);
    if (matches.length)
        writer.matches(fixedCells + columns.length, matches);
    else
        writer.nothing(fixedCells + columns.length); // most rows: the search didn't find them
}

//! The values of the columns (log_core/column_values) as the cells after the fixed ones
private struct ColumnCells(W)
{
    W* writer;

    void nothing(size_t column) { writer.nothing(fixedCells + column); }

    //! [microseconds, TimeKind]: microseconds are exact in a double (a script number) for
    //! 285 years
    void time(size_t column, long ns, TimeKind kind)
    {
        writer.time(fixedCells + column, cast(double)(ns / 1000), kind);
    }

    void level(size_t column, LogLevel level) { writer.integer(fixedCells + column, cast(int) level); }
    void text(size_t column, const(wchar)[] value) { writer.text(fixedCells + column, value); }
    void hex(size_t column, const(char)[] digits) { writer.text(fixedCells + column, digits); }
    void number(size_t column, long value) { writer.number(fixedCells + column, cast(double) value); }
}

//! @brief The columns of a log of the format `formatId` (FormatInfo.id) as
//! JSON for the script (see virtual-dlt-view.js): the style of the table
//! finds a column by the ids of its format and of the column
string columnsJson(const(ColumnInfo)[] columns, string formatId)
{
    import std.conv : to;

    JSONValue[] result;
    foreach (ref column; columns)
    {
        JSONValue c = [
            "id": JSONValue(column.id),
            "format": JSONValue(formatId),
            "title": JSONValue(column.title),
            "kind": JSONValue(column.kind.to!string),
        ];
        if (column.kind == ColumnKind.Time)
            c["timeKind"] = JSONValue(column.timeKind.to!string);
        if (column.kind == ColumnKind.Duration)
            c["unitsPerSecond"] = JSONValue(column.unitsPerSecond);
        if (column.kind == ColumnKind.Enum)
            c["labels"] = JSONValue(column.labels);
        if (column.byLevel)
            c["byLevel"] = JSONValue(true);
        result ~= c;
    }
    return JSONValue(result).toString();
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

version (unittest)
{
    import std.conv : to;

    /// Writes the cells as text: "-" nothing, "b:true", "i:3", "n:2.5", "t:abc",
    /// "time:1500:Absolute", "m:[start-end/chip...]"
    private struct TextCells
    {
        string[] cells;

        this(size_t length)
        {
            cells = new string[length];
        }

        void nothing(size_t cell) { cells[cell] = "-"; }
        void boolean(size_t cell, bool value) { cells[cell] = "b:" ~ value.to!string; }
        void integer(size_t cell, int value) { cells[cell] = "i:" ~ value.to!string; }
        void number(size_t cell, double value) { cells[cell] = "n:" ~ value.to!string; }
        void text(size_t cell, const(wchar)[] value) { cells[cell] = "t:" ~ value.to!string; }
        void text(size_t cell, const(char)[] value) { cells[cell] = "s:" ~ value.idup; }
        void time(size_t cell, double microseconds, TimeKind kind)
        {
            cells[cell] = "time:" ~ (cast(long) microseconds).to!string ~ ":" ~ kind.to!string;
        }

        void matches(size_t cell, const(MatchRange)[] ranges)
        {
            string text = "m:";
            foreach (r; ranges)
                text ~= r.start.to!string ~ "-" ~ r.end.to!string ~ "/" ~ r.chip.to!string ~ " ";
            cells[cell] = text;
        }
    }

    static assert(isCellWriter!TextCells);

    private const ColumnInfo[] testColumns = [
        ColumnInfo("time", "Time", ColumnKind.Time),
        ColumnInfo("level", "Level", ColumnKind.Level),
        ColumnInfo("tag", "Tag", ColumnKind.Text, 0),
        ColumnInfo("pid", "Pid", ColumnKind.Integer, 1),
        ColumnInfo("id", "Id", ColumnKind.Hex, 2),
        ColumnInfo("payload", "Payload", ColumnKind.Payload),
    ];

    /// A record with a time, a level, the fields tag, pid and id, and a payload
    private void fillRecord(ref LogMessage!wchar msg, bool withTime = true)
    {
        msg.beginRecord();
        if (withTime)
        {
            msg.timeNs = 1_500_000;
            msg.timeKind = TimeKind.Absolute;
        }
        msg.level = LogLevel.Warn;
        msg.setText(0, "TAG");
        msg.setNumber(1, 42);
        msg.setNumber(2, -1);
        auto builder = msg.payloadBuilder();
        builder.appendUtf8("hello");
    }
}

@("writeRow: the fixed cells, then a cell per column as its kind shows it")
unittest
{
    LogMessage!wchar msg;
    fillRecord(msg);
    auto cells = TextCells(rowLength(testColumns.length));
    writeRow(cells, 7, msg, true, false, 1234, testColumns, RuleId(3), null);
    assert(cells.cells == [
        "b:true", "n:3", "i:7", "n:1234", "i:" ~ (cast(int) LogLevel.Warn).to!string, "b:false",
        "time:1500:Absolute", "i:" ~ (cast(int) LogLevel.Warn).to!string, "t:TAG", "n:42",
        "s:FFFFFFFFFFFFFFFF", "t:hello", "-"
    ], cells.cells.to!string);
}

@("writeRow: no rule and the fields a record hasn't are nothing, the rest is written")
unittest
{
    LogMessage!wchar msg;
    msg.beginRecord(); // a time, a level and a payload, none of the fields
    msg.timeNs = 1_500_000;
    msg.timeKind = TimeKind.Absolute;
    msg.level = LogLevel.Warn;
    {
        auto builder = msg.payloadBuilder();
        builder.appendUtf8("hello");
    } // the payload is stored when the builder goes

    auto cells = TextCells(rowLength(testColumns.length));
    writeRow(cells, 0, msg, false, true, 0, testColumns, RuleId.init, null);
    assert(cells.cells[0] == "b:false", "not anchored");
    assert(cells.cells[1] == "-", "no rule");
    assert(cells.cells[5] == "b:true", "found by the search");
    assert(cells.cells[fixedCells] == "time:1500:Absolute");
    assert(cells.cells[fixedCells + 2 .. fixedCells + 5] == ["-", "-", "-"], "fields the record hasn't");
    assert(cells.cells[$ - 2] == "t:hello");
    assert(cells.cells[$ - 1] == "-", "the search found nothing in it");
}

@("writeRow: a record without a time has none in its time cell")
unittest
{
    LogMessage!wchar msg;
    fillRecord(msg, false);
    auto cells = TextCells(rowLength(testColumns.length));
    writeRow(cells, 0, msg, false, false, 0, testColumns, RuleId.init, null);
    assert(cells.cells[fixedCells] == "-");
    assert(cells.cells[fixedCells + 2] == "t:TAG", "the fields are there");
}

@("writeRow: a row the search found ends with what the chips found")
unittest
{
    LogMessage!wchar msg;
    fillRecord(msg);
    auto cells = TextCells(rowLength(testColumns.length));
    writeRow(cells, 0, msg, false, true, 0, testColumns, RuleId.init, [MatchRange(0, 2, 1)]);
    assert(cells.cells[$ - 1] == "m:0-2/1 ");
}

@("columnsJson: a column colored by the level says so")
unittest
{
    import std.algorithm.searching : canFind, count;

    const json = columnsJson([
        ColumnInfo("status", "Status", ColumnKind.Integer, 0, TimeKind.None, 0, null, true),
        ColumnInfo("bytes", "Bytes", ColumnKind.Integer, 1),
    ], "access-log");
    assert(json.canFind(`"byLevel":true`), json);
    assert(json.count(`"byLevel"`) == 1, "only for the flagged column");
}

@("columnsJson: every column names its format, the look of a column is left to the style")
unittest
{
    import std.algorithm.searching : canFind, count;

    const json = columnsJson([
        ColumnInfo("time", "Time", ColumnKind.Time),
        ColumnInfo("payload", "Payload", ColumnKind.Payload),
    ], "dlt");
    assert(json.count(`"format":"dlt"`) == 2, json);
    assert(!json.canFind(`"width"`), json);
}
