module dlt_core.log_filter;

import dlt_core.log_item;

interface LogFilter
{
    bool matches(in const(LogItem) item) const;
}
