//! Sciter's debug output (its console, its errors) written to the program's log (`utils/app_log`).
module sciter.debug_output;

import sciter.capi.types;
import sciter.capi.def;
import sciter.capi.api;
import sciter.api;
import utils.foreign_callback : guardCallback;
import utils.app_log : appLog;

// Allow to enable Sciter debug output

void enableSciterDebugOutput()
{
    sciterApi.SciterSetupDebugOutput(null, null, &_output_debug);
    //sciter_api.SciterSetOption(null, SCITER_SET_OPTION_TYPES.SCITER_SET_DEBUG_OUTPUT, cast(UINT_PTR) _output_debug);
}

// To the log of `appLog`, which can always be written: a stdout that fails a write (a Windows
// program without a console) gives way to the debug output of the system
private extern (C) void _output_debug(void* param, UINT subsystem, UINT severity, LPCWSTR text,
    UINT text_length) nothrow
{
    guardCallback("Sciter's debug output", () => appLog(debugLine(cast(OUTPUT_SUBSYTEMS) subsystem,
        cast(OUTPUT_SEVERITY) severity, text[0 .. text_length])));
}

private string subsystem_to_string(OUTPUT_SUBSYTEMS subsystem)
{
    switch (subsystem)
    {
    case OUTPUT_SUBSYTEMS.OT_DOM:
        return "DOM";
    case OUTPUT_SUBSYTEMS.OT_CSSS:
        return "csss!";
    case OUTPUT_SUBSYTEMS.OT_CSS:
        return "css";
    case OUTPUT_SUBSYTEMS.OT_TIS:
        return "script";
    default:
        return "unknown";
    }
}

private string severity_to_string(OUTPUT_SEVERITY severity)
{
    switch (severity)
    {
    case OUTPUT_SEVERITY.OS_INFO:
        return "info";
    case OUTPUT_SEVERITY.OS_WARNING:
        return "warning";
    case OUTPUT_SEVERITY.OS_ERROR:
        return "error";
    default:
        return "unknown";
    }
}

// The line of the log of a message of Sciter, which ends its text with a line break
private string debugLine(OUTPUT_SUBSYTEMS subsystem, OUTPUT_SEVERITY severity, const(wchar)[] text)
{
    import std.conv : to;
    import std.string : stripRight;

    return severity_to_string(severity) ~ " [" ~ subsystem_to_string(subsystem) ~ "]: "
        ~ text.to!string.stripRight("\r\n");
}

@("debugLine: the severity, the subsystem and the text without its line break")
unittest
{
    assert(debugLine(OUTPUT_SUBSYTEMS.OT_TIS, OUTPUT_SEVERITY.OS_INFO, "hello\n"w) == "info [script]: hello");
    assert(debugLine(OUTPUT_SUBSYTEMS.OT_CSS, OUTPUT_SEVERITY.OS_WARNING, "a\r\n"w) == "warning [css]: a");
    assert(debugLine(OUTPUT_SUBSYTEMS.OT_DOM, OUTPUT_SEVERITY.OS_ERROR, "no break"w) == "error [DOM]: no break");
}

@("_output_debug: nothing thrown unwinds into Sciter")
unittest
{
    import std.traits : FunctionAttribute, functionAttributes;

    assert(functionAttributes!_output_debug & FunctionAttribute.nothrow_,
        "_output_debug must be nothrow: a failed write (no console on Windows) would unwind "
        ~ "through the frames of Sciter");
}
