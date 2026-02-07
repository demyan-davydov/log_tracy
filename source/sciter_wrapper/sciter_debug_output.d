module sciter_wrapper.sciter_debug_output;

import sciter.types;
import sciter.def;
import sciter.api;
import sciter_wrapper.sciter_api;
import std.stdio;

void enableSciterDebugOutput()
{
    sciterApi.SciterSetupDebugOutput(null, null, &_output_debug);
    //sciter_api.SciterSetOption(null, SCITER_SET_OPTION_TYPES.SCITER_SET_DEBUG_OUTPUT, cast(UINT_PTR) _output_debug);
}

private extern (C) void _output_debug(void* param, UINT subsystem, UINT severity, LPCWSTR text, UINT text_length)
{
    output(cast(OUTPUT_SUBSYTEMS) subsystem, cast(OUTPUT_SEVERITY) severity, text[0 .. text_length]);
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

private void output(OUTPUT_SUBSYTEMS subsystem, OUTPUT_SEVERITY severity, const(wchar)[] text)
{
    writef("%s [%s]: %s", severity_to_string(severity), subsystem_to_string(subsystem), text);
}
