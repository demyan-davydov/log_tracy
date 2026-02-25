module dlt_core.dlt_log_filter;

import dlt_core.log_filter;
import dlt_core.dlt_filter_record;
import dlt_core.dlt_filter_serialization;
import dlt_core.decoded_message;

import std.traits : isSomeChar;

/// implements LogFilter interface using data loaded from .dlf file

final class DltLogFilter(CharType) : LogFilter!CharType if (isSomeChar!(CharType))
{
    private DltFilterRecord!CharType[] _records;

    this()
    {
    }

    this(typeof(this) other)
    {
        _records = other._records.dup;
    }

    this(string path)
    {
        load(path);
    }

    const(DltFilterRecord!CharType[]) records() const @property
    {
        return _records;
    }

    void opAssign(DltFilterRecord!CharType[] newRecords)
    {
        _records = newRecords.dup;
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
            if (!isMatched!CharType(item, record))
                return false;
        }

        return true;
    }
}
