module dlt_core.log_filter;

import dlt_core.decoded_message;

import std.traits : isSomeChar;

interface LogFilter(T) if (isSomeChar!(T))
{
    alias CharType = T;

    bool matches(ref const(DecodedMessage!CharType) item) const;

    // return index of matched record or -1 if no match
    int matchIndex(scope ref const(DecodedMessage!CharType) item) const;

    immutable(LogFilter!CharType) idup() const pure;

    LogFilter!CharType dup() const pure;
}
