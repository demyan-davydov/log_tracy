module dlt_core.log_filter;

import dlt_core.decoded_message;

import std.traits : isSomeChar;

interface LogFilter(T) if (isSomeChar!(T))
{
    bool matches(ref const(DecodedMessage!T) item) const;
}
