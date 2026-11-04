module dlt_core.dlt_log_filter;

import log_core.log_filter;
import dlt_core.dlt_filter_record;
import dlt_core.dlt_filter_serialization;
import log_core.log_message;

import std.traits : isSomeChar;
import std.algorithm.iteration : map;
import std.array : array;
import std.typecons : Nullable, nullable;
import core.stdc.stdint : uint16_t;

/// implements LogFilter interface using data loaded from .dlf file

final class DltLogFilter(CharType) : LogFilter!CharType if (isSomeChar!(CharType))
{
    private DltFilterRecord!CharType[] _records;

    this()
    {
    }

    // Copy constructor: DltFilterRecord contains Regex which is not const-copyable,
    // so we copy element-by-element via map (each element is copied by value).
    this(const(typeof(this)) other)
    {
        _records = other._records.map!(r => cast(DltFilterRecord!CharType) r).array;
    }

    this(string path)
    {
        load(path);
    }

    const(DltFilterRecord!CharType[]) records() const @property
    {
        return _records;
    }

    void opAssign(const(DltFilterRecord!CharType)[] newRecords)
    {
        _records = newRecords.map!(r => cast(DltFilterRecord!CharType) r).array;
    }

    void load(string path)
    {
        _records = loadDlf!CharType(path);
    }

    void save(string path)
    {
        saveDlf!CharType(path, _records);
    }

    override bool matches(scope ref const(LogMessage!CharType) item) const
    {
        foreach (const ref record; _records)
        {
            if (isMatched!CharType(item, record))
                return true;
        }

        return false;
    }

    override Nullable!uint matchIndex(scope ref const(LogMessage!CharType) item) const
    {
        uint idx = 0;
        foreach (const ref record; _records)
        {
            if (isMatched!CharType(item, record))
                return idx.nullable;
            ++idx;
        }

        return Nullable!uint.init;
    }

    override immutable(LogFilter!CharType) idup() const
    {
        // Cast mutable duplicate to immutable — safe because we own the new object
        return cast(immutable) dup();
    }

    override LogFilter!CharType dup() const
    {
        return new DltLogFilter!CharType(this);
    }
}

/// Builds a one-record filter from the quick filter fields of the UI.
/// Empty fields are not checked; ECU, application and context IDs must match
/// exactly, the payload is a regular expression.
/// Returns: null if all fields are empty, which means "no filter".
/// Throws: RegexException if payloadRegex is not a valid regular expression.
DltLogFilter!CharType quickFilter(CharType)(string ecuId, string appId, string ctxId, string payloadRegex)
{
    if (ecuId.length == 0 && appId.length == 0 && ctxId.length == 0 && payloadRegex.length == 0)
        return null;

    DltFilterRecord!CharType record;
    record.enabled = true;
    record.name = toUtf!CharType("Quick filter");

    if (ecuId.length)
    {
        record.ecuId.value = toUtf!CharType(ecuId);
        record.ecuId.enabled = true;
    }
    if (appId.length)
    {
        record.applicationId.value.setPatternFromUtf8(appId);
        record.applicationId.enabled = true;
    }
    if (ctxId.length)
    {
        record.contextId.value.setPatternFromUtf8(ctxId);
        record.contextId.enabled = true;
    }
    if (payloadRegex.length)
    {
        record.payloadText.value.setRegexFromUtf8(payloadRegex);
        record.payloadText.enabled = true;
    }

    auto filter = new DltLogFilter!CharType();
    filter.opAssign([record]);
    return filter;
}

@("quickFilter: empty fields are not checked, all empty means no filter")
unittest
{
    import std.regex : RegexException;
    import std.exception : assertThrown;

    assert(quickFilter!char("", "", "", "") is null);

    LogMessage!char msg;
    auto builder = msg.setupPayload("ECU1", "APP1", "CTX1");
    builder.appendAscii("engine started");
    builder.storePayload();

    assert(quickFilter!char("ECU1", "", "", "").matches(msg));
    assert(!quickFilter!char("ECU2", "", "", "").matches(msg));
    assert(quickFilter!char("", "APP1", "CTX1", "").matches(msg));
    assert(!quickFilter!char("", "APP1", "CTX2", "").matches(msg), "all set fields must match");
    assert(quickFilter!char("", "", "", "eng.*start").matches(msg), "payload is a regex");
    assert(!quickFilter!char("", "", "", "^started").matches(msg));

    assertThrown!RegexException(quickFilter!char("", "", "", "(unclosed"));
}
