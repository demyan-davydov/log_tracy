//! The boundary of a callback that foreign code calls (Sciter, the Objective-C runtime): nothing
//! thrown in D may unwind through the frames of that code, whose state is undefined after it.
//!
//! Every `extern (C)` function such code calls is `nothrow` and runs its body through
//! `guardCallback`: an `Exception` is logged and the callback answers its fallback, an `Error`
//! (a bug) is logged and the process aborts. The log is `appLog`'s: stdout, or the debug output of
//! the system where stdout can't be written (a Windows program without a console).
module utils.foreign_callback;

import utils.app_log : appLog;

/// Runs `run` and gives its result; an `Exception` it throws is logged as of `where` and
/// gives `fallback` instead, an `Error` is logged and aborts the process.
T guardCallback(T)(string where, T fallback, scope T delegate() run) nothrow
{
    try
        return run();
    catch (Exception e)
    {
        logFailure(where, e);
        return fallback;
    }
    catch (Throwable e)
        abortOn(where, e);
}

/// `guardCallback` of a callback that answers nothing.
void guardCallback(string where, scope void delegate() run) nothrow
{
    try
        run();
    catch (Exception e)
        logFailure(where, e);
    catch (Throwable e)
        abortOn(where, e);
}

/// Where the lines of the log go: `appLog`; the tests catch them
private __gshared void function(scope const(char)[]) nothrow toLog = &appLog;

private void logFailure(string where, Exception e) nothrow
{
    toLog(where ~ ": " ~ e.msg);
}

// An Error is a bug: the program can't go on, and unwinding into foreign code is no way out
private noreturn abortOn(string where, Throwable e) nothrow
{
    import core.stdc.stdlib : abort;

    try
        toLog(where ~ ": " ~ e.toString());
    catch (Throwable) // toString of a broken Throwable
    {
    }
    abort();
}

version (unittest)
{
    private int answer() => 42;
    private int failing() => throw new Exception("the file is gone");

    private __gshared string[] loggedLines;

    private void catchLog(scope const(char)[] line) nothrow
    {
        loggedLines ~= line.idup;
    }

    /// The lines `test` logs, caught instead of printed
    private string[] logOf(scope void delegate() test)
    {
        loggedLines = null;
        toLog = &catchLog;
        scope (exit) toLog = &appLog;
        test();
        return loggedLines;
    }
}

@("guardCallback: the result of the callback when it throws nothing")
unittest
{
    int result;
    assert(logOf({ result = guardCallback("test", -1, () => answer()); }).length == 0);
    assert(result == 42);
}

@("guardCallback: an Exception gives the fallback and a line of the log, not an unwinding")
unittest
{
    int result;
    const lines = logOf({ result = guardCallback("elementProc", -1, () => failing()); });
    assert(result == -1);
    assert(lines == ["elementProc: the file is gone"], "the log names the callback and the error");
}

@("guardCallback: a callback of no result")
unittest
{
    bool ran;
    assert(logOf({ guardCallback("test", () { ran = true; }); }).length == 0);
    assert(ran);
    assert(logOf({ guardCallback("output", () { failing(); }); }) == ["output: the file is gone"]);
}
