//! The values of the columns of a record (ColumnInfo), each read by the kind of its column
//! (ColumnKind) and given to a writer of values: the one place the columns of a decoded
//! record are read as values to show (a filter reads them to compare: log_core/rule_filter). The log table writes Sciter values through it
//! (ui/row_cells), another reader of the records may write text.
module log_core.column_values;

import log_core.log_format : ColumnInfo, ColumnKind;
import log_core.log_level : LogLevel;
import log_core.log_message : LogMessage, TimeKind;

/// Whether W can take the values of the columns of a record, `column` being the index of
/// the column: W.nothing(column) - the record has no value there (a field it hasn't, no
/// time); W.time(column, nanoseconds, TimeKind) - the kind of this record, the column's is
/// only the usual one; W.level(column, LogLevel); W.text(column, wchar[]) - the payload or
/// a text field; W.hex(column, wchar[]) - the hex digits of all 64 bits of a Hex column, in
/// upper case; W.number(column, long) - an Integer, Duration or Enum column, read as its
/// ColumnInfo tells (unitsPerSecond, labels). What a writer is given is valid during the
/// call only.
enum isColumnValueWriter(W) = __traits(compiles, (ref W w, const(wchar)[] s) {
    w.nothing(size_t(0));
    w.time(size_t(0), long(0), TimeKind.None);
    w.level(size_t(0), LogLevel.init);
    w.text(size_t(0), s);
    w.hex(size_t(0), s);
    w.number(size_t(0), long(0));
});

/// Writes the value of each column of `columns` of the record `msg`, in their order. Per
/// row of the log table: nothing here allocates
void writeColumnValues(W)(ref W writer, ref const(LogMessage!wchar) msg, const(ColumnInfo)[] columns)
    if (isColumnValueWriter!W)
{
    foreach (i, ref column; columns)
    {
        if (column.isField && !msg.hasField(column.field))
        {
            writer.nothing(i); // e.g. a line without a header
            continue;
        }
        final switch (column.kind)
        {
        case ColumnKind.Time:
            if (msg.timeKind == TimeKind.None)
                writer.nothing(i);
            else
                writer.time(i, msg.timeNs, msg.timeKind);
            break;
        case ColumnKind.Level:
            writer.level(i, msg.level);
            break;
        case ColumnKind.Payload:
            writer.text(i, msg.payloadText);
            break;
        case ColumnKind.Text:
            writer.text(i, msg.text(column.field));
            break;
        case ColumnKind.Hex:
            wchar[16] digits;
            writer.hex(i, hexDigits(msg.number(column.field), digits));
            break;
        case ColumnKind.Integer:
        case ColumnKind.Duration:
        case ColumnKind.Enum:
            writer.number(i, msg.number(column.field));
            break;
        }
    }
}

/// The digits of a Hex value: all 64 bits, in upper case, as typed into the quick filter
/// (FieldFilter reads FFFFFFFFFFFFFFFF as -1). A script number would round values above
/// 2^53 and show -1 as "-1".
/// @return the digits, in `buffer`
const(wchar)[] hexDigits(long value, return ref wchar[16] buffer) pure nothrow @nogc @safe
{
    ulong bits = cast(ulong) value;
    size_t start = buffer.length;
    do
    {
        buffer[--start] = "0123456789ABCDEF"w[bits & 0xF];
        bits >>= 4;
    }
    while (bits != 0);
    return buffer[start .. $];
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

version (unittest)
{
    import std.conv : to;

    /// Writes the values as text: "-" nothing, "time:ns:Kind", "level:Warn", "t:abc",
    /// "hex:FF", "n:42"
    private struct TextValues
    {
        string[] values;

        this(size_t length)
        {
            values = new string[length];
        }

        void nothing(size_t column) { values[column] = "-"; }
        void time(size_t column, long ns, TimeKind kind) { values[column] = "time:" ~ ns.to!string ~ ":" ~ kind.to!string; }
        void level(size_t column, LogLevel level) { values[column] = "level:" ~ level.to!string; }
        void text(size_t column, const(wchar)[] value) { values[column] = "t:" ~ value.to!string; }
        void hex(size_t column, const(wchar)[] digits) { values[column] = "hex:" ~ digits.to!string; }
        void number(size_t column, long value) { values[column] = "n:" ~ value.to!string; }
    }

    static assert(isColumnValueWriter!TextValues);

    private const ColumnInfo[] testColumns = [
        ColumnInfo("time", "Time", ColumnKind.Time),
        ColumnInfo("level", "Level", ColumnKind.Level),
        ColumnInfo("tag", "Tag", ColumnKind.Text, 0),
        ColumnInfo("pid", "Pid", ColumnKind.Integer, 1),
        ColumnInfo("id", "Id", ColumnKind.Hex, 2),
        ColumnInfo("payload", "Payload", ColumnKind.Payload),
    ];
}

@("writeColumnValues: a value per column, as its kind reads it")
unittest
{
    LogMessage!wchar msg;
    msg.beginRecord();
    msg.timeNs = 1_500_000;
    msg.timeKind = TimeKind.Absolute;
    msg.level = LogLevel.Warn;
    msg.setText(0, "TAG");
    msg.setNumber(1, 42);
    msg.setNumber(2, -1);
    {
        auto builder = msg.payloadBuilder();
        builder.appendUtf8("hello");
    } // the payload is stored when the builder goes

    auto values = TextValues(testColumns.length);
    writeColumnValues(values, msg, testColumns);
    assert(values.values == [
        "time:1500000:Absolute", "level:Warn", "t:TAG", "n:42", "hex:FFFFFFFFFFFFFFFF", "t:hello"
    ], values.values.to!string);
}

@("writeColumnValues: the fields a record hasn't and a missing time are nothing")
unittest
{
    LogMessage!wchar msg;
    msg.beginRecord(); // a level and a payload, no time, none of the fields
    msg.level = LogLevel.Info;
    {
        auto builder = msg.payloadBuilder();
        builder.appendUtf8("hello");
    }

    auto values = TextValues(testColumns.length);
    writeColumnValues(values, msg, testColumns);
    assert(values.values == ["-", "level:Info", "-", "-", "-", "t:hello"], values.values.to!string);
}

@("writeColumnValues: a writer that doesn't allocate gets the values without allocating")
unittest
{
    static struct Discard
    {
        size_t written;
        const(wchar)[] lastHex;

        void nothing(size_t column) @nogc { ++written; }
        void time(size_t column, long ns, TimeKind kind) @nogc { ++written; }
        void level(size_t column, LogLevel level) @nogc { ++written; }
        void text(size_t column, const(wchar)[] value) @nogc { ++written; }
        void hex(size_t column, const(wchar)[] digits) @nogc { ++written; lastHex = digits.length == 16 ? "16"w : "?"w; }
        void number(size_t column, long value) @nogc { ++written; }
    }

    static immutable ColumnInfo[] columns = [
        ColumnInfo("id", "Id", ColumnKind.Hex, 0),
        ColumnInfo("pid", "Pid", ColumnKind.Integer, 1),
    ];
    static void write(ref Discard values, ref const(LogMessage!wchar) msg) @nogc
    {
        writeColumnValues(values, msg, columns); // compiles as @nogc: nothing allocates
    }

    LogMessage!wchar msg;
    msg.beginRecord();
    msg.setNumber(0, -1);
    msg.setNumber(1, 42);
    Discard values;
    write(values, msg);
    assert(values.written == 2 && values.lastHex == "16"w, "the hex digits of all 64 bits");
}

@("hexDigits: the 64 bits in upper case hex")
unittest
{
    wchar[16] buffer;
    assert(hexDigits(0x1F, buffer) == "1F");
    assert(hexDigits(0, buffer) == "0");
    assert(hexDigits(-1, buffer) == "FFFFFFFFFFFFFFFF");
    assert(hexDigits(0x1234_5678_9ABC_DEF1, buffer) == "123456789ABCDEF1", "no rounding above 2^53");
}
