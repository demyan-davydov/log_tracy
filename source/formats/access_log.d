//! Access logs of web servers, a record per line:
//!   Common Log Format (Apache):  client ident user [time] "request" status bytes
//!   Combined (nginx by default): the same, then "referer" "user agent"
//! The status is shown as it is; it also gives the level of the record
//! (5xx Error, 4xx Warn, other Info) that colors its cell. "-" is an empty
//! value. Fields after the combined ones (nginx $request_time...) are not read.
module formats.access_log;

import log_core.log_format;
import log_core.log_level : LogLevel;
import log_core.log_message : LogMessage, TimeKind;
import log_core.text.text_format;
import log_core.text.text_parsing;

//! Field indexes of an access log record in LogMessage
enum AccessLogField : ubyte
{
    Client, // text: host or address of the client
    User, // text
    Method, // text: GET, POST...
    Status, // number
    Bytes, // number
    Referer, // text: Combined
    Agent, // text: Combined
}

//! How the user and the settings know AccessLogFormat
enum FormatInfo accessLogFormatInfo = FormatInfo("access-log", "Web server access log", "WEB");

final class AccessLogFormat : TextFormat
{
    enum Variant
    {
        Common,
        Combined,
    }

    private immutable Variant _variant;

    this(Variant variant) pure nothrow @nogc @safe
    {
        super(false);
        _variant = variant;
    }

    override FormatInfo info() const pure nothrow @nogc
    {
        return accessLogFormatInfo;
    }

    override const(ColumnInfo)[] columns() const pure nothrow @nogc
    {
        return _variant == Variant.Combined ? combinedColumns : commonColumns;
    }

    protected override bool decodeText(ref LogMessage!wchar msg, const(char)[] text) const nothrow @nogc
    {
        msg.beginRecord();

        AccessLine line;
        if (!parseLine(_variant, text, line))
            return decodeAsPlainText(msg, text);

        msg.timeNs = line.timeNs;
        msg.timeKind = TimeKind.Absolute;
        msg.level = statusLevel(line.status);
        setText(msg, AccessLogField.Client, line.client);
        setText(msg, AccessLogField.User, line.user);
        setText(msg, AccessLogField.Method, line.method);
        msg.setNumber(AccessLogField.Status, line.status);
        if (line.hasBytes)
            msg.setNumber(AccessLogField.Bytes, cast(long) line.bytes);
        setText(msg, AccessLogField.Referer, line.referer);
        setText(msg, AccessLogField.Agent, line.agent);
        auto builder = msg.payloadBuilder();
        builder.appendUtf8(line.request);
        return true;
    }

    //! Sets a text field unless it is empty or "-"
    private static void setText(ref LogMessage!wchar msg, AccessLogField field, const(char)[] value) nothrow @nogc
    {
        if (value.length && value != "-")
            msg.setText(field, value);
    }
}

//! The level of an HTTP status: 5xx Error, 4xx Warn, other Info
private LogLevel statusLevel(uint status) pure nothrow @nogc @safe
{
    return status >= 500 ? LogLevel.Error : status >= 400 ? LogLevel.Warn : LogLevel.Info;
}

// ─── Columns ────────────────────────────────────────────────────────────────

private static immutable ColumnInfo[] commonColumns = [
    ColumnInfo("time", "Time", ColumnKind.Time, -1, TimeKind.Absolute),
    ColumnInfo("client", "Client", ColumnKind.Text, AccessLogField.Client),
    ColumnInfo("user", "User", ColumnKind.Text, AccessLogField.User),
    ColumnInfo("method", "Method", ColumnKind.Text, AccessLogField.Method),
    // The status as it is, its cell colored by the level it gives
    ColumnInfo("status", "Status", ColumnKind.Integer, AccessLogField.Status, TimeKind.None, 0, null, true),
    ColumnInfo("bytes", "Bytes", ColumnKind.Integer, AccessLogField.Bytes),
    ColumnInfo("payload", "Request", ColumnKind.Payload),
];

private static immutable ColumnInfo[] combinedColumns = commonColumns[0 .. $ - 1] ~ [
    ColumnInfo("referer", "Referer", ColumnKind.Text, AccessLogField.Referer),
    ColumnInfo("agent", "User agent", ColumnKind.Text, AccessLogField.Agent),
    commonColumns[$ - 1],
];

final class AccessLogDetector : FormatDetector
{
    override const(int)[] variants() const pure nothrow
    {
        import std.traits : EnumMembers;

        int[] all;
        foreach (variant; EnumMembers!(AccessLogFormat.Variant))
            all ~= variant;
        return all;
    }

    override FormatInfo info() const pure nothrow @nogc
    {
        return accessLogFormatInfo;
    }

    override Detection detect(string path, const(ubyte)[] head) const
    {
        size_t lines, common, combined;
        AccessLine parsed;
        forEachSampleLine(head, (const(char)[] line) {
            if (line.length == 0)
                return;
            ++lines;
            if (parseLine(AccessLogFormat.Variant.Combined, line, parsed))
                ++combined; // a combined line is a common one too
            else if (parseLine(AccessLogFormat.Variant.Common, line, parsed))
                ++common;
        });
        // Combined if most of the lines that fit have the referer and agent
        if (combined * 2 > combined + common)
            return detectionByShare(combined + common, lines, AccessLogFormat.Variant.Combined);
        return detectionByShare(combined + common, lines, AccessLogFormat.Variant.Common);
    }

    override LogFormat create(int variant, const(ubyte)[] head) const
    {
        import std.conv : to;

        return new AccessLogFormat(variant.to!(AccessLogFormat.Variant)); // throws for a variant it has not
    }
}

// ─── Line parsing ───────────────────────────────────────────────────────────

private struct AccessLine
{
    const(char)[] client;
    const(char)[] user;
    long timeNs;
    const(char)[] request;
    const(char)[] method;
    uint status;
    bool hasBytes;
    ulong bytes;
    const(char)[] referer;
    const(char)[] agent;
}

//! client ident user [time] "request" status bytes ["referer" "agent"]
private bool parseLine(AccessLogFormat.Variant variant, const(char)[] s, out AccessLine line) pure nothrow @nogc @safe
{
    const(char)[] ident, bytes;
    if (!readWord(s, line.client) || !readChar(s, ' ') || !readWord(s, ident) || !readChar(s, ' ')
        || !readWord(s, line.user) || !readChar(s, ' ') || !readChar(s, '[')
        || !readClfDateTime(s, line.timeNs) || !readChar(s, ']') || !readChar(s, ' ')
        || !readQuoted(s, line.request) || !readChar(s, ' ') || !readStatus(s, line.status)
        || !readChar(s, ' ') || !readWord(s, bytes))
        return false;

    if (bytes != "-")
    {
        if (!readNumber64(bytes, line.bytes) || bytes.length)
            return false;
        line.hasBytes = true;
    }
    line.method = requestMethod(line.request);

    if (variant == AccessLogFormat.Variant.Combined)
    {
        if (!readChar(s, ' ') || !readQuoted(s, line.referer) || !readChar(s, ' ')
            || !readQuoted(s, line.agent))
            return false;
    }
    return s.length == 0 || s[0] == ' '; // fields after these are not read
}

//! A double quoted value, as written: \" inside stays
private bool readQuoted(ref const(char)[] s, out const(char)[] value) pure nothrow @nogc @safe
{
    if (!readChar(s, '"'))
        return false;
    for (size_t i = 0; i < s.length; ++i)
    {
        if (s[i] == '\\')
            ++i; // an escaped character
        else if (s[i] == '"')
        {
            value = s[0 .. i];
            s = s[i + 1 .. $];
            return true;
        }
    }
    return false; // not closed
}

//! Three digits followed by the end of the field
private bool readStatus(ref const(char)[] s, out uint status) pure nothrow @nogc @safe
{
    return readDigits(s, 3, status) && (s.length == 0 || s[0] == ' ');
}

//! The method of "GET /path HTTP/1.1": its first word in capitals, if any
private const(char)[] requestMethod(const(char)[] request) pure nothrow @nogc @safe
{
    size_t n = 0;
    while (n < request.length && request[n] >= 'A' && request[n] <= 'Z')
        ++n;
    return n > 0 && n < request.length && request[n] == ' ' ? request[0 .. n] : null;
}

// ─── Tests ──────────────────────────────────────────────────────────────────

version (unittest)
{
    private const(ubyte)[] bytes(string s)
    {
        return cast(const(ubyte)[]) s;
    }

    private void decodeLine(AccessLogFormat.Variant variant, string text, ref LogMessage!wchar msg)
    {
        assert(new AccessLogFormat(variant).decode(msg, bytes(text)));
    }

    private enum combinedLine = `203.0.113.7 - frank [10/Oct/2026:13:55:36 -0700] "GET /api/items?id=5 HTTP/1.1" `
        ~ `200 2326 "https://example.com/" "Mozilla/5.0 (X11)"`;
}

@("AccessLogFormat: all the fields of a combined line")
unittest
{
    LogMessage!wchar msg;
    decodeLine(AccessLogFormat.Variant.Combined, combinedLine ~ "\n", msg);
    assert(msg.timeKind == TimeKind.Absolute);
    assert(msg.timeNs == toEpochNs(2026, 10, 10, ((20 * 60 + 55) * 60 + 36) * 1_000_000_000L), "UTC");
    assert(msg.text(AccessLogField.Client) == "203.0.113.7"w);
    assert(msg.text(AccessLogField.User) == "frank"w);
    assert(msg.text(AccessLogField.Method) == "GET"w);
    assert(msg.number(AccessLogField.Status) == 200);
    assert(msg.number(AccessLogField.Bytes) == 2326);
    assert(msg.text(AccessLogField.Referer) == "https://example.com/"w);
    assert(msg.text(AccessLogField.Agent) == "Mozilla/5.0 (X11)"w);
    assert(msg.payloadText == "GET /api/items?id=5 HTTP/1.1"w, "the request as written");
    assert(msg.level == LogLevel.Info);
}

@("AccessLogFormat: the status gives the level, and stays as it is")
unittest
{
    import std.conv : to;

    LogMessage!wchar msg;
    foreach (status, level; [101: LogLevel.Info, 200: LogLevel.Info, 302: LogLevel.Info,
            404: LogLevel.Warn, 499: LogLevel.Warn, 500: LogLevel.Error, 503: LogLevel.Error])
    {
        decodeLine(AccessLogFormat.Variant.Common,
            `h - - [10/Oct/2026:13:55:36 +0000] "GET / HTTP/1.1" ` ~ status.to!string ~ ` 0`, msg);
        assert(msg.number(AccessLogField.Status) == status);
        assert(msg.level == level, status.to!string);
    }
}

@("AccessLogFormat: \"-\" is an empty value")
unittest
{
    LogMessage!wchar msg;
    decodeLine(AccessLogFormat.Variant.Combined, `h - - [10/Oct/2026:13:55:36 +0000] "-" 400 - "-" "-"`, msg);
    assert(!msg.hasField(AccessLogField.User) && !msg.hasField(AccessLogField.Bytes));
    assert(!msg.hasField(AccessLogField.Referer) && !msg.hasField(AccessLogField.Agent));
    assert(!msg.hasField(AccessLogField.Method), "no request line");
    assert(msg.payloadText == "-"w && msg.number(AccessLogField.Status) == 400);
}

@("AccessLogFormat: quotes inside a quoted value, fields after the combined ones")
unittest
{
    LogMessage!wchar msg;
    decodeLine(AccessLogFormat.Variant.Combined,
        `h - - [10/Oct/2026:13:55:36 +0000] "GET / HTTP/1.1" 200 5 "-" "Bot \"x\" 1.0" 0.123 0.120`, msg);
    assert(msg.text(AccessLogField.Agent) == `Bot \"x\" 1.0`w, "as written");
    assert(msg.number(AccessLogField.Bytes) == 5);
}

@("AccessLogFormat: a line that doesn't fit keeps its text")
unittest
{
    LogMessage!wchar msg;
    foreach (variant; [AccessLogFormat.Variant.Common, AccessLogFormat.Variant.Combined])
    {
        decodeLine(variant, "not an access log line", msg);
        assert(msg.timeKind == TimeKind.None && msg.level == LogLevel.None);
        assert(msg.payloadText == "not an access log line"w);
    }
    decodeLine(AccessLogFormat.Variant.Combined, `h - - [10/Oct/2026:13:55:36 +0000] "GET /" 2x0 5`, msg);
    assert(msg.timeKind == TimeKind.None, "a status that is not a number");
}

@("AccessLogFormat: the columns, the status colored by the level")
unittest
{
    string[] ids(AccessLogFormat.Variant variant)
    {
        string[] result;
        foreach (column; new AccessLogFormat(variant).columns)
            result ~= column.id;
        return result;
    }

    assert(ids(AccessLogFormat.Variant.Common) == ["time", "client", "user", "method", "status", "bytes", "payload"]);
    assert(ids(AccessLogFormat.Variant.Combined)
            == ["time", "client", "user", "method", "status", "bytes", "referer", "agent", "payload"]);
    foreach (column; new AccessLogFormat(AccessLogFormat.Variant.Combined).columns)
        assert(column.byLevel == (column.id == "status"), column.id);
}

@("AccessLogDetector: recognises the variants, not other logs")
unittest
{
    auto detector = new AccessLogDetector();
    auto d = detector.detect("access.log", bytes(combinedLine ~ "\n" ~ combinedLine ~ "\n"));
    assert(d.score > 0.5f && d.variant == AccessLogFormat.Variant.Combined);

    d = detector.detect("access_log", bytes(`127.0.0.1 - - [10/Oct/2026:13:55:36 -0700] "GET / HTTP/1.0" 200 2326` ~ "\n"));
    assert(d.score > 0.5f && d.variant == AccessLogFormat.Variant.Common);

    foreach (other; ["Nov  3 14:22:01 host sshd[812]: a\n", "11-03 14:22:01.123  1  2 I T: a\n",
            "just some\ntext lines\n"])
        assert(detector.detect("x.log", bytes(other)).score == 0, other);
}
