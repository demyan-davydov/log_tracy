module dlt_core.log_filter;

import dlt_core.decoded_message;

import std.traits : isSomeChar;
import std.typecons : Nullable;

interface LogFilter(T) if (isSomeChar!(T))
{
    alias CharType = T;

    bool matches(scope ref const(DecodedMessage!CharType) item) const;

    //! Scan all of rules and return index of first matched record or Nullable.init if no match
    Nullable!uint matchIndex(scope ref const(DecodedMessage!CharType) item) const;

    immutable(LogFilter!CharType) idup() const pure;

    LogFilter!CharType dup() const pure;
}
