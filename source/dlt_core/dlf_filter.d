module dlt_core.dlf_filter;

import dlt_core.log_item;
import dlt_core.filter;
import std.regex;
import std.uni : toLower;

private struct Enableable(T)
{
    T value;
    bool enabled = false;

    bool matches(V)(in const(V) other) const
    {
        if (enabled)
        {
            static if (__traits(compiles, value.matches(other)))
                return value.matches(other);
            else
                return value == other;
        }
        else
            return true;
    }
}

private struct RegexPattern
{
    private string _pattern;
    private Regex!char _regex;
    private bool _isRegex = false;

    bool isRegex() const pure nothrow @nogc @property
    {
        return _isRegex;
    }

    void setPattern(string pattern)
    {
        this._pattern = pattern;
        this._isRegex = false;
    }

    void setRegex(string regexString)
    {
        this._regex = regex(regexString);
        this._pattern = regexString;
        this._isRegex = true;
    }

    bool matches(string other) const
    {
        if (!_isRegex)
            return _pattern == other;

        return !matchFirst(other, _regex).empty;
    }

    bool matches(string other, bool caseInsensitive) const
    {
        if (!_isRegex)
            return (caseInsensitive) ? _pattern.toLower() == other.toLower() : _pattern == other;

        return !matchFirst(other, _regex).empty;
    }

    string asString() const
    {
        return _pattern;
    }
}

private struct EnableableRegex
{
    //SumType!(string, Regex!char) value;
    RegexPattern value;
    bool enabled = false;

    bool matches(in const(string) other) const
    {
        if (!enabled)
            return true;

        return value.matches(other);
    }
}

private struct EnableableRegexWithCase
{
    //SumType!(string, Regex!char) value;
    RegexPattern value;
    bool enabled = false;
    bool caseInsensitive = false;

    bool matches(in const(string) other) const
    {
        if (!enabled)
            return true;

        return value.matches(other, caseInsensitive);
    }

    alias value this;
}

private struct Range(T)
{
    T min;
    T max;

    bool matches(in const(T) value) const pure nothrow @nogc
    {
        return value >= min && value <= max;
    }
}

/** Example: 
    <filter>
        <type>0</type>
        <name>Cerence Drive Framework Error</name>
        <ecuid></ecuid>
        <applicationid>DDFW</applicationid>
        <contextid></contextid>
        <headertext></headertext>
        <payloadtext>CTRL ERRO</payloadtext>
        <regex_search></regex_search>
        <regex_replace></regex_replace>
        <messageIdMin>0</messageIdMin>
        <messageIdMax>0</messageIdMax>
        <enableregexp_Appid>0</enableregexp_Appid>
        <enableregexp_Context>0</enableregexp_Context>
        <enableregexp_Header>0</enableregexp_Header>
        <enableregexp_Payload>0</enableregexp_Payload>
        <ignoreCase_Header>0</ignoreCase_Header>
        <ignoreCase_Payload>0</ignoreCase_Payload>
        <enablefilter>1</enablefilter>
        <enableecuid>0</enableecuid>
        <enableapplicationid>1</enableapplicationid>
        <enablecontextid>0</enablecontextid>
        <enableheadertext>0</enableheadertext>
        <enablepayloadtext>1</enablepayloadtext>
        <enablectrlmsgs>0</enablectrlmsgs>
        <enableLogLevelMin>0</enableLogLevelMin>
        <enableLogLevelMax>0</enableLogLevelMax>
        <enableMarker>1</enableMarker>
        <enableMessageId>0</enableMessageId>
        <enableRegexSearchReplace>0</enableRegexSearchReplace>
        <filterColour>#ff0000</filterColour>
        <logLevelMax>0</logLevelMax>
        <logLevelMin>0</logLevelMin>
    </filter>
*/

struct DlfFilterRecord
{
    bool enabled;
    string name;

    LogType type;

    Enableable!string ecuId;
    Enableable!(Range!uint) messageId;
    Enableable!(Range!LogLevel) logLevel;

    EnableableRegex applicationId;
    EnableableRegex contextId;
    EnableableRegexWithCase headerText;
    EnableableRegexWithCase payloadText;

    EnableableRegex regexSearch;
    EnableableRegex regexReplace;

    invariant
    {
        assert(regexSearch.enabled == regexReplace.enabled);
    }

    bool enableMarker;
    bool enableCtrlMsgs;

    string filterColour; // is RGB like #ff0000, but stored as string
}

bool isMatched(ulong index, in const(LogItem) item, in const(DlfFilterRecord) config)
{
    if (!config.enabled)
        return true;

    // ECU ID
    if (!config.ecuId.matches(item.ecu))
        return false;

    // Message ID
    if (!config.messageId.matches(item.messageId))
        return false;

    // Log level
    if (!config.logLevel.matches(item.level))
        return false;

    // Application ID
    if (!config.applicationId.matches(item.appId))
        return false;

    // Context ID
    if (!config.contextId.matches(item.ctxId))
        return false;

    // Header text - skipped
    /*
    if (!config.headerText.matches(item.headerText))
        return false;
    */

    // Payload text
    if (!config.payloadText.matches(item.payload))
        return false;

    // Regex search replace - skipped
    //if (!config.regexSearch.matches(item.payload))
    //    return false;

    // Regex replace - skipped
    //if (!config.regexReplace.matches(item.payload))
    //    return false;

    return true;
}

final class DlfFilter : LogFilter
{
    DlfFilterRecord record;

    this(DlfFilterRecord rec)
    {
        this.record = rec;
    }

    override bool matches(in const(LogItem) item) const
    {
        try
        {
            return isMatched(cast(uint) item.index, item, record);
        }
        catch (Exception e)
        {
            // Exceptions in regex matching or other pure functions (unlikely but possible if not protected)
            return false;
        }
    }
}

unittest
{
    import std.stdio : writeln;

    writeln("Test RegexPattern");

    RegexPattern pattern;
    pattern.setPattern("Test");
    assert(pattern.matches("Test"));
    assert(!pattern.matches("Test2"));
    assert(pattern.isRegex == false);
    assert(pattern.asString() == "Test");

    pattern.setRegex("Test.*2");
    assert(pattern.matches("Test2"));
    assert(!pattern.matches("Test"));
    assert(pattern.isRegex == true);
    assert(pattern.asString() == "Test.*2");

    writeln("RegexPattern is ok");
}

unittest
{
    import std.stdio;

    DlfFilterRecord record;
    record.enabled = true;
    record.name = "Test Filter";
    record.type = LogType.Log;
    record.ecuId.value = "Test ECU";
    record.ecuId.enabled = true;
    record.applicationId.value.setPattern("Test App");
    record.applicationId.enabled = true;
    record.contextId.value.setPattern("Test Context");
    record.contextId.enabled = true;
    record.headerText.value.setPattern("Test Header");
    record.headerText.enabled = true;
    record.payloadText.value.setPattern("Test Payload");
    record.payloadText.enabled = true;
    record.regexSearch.value.setPattern("Test Regex");
    record.regexSearch.enabled = true;
    record.regexReplace.value.setPattern("Test Regex Replace");
    record.regexReplace.enabled = true;
    record.messageId.value = Range!uint(0, 100);
    record.messageId.enabled = true;
    record.logLevel.value = Range!LogLevel(LogLevel.Error, LogLevel.Info);
    record.logLevel.enabled = true;
    record.enableMarker = true;
    record.enableCtrlMsgs = true;
    record.filterColour = "#ff0000";

    LogItem item;
    item.index = 0;
    item.ecu = "Test ECU";
    item.appId = "Test App";
    item.ctxId = "Test Context";
    //item.headerText = "Test Header";
    item.payload = "Test Payload";
    item.messageId = 0;
    item.level = LogLevel.Info;

    assert(isMatched(item.index, item, record));
}
