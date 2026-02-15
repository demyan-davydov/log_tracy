module dlt_core.dlf_filter_serialization;

import dlt_core.dlf_filter_record;
import dlt_core.log_item;
import dlt_core.dlt_protocol;
import dxml.dom;
import std.stdio : writeln;
import std.array : appender;
import std.conv : to;
import std.range;

import std.file : write, readText;

void saveDlf(string filename, const DlfFilterRecord[] filters)
{
    auto sb = appender!string;
    sb.put("<dltfilter>\n");
    foreach (ref f; filters)
    {
        sb.put(toXml(f));
        sb.put("\n");
    }
    sb.put("</dltfilter>");

    // std.file.write takes void[], string is compatible
    write(filename, sb.data);
}

DlfFilterRecord[] loadDlf(string filename)
{
    string content = readText(filename);
    DlfFilterRecord[] filters;

    try
    {
        auto dom = parseDOM(content);
        // Root should be dltfilter, usually
        // But dxml parseDOM returns a "root" pseudo-element containing the document elements

        // Find dltfilter node
        DOMEntity!string rootNode;
        bool foundRoot = false;

        foreach (child; dom.children)
        {
            if (child.name == "dltfilter")
            {
                rootNode = child;
                foundRoot = true;
                break;
            }
        }

        if (!foundRoot)
        {
            // Fallback: maybe the file is just one <filter> or root is implicit? 
            // Standard DLF starts with <dltfilter>
            // Let's try iterating top level children if they are <filter>
            foreach (child; dom.children)
            {
                if (child.name == "filter")
                {
                    filters ~= fromXml(child);
                }
            }
            return filters;
        }

        // Iterate children of <dltfilter>
        foreach (child; rootNode.children)
        {
            if (child.name == "filter")
            {
                filters ~= fromXml(child);
            }
        }
    }
    catch (Exception e)
    {
        writeln("Error loading DLF: ", e.msg);
        throw e; // Rethrow or handle? For now rethrow or empty?
    }

    return filters;
}

string toXml(const DlfFilterRecord record)
{
    auto sb = appender!string;
    sb.put("<filter>\n");

    // Helper specifically for DLT XML booleans (0/1)
    static string b2s(bool b)
    {
        return b ? "1" : "0";
    }

    // Helper to check if a SumType value is actually holding a Regex type
    static bool isRegex(T)(const T t)
    {
        return t.value.isRegex;
    }

    sb.put("  <type>" ~ record.type
            .to!int
            .to!string ~ "</type>\n");
    sb.put("  <name>" ~ record.name ~ "</name>\n");
    sb.put("  <ecuid>" ~ record.ecuId.value ~ "</ecuid>\n");
    sb.put("  <applicationid>" ~ record.applicationId.value.asString() ~ "</applicationid>\n");
    sb.put("  <contextid>" ~ record.contextId.value.asString() ~ "</contextid>\n");
    sb.put("  <headertext>" ~ record.headerText.value.asString() ~ "</headertext>\n");
    sb.put("  <payloadtext>" ~ record.payloadText.value.asString() ~ "</payloadtext>\n");

    sb.put("  <regex_search>" ~ record.regexSearch.value.asString() ~ "</regex_search>\n");
    sb.put("  <regex_replace>" ~ record.regexReplace.value.asString() ~ "</regex_replace>\n");

    sb.put("  <messageIdMin>" ~ record.messageId.value.min.to!string ~ "</messageIdMin>\n");
    sb.put("  <messageIdMax>" ~ record.messageId.value.max.to!string ~ "</messageIdMax>\n");

    sb.put("  <enableregexp_Appid>" ~ b2s(isRegex(record.applicationId)) ~ "</enableregexp_Appid>\n");
    sb.put("  <enableregexp_Context>" ~ b2s(isRegex(record.contextId)) ~ "</enableregexp_Context>\n");
    sb.put("  <enableregexp_Header>" ~ b2s(isRegex(record.headerText)) ~ "</enableregexp_Header>\n");
    sb.put("  <enableregexp_Payload>" ~ b2s(
            isRegex(record.payloadText)) ~ "</enableregexp_Payload>\n");

    sb.put("  <ignoreCase_Header>" ~ b2s(
            record.headerText.caseInsensitive) ~ "</ignoreCase_Header>\n");
    sb.put("  <ignoreCase_Payload>" ~ b2s(
            record.payloadText.caseInsensitive) ~ "</ignoreCase_Payload>\n");

    sb.put("  <enablefilter>" ~ b2s(record.enabled) ~ "</enablefilter>\n");
    sb.put("  <enableecuid>" ~ b2s(record.ecuId.enabled) ~ "</enableecuid>\n");
    sb.put("  <enableapplicationid>" ~ b2s(
            record.applicationId.enabled) ~ "</enableapplicationid>\n");
    sb.put("  <enablecontextid>" ~ b2s(record.contextId.enabled) ~ "</enablecontextid>\n");
    sb.put("  <enableheadertext>" ~ b2s(record.headerText.enabled) ~ "</enableheadertext>\n");
    sb.put("  <enablepayloadtext>" ~ b2s(record.payloadText.enabled) ~ "</enablepayloadtext>\n");
    sb.put("  <enablectrlmsgs>" ~ b2s(record.enableCtrlMsgs) ~ "</enablectrlmsgs>\n");

    sb.put("  <enableLogLevelMin>" ~ b2s(record.logLevel.enabled) ~ "</enableLogLevelMin>\n");
    sb.put("  <enableLogLevelMax>" ~ b2s(record.logLevel.enabled) ~ "</enableLogLevelMax>\n");
    sb.put("  <enableMarker>" ~ b2s(record.enableMarker) ~ "</enableMarker>\n");
    sb.put("  <enableMessageId>" ~ b2s(record.messageId.enabled) ~ "</enableMessageId>\n");

    sb.put("  <enableRegexSearchReplace>" ~ b2s(
            record.regexSearch.enabled) ~ "</enableRegexSearchReplace>\n");

    sb.put("  <filterColour>" ~ record.filterColour ~ "</filterColour>\n");

    sb.put("  <logLevelMax>" ~ record.logLevel
            .value
            .max
            .to!int
            .to!string ~ "</logLevelMax>\n");
    sb.put("  <logLevelMin>" ~ record.logLevel
            .value
            .min
            .to!int
            .to!string ~ "</logLevelMin>\n");

    sb.put("</filter>");
    return sb.data;
}

DlfFilterRecord fromXml(DOMEntity!string filterNode)
{
    DlfFilterRecord config;

    // Helper to extract text from a child node
    string getChildText(string tagName)
    {
        foreach (child; filterNode.children)
        {
            if (child.name == tagName && !child.children.empty)
            {
                // Assuming text is the first child of the element
                auto textNode = child.children[0];
                if (textNode.type == EntityType.text)
                    return textNode.text;
            }
        }
        return "";
    }

    bool getBool(string tagName)
    {
        return getChildText(tagName) == "1";
    }

    config.enabled = getBool("enablefilter");
    config.name = getChildText("name");

    try
    {
        string typeStr = getChildText("type");
        if (typeStr.length > 0)
            config.type = cast(MessageType) typeStr.to!int;
    }
    catch (Exception e)
    {
    } // Use default

    config.ecuId.value = getChildText("ecuid");
    config.ecuId.enabled = getBool("enableecuid");

    // Application ID
    bool appIdRegex = getBool("enableregexp_Appid");
    string appIdStr = getChildText("applicationid");
    config.applicationId.enabled = getBool("enableapplicationid");
    if (appIdRegex)
        config.applicationId.value.setRegex(appIdStr);
    else
        config.applicationId.value.setPattern(appIdStr);

    // Context ID
    bool ctxIdRegex = getBool("enableregexp_Context");
    string ctxIdStr = getChildText("contextid");
    config.contextId.enabled = getBool("enablecontextid");
    if (ctxIdRegex)
        config.contextId.value.setRegex(ctxIdStr);
    else
        config.contextId.value.setPattern(ctxIdStr);

    // Header Text
    bool headRegex = getBool("enableregexp_Header");
    string headStr = getChildText("headertext");
    config.headerText.enabled = getBool("enableheadertext");
    config.headerText.caseInsensitive = getBool("ignoreCase_Header"); // Note: XML key might differ slightly? Copied from example.
    if (headRegex)
        config.headerText.value.setRegex(headStr);
    else
        config.headerText.value.setPattern(headStr);

    // Payload Text
    bool payRegex = getBool("enableregexp_Payload");
    string payStr = getChildText("payloadtext");
    config.payloadText.enabled = getBool("enablepayloadtext");
    config.payloadText.caseInsensitive = getBool("ignoreCase_Payload");
    if (payRegex)
        config.payloadText.value.setRegex(payStr);
    else
        config.payloadText.value.setPattern(payStr);

    // Regex Search/Replace
    config.regexSearch.enabled = getBool("enableRegexSearchReplace");
    config.regexSearch.value.setRegex(getChildText("regex_search")); // Usually always regex if used

    config.regexReplace.enabled = config.regexSearch.enabled;
    config.regexReplace.value.setPattern(getChildText("regex_replace")); // Replace string isn't a regex itself usually, but a substitution string

    // Message ID
    config.messageId.enabled = getBool("enableMessageId");
    try
    {
        config.messageId.value.min = getChildText("messageIdMin").to!uint;
        config.messageId.value.max = getChildText("messageIdMax").to!uint;
    }
    catch (Exception e)
    {
    }

    // Log Level
    config.logLevel.enabled = getBool("enableLogLevelMin"); // Assuming single enable for range
    try
    {
        // DLT Viewer XML example has min/max reversed or uses integer values directly.
        // Our struct uses LogLevel enum.
        string minStr = getChildText("logLevelMin");
        string maxStr = getChildText("logLevelMax");
        if (minStr.length > 0)
            config.logLevel.value.min = cast(LogLevel) minStr.to!int;
        if (maxStr.length > 0)
            config.logLevel.value.max = cast(LogLevel) maxStr.to!int;
    }
    catch (Exception e)
    {
    }

    config.enableMarker = getBool("enableMarker");
    config.enableCtrlMsgs = getBool("enableCtrlMsgs");
    config.filterColour = getChildText("filterColour");

    return config;
}

unittest
{
    import std.stdio : writeln;

    writeln("Test Serialization/Deserialization (Comprehensive)");

    DlfFilterRecord original;
    original.enabled = true;
    original.name = "Comprehensive Filter";
    original.type = MessageType.Control; // Non-default
    original.filterColour = "#123456";

    // String fields
    original.ecuId.value = "ECU_TEST";
    original.ecuId.enabled = true;

    // Application ID (Regex)
    original.applicationId.enabled = true;
    original.applicationId.value.setRegex("APP.*");

    // Context ID (String)
    original.contextId.enabled = false;
    original.contextId.value.setPattern("CTX1");

    // Header Text (Case Insensitive Regex)
    original.headerText.enabled = true;
    original.headerText.caseInsensitive = true;
    original.headerText.value.setRegex("Head.*");

    // Payload Text (Case Sensitive String)
    original.payloadText.enabled = true;
    original.payloadText.caseInsensitive = false;
    original.payloadText.value.setPattern("PayloadContent");

    // Message ID Range
    original.messageId.enabled = true;
    original.messageId.value.min = 100;
    original.messageId.value.max = 200;

    // Log Level Range
    original.logLevel.enabled = true;
    original.logLevel.value.min = LogLevel.Warn; //= Range!LogLevel(LogLevel.Warn, LogLevel.Verbose);
    original.logLevel.value.max = LogLevel.Verbose;

    original.enableMarker = true;
    original.enableCtrlMsgs = false;

    // Regex Search/Replace
    original.regexSearch.enabled = true;
    original.regexSearch.value.setRegex("SearchRegex");
    original.regexReplace.enabled = true;
    original.regexReplace.value.setPattern("ReplaceString");

    // 1. Serialize
    string xml = original.toXml();
    // writeln("Serialized XML:\n", xml);

    // 2. Deserialize
    DlfFilterRecord parsed;
    try
    {
        auto dom = parseDOM(xml);
        if (!dom.children.empty)
        {
            parsed = fromXml(dom.children[0]);
        }
        else
        {
            assert(false, "XML parsing resulted in empty DOM");
        }
    }
    catch (Exception e)
    {
        writeln("Deserialization failed: ", e.msg);
        assert(false, "Deserialization threw exception");
    }

    // 3. Verify Equality
    assert(parsed.enabled == original.enabled, "Enabled mismatch");
    assert(parsed.name == original.name, "Name mismatch");
    assert(parsed.type == original.type, "Type mismatch");
    assert(parsed.filterColour == original.filterColour, "Color mismatch");

    assert(parsed.ecuId.enabled == original.ecuId.enabled, "ECU Enable mismatch");
    assert(parsed.ecuId.value == original.ecuId.value, "ECU Value mismatch");

    assert(parsed.applicationId.enabled == original.applicationId.enabled);
    assert(parsed.applicationId.value.asString() == original.applicationId.value.asString());
    assert(parsed.applicationId.value.isRegex == original.applicationId.value.isRegex);

    assert(parsed.contextId.enabled == original.contextId.enabled);
    assert(parsed.contextId.value.asString() == original.contextId.value.asString());
    assert(parsed.contextId.value.isRegex == original.contextId.value.isRegex);

    assert(parsed.headerText.enabled == original.headerText.enabled);
    assert(parsed.headerText.caseInsensitive == original.headerText.caseInsensitive);
    assert(parsed.headerText.value.asString() == original.headerText.value.asString());
    assert(parsed.headerText.value.isRegex == original.headerText.value.isRegex);

    assert(parsed.payloadText.enabled == original.payloadText.enabled);
    assert(parsed.payloadText.caseInsensitive == original.payloadText.caseInsensitive);
    assert(parsed.payloadText.value.asString() == original.payloadText.value.asString());
    assert(parsed.payloadText.value.isRegex == original.payloadText.value.isRegex);

    assert(parsed.messageId.enabled == original.messageId.enabled, "MessageID enabled mismatch");
    assert(parsed.messageId.value.min == original.messageId.value.min, "MessageID min mismatch");
    assert(parsed.messageId.value.max == original.messageId.value.max, "MessageID max mismatch");

    assert(parsed.logLevel.enabled == original.logLevel.enabled, "LogLevel enabled mismatch");
    assert(parsed.logLevel.value.min == original.logLevel.value.min, "LogLevel min mismatch");
    assert(parsed.logLevel.value.max == original.logLevel.value.max, "LogLevel max mismatch");

    assert(parsed.enableMarker == original.enableMarker);
    assert(parsed.enableCtrlMsgs == original.enableCtrlMsgs);

    assert(parsed.regexSearch.enabled == original.regexSearch.enabled);
    assert(parsed.regexSearch.value.asString() == original.regexSearch.value.asString());
    // Note: regexSearch is usually parsed as regex if enabled/present

    assert(parsed.regexReplace.enabled == original.regexReplace.enabled);
    assert(parsed.regexReplace.value.asString() == original.regexReplace.value.asString());

    writeln("Serialization/Deserialization Test Passed");

}

unittest
{
    writeln("Test List Serialization (saveDlf/loadDlf)");
    string tempFile = "temp_test_filters.dlf";

    DlfFilterRecord[] filters;

    // Filter 1
    DlfFilterRecord f1;
    f1.enabled = true;
    f1.name = "Filter One";
    f1.type = MessageType.Log;
    f1.ecuId.value = "ECU1";
    f1.ecuId.enabled = true;
    filters ~= f1;

    // Filter 2
    DlfFilterRecord f2;
    f2.enabled = false;
    f2.name = "Filter Two";
    f2.type = MessageType.Control;
    f2.applicationId.value.setRegex("APP.*");
    f2.applicationId.enabled = true;
    filters ~= f2;

    // Save
    saveDlf(tempFile, filters);

    // Load
    DlfFilterRecord[] loaded = loadDlf(tempFile);

    assert(loaded.length == 2);

    assert(loaded[0].name == "Filter One");
    assert(loaded[0].ecuId.value == "ECU1");
    assert(loaded[0].type == MessageType.Log);

    assert(loaded[1].name == "Filter Two");
    assert(loaded[1].applicationId.value.asString() == "APP.*");
    assert(loaded[1].applicationId.value.isRegex == true);
    assert(loaded[1].type == MessageType.Control);

    // Cleanup
    import std.file : remove, exists;

    if (exists(tempFile))
        remove(tempFile);

    writeln("List Serialization Test Passed");
}
