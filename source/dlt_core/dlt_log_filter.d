module dlt_core.dlt_log_filter;

import dlt_core.log_filter;
import dlt_core.dlt_filter_record;
import dlt_core.dlt_filter_serialization;
import dlt_core.decoded_message;

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

    override bool matches(ref const(DecodedMessage!CharType) item) const
    {
        foreach (ref record; _records)
        {
            if (isMatched!CharType(item, record))
                return true;
        }

        return false;
    }

    override Nullable!uint matchIndex(scope ref const(DecodedMessage!CharType) item) const
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
