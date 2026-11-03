module dlt_core.dlt_filter_record;

import dlt_core.log_filter;
import dlt_core.dlt_protocol;
import dlt_core.decoded_message;
import std.regex;
import std.uni : toLower;
import std.utf : toUTF8, toUTF16, toUTF32;
import std.traits : isSomeChar;

immutable(Char)[] toUtf(Char)(string str) if (isSomeChar!Char)
{
    static if (is(Char == char))
    {
        return str;
    }
    else static if (is(Char == wchar))
    {
        return str.toUTF16();
    }
    else static if (is(Char == dchar))
    {
        return str.toUTF32();
    }
    else
    {
        static assert(false, "Unsupported character type: " ~ __traits(identifier, Char));
    }
}

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

private struct RegexPattern(CharType) if (isSomeChar!CharType)
{
    alias String = immutable(CharType)[];

    private String _pattern;
    private Regex!CharType _regex;
    private bool _isRegex = false;

    bool isRegex() const pure nothrow @nogc @property
    {
        return _isRegex;
    }

    void setPattern(String pattern)
    {
        this._pattern = pattern;
        this._isRegex = false;
    }

    void setRegex(String regexString)
    {
        this._regex = regex(regexString);
        this._pattern = regexString;
        this._isRegex = true;
    }

    void setPatternFromUtf8(string patternUtf8)
    {
        this._pattern = patternUtf8.toUtf!CharType;
        this._isRegex = false;
    }

    void setRegexFromUtf8(string regexStringUtf8)
    {
        this._pattern = regexStringUtf8.toUtf!CharType;
        this._regex = regex(this._pattern);
        this._isRegex = true;
    }

    bool matches(const(CharType)[] other) const
    {
        if (!_isRegex)
            return _pattern == other;

        return !matchFirst(other, _regex).empty;
    }

    bool matches(const(CharType)[] other, bool caseInsensitive) const
    {
        if (!_isRegex)
            return (caseInsensitive) ? _pattern.toLower() == other.toLower() : _pattern == other;

        return !matchFirst(other, _regex).empty;
    }

    String asString() const
    {
        return _pattern;
    }

    string asUtf8String() const
    {
        static if (is(CharType == char))
        {
            return _pattern;
        }
        else static if (is(CharType == wchar))
        {
            return _pattern.toUTF8();
        }
        else static if (is(CharType == dchar))
        {
            return _pattern.toUTF8();
        }
        else
        {
            static assert(false, "Unsupported character type");
        }
    }
}

private struct EnableableRegex(CharType) if (isSomeChar!CharType)
{
    alias String = immutable(CharType)[];

    RegexPattern!CharType value;
    bool enabled = false;

    bool matches(const(CharType)[] other) const
    {
        if (!enabled)
            return true;

        return value.matches(other);
    }

    bool isRegex() const
    {
        return value.isRegex();
    }
}

private struct EnableableRegexWithCase(CharType) if (isSomeChar!CharType)
{
    alias String = immutable(CharType)[];

    RegexPattern!CharType value;
    bool enabled = false;
    bool caseInsensitive = false;

    bool matches(const(CharType)[] other) const
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

struct DltFilterRecord(CharType : wchar) if (isSomeChar!CharType)
{
    alias String = immutable(CharType)[];

    bool enabled;
    String name;

    MessageType type;

    Enableable!String ecuId;
    Enableable!(Range!uint) messageId;
    Enableable!(Range!LogLevel) logLevel;

    EnableableRegex!CharType applicationId;
    EnableableRegex!CharType contextId;
    EnableableRegexWithCase!CharType headerText;
    EnableableRegexWithCase!CharType payloadText;

    EnableableRegex!CharType regexSearch;
    EnableableRegex!CharType regexReplace;

    invariant
    {
        assert(regexSearch.enabled == regexReplace.enabled);
    }

    bool enableMarker;
    bool enableCtrlMsgs;

    String filterColour; // is RGB like #ff0000, but stored as string
}

bool isMatched(CharType : wchar)(
    ref const(DecodedMessage!CharType) item,
    ref const(DltFilterRecord!CharType) config) if (isSomeChar!CharType)
{
    if (!config.enabled)
        return true;

    // ECU ID
    if (!config.ecuId.matches(item.ecuId))
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
    if (!config.payloadText.matches(item.payloadText))
        return false;

    // Regex search replace - skipped
    //if (!config.regexSearch.matches(item.payload))
    //    return false;

    // Regex replace - skipped
    //if (!config.regexReplace.matches(item.payload))
    //    return false;

    return true;
}

unittest
{
    import std.stdio : writeln;

    writeln("Test RegexPattern");

    RegexPattern!char pattern;
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

    DltFilterRecord!char record;
    record.enabled = true;
    record.name = "Test Filter";
    record.type = MessageType.Log;
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

    DecodedMessage!char msg;
    auto builder = msg.setupPayload("Test ECU", "Test App", "Test Context");
    builder.appendAscii("Test Payload");
    builder.storePayload();
    msg.level = LogLevel.Info;
    msg.messageId = 0;

    assert(isMatched(msg, record));
}
