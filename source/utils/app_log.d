//! The program's own log (its diagnostics, not the logs it shows), written so that it never
//! throws: to stdout, or, once stdout fails a write (a Windows program started without a console
//! has none), to the debug output of the system, which DebugView of Sysinternals shows on
//! Windows. A failed write isn't tried again: every later line goes straight to the debug output.
module utils.app_log;

/// Writes `line` (without its line break) to the program's log.
void appLog(scope const(char)[] line) nothrow
{
    sink.put(line);
}

// Shared by the threads that log: a race only writes a line to both places, or tries stdout
// once more
private __gshared AppLogSink sink = AppLogSink(&toStdout, &toDebugOutput);

/// Where the lines go: `primary` until it fails a write (it throws), then `fallback` for good.
private struct AppLogSink
{
    void function(scope const(char)[]) primary;
    void function(scope const(char)[]) nothrow fallback;
    private bool primaryBroken;

    void put(scope const(char)[] line) nothrow
    {
        if (!primaryBroken)
        {
            try
            {
                primary(line);
                return;
            }
            catch (Exception)
                primaryBroken = true;
        }
        fallback(line);
    }
}

// Flushed: a write that can't be done fails at once, not once a buffer of 4 KB fills
private void toStdout(scope const(char)[] line)
{
    import std.stdio : stdout, writeln;

    writeln(line);
    stdout.flush();
}

private void toDebugOutput(scope const(char)[] line) nothrow
{
    version (Windows)
    {
        import core.sys.windows.winbase : OutputDebugStringW;
        import std.utf : toUTF16z;

        try
            OutputDebugStringW((line ~ "\n").toUTF16z);
        catch (Exception) // not UTF-8: nowhere to say it
        {
        }
    }
    // elsewhere stdout fails no write that matters: the line is dropped
}

version (unittest)
{
    // What the writers of a test's sink got
    private __gshared string[] primaryLines, fallbackLines;
    private __gshared bool primaryFails;

    private void testPrimary(scope const(char)[] line)
    {
        if (primaryFails)
            throw new Exception("no console");
        primaryLines ~= line.idup;
    }

    private void testFallback(scope const(char)[] line) nothrow
    {
        fallbackLines ~= line.idup;
    }

    /// A sink of the test writers, their lines cleared
    private AppLogSink testSink(bool primaryFailing)
    {
        primaryLines = fallbackLines = null;
        primaryFails = primaryFailing;
        return AppLogSink(&testPrimary, &testFallback);
    }
}

@("AppLogSink: to stdout while it writes")
unittest
{
    auto sink = testSink(false);
    sink.put("one");
    sink.put("two");
    assert(primaryLines == ["one", "two"]);
    assert(fallbackLines.length == 0);
}

@("AppLogSink: once stdout fails a write, the line and every later one go to the debug output")
unittest
{
    auto sink = testSink(true);
    sink.put("one");
    primaryFails = false; // a later write would work: it isn't tried
    sink.put("two");
    assert(primaryLines.length == 0, "stdout is not tried again");
    assert(fallbackLines == ["one", "two"]);
}
