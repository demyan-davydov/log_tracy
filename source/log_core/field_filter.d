module log_core.field_filter;

import log_core.log_filter;
import log_core.log_format : ColumnInfo, ColumnKind;
import log_core.log_message;

import std.algorithm.iteration : map;
import std.algorithm.searching : countUntil;
import std.array : array;
import std.conv : ConvException, ConvOverflowException, to;
import std.format : format;
import std.regex : matchFirst, regex, Regex;
import std.string : strip;
import std.typecons : Nullable;
import std.uni : icmp;
import std.utf : toUTF16;

//! The quick filter of a log of any format: a value per column of the format,
//! all of them must match. Text fields match the exact value (like DLT IDs),
//! number fields the number (in hex for hex columns), enum fields the label
//! (in any case), the payload a regular expression. A record without the
//! field of a value doesn't match.
final class FieldFilter : LogFilter!wchar
{
    private struct Condition
    {
        ColumnKind kind;
        int field = -1;
        wstring text; // Text
        long number; // Integer, Hex, Enum
        Regex!wchar regex; // Payload
    }

    private Condition[] _conditions;

    private this(Condition[] conditions) pure
    {
        _conditions = conditions;
    }

    //! @brief Builds the filter from the values typed for the columns.
    //! @param values - by column id; empty values and columns that can't be
    //! filtered (time, level) are skipped
    //! @returns null if no value is left: no filter
    //! @throws Exception if a value doesn't suit its column (not a number,
    //! an unknown label, an invalid regular expression)
    static FieldFilter fromValues(const(ColumnInfo)[] columns, const string[string] values)
    {
        Condition[] conditions;
        foreach (ref column; columns)
        {
            auto typed = column.id in values;
            if (typed is null)
                continue;
            const value = strip(*typed);
            if (value.length == 0)
                continue;

            Condition condition;
            condition.kind = column.kind;
            condition.field = column.field;
            final switch (column.kind)
            {
            case ColumnKind.Time:
            case ColumnKind.Level:
            case ColumnKind.Duration:
                continue; // can't be filtered
            case ColumnKind.Text:
                condition.text = value.toUTF16;
                break;
            case ColumnKind.Integer:
                condition.number = parseNumber(column, value, 10);
                break;
            case ColumnKind.Hex:
                const digits = value.length > 2 && (value[0 .. 2] == "0x" || value[0 .. 2] == "0X")
                    ? value[2 .. $] : value;
                condition.number = parseNumber(column, digits, 16);
                break;
            case ColumnKind.Enum:
                const index = column.labels.countUntil!(label => icmp(label, value) == 0);
                if (index < 0)
                    throw new Exception(format("%s: unknown value \"%s\", expected one of %-(%s, %)",
                        column.title, value, column.labels));
                condition.number = index;
                break;
            case ColumnKind.Payload:
                condition.regex = regex(value.toUTF16); // throws RegexException
                break;
            }
            conditions ~= condition;
        }
        return conditions.length ? new FieldFilter(conditions) : null;
    }

    //! A hex value is read as the 64 bits of an ID: FFFFFFFFFFFFFFFF is -1
    private static long parseNumber(ref const(ColumnInfo) column, const(char)[] value, uint radix)
    {
        try
            return radix == 16 ? cast(long) to!ulong(value, radix) : to!long(value, radix);
        catch (ConvOverflowException)
            throw new Exception(format("%s: %s is out of range", column.title, value));
        catch (ConvException)
            throw new Exception(format("%s: \"%s\" is not a%s number",
                column.title, value, radix == 16 ? " hex" : ""));
    }

    override bool matches(scope ref const(LogMessage!wchar) item) const
    {
        foreach (ref condition; _conditions)
        {
            if (condition.kind == ColumnKind.Payload)
            {
                if (matchFirst(item.payloadText, condition.regex).empty)
                    return false;
                continue;
            }
            if (!item.hasField(condition.field))
                return false;
            if (condition.kind == ColumnKind.Text)
            {
                if (item.text(condition.field) != condition.text)
                    return false;
            }
            else if (item.number(condition.field) != condition.number)
                return false;
        }
        return true;
    }

    override Nullable!uint matchIndex(scope ref const(LogMessage!wchar) item) const
    {
        return matches(item) ? Nullable!uint(0) : Nullable!uint.init;
    }

    override immutable(LogFilter!wchar) idup() const pure
    {
        // Cast mutable duplicate to immutable — safe because we own the new object
        return cast(immutable) dup();
    }

    override LogFilter!wchar dup() const pure
    {
        // Regex is not const-copyable: the conditions are copied one by one
        return new FieldFilter(_conditions.map!(c => cast(Condition) c).array);
    }
}

// ─── Tests ──────────────────────────────────────────────────────────────────

version (unittest)
{
    private static immutable ColumnInfo[] testColumns = [
        ColumnInfo("time", "Time", ColumnKind.Time, -1, 0, TimeKind.Local),
        ColumnInfo("tag", "Tag", ColumnKind.Text, 0),
        ColumnInfo("pid", "PID", ColumnKind.Integer, 1),
        ColumnInfo("id", "ID", ColumnKind.Hex, 2),
        ColumnInfo("type", "Type", ColumnKind.Enum, 3, 0, TimeKind.None, 0, ["LOG", "APP"]),
        ColumnInfo("level", "Level", ColumnKind.Level),
        ColumnInfo("payload", "Message", ColumnKind.Payload),
    ];

    //! A record with all the test fields
    private void makeRecord(ref LogMessage!wchar msg, string tag, long pid, long id, long type, string text)
    {
        msg.beginRecord();
        msg.setText(0, tag);
        msg.setNumber(1, pid);
        msg.setNumber(2, id);
        msg.setNumber(3, type);
        auto builder = msg.payloadBuilder();
        builder.appendUtf8(text);
    }

    private FieldFilter filterOf(const string[string] values)
    {
        return FieldFilter.fromValues(testColumns, values);
    }
}

@("FieldFilter: no values, or values of columns that can't be filtered, is no filter")
unittest
{
    assert(filterOf(null) is null);
    assert(filterOf(["tag": "", "payload": ""]) is null, "empty values are skipped");
    assert(filterOf(["time": "14:22", "level": "Error", "nope": "x"]) is null,
        "time, level and unknown ids are skipped");
}

@("FieldFilter: a text column matches the exact value, a record without the field doesn't")
unittest
{
    LogMessage!wchar msg;
    makeRecord(msg, "Tag", 1, 2, 0, "text");
    assert(filterOf(["tag": "Tag"]).matches(msg));
    assert(!filterOf(["tag": "Ta"]).matches(msg), "not a substring");

    msg.beginRecord(); // a line without a header: no fields
    assert(!filterOf(["tag": "Tag"]).matches(msg));
}

@("FieldFilter: an integer column matches the number")
unittest
{
    import std.exception : assertThrown;

    LogMessage!wchar msg;
    makeRecord(msg, "Tag", 1234, 2, 0, "text");
    assert(filterOf(["pid": "1234"]).matches(msg));
    assert(filterOf(["pid": " 1234 "]).matches(msg), "spaces around are ignored");
    assert(!filterOf(["pid": "123"]).matches(msg));
    assertThrown(filterOf(["pid": "12x"]));
}

@("FieldFilter: a hex column matches the number written in hex")
unittest
{
    import std.exception : assertThrown;

    LogMessage!wchar msg;
    makeRecord(msg, "Tag", 1, 0x1F, 0, "text");
    assert(filterOf(["id": "1F"]).matches(msg));
    assert(filterOf(["id": "0x1f"]).matches(msg));
    assert(!filterOf(["id": "20"]).matches(msg));
    assertThrown(filterOf(["id": "1G"]));
}

@("FieldFilter: an enum column matches the label, in any case")
unittest
{
    import std.exception : assertThrown;

    LogMessage!wchar msg;
    makeRecord(msg, "Tag", 1, 2, 1, "text");
    assert(filterOf(["type": "APP"]).matches(msg));
    assert(filterOf(["type": "app"]).matches(msg));
    assert(!filterOf(["type": "LOG"]).matches(msg));
    assertThrown(filterOf(["type": "CTRL"]), "not a label of the column");
}

@("FieldFilter: the payload is matched by a regular expression")
unittest
{
    import std.exception : assertThrown;

    LogMessage!wchar msg;
    makeRecord(msg, "Tag", 1, 2, 0, "engine started with an error");
    assert(filterOf(["payload": "err.*r"]).matches(msg));
    assert(!filterOf(["payload": "^error"]).matches(msg));
    assertThrown(filterOf(["payload": "(unclosed"]));
}

@("FieldFilter: every value must match")
unittest
{
    LogMessage!wchar msg;
    makeRecord(msg, "Tag", 1234, 2, 0, "text");
    assert(filterOf(["tag": "Tag", "pid": "1234"]).matches(msg));
    assert(!filterOf(["tag": "Tag", "pid": "1"]).matches(msg));
    assert(filterOf(["tag": "Tag"]).matchIndex(msg) == 0);
    assert(filterOf(["tag": "Other"]).matchIndex(msg).isNull);
}

@("FieldFilter: a copy matches like the original")
unittest
{
    LogMessage!wchar msg;
    makeRecord(msg, "Tag", 1, 2, 0, "text");
    auto filter = filterOf(["tag": "Other"]);
    assert(!filter.dup().matches(msg));
    assert(!filter.idup().matches(msg));
}

@("FieldFilter: a hex value takes all 64 bits, a number out of range says so")
unittest
{
    import std.algorithm.searching : canFind;
    import std.exception : collectExceptionMsg;

    LogMessage!wchar msg;
    makeRecord(msg, "Tag", 1, cast(long) ulong.max, 0, "text");
    assert(filterOf(["id": "FFFFFFFFFFFFFFFF"]).matches(msg), "a full 64-bit ID");

    const error = collectExceptionMsg(filterOf(["pid": "99999999999999999999"]));
    assert(error.canFind("out of range"), error);
}
