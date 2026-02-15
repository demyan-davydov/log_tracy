module dlt_core.log_item;

import dlt_core.dlt_protocol : LogLevel, MessageType;

/// Represents a decoded DLT log message
struct LogItem
{
    size_t index;
    ulong offset;
    ushort length;
    ulong timestamp;
    string ecu;
    string appId;
    string ctxId;
    LogLevel level;
    MessageType type;
    uint messageId;
    string payload;
}

string toString(MessageType type) pure nothrow @nogc
{
    enum STR_LOG = "LOG";
    enum STR_APP = "APP";
    enum STR_NW = "NW";
    enum STR_CTRL = "CTRL";
    enum STR_UNK = "UNK";

    switch (type)
    {
    case MessageType.Log:
        return STR_LOG;
    case MessageType.AppTrace:
        return STR_APP;
    case MessageType.NwTrace:
        return STR_NW;
    case MessageType.Control:
        return STR_CTRL;
    default:
        return STR_UNK;
    }
}

string toString(LogLevel level) pure nothrow @nogc
{
    enum STR_FATAL = "Fatal";
    enum STR_ERROR = "Error";
    enum STR_WARN = "Warn";
    enum STR_INFO = "Info";
    enum STR_DEBUG = "Debug";
    enum STR_VERBOSE = "Verbose";
    enum STR_UNKNOWN = "Unknown";

    switch (level)
    {
    case LogLevel.Fatal:
        return STR_FATAL;
    case LogLevel.Error:
        return STR_ERROR;
    case LogLevel.Warn:
        return STR_WARN;
    case LogLevel.Info:
        return STR_INFO;
    case LogLevel.Debug:
        return STR_DEBUG;
    case LogLevel.Verbose:
        return STR_VERBOSE;

    default:
        return STR_UNKNOWN;
    }
}

@("toString(MessageType)")
unittest
{
    assert(toString(MessageType.Log) == "LOG");
    assert(toString(MessageType.AppTrace) == "APP");
    assert(toString(MessageType.NwTrace) == "NW");
    assert(toString(MessageType.Control) == "CTRL");
    assert(toString(cast(MessageType) 0xFF) == "UNK");
}

@("toString(LogLevel)")
unittest
{
    assert(toString(LogLevel.Fatal) == "Fatal");
    assert(toString(LogLevel.Error) == "Error");
    assert(toString(LogLevel.Warn) == "Warn");
    assert(toString(LogLevel.Info) == "Info");
    assert(toString(LogLevel.Debug) == "Debug");
    assert(toString(LogLevel.Verbose) == "Verbose");
    assert(toString(cast(LogLevel) 0xFF) == "Unknown");
}
