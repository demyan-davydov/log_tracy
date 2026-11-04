module formats.dlt.dlf;

//! The filter files of dlt-viewer (.dlf): read as DlfFilters with all the
//! fields of dlt-viewer, written in the layout of dlt-viewer, and turned into
//! filter rules on the columns of DltFormat and back (fromDlf, toDlf). A filter becomes a rule with the same meaning as in
//! dlt-viewer (qdlt/qdltfilter.cpp, QDltFilter::match):
//!   type 0/1/2         -> include / exclude / marker
//!   ecuid              -> ecu equals
//!   applicationid      -> app equals, or regex
//!   contextid          -> ctx contains, or regex
//!   payloadtext        -> payload contains, or regex; in any case if asked
//!   messageId min..max -> msgid equals min if max is 0, else min <= id < max
//!   ctrl messages      -> type is CTRL
//!   log level min/max  -> level range (records without a level are out)
//!   headertext         -> header contains, or regex: no log has this column
//!                         yet, so such a rule is kept but not applied
//! The regex search/replace changes how the payload is shown, not what is
//! shown: it isn't kept (fromDlf says so). toDlf writes rules back, dropping
//! and naming the conditions a .dlf can't hold.

import log_core.log_format : LogFormat;
import log_core.rule_filter;

//! @returns true if the rules of a .dlf apply to the logs of `format`: they
//! refer to the columns of DltFormat
bool canLoadDlf(const(LogFormat) format) pure nothrow @nogc
{
    import formats.dlt.format : DltFormat;

    return cast(const(DltFormat)) format !is null;
}

//! A filter of dlt-viewer as a .dlf holds it (QDltFilter): what the rule
//! editor edits and what is written back. The defaults are those of
//! dlt-viewer (QDltFilter::clear) but the name and the switch.
struct DlfFilter
{
    int type; // 0 positive, 1 negative, 2 marker
    string name;
    string ecuId, appId, ctxId, header, payload, regexSearch, regexReplace;
    uint messageIdMin, messageIdMax;
    bool regexApp, regexCtx, regexHeader, regexPayload;
    bool ignoreCaseHeader, ignoreCasePayload;
    bool enabled = true;
    bool enableEcu, enableApp, enableCtx, enableHeader, enablePayload, enableCtrl;
    bool enableLevelMin, enableLevelMax, enableMarker, enableMessageId, enableRegexSearchReplace;
    string color = "#000000";
    int levelMax = 6;
    int levelMin = 0;
}

//! @brief Reads the filters of a .dlf file
//! @throws Exception if the file can't be read or isn't a .dlf
DlfFilter[] readDlf(string path)
{
    import std.file : readText;

    return parseDlfFilters(readText(path));
}

//! @brief Writes the filters to a .dlf file
//! @throws Exception if the file can't be written
void writeDlf(string path, const(DlfFilter)[] filters)
{
    import std.file : write;

    write(path, toDlfXml(filters));
}

//! @brief Parses the filters of a .dlf
//! @throws Exception if it isn't the XML of a .dlf
DlfFilter[] parseDlfFilters(string xml)
{
    import dxml.dom : EntityType, parseDOM;

    auto dom = parseDOM(xml); // throws XMLParsingException
    foreach (root; dom.children)
    {
        if (root.type != EntityType.elementStart && root.type != EntityType.elementEmpty)
            continue;
        if (root.name != "dltfilter")
            break;
        DlfFilter[] filters;
        if (root.type == EntityType.elementStart)
            foreach (child; root.children)
                if (child.type == EntityType.elementStart && child.name == "filter")
                    filters ~= parseFilter(child);
        return filters;
    }
    throw new Exception("not a dlt-viewer filter file: no <dltfilter>");
}

//! A <filter> of a .dlf; a tag that is missing keeps the default
private DlfFilter parseFilter(Entity)(Entity element)
{
    import dxml.dom : EntityType;
    import dxml.util : decodeXML;
    import std.conv : to;
    import std.string : strip;

    // The tags of the filter: the text of each, decoded
    string[string] tags;
    foreach (child; element.children)
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

    DlfFilter f;
    void text(string tag, ref string field)
    {
        if (auto value = tag in tags)
            field = *value;
    }

    void flag(string tag, ref bool field)
    {
        if (auto value = tag in tags)
            field = strip(*value) == "1";
    }

    void number(T)(string tag, ref T field)
    {
        if (auto value = tag in tags)
        {
            try
                field = strip(*value).to!T;
            catch (Exception)
            {
            } // the default
        }
    }

    number("type", f.type);
    text("name", f.name);
    text("ecuid", f.ecuId);
    text("applicationid", f.appId);
    text("contextid", f.ctxId);
    text("headertext", f.header);
    text("payloadtext", f.payload);
    text("regex_search", f.regexSearch);
    text("regex_replace", f.regexReplace);
    number("messageIdMin", f.messageIdMin);
    number("messageIdMax", f.messageIdMax);
    // The legacy <enableregexp> was the flag of the ids and the header
    bool legacyRegex;
    flag("enableregexp", legacyRegex);
    f.regexApp = f.regexCtx = f.regexHeader = legacyRegex;
    flag("enableregexp_Appid", f.regexApp);
    flag("enableregexp_Context", f.regexCtx);
    flag("enableregexp_Header", f.regexHeader);
    flag("enableregexp_Payload", f.regexPayload);
    flag("ignoreCase_Header", f.ignoreCaseHeader);
    flag("ignoreCase_Payload", f.ignoreCasePayload);
    f.enabled = false; // a filter without the tag is off, as in dlt-viewer
    flag("enablefilter", f.enabled);
    flag("enableecuid", f.enableEcu);
    flag("enableapplicationid", f.enableApp);
    flag("enablecontextid", f.enableCtx);
    flag("enableheadertext", f.enableHeader);
    flag("enablepayloadtext", f.enablePayload);
    flag("enablectrlmsgs", f.enableCtrl);
    flag("enableLogLevelMin", f.enableLevelMin);
    flag("enableLogLevelMax", f.enableLevelMax);
    flag("enableMarker", f.enableMarker);
    flag("enableMessageId", f.enableMessageId);
    flag("enableRegexSearchReplace", f.enableRegexSearchReplace);
    text("filterColour", f.color);
    number("logLevelMax", f.levelMax);
    number("logLevelMin", f.levelMin);
    return f;
}

//! The content of a .dlf of the filters, laid out as dlt-viewer writes it
//! (QDltFilterList::SaveFilter, QDltFilter::SaveFilterItem)
string toDlfXml(const(DlfFilter)[] filters)
{
    import dxml.util : encodeText;
    import std.array : appender;
    import std.conv : to;

    auto xml = appender!string;
    xml.put(`<?xml version="1.0" encoding="UTF-8"?>` ~ "\n<dltfilter>\n");
    foreach (ref f; filters)
    {
        void tag(T)(string name, T value)
        {
            import std.traits : Unqual;

            static if (is(Unqual!T == bool))
                const text = value ? "1" : "0";
            else static if (is(T : const(char)[]))
                const text = encodeText(value).to!string;
            else
                const text = value.to!string;
            xml.put("        <" ~ name ~ ">" ~ text ~ "</" ~ name ~ ">\n");
        }

        xml.put("    <filter>\n");
        tag("type", f.type);
        tag("name", f.name);
        tag("ecuid", f.ecuId);
        tag("applicationid", f.appId);
        tag("contextid", f.ctxId);
        tag("headertext", f.header);
        tag("payloadtext", f.payload);
        tag("regex_search", f.regexSearch);
        tag("regex_replace", f.regexReplace);
        tag("messageIdMin", f.messageIdMin);
        tag("messageIdMax", f.messageIdMax);
        tag("enableregexp_Appid", f.regexApp);
        tag("enableregexp_Context", f.regexCtx);
        tag("enableregexp_Header", f.regexHeader);
        tag("enableregexp_Payload", f.regexPayload);
        tag("ignoreCase_Header", f.ignoreCaseHeader);
        tag("ignoreCase_Payload", f.ignoreCasePayload);
        tag("enablefilter", f.enabled);
        tag("enableecuid", f.enableEcu);
        tag("enableapplicationid", f.enableApp);
        tag("enablecontextid", f.enableCtx);
        tag("enableheadertext", f.enableHeader);
        tag("enablepayloadtext", f.enablePayload);
        tag("enablectrlmsgs", f.enableCtrl);
        tag("enableLogLevelMin", f.enableLevelMin);
        tag("enableLogLevelMax", f.enableLevelMax);
        tag("enableMarker", f.enableMarker);
        tag("enableMessageId", f.enableMessageId);
        tag("enableRegexSearchReplace", f.enableRegexSearchReplace);
        tag("filterColour", f.color);
        tag("logLevelMax", f.levelMax);
        tag("logLevelMin", f.levelMin);
        xml.put("    </filter>\n");
    }
    xml.put("</dltfilter>\n");
    return xml.data;
}

//! @brief The rules of the filters (see toRule)
//! @param warnings - gets what of them isn't kept, by rule: the regex replace,
//! which changes how the payload is shown
FilterRule[] fromDlf(const(DlfFilter)[] filters, ref string[] warnings)
{
    FilterRule[] rules;
    foreach (ref f; filters)
    {
        if (f.enableRegexSearchReplace)
            warnings ~= ruleTitle(f.name) ~ ": the regex replace isn't kept";
        rules ~= toRule(f);
    }
    return rules;
}

private string ruleTitle(string name)
{
    return name.length ? "\"" ~ name ~ "\"" : "a rule without a name";
}

//! @brief The filters of the rules, for a .dlf
//! @param warnings - gets the conditions a .dlf can't hold (they are dropped),
//! by rule
DlfFilter[] toDlf(const(FilterRule)[] rules, ref string[] warnings)
{
    import std.algorithm.searching : canFind;
    import std.format : format;

    DlfFilter[] filters;
    foreach (ref rule; rules)
    {
        DlfFilter f;
        f.name = rule.name;
        f.enabled = rule.enabled;
        f.type = rule.kind == RuleKind.Exclude ? 1 : rule.kind == RuleKind.Marker ? 2 : 0;
        if (rule.color.length)
            f.color = rule.color;

        string[] taken; // a .dlf holds one condition per column
        foreach (ref c; rule.conditions)
        {
            bool kept;
            if (!taken.canFind(c.columnId))
                kept = put(f, c);
            if (kept)
                taken ~= c.columnId;
            else
                warnings ~= format("%s: the condition on %s can't be written to a .dlf",
                    ruleTitle(rule.name), c.columnId);
        }
        filters ~= f;
    }
    return filters;
}

//! Puts a condition into a filter of dlt-viewer
//! @returns false if a filter can't hold it
private bool put(ref DlfFilter f, ref const(Condition) c)
{
    import log_core.log_level : LogLevel;

    const regex = c.check == Check.Regex;
    switch (c.columnId)
    {
    case "ecu":
        if (c.check != Check.Equals || c.ignoreCase)
            return false;
        f.enableEcu = true;
        f.ecuId = c.text;
        return true;
    case "app":
        if ((c.check != Check.Equals && !regex) || c.ignoreCase)
            return false;
        f.enableApp = true;
        f.regexApp = regex;
        f.appId = c.text;
        return true;
    case "ctx":
        if ((c.check != Check.Contains && !regex) || c.ignoreCase)
            return false;
        f.enableCtx = true;
        f.regexCtx = regex;
        f.ctxId = c.text;
        return true;
    case "payload":
        if (c.check != Check.Contains && !regex)
            return false;
        f.enablePayload = true;
        f.regexPayload = regex;
        f.ignoreCasePayload = c.ignoreCase;
        f.payload = c.text;
        return true;
    case "header":
        if (c.check != Check.Contains && !regex)
            return false;
        f.enableHeader = true;
        f.regexHeader = regex;
        f.ignoreCaseHeader = c.ignoreCase;
        f.header = c.text;
        return true;
    case "msgid":
        if (c.check == Check.Equals)
        {
            long id;
            try
                id = parseNumberText(c.text, false);
            catch (Exception)
                return false;
            if (id < 0 || id > uint.max)
                return false;
            f.enableMessageId = true;
            f.messageIdMin = cast(uint) id;
            f.messageIdMax = 0;
            return true;
        }
        if (c.check != Check.Range || c.min < 0 || c.max < c.min || c.max >= uint.max)
            return false;
        f.enableMessageId = true;
        f.messageIdMin = cast(uint) c.min;
        f.messageIdMax = cast(uint)(c.max + 1); // dlt-viewer: min <= id < max
        return true;
    case "type":
        if (c.check != Check.Equals || c.text != "CTRL")
            return false;
        f.enableCtrl = true;
        return true;
    case "level":
        long min = c.min, max = c.max;
        if (c.check == Check.Equals)
        {
            import std.algorithm.searching : countUntil;
            import std.uni : icmp;

            min = max = levelNames.countUntil!(name => icmp(name, c.text) == 0);
            if (min < 0)
            {
                try
                    min = max = parseNumberText(c.text, false);
                catch (Exception)
                    return false;
            }
        }
        else if (c.check != Check.Range)
            return false;
        if (min < LogLevel.None || max > LogLevel.Verbose)
            return false;
        // A side at its end is left open, as toRule makes it
        f.enableLevelMin = min > LogLevel.Fatal;
        f.levelMin = cast(int) min;
        f.enableLevelMax = max < LogLevel.Verbose || !f.enableLevelMin;
        f.levelMax = cast(int) max;
        return true;
    default:
        return false;
    }
}

//! The rule of a filter, see the module comment
FilterRule toRule(ref const(DlfFilter) f)
{
    import std.conv : to;

    import log_core.log_level : LogLevel;
    import std.algorithm.comparison : max;

    FilterRule rule;
    rule.name = f.name;
    rule.enabled = f.enabled;
    rule.color = f.color;
    rule.kind = f.type == 1 ? RuleKind.Exclude : f.type == 2 ? RuleKind.Marker : RuleKind.Include;

    void add(string columnId, Check check, string value, long min = 0, long max = 0,
        bool ignoreCase = false)
    {
        rule.conditions ~= Condition(columnId, check, value, min, max, ignoreCase);
    }

    if (f.enableEcu)
        add("ecu", Check.Equals, f.ecuId);
    if (f.enableApp)
        add("app", f.regexApp ? Check.Regex : Check.Equals, f.appId);
    if (f.enableCtx)
        add("ctx", f.regexCtx ? Check.Regex : Check.Contains, f.ctxId);
    if (f.enableHeader) // no log has the column yet: the rule isn't applied, but kept
        add("header", f.regexHeader ? Check.Regex : Check.Contains, f.header, 0, 0,
            f.ignoreCaseHeader);
    if (f.enablePayload)
        add("payload", f.regexPayload ? Check.Regex : Check.Contains, f.payload, 0, 0,
            f.ignoreCasePayload);
    if (f.enableMessageId)
    {
        if (f.messageIdMax == 0)
            add("msgid", Check.Equals, f.messageIdMin.to!string);
        else
            add("msgid", Check.Range, "", f.messageIdMin, cast(long) f.messageIdMax - 1);
    }
    if (f.enableCtrl)
        add("type", Check.Equals, "CTRL");
    // dlt-viewer checks the level of log messages only: those have a level
    if (f.enableLevelMin || f.enableLevelMax)
        add("level", Check.Range, "",
            f.enableLevelMin ? max(f.levelMin, LogLevel.Fatal) : LogLevel.Fatal,
            f.enableLevelMax ? f.levelMax : LogLevel.Verbose);
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

    //! The rules of the filters of a .dlf
    private FilterRule[] rulesOf(string xml)
    {
        import std.algorithm.iteration : map;
        import std.array : array;

        return parseDlfFilters(xml).map!((ref f) => toRule(f)).array;
    }

    private FilterRule onlyRule(string filter)
    {
        auto rules = rulesOf(dlf(filter));
        assert(rules.length == 1);
        return rules[0];
    }

    private Condition onlyCondition(string filter)
    {
        auto rule = onlyRule(filter);
        assert(rule.conditions.length == 1, "one condition");
        return rule.conditions[0];
    }
}

@("toRule: the rules of a .dlf: name, kind, enabled, color")
unittest
{
    auto rules = rulesOf(dlf(
            "<type>0</type><name>Positive</name><enablefilter>1</enablefilter><filterColour>#ff0000</filterColour>",
            "<type>1</type><name>Negative</name><enablefilter>0</enablefilter>",
            "<type>2</type><name>Marker</name><enablefilter>1</enablefilter>"));
    assert(rules.length == 3);
    assert(rules[0].name == "Positive" && rules[0].kind == RuleKind.Include);
    assert(rules[0].enabled && rules[0].color == "#ff0000");
    assert(rules[1].kind == RuleKind.Exclude && !rules[1].enabled);
    assert(rules[2].kind == RuleKind.Marker);
    foreach (ref rule; rules)
        assert(rule.conditions.length == 0 && rule.problem == "");
}

@("parseDlfFilters: only the enabled fields become conditions")
unittest
{
    auto rule = onlyRule("<ecuid>ECU1</ecuid><enableecuid>0</enableecuid>"
            ~ "<applicationid>APP</applicationid><enableapplicationid>0</enableapplicationid>");
    assert(rule.conditions.length == 0);
}

@("parseDlfFilters: ids: ecu equals, app equals or regex, ctx contains or regex")
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

@("parseDlfFilters: the legacy enableregexp makes the ids regular expressions")
unittest
{
    auto app = onlyCondition("<applicationid>A.P</applicationid><enableapplicationid>1</enableapplicationid>"
            ~ "<enableregexp>1</enableregexp>");
    assert(app.check == Check.Regex);
}

@("parseDlfFilters: payload contains or regex, in any case if asked; XML entities are decoded")
unittest
{
    auto payload = onlyCondition("<payloadtext>a &amp; b</payloadtext><enablepayloadtext>1</enablepayloadtext>");
    assert(payload.columnId == "payload" && payload.check == Check.Contains);
    assert(payload.text == "a & b" && !payload.ignoreCase);

    payload = onlyCondition("<payloadtext>x&lt;y</payloadtext><enablepayloadtext>1</enablepayloadtext>"
            ~ "<enableregexp_Payload>1</enableregexp_Payload><ignoreCase_Payload>1</ignoreCase_Payload>");
    assert(payload.check == Check.Regex && payload.text == "x<y" && payload.ignoreCase);
}

@("parseDlfFilters: message id: the value if max is 0, else min <= id < max")
unittest
{
    auto id = onlyCondition("<enableMessageId>1</enableMessageId><messageIdMin>7</messageIdMin><messageIdMax>0</messageIdMax>");
    assert(id.columnId == "msgid" && id.check == Check.Equals && id.text == "7");

    id = onlyCondition("<enableMessageId>1</enableMessageId><messageIdMin>7</messageIdMin><messageIdMax>10</messageIdMax>");
    assert(id.check == Check.Range && id.min == 7 && id.max == 9);
}

@("parseDlfFilters: control messages and log levels")
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

@("toRule: the header text is a condition on the column \"header\", which no log has yet")
unittest
{
    auto header = onlyCondition("<headertext>X</headertext><enableheadertext>1</enableheadertext>"
            ~ "<ignoreCase_Header>1</ignoreCase_Header>");
    assert(header.columnId == "header" && header.check == Check.Contains && header.text == "X");
    assert(header.ignoreCase);
    auto rule = onlyRule("<headertext>X</headertext><enableheadertext>1</enableheadertext>");
    assert(ruleError(new DltFormat().columns, rule).length, "not applied, but kept");
}

@("fromDlf: the rules of the filters, and what of them is lost")
unittest
{
    import std.algorithm.searching : canFind;

    DlfFilter plain;
    plain.name = "Plain";
    DlfFilter replace;
    replace.name = "Replacing";
    replace.enableRegexSearchReplace = true;
    replace.regexSearch = "a";
    string[] warnings;
    auto rules = fromDlf([plain, replace], warnings);
    assert(rules.length == 2 && rules[1].name == "Replacing");
    assert(warnings.length == 1 && warnings[0].canFind("Replacing"), "the regex replace isn't kept");
}

@("toDlf: the rules written to a .dlf are read back the same")
unittest
{
    DlfFilter f;
    f.type = 1;
    f.name = "All";
    f.color = "#00ff00";
    f.ecuId = "ECU1";
    f.enableEcu = true;
    f.appId = "A.P";
    f.enableApp = f.regexApp = true;
    f.ctxId = "CT";
    f.enableCtx = true;
    f.payload = "err";
    f.enablePayload = f.ignoreCasePayload = true;
    f.header = "H";
    f.enableHeader = f.regexHeader = true;
    f.enableMessageId = true;
    f.messageIdMin = 7;
    f.messageIdMax = 10;
    f.enableCtrl = true;
    f.enableLevelMin = f.enableLevelMax = true;
    f.levelMin = 2;
    f.levelMax = 4;
    DlfFilter single;
    single.enableMessageId = true;
    single.messageIdMin = 5;

    string[] warnings;
    const rules = fromDlf([f, single], warnings);
    auto filters = toDlf(rules, warnings);
    assert(warnings.length == 0);
    assert(fromDlf(filters, warnings) == rules);
}

@("toDlf: a message id typed in the editor (text) is written")
unittest
{
    FilterRule rule;
    rule.conditions = [Condition("msgid", Check.Equals, "5"), Condition("level", Check.Equals, "warn")];
    string[] warnings;
    auto filters = toDlf([rule], warnings);
    assert(warnings.length == 0, warnings.length ? warnings[0] : "");
    assert(filters[0].enableMessageId && filters[0].messageIdMin == 5 && filters[0].messageIdMax == 0);
    assert(filters[0].enableLevelMin && filters[0].levelMin == 3 && filters[0].levelMax == 3);
}

@("toDlf: what a .dlf can't hold is dropped and named")
unittest
{
    import std.algorithm.searching : canFind;

    FilterRule rule;
    rule.name = "Wide";
    rule.conditions = [Condition("session", Check.Equals, "3"),
        Condition("ctx", Check.Equals, "CTX1"), Condition("app", Check.Equals, "APP")];
    string[] warnings;
    auto filters = toDlf([rule], warnings);
    assert(filters.length == 1 && filters[0].enableApp && filters[0].appId == "APP");
    assert(!filters[0].enableCtx, "ctx equals: dlt-viewer only finds a part");
    assert(warnings.length == 2 && warnings[0].canFind("Wide"));
}

@("parseDlfFilters: all the conditions of a filter, every one applies to DltFormat")
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

@("parseDlfFilters: a file of dlt-viewer (filters/error_fatal_messages.dlf)")
unittest
{
    auto rules = rulesOf(`<?xml version="1.0" encoding="UTF-8"?>
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
`);
    assert(rules.length == 1);
    auto rule = rules[0];
    assert(rule.name == "Error/Fatal Messages" && rule.enabled && rule.kind == RuleKind.Include);
    assert(rule.conditions.length == 1 && rule.conditions[0].columnId == "level");
}

@("parseDlfFilters: a level range from 0 (dlt-viewer's default minimum) leaves out records without a level")
unittest
{
    auto levels = onlyCondition("<enableLogLevelMin>1</enableLogLevelMin><logLevelMin>0</logLevelMin>"
            ~ "<enableLogLevelMax>1</enableLogLevelMax><logLevelMax>4</logLevelMax>");
    assert(levels.min == LogLevel.Fatal && levels.max == LogLevel.Info);
}

@("toDlfXml: what is written is read back the same, special characters included")
unittest
{
    DlfFilter f;
    f.type = 1;
    f.name = `a <b> & "c"`;
    f.ecuId = "ECU1";
    f.appId = "A.P";
    f.ctxId = "CTX";
    f.header = "hdr";
    f.payload = "x<y & z";
    f.regexSearch = "(\\d+)";
    f.regexReplace = "<$1>";
    f.messageIdMin = 7;
    f.messageIdMax = 10;
    f.regexApp = f.regexCtx = f.regexHeader = f.regexPayload = true;
    f.ignoreCaseHeader = f.ignoreCasePayload = true;
    f.enabled = f.enableEcu = f.enableApp = f.enableCtx = f.enableHeader = f.enablePayload = true;
    f.enableCtrl = f.enableLevelMin = f.enableLevelMax = f.enableMarker = true;
    f.enableMessageId = f.enableRegexSearchReplace = true;
    f.color = "#00ff00";
    f.levelMin = 2;
    f.levelMax = 5;

    DlfFilter plain; // the defaults of dlt-viewer
    const filters = [f, plain];
    assert(parseDlfFilters(toDlfXml(filters)) == filters);
}

@("toDlfXml: the layout of dlt-viewer, every tag of a filter in its order")
unittest
{
    import std.algorithm.searching : canFind, countUntil;
    import std.string : indexOf;

    const xml = toDlfXml([DlfFilter.init]);
    assert(xml.canFind(`<?xml version="1.0" encoding="UTF-8"?>`));
    assert(xml.canFind("<dltfilter>") && xml.canFind("</dltfilter>"));
    static immutable tags = ["type", "name", "ecuid", "applicationid", "contextid", "headertext",
        "payloadtext", "regex_search", "regex_replace", "messageIdMin", "messageIdMax",
        "enableregexp_Appid", "enableregexp_Context", "enableregexp_Header", "enableregexp_Payload",
        "ignoreCase_Header", "ignoreCase_Payload", "enablefilter", "enableecuid",
        "enableapplicationid", "enablecontextid", "enableheadertext", "enablepayloadtext",
        "enablectrlmsgs", "enableLogLevelMin", "enableLogLevelMax", "enableMarker",
        "enableMessageId", "enableRegexSearchReplace", "filterColour", "logLevelMax", "logLevelMin"];
    ptrdiff_t previous = -1;
    foreach (tag; tags)
    {
        const at = xml.indexOf("<" ~ tag ~ ">");
        assert(at > previous, tag);
        previous = at;
    }
    assert(xml.canFind("<logLevelMax>6</logLevelMax>"), "the defaults of dlt-viewer");
}

@("writeDlf: a file written is read back the same")
unittest
{
    import std.file : remove, tempDir;
    import std.path : buildPath;

    const path = buildPath(tempDir(), "dlf_write_test.dlf");
    scope (exit)
        remove(path);
    DlfFilter f;
    f.name = "Errors";
    f.enabled = true;
    writeDlf(path, [f]);
    assert(readDlf(path) == [f]);
}

@("parseDlfFilters: what isn't a .dlf is refused")
unittest
{
    import std.exception : assertThrown;

    assertThrown(parseDlfFilters("not xml <"));
    assertThrown(parseDlfFilters("<other/>"));
    assert(parseDlfFilters("<dltfilter></dltfilter>").length == 0, "empty is fine");
}
