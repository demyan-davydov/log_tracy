module dlt_core.filter;

/// Structure defining active filters
struct FilterConfig
{
    string ecuId;
    string appId;
    string ctxId;
    string payloadRegex;
}
