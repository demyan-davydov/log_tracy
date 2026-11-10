module log_core.log_filter;

import log_core.log_message;

import std.traits : isSomeChar;
import std.typecons : Nullable;

//! A condition on a record. `matches` and `matchIndex` are called from many
//! threads at once (the blocks of a filter or a search, utils/parallel_scan,
//! and the UI thread): they must not change the filter, and what they keep per
//! thread stays per thread.
interface LogFilter(T) if (isSomeChar!(T))
{
    alias CharType = T;

    bool matches(scope ref const(LogMessage!CharType) item) const;

    //! Scan all of rules and return index of first matched record or Nullable.init if no match
    Nullable!uint matchIndex(scope ref const(LogMessage!CharType) item) const;

    immutable(LogFilter!CharType) idup() const pure;

    LogFilter!CharType dup() const pure;
}
