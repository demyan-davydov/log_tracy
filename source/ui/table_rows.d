//! The rows and the columns of the log tables as the script gets them, free
//! of Sciter: what each cell of a row holds (see rowLayout in
//! resources/cell-format.js), written through a cell writer the window makes
//! of Sciter values, and the columns as JSON.
module ui.table_rows;

import log_core.log_format : ColumnInfo, ColumnKind;
import log_core.log_message : LogMessage, TimeKind;
import log_core.rule_filter : RuleId;
import log_core.search_filter : MatchRange;

import std.json : JSONValue;

/// The cells of a row before those of the columns: anchored, rule id, view
/// index, message index, level
enum fixedCells = 5;

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

/// The number of cells of a row with `columnCount` columns
size_t rowLength(size_t columnCount, bool withMatches) pure nothrow @nogc
{
    return fixedCells + columnCount + (withMatches ? 1 : 0);
}

/// Writes a row of the log table: anchored, rule id, view index, message index,
/// level, then a cell per column. The level colors the cells of the columns
/// that ask for it (ColumnInfo.byLevel, done by the script).
/// @param index - the position of the row in its view
/// @param rule - the first filter rule with a color the record matches (the
/// script shows it by its color); none is written as nothing
/// @param withMatches - a row of the search results: after the cells comes what
/// the chips found in the payload, [[start, end, chip]] (see MatchRange)
void writeRow(W)(ref W writer, int index, ref const(LogMessage!wchar) msg, bool anchored, size_t messageIndex,
    const(ColumnInfo)[] columns, RuleId rule, bool withMatches = false, const(MatchRange)[] matches = null)
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

    foreach (i, ref column; columns)
    {
        const cell = fixedCells + i;
        if (column.isField && !msg.hasField(column.field))
        {
            writer.nothing(cell); // e.g. a line without a header
            continue;
        }
        final switch (column.kind)
        {
        case ColumnKind.Time:
            // [microseconds, TimeKind]: the kind of this record, the column's
            // is only the usual one. Microseconds are exact in a double (a
            // script number) for 285 years.
            if (msg.timeKind == TimeKind.None)
                writer.nothing(cell);
            else
                writer.time(cell, cast(double)(msg.timeNs / 1000), msg.timeKind);
            break;
        case ColumnKind.Level:
            writer.integer(cell, cast(int) msg.level);
            break;
        case ColumnKind.Payload:
            writer.text(cell, msg.payloadText);
            break;
        case ColumnKind.Text:
            writer.text(cell, msg.text(column.field));
            break;
        case ColumnKind.Hex:
            writer.text(cell, hexCellText(msg.number(column.field)));
            break;
        case ColumnKind.Integer:
        case ColumnKind.Duration:
        case ColumnKind.Enum:
            writer.number(cell, cast(double) msg.number(column.field));
            break;
        }
    }
    if (withMatches)
        writer.matches(fixedCells + columns.length, matches);
}

//! @brief The text of a hex cell: all 64 bits, as typed into the quick filter
//! (FieldFilter reads FFFFFFFFFFFFFFFF as -1). A script number would round
//! values above 2^53 and show -1 as "-1".
string hexCellText(long value) pure
{
    import std.format : format;

    return format("%X", cast(ulong) value);
}

//! @brief The columns as JSON for the script (see virtual-dlt-view.js)
string columnsJson(const(ColumnInfo)[] columns)
{
    import std.conv : to;

    JSONValue[] result;
    foreach (ref column; columns)
    {
        JSONValue c = [
            "id": JSONValue(column.id),
            "title": JSONValue(column.title),
            "kind": JSONValue(column.kind.to!string),
            "width": JSONValue(column.width),
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
    import log_core.log_level : LogLevel;
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
    auto cells = TextCells(rowLength(testColumns.length, false));
    writeRow(cells, 7, msg, true, 1234, testColumns, RuleId(3));
    assert(cells.cells == [
        "b:true", "n:3", "i:7", "n:1234", "i:" ~ (cast(int) LogLevel.Warn).to!string,
        "time:1500:Absolute", "i:" ~ (cast(int) LogLevel.Warn).to!string, "t:TAG", "n:42",
        "s:FFFFFFFFFFFFFFFF", "t:hello"
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

    auto cells = TextCells(rowLength(testColumns.length, false));
    writeRow(cells, 0, msg, false, 0, testColumns, RuleId.init);
    assert(cells.cells[1] == "-", "no rule");
    assert(cells.cells[fixedCells] == "time:1500:Absolute");
    assert(cells.cells[fixedCells + 2 .. fixedCells + 5] == ["-", "-", "-"], "fields the record hasn't");
    assert(cells.cells[$ - 1] == "t:hello");
}

@("writeRow: a record without a time has none in its time cell")
unittest
{
    LogMessage!wchar msg;
    fillRecord(msg, false);
    auto cells = TextCells(rowLength(testColumns.length, false));
    writeRow(cells, 0, msg, false, 0, testColumns, RuleId.init);
    assert(cells.cells[fixedCells] == "-");
    assert(cells.cells[fixedCells + 2] == "t:TAG", "the fields are there");
}

@("writeRow: a search result ends with what the chips found")
unittest
{
    LogMessage!wchar msg;
    fillRecord(msg);
    auto cells = TextCells(rowLength(testColumns.length, true));
    writeRow(cells, 0, msg, false, 0, testColumns, RuleId.init, true, [MatchRange(0, 2, 1)]);
    assert(cells.cells[$ - 1] == "m:0-2/1 ");
}

@("hexCellText: the 64 bits in upper case hex")
unittest
{
    assert(hexCellText(0x1F) == "1F");
    assert(hexCellText(0) == "0");
    assert(hexCellText(-1) == "FFFFFFFFFFFFFFFF");
    assert(hexCellText(0x1234_5678_9ABC_DEF1) == "123456789ABCDEF1", "no rounding above 2^53");
}

@("columnsJson: a column colored by the level says so")
unittest
{
    import std.algorithm.searching : canFind, count;

    const json = columnsJson([
        ColumnInfo("status", "Status", ColumnKind.Integer, 0, 50, TimeKind.None, 0, null, true),
        ColumnInfo("bytes", "Bytes", ColumnKind.Integer, 1, 70),
    ]);
    assert(json.canFind(`"byLevel":true`), json);
    assert(json.count(`"byLevel"`) == 1, "only for the flagged column");
}
