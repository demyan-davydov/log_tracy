module log_core.log_level;

//! Severity of a log record, common to all formats.
//! The values are those of the DLT protocol, so DLT levels need no mapping.
//! Formats without a level use None.
enum LogLevel : ubyte
{
    None = 0x0,
    Fatal = 0x1,
    Error = 0x2,
    Warn = 0x3,
    Info = 0x4,
    Debug = 0x5,
    Verbose = 0x6
}
