module dlt_core.filter;

import dlt_core.log_item;

interface LogFilter
{
    bool matches(in const(LogItem) item) const;
}

/// Structure defining active filters
struct FilterConfig
{
    string ecuId;
    string appId;
    string ctxId;
    string payloadRegex;
}
