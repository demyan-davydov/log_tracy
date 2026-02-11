module dlt_core.log_item;

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
    LogType type;
    uint messageId;
    string payload;
}

enum LogType : ubyte
{
    Log = 0x0,
    AppTrace = 0x1,
    NwTrace = 0x2,
    Control = 0x3
}

string toString(LogType type) pure nothrow @nogc
{
    enum STR_LOG = "LOG";
    enum STR_APP = "APP";
    enum STR_NW = "NW";
    enum STR_CTRL = "CTRL";
    enum STR_UNK = "UNK";

    switch (type)
    {
    case LogType.Log:
        return STR_LOG;
    case LogType.AppTrace:
        return STR_APP;
    case LogType.NwTrace:
        return STR_NW;
    case LogType.Control:
        return STR_CTRL;
    default:
        return STR_UNK;
    }
}

enum LogLevel : ubyte
{
    Fatal = 0x1,
    Error = 0x2,
    Warn = 0x3,
    Info = 0x4,
    Debug = 0x5,
    Verbose = 0x6
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

@("toString(LogType)")
unittest
{
    assert(toString(LogType.Log) == "LOG");
    assert(toString(LogType.AppTrace) == "APP");
    assert(toString(LogType.NwTrace) == "NW");
    assert(toString(LogType.Control) == "CTRL");
    assert(toString(cast(LogType) 0xFF) == "UNK");
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
