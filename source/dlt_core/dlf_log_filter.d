module dlt_core.dlf_log_filter;

import dlt_core.log_filter;
import dlt_core.log_item;
import dlt_core.dlf_filter_record;
import dlt_core.dlf_filter_serialization;

/// implements LogFilter interface using data loaded from .dlf file

final class DlfLogFilter : LogFilter
{
    private DlfFilterRecord[] _records;

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

    const(DlfFilterRecord[]) records() const @property
    {
        return _records;
    }

    void opAssign(DlfFilterRecord[] newRecords)
    {
        _records = newRecords.dup;
    }

    void load(string path)
    {
        _records = loadDlf(path);
    }

    void save(string path)
    {
        saveDlf(path, _records);
    }

    override bool matches(in const(LogItem) item) const
    {
        foreach (ref record; _records)
        {
            if (!isMatched(cast(uint) item.index, item, record))
                return false;
        }

        return true;
    }
}
