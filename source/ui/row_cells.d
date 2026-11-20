//! The texts of the cells of a row as the log table shows them (prototype of
//! docs/experiments/2026-11-19-painted-rows-d.md): the D port of what the DOM table showed (`cellTexts`, removed),
//! written through log_core/column_values, free of Sciter.
module ui.row_cells;

import log_core.column_values : writeColumnValues;
import log_core.log_format : ColumnInfo, ColumnKind;
import log_core.log_level : LogLevel;
import log_core.log_message : LogMessage, TimeKind;
import ptable.memory : Buffer, mallocAllocator;

import std.datetime : SysTime, TimeZone, UTC, unixTimeToStdTime;
import std.format : formattedWrite;

/// Appends `value` in decimal (a sign, then the magnitude: `long.min` too)
void putNumber(ref Buffer!wchar buffer, long value) nothrow
{
    if (value < 0)
        buffer.put('-');
    putMagnitude(buffer, value < 0 ? -cast(ulong) value : cast(ulong) value, 1);
}

/// Appends `value` in decimal, padded with zeros to `width` digits (a sign first if it is negative)
void putPadded(ref Buffer!wchar buffer, long value, size_t width) nothrow
{
    if (value < 0)
        buffer.put('-');
    putMagnitude(buffer, value < 0 ? -cast(ulong) value : cast(ulong) value, width);
}

private void putMagnitude(ref Buffer!wchar buffer, ulong magnitude, size_t width) nothrow
{
    wchar[20] digits;
    size_t at = digits.length;
    do
    {
        digits[--at] = cast(wchar)('0' + magnitude % 10);
        magnitude /= 10;
    }
    while (magnitude != 0);
    foreach (_; 0 .. (width > digits.length - at ? width - (digits.length - at) : 0))
        buffer.put('0');
    buffer.put(digits[at .. $]);
}

/// Appends text of UTF-8 as UTF-16
void putUtf8(ref Buffer!wchar buffer, const(char)[] text) nothrow
{
    import std.utf : decode;

    size_t at = 0;
    while (at < text.length)
    {
        dchar c;
        try
            c = decode(text, at);
        catch (Exception)
        {
            c = 0xFFFD;
            at++;
        }
        if (c < 0x10000)
            buffer.put(cast(wchar) c);
        else
        {
            const v = c - 0x10000;
            buffer.put(cast(wchar)(0xD800 + (v >> 10)));
            buffer.put(cast(wchar)(0xDC00 + (v & 0x3FF)));
        }
    }
}

/// Appends the text of a time cell: `ns` since the epoch (Absolute: shown in `zone`; Local*: the
/// wall clock stored as if it were UTC, shown as is) or since the boot. "-" for no time.
void putTime(ref Buffer!wchar buffer, long ns, TimeKind kind, immutable TimeZone zone) nothrow
{
    const us = ns / 1000;
    const seconds = us / 1_000_000;
    const fraction = us - seconds * 1_000_000;
    if (kind == TimeKind.SinceBoot)
    {
        putNumber(buffer, seconds);
        buffer.put('.');
        putPadded(buffer, fraction, 6);
        return;
    }
    if (kind == TimeKind.None || us == 0)
    {
        buffer.put('-');
        return;
    }
    try
    {
        const moment = SysTime(unixTimeToStdTime(seconds), kind == TimeKind.Absolute ? zone : UTC());
        if (kind != TimeKind.LocalNoYear)
        {
            putPadded(buffer, moment.year, 4);
            buffer.put('/');
        }
        putPadded(buffer, cast(int) moment.month, 2);
        buffer.put('/');
        putPadded(buffer, moment.day, 2);
        buffer.put(' ');
        putPadded(buffer, moment.hour, 2);
        buffer.put(':');
        putPadded(buffer, moment.minute, 2);
        buffer.put(':');
        putPadded(buffer, moment.second, 2);
        buffer.put('.');
        putPadded(buffer, fraction, 6);
    }
    catch (Exception)
    {
        buffer.put('-');
    }
}

/// The text of a time cell as a string (see `putTime`)
wstring formatTime(long ns, TimeKind kind, immutable TimeZone zone)
{
    auto buffer = Buffer!wchar(mallocAllocator());
    putTime(buffer, ns, kind, zone);
    return buffer[].idup;
}

/// The name of a level, "" for None
wstring levelName(LogLevel level) pure nothrow @nogc @safe
{
    final switch (level)
    {
    case LogLevel.None: return "";
    case LogLevel.Fatal: return "Fatal";
    case LogLevel.Error: return "Error";
    case LogLevel.Warn: return "Warn";
    case LogLevel.Info: return "Info";
    case LogLevel.Debug: return "Debug";
    case LogLevel.Verbose: return "Verb";
    }
}

/// Appends a duration of `units` 1/`unitsPerSecond` of a second: "-" for 0
void putDuration(ref Buffer!wchar buffer, long units, long unitsPerSecond) nothrow
{
    if (units == 0 || unitsPerSecond <= 0)
    {
        buffer.put('-');
        return;
    }
    size_t digits = 0;
    for (long u = unitsPerSecond; u > 1; u /= 10)
        digits++;
    putNumber(buffer, units / unitsPerSecond);
    buffer.put('.');
    putPadded(buffer, units % unitsPerSecond, digits);
}

/// A duration of `units` 1/`unitsPerSecond` of a second: "-" for 0
wstring formatDuration(long units, long unitsPerSecond)
{
    auto buffer = Buffer!wchar(mallocAllocator());
    putDuration(buffer, units, unitsPerSecond);
    return buffer[].idup;
}

/// A writer of the values of the columns (isColumnValueWriter) that keeps their texts
struct CellTexts
{
    const(ColumnInfo)[] columns;
    immutable TimeZone zone;
    wstring[] texts; // per column; the Index is not in it

    this(const(ColumnInfo)[] columns, immutable TimeZone zone)
    {
        this.columns = columns;
        this.zone = zone;
        texts.length = columns.length;
    }

    void nothing(size_t column) { texts[column] = ""; }
    void time(size_t column, long ns, TimeKind kind) { texts[column] = formatTime(ns, kind, zone); }
    void level(size_t column, LogLevel level)
    {
        const name = levelName(level);
        texts[column] = name.length ? name : "";
    }

    void text(size_t column, const(wchar)[] value) { texts[column] = value.idup; }
    void hex(size_t column, const(wchar)[] digits) { texts[column] = digits.idup; }
    void number(size_t column, long value)
    {
        import std.conv : to;

        auto info = &columns[column];
        final switch (info.kind)
        {
        case ColumnKind.Duration:
            texts[column] = formatDuration(value, info.unitsPerSecond);
            break;
        case ColumnKind.Enum:
            texts[column] = value >= 0 && value < info.labels.length ? info.labels[cast(size_t) value].to!wstring : "unknown";
            break;
        case ColumnKind.Time:
        case ColumnKind.Level:
        case ColumnKind.Payload:
        case ColumnKind.Text:
        case ColumnKind.Integer:
        case ColumnKind.Hex:
            texts[column] = value.to!wstring;
            break;
        }
    }
}

/// Appends the text of a numeric value of a column as the column's kind shows it (a duration, a label of an
/// enum, a number)
void putNumberOf(ref Buffer!wchar buffer, ref const ColumnInfo info, long value) nothrow
{
    final switch (info.kind)
    {
    case ColumnKind.Duration:
        putDuration(buffer, value, info.unitsPerSecond);
        break;
    case ColumnKind.Enum:
        if (value >= 0 && value < info.labels.length)
            putUtf8(buffer, info.labels[cast(size_t) value]);
        else
            buffer.put("unknown"w);
        break;
    case ColumnKind.Time:
    case ColumnKind.Level:
    case ColumnKind.Payload:
    case ColumnKind.Text:
    case ColumnKind.Integer:
    case ColumnKind.Hex:
        putNumber(buffer, value);
        break;
    }
}

// Writes the value of one column into a buffer
private struct ColumnWriter
{
    Buffer!wchar* buffer;
    const(ColumnInfo)[] columns; // the one column
    immutable TimeZone zone;

    void nothing(size_t column) {}
    void time(size_t column, long ns, TimeKind kind) { putTime(*buffer, ns, kind, zone); }
    void level(size_t column, LogLevel level) { buffer.put(levelName(level)); }
    void text(size_t column, const(wchar)[] value) { buffer.put(value); }
    void hex(size_t column, const(wchar)[] digits) { buffer.put(digits); }
    void number(size_t column, long value) { putNumberOf(*buffer, columns[0], value); }
}

/// Appends the text of the cell of `column` of the record `msg` (nothing for a value it has none of)
void putColumnText(ref Buffer!wchar buffer, ref const(LogMessage!wchar) msg, ref const ColumnInfo column, immutable TimeZone zone)
{
    auto writer = ColumnWriter(&buffer, (&column)[0 .. 1], zone);
    writeColumnValues(writer, msg, (&column)[0 .. 1]);
}

/// The cells of the row of `msg`: the Index (`messageIndex`), then a text per column
wstring[] rowTexts(ref const(LogMessage!wchar) msg, size_t messageIndex, const(ColumnInfo)[] columns, immutable TimeZone zone)
{
    import std.conv : to;

    auto cells = CellTexts(columns, zone);
    writeColumnValues(cells, msg, columns);
    return [messageIndex.to!wstring] ~ cells.texts;
}

version (unittest)
{
    import log_core.log_message : LogMessage;
}

@("formatTime: an absolute time in the zone given, to the microsecond")
unittest
{
    // 2026-01-02 03:04:05.000678 UTC
    const ns = (1_767_323_045L * 1_000_000 + 678) * 1000;
    assert(formatTime(ns, TimeKind.Absolute, UTC()) == "2026/01/02 03:04:05.000678");
    assert(formatTime(ns, TimeKind.Local, UTC()) == "2026/01/02 03:04:05.000678", "Local is shown as it is stored");
    assert(formatTime(ns, TimeKind.LocalNoYear, UTC()) == "01/02 03:04:05.000678");
}

@("formatTime: since the boot, no time and an unset time")
unittest
{
    assert(formatTime(12_345_678_000, TimeKind.SinceBoot, UTC()) == "12.345678");
    assert(formatTime(5, TimeKind.None, UTC()) == "-");
    assert(formatTime(0, TimeKind.Absolute, UTC()) == "-");
}

@("formatDuration: seconds and the fraction of the unit, - for zero")
unittest
{
    assert(formatDuration(0, 1000) == "-");
    assert(formatDuration(1234, 1000) == "1.234");
    assert(formatDuration(5, 1_000_000) == "0.000005");
}

@("rowTexts: the Index, then a text per column as the table shows it")
unittest
{
    LogMessage!wchar msg;
    msg.beginRecord();
    msg.timeNs = 1_500_000;
    msg.timeKind = TimeKind.SinceBoot;
    msg.level = LogLevel.Warn;
    msg.setText(0, "TAG");
    msg.setNumber(1, 42);
    msg.setNumber(2, 1);
    {
        auto builder = msg.payloadBuilder();
        builder.appendUtf8("hello");
    }
    const ColumnInfo[] columns = [
        ColumnInfo("time", "Time", ColumnKind.Time),
        ColumnInfo("level", "Level", ColumnKind.Level),
        ColumnInfo("tag", "Tag", ColumnKind.Text, 0),
        ColumnInfo("pid", "Pid", ColumnKind.Integer, 1),
        ColumnInfo("mode", "Mode", ColumnKind.Enum, 2, TimeKind.None, 0, ["off", "on"]),
        ColumnInfo("payload", "Payload", ColumnKind.Payload),
    ];
    const cells = rowTexts(msg, 77, columns, UTC());
    assert(cells == ["77"w, "0.001500", "Warn", "TAG", "42", "on", "hello"], "got " ~ cells.to!string);
}

version (unittest)
    import std.conv : to;

@("putNumber, putPadded: the smallest long and negative values are written, not looped on or garbled")
unittest
{
    auto buffer = Buffer!wchar(mallocAllocator());
    putNumber(buffer, long.min);
    buffer.put(' ');
    putPadded(buffer, -7, 3);
    assert(buffer[] == "-9223372036854775808 -007"w);
}

@("putNumber, putPadded: signs, zeros and width")
unittest
{
    auto buffer = Buffer!wchar(mallocAllocator());
    putNumber(buffer, -305);
    buffer.put(' ');
    putPadded(buffer, 7, 3);
    buffer.put(' ');
    putPadded(buffer, 12345, 3);
    buffer.put(' ');
    putNumber(buffer, 0);
    assert(buffer[] == "-305 007 12345 0"w);
}

@("putColumnText: the text of one column is the one rowTexts gives")
unittest
{
    LogMessage!wchar msg;
    msg.beginRecord();
    msg.timeNs = 1_500_000;
    msg.timeKind = TimeKind.SinceBoot;
    msg.level = LogLevel.Warn;
    msg.setText(0, "TAG");
    msg.setNumber(1, 42);
    msg.setNumber(2, 1);
    {
        auto builder = msg.payloadBuilder();
        builder.appendUtf8("hello");
    }
    const ColumnInfo[] columns = [
        ColumnInfo("time", "Time", ColumnKind.Time),
        ColumnInfo("level", "Level", ColumnKind.Level),
        ColumnInfo("tag", "Tag", ColumnKind.Text, 0),
        ColumnInfo("pid", "Pid", ColumnKind.Integer, 1),
        ColumnInfo("mode", "Mode", ColumnKind.Enum, 2, TimeKind.None, 0, ["off", "on"]),
        ColumnInfo("payload", "Payload", ColumnKind.Payload),
    ];
    const expected = rowTexts(msg, 77, columns, UTC())[1 .. $];
    auto buffer = Buffer!wchar(mallocAllocator());
    foreach (i, ref column; columns)
    {
        buffer.clear();
        putColumnText(buffer, msg, column, UTC());
        assert(buffer[] == expected[i], "column " ~ column.id);
    }
}
