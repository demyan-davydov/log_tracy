module dlt_core.dlf_parser;

import dlt_core.filter : FilterConfig;
import std.regex;
import std.string;
import std.algorithm;
import std.stdio;

/**
 * Parses DLT Viewer Filter file (.dlf)
 * Returns the first enabled filter found in the file.
 */
FilterConfig parseDlf(const(char)[] xmlContent) pure
{
    FilterConfig config;

    // Simple check to ensure it looks like XML
    if (!xmlContent.startsWith("<"))
        return config;

    try
    {
        // Find first <filter> block (non-greedy)
        // Use single-line mode 's' so . matches newlines if needed, but XML is often multiline
        auto filterParams = matchFirst(xmlContent, regex(r"<filter>(.*?)</filter>", "s"));

        if (!filterParams.empty)
        {
            auto bodyContent = filterParams[1];

            auto extract = (const(char)[] tag) {
                auto m = matchFirst(bodyContent, regex("<" ~ tag ~ ">(.*?)</" ~ tag ~ ">", "s"));
                return m.empty ? "" : m[1].strip.idup;
            };

            config.ecuId = extract("ecuid");
            config.appId = extract("appid");
            config.ctxId = extract("contextid");
            config.payloadRegex = extract("payload");

            // Clean up type/level if needed, but we only support string IDs for now
        }
    }
    catch (Exception e)
    {
        writeln("Error parsing DLF: ", e.msg);
    }

    return config;
}
