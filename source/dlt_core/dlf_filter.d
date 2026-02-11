module dlt_core.dlf_filter;

import dlt_core.log_item;
import dlt_core.filter;
import std.regex;
import std.sumtype : SumType, matchSum = match;
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

    alias value this;
}

private struct EnableableRegex
{
    SumType!(string, Regex!char) value;
    bool enabled = false;

    bool matches(in const(string) other) const
    {
        if (!enabled)
            return true;

        return value.matchSum!(
            (const(Regex!char) r) { return !matchFirst(other, r).empty; },
            (const(string) s) { return s == other; }
        );
    }
}

private struct EnableableRegexWithCase
{
    SumType!(string, Regex!char) value;
    bool enabled = false;
    bool caseInsensitive = false;

    bool matches(in const(string) other) const
    {
        if (!enabled)
            return true;

        return value.matchSum!(
            (const(Regex!char) r) { return !matchFirst(other, r).empty; },
            (const(string) s) {
            return (caseInsensitive) ? s.toLower() == other.toLower() : s == other;
        }
        );
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

    // invariant (regexSearch.enabled == regexReplace.enabled);

    bool enableMarker;
    bool enableCtrlMsgs;

    string filterColour; // is RGB like #ff0000, but stored as string
}

bool isMatched(uint index, in const(LogItem) item, in const(DlfFilterRecord) config)
{
    if (!config.enabled)
        return true;

    // ECU ID
    if (!config.ecuId.matches(item.ecu))
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

    // Regex search replace
    //if (!config.regexSearch.matches(item.payload))
    //    return false;

    // Message ID
    if (!config.messageId.matches(item.messageId))
        return false;

    // Log level
    if (!config.logLevel.matches(item.level))
        return false;

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
