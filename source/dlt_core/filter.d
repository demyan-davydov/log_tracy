module dlt_core.filter;

import dlt_core.log_item;
import dlt_core.dlf_filter;
import dlt_core.dlf_filter_serialization;

interface LogFilter
{
    bool matches(in const(LogItem) item) const;
}

/// Simple filter implementation that mimics behavior but implements LogFilter
final class DlfLogFilter : LogFilter
{
    private DlfFilterRecord[] _records;

    void load(string path)
    {
        _records = loadDlf(path);
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
