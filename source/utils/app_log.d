//! The program's own log (its diagnostics, not the logs it shows), written so that it never
//! throws: to stdout, a write that fails dropped (a pipe whose reader is gone). A stdout the
//! program was started without is the null device already (`utils/std_streams`).
module utils.app_log;

/// Writes `line` (without its line break) to the program's log.
void appLog(scope const(char)[] line) nothrow
{
    import std.stdio : writeln;

    try
        writeln(line);
    catch (Exception) // nowhere to say it
    {
    }
}

@("appLog: never throws, so a callback of foreign code can log")
unittest
{
    import std.traits : FunctionAttribute, functionAttributes;

    assert(functionAttributes!appLog & FunctionAttribute.nothrow_);
}
