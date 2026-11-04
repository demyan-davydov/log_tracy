module formats.dlt.dlf;

//! Import of the filter files of dlt-viewer (.dlf) into filter rules on the
//! columns of DltFormat. A .dlf filter becomes a rule with the same meaning as
//! in dlt-viewer (qdlt/qdltfilter.cpp, QDltFilter::match):
//!   type 0/1/2         -> include / exclude / marker
//!   ecuid              -> ecu equals
//!   applicationid      -> app equals, or regex
//!   contextid          -> ctx contains, or regex
//!   payloadtext        -> payload contains, or regex; in any case if asked
//!   messageId min..max -> msgid equals min if max is 0, else min <= id < max
//!   ctrl messages      -> type is CTRL
//!   log level min/max  -> level range (records without a level are out)
//! The header text has no column: such a rule gets a problem and isn't applied.
//! The regex search/replace changes how the payload is shown, not what is
//! shown, so it is ignored.

import log_core.log_format : LogFormat;
import log_core.rule_filter;

//! @returns true if the rules of a .dlf apply to the logs of `format`: they
//! refer to the columns of DltFormat
bool canLoadDlf(const(LogFormat) format) pure nothrow @nogc
{
    import formats.dlt.format : DltFormat;

    return cast(const(DltFormat)) format !is null;
}

//! @brief Reads a .dlf file
//! @throws Exception if the file can't be read or isn't a .dlf
FilterSet loadDlf(string path)
{
    import std.file : readText;
    import std.path : baseName;

    return parseDlf(readText(path), baseName(path), path);
}

//! @brief Parses the content of a .dlf
//! @throws Exception if it isn't the XML of a .dlf
FilterSet parseDlf(string xml, string name, string path)
{
    import dxml.dom : EntityType, parseDOM;

    FilterSet set;
    set.name = name;
    set.path = path;

    auto dom = parseDOM(xml); // throws XMLParsingException
    foreach (root; dom.children)
    {
        if (root.type != EntityType.elementStart && root.type != EntityType.elementEmpty)
            continue;
        if (root.name != "dltfilter")
            break;
        if (root.type == EntityType.elementStart)
            foreach (child; root.children)
                if (child.type == EntityType.elementStart && child.name == "filter")
                    set.rules ~= parseFilter(child);
        return set;
    }
    throw new Exception("not a dlt-viewer filter file: no <dltfilter>");
}

//! A <filter> of a .dlf as a rule, see the module comment
private FilterRule parseFilter(Entity)(Entity filter)
{
    import dxml.dom : EntityType;
    import dxml.util : decodeXML;
    import log_core.log_level : LogLevel;
    import std.conv : to;
    import std.string : strip;

    // The tags of the filter: the text of each, decoded
    string[string] tags;
    foreach (child; filter.children)
    {
        if (child.type == EntityType.elementEmpty)
            tags[child.name] = "";
        else if (child.type == EntityType.elementStart)
        {
            string text;
            foreach (part; child.children)
                if (part.type == EntityType.text)
                    text ~= decodeXML(part.text);
            tags[child.name] = text;
        }
    }

    string text(string tag)
    {
        return tags.get(tag, "");
    }

    bool flag(string tag)
    {
        return text(tag).strip == "1";
    }

    long number(string tag, long otherwise = 0)
    {
        try
            return text(tag).strip.to!long;
        catch (Exception)
            return otherwise;
    }

    FilterRule rule;
    rule.name = text("name");
    rule.enabled = flag("enablefilter");
    rule.color = text("filterColour");
    switch (number("type"))
    {
    case 1:
        rule.kind = RuleKind.Exclude;
        break;
    case 2:
        rule.kind = RuleKind.Marker;
        break;
    default:
        rule.kind = RuleKind.Include;
        break;
    }

    void add(string columnId, Check check, string value, long min = 0, long max = 0,
        bool ignoreCase = false)
    {
        rule.conditions ~= Condition(columnId, check, value, min, max, ignoreCase);
    }

    // The legacy <enableregexp> was the flag of the ids and the header
    const legacyRegex = flag("enableregexp");
    bool regexOf(string tag)
    {
        return tag in tags ? flag(tag) : legacyRegex;
    }

    if (flag("enableecuid"))
        add("ecu", Check.Equals, text("ecuid"));
    if (flag("enableapplicationid"))
        add("app", regexOf("enableregexp_Appid") ? Check.Regex : Check.Equals, text("applicationid"));
    if (flag("enablecontextid"))
        add("ctx", regexOf("enableregexp_Context") ? Check.Regex : Check.Contains, text("contextid"));
    if (flag("enableheadertext"))
        rule.problem = "the header text can't be filtered yet";
    if (flag("enablepayloadtext"))
        add("payload", flag("enableregexp_Payload") ? Check.Regex : Check.Contains,
            text("payloadtext"), 0, 0, flag("ignoreCase_Payload"));
    if (flag("enableMessageId"))
    {
        const min = number("messageIdMin"), max = number("messageIdMax");
        if (max == 0)
            add("msgid", Check.Equals, "", min, min);
        else
            add("msgid", Check.Range, "", min, max - 1);
    }
    if (flag("enablectrlmsgs"))
        add("type", Check.Equals, "CTRL");
    const levelMin = flag("enableLogLevelMin"), levelMax = flag("enableLogLevelMax");
    if (levelMin || levelMax)
        add("level", Check.Range, "",
            levelMin ? number("logLevelMin", LogLevel.Fatal) : LogLevel.Fatal,
            levelMax ? number("logLevelMax", LogLevel.Verbose) : LogLevel.Verbose);
    return rule;
}

// ─── Tests ──────────────────────────────────────────────────────────────────

version (unittest)
{
    import formats.dlt.format : DltFormat;
    import log_core.log_level : LogLevel;

    //! A .dlf of the given <filter> bodies
    private string dlf(string[] filters...)
    {
        string xml = `<?xml version="1.0" encoding="UTF-8"?>` ~ "\n<dltfilter>\n";
        foreach (f; filters)
            xml ~= "<filter>" ~ f ~ "</filter>\n";
        return xml ~ "</dltfilter>\n";
    }

    private FilterRule onlyRule(string filter)
    {
        auto set = parseDlf(dlf(filter), "test.dlf", "/tmp/test.dlf");
        assert(set.rules.length == 1);
        return set.rules[0];
    }

    private Condition onlyCondition(string filter)
    {
        auto rule = onlyRule(filter);
        assert(rule.conditions.length == 1, "one condition");
        return rule.conditions[0];
    }
}

@("parseDlf: the set and its rules: name, kind, enabled, color")
unittest
{
    auto set = parseDlf(dlf(
            "<type>0</type><name>Positive</name><enablefilter>1</enablefilter><filterColour>#ff0000</filterColour>",
            "<type>1</type><name>Negative</name><enablefilter>0</enablefilter>",
            "<type>2</type><name>Marker</name><enablefilter>1</enablefilter>"),
        "my.dlf", "/logs/my.dlf");
    assert(set.name == "my.dlf" && set.path == "/logs/my.dlf" && set.enabled);
    assert(set.rules.length == 3);
    assert(set.rules[0].name == "Positive" && set.rules[0].kind == RuleKind.Include);
    assert(set.rules[0].enabled && set.rules[0].color == "#ff0000");
    assert(set.rules[1].kind == RuleKind.Exclude && !set.rules[1].enabled);
    assert(set.rules[2].kind == RuleKind.Marker);
    foreach (ref rule; set.rules)
        assert(rule.conditions.length == 0 && rule.problem == "");
}

@("parseDlf: only the enabled fields become conditions")
unittest
{
    auto rule = onlyRule("<ecuid>ECU1</ecuid><enableecuid>0</enableecuid>"
            ~ "<applicationid>APP</applicationid><enableapplicationid>0</enableapplicationid>");
    assert(rule.conditions.length == 0);
}

@("parseDlf: ids: ecu equals, app equals or regex, ctx contains or regex")
unittest
{
    auto ecu = onlyCondition("<ecuid>ECU1</ecuid><enableecuid>1</enableecuid>");
    assert(ecu.columnId == "ecu" && ecu.check == Check.Equals && ecu.text == "ECU1");

    auto app = onlyCondition("<applicationid>APP</applicationid><enableapplicationid>1</enableapplicationid>");
    assert(app.columnId == "app" && app.check == Check.Equals && app.text == "APP");
    app = onlyCondition("<applicationid>A.P</applicationid><enableapplicationid>1</enableapplicationid>"
            ~ "<enableregexp_Appid>1</enableregexp_Appid>");
    assert(app.check == Check.Regex && app.text == "A.P");

    auto ctx = onlyCondition("<contextid>CT</contextid><enablecontextid>1</enablecontextid>");
    assert(ctx.columnId == "ctx" && ctx.check == Check.Contains && ctx.text == "CT");
    ctx = onlyCondition("<contextid>^C</contextid><enablecontextid>1</enablecontextid>"
            ~ "<enableregexp_Context>1</enableregexp_Context>");
    assert(ctx.check == Check.Regex);
}

@("parseDlf: the legacy enableregexp makes the ids regular expressions")
unittest
{
    auto app = onlyCondition("<applicationid>A.P</applicationid><enableapplicationid>1</enableapplicationid>"
            ~ "<enableregexp>1</enableregexp>");
    assert(app.check == Check.Regex);
}

@("parseDlf: payload contains or regex, in any case if asked; XML entities are decoded")
unittest
{
    auto payload = onlyCondition("<payloadtext>a &amp; b</payloadtext><enablepayloadtext>1</enablepayloadtext>");
    assert(payload.columnId == "payload" && payload.check == Check.Contains);
    assert(payload.text == "a & b" && !payload.ignoreCase);

    payload = onlyCondition("<payloadtext>x&lt;y</payloadtext><enablepayloadtext>1</enablepayloadtext>"
            ~ "<enableregexp_Payload>1</enableregexp_Payload><ignoreCase_Payload>1</ignoreCase_Payload>");
    assert(payload.check == Check.Regex && payload.text == "x<y" && payload.ignoreCase);
}

@("parseDlf: message id: the value if max is 0, else min <= id < max")
unittest
{
    auto id = onlyCondition("<enableMessageId>1</enableMessageId><messageIdMin>7</messageIdMin><messageIdMax>0</messageIdMax>");
    assert(id.columnId == "msgid" && id.check == Check.Equals && id.min == 7);

    id = onlyCondition("<enableMessageId>1</enableMessageId><messageIdMin>7</messageIdMin><messageIdMax>10</messageIdMax>");
    assert(id.check == Check.Range && id.min == 7 && id.max == 9);
}

@("parseDlf: control messages and log levels")
unittest
{
    auto ctrl = onlyCondition("<enablectrlmsgs>1</enablectrlmsgs>");
    assert(ctrl.columnId == "type" && ctrl.check == Check.Equals && ctrl.text == "CTRL");

    auto levels = onlyCondition("<enableLogLevelMin>1</enableLogLevelMin><enableLogLevelMax>1</enableLogLevelMax>"
            ~ "<logLevelMax>2</logLevelMax><logLevelMin>1</logLevelMin>");
    assert(levels.columnId == "level" && levels.check == Check.Range);
    assert(levels.min == LogLevel.Fatal && levels.max == LogLevel.Error);

    auto max = onlyCondition("<enableLogLevelMax>1</enableLogLevelMax><logLevelMax>3</logLevelMax><logLevelMin>5</logLevelMin>");
    assert(max.min == LogLevel.Fatal && max.max == LogLevel.Warn, "min not enabled: from Fatal");
    auto min = onlyCondition("<enableLogLevelMin>1</enableLogLevelMin><logLevelMin>4</logLevelMin>");
    assert(min.min == LogLevel.Info && min.max == LogLevel.Verbose, "max not enabled: to Verbose");
}

@("parseDlf: the header text is a problem of the rule, not dropped silently")
unittest
{
    auto rule = onlyRule("<headertext>X</headertext><enableheadertext>1</enableheadertext>");
    assert(rule.problem.length);
    assert(onlyRule("<headertext>X</headertext><enableheadertext>0</enableheadertext>").problem == "");
}

@("parseDlf: all the conditions of a filter, every one applies to DltFormat")
unittest
{
    auto rule = onlyRule("<ecuid>ECU1</ecuid><enableecuid>1</enableecuid>"
            ~ "<applicationid>APP</applicationid><enableapplicationid>1</enableapplicationid>"
            ~ "<contextid>CTX</contextid><enablecontextid>1</enablecontextid>"
            ~ "<payloadtext>err</payloadtext><enablepayloadtext>1</enablepayloadtext>"
            ~ "<enableMessageId>1</enableMessageId><messageIdMin>7</messageIdMin>"
            ~ "<enablectrlmsgs>1</enablectrlmsgs>"
            ~ "<enableLogLevelMax>1</enableLogLevelMax><logLevelMax>2</logLevelMax>");
    assert(rule.conditions.length == 7);
    assert(ruleError(new DltFormat().columns, rule) == "");
}

@("parseDlf: a file of dlt-viewer (filters/error_fatal_messages.dlf)")
unittest
{
    auto set = parseDlf(`<?xml version="1.0" encoding="UTF-8"?>
<dltfilter>
    <filter>
        <type>0</type>
        <name>Error/Fatal Messages</name>
        <ecuid></ecuid>
        <applicationid></applicationid>
        <contextid></contextid>
        <headertext></headertext>
        <payloadtext></payloadtext>
        <enableregexp>0</enableregexp>
        <enablefilter>1</enablefilter>
        <enableecuid>0</enableecuid>
        <enableapplicationid>0</enableapplicationid>
        <enablecontextid>0</enablecontextid>
        <enableheadertext>0</enableheadertext>
        <enablepayloadtext>0</enablepayloadtext>
        <enablectrlmsgs>0</enablectrlmsgs>
        <enableLogLevelMin>1</enableLogLevelMin>
        <enableLogLevelMax>1</enableLogLevelMax>
        <enableLMarker>0</enableLMarker>
        <filterColour>#f0f0f0</filterColour>
        <logLevelMax>2</logLevelMax>
        <logLevelMin>1</logLevelMin>
    </filter>
</dltfilter>
`, "error_fatal_messages.dlf", "");
    assert(set.rules.length == 1);
    auto rule = set.rules[0];
    assert(rule.name == "Error/Fatal Messages" && rule.enabled && rule.kind == RuleKind.Include);
    assert(rule.conditions.length == 1 && rule.conditions[0].columnId == "level");
}

@("parseDlf: what isn't a .dlf is refused")
unittest
{
    import std.exception : assertThrown;

    assertThrown(parseDlf("not xml <", "x.dlf", ""));
    assertThrown(parseDlf("<other/>", "x.dlf", ""));
    assert(parseDlf("<dltfilter></dltfilter>", "x.dlf", "").rules.length == 0, "empty is fine");
}
