module formats.syslog.syslog;

//! Syslog files, a record per line:
//!   BSD (RFC 3164), journalctl short: "Nov  3 14:22:01 host sshd[812]: message"
//!   ISO (rsyslog, journalctl short-iso): "2026-11-03T14:22:01.123456+01:00 host app[1]: message"
//!   RFC 5424: "<165>1 2026-11-03T14:22:01.003Z host app procid msgid [data] message"
//! BSD and ISO lines may start with a "<priority>". A time with a zone is a
//! moment (shown in the user's zone), one without is shown as written: each
//! record has its own kind of time. Lines that don't fit keep their text as
//! the payload.

import log_core.log_format;
import log_core.log_level : LogLevel;
import log_core.log_message : LogMessage, TimeKind;
import log_core.text.text_format;
import log_core.text.text_parsing;
import formats.syslog.priority : readPriority;

//! Field indexes of a syslog record in LogMessage
enum SyslogField : ubyte
{
    Host, // text
    App, // text: the tag, the APP-NAME of RFC 5424
    Pid, // number
    MsgId, // text: RFC 5424
    Data, // text: the structured data of RFC 5424, as written
    ProcId, // text: the PROCID of RFC 5424, not always a number
}

//! How the user and the settings know SyslogFormat
enum FormatInfo syslogFormatInfo = FormatInfo("syslog", "Syslog", "SYS");

final class SyslogFormat : TextFormat
{
    enum Kind
    {
        Bsd, // "Mmm dd hh:mm:ss": no year
        Iso, // ISO 8601, with a zone (a moment) or without (as written)
        Rfc5424,
    }

    private immutable Kind _kind;
    private immutable bool _hasPriority;

    //! @param hasPriority - the lines start with <priority>: a Level column
    this(Kind kind, bool hasPriority) pure nothrow @nogc @safe
    {
        super(false); // every line has its own header
        _kind = kind;
        _hasPriority = hasPriority || kind == Kind.Rfc5424;
    }

    //! The variant of a detection: kind and priority in one number
    static int variantOf(Kind kind, bool hasPriority) pure nothrow @nogc @safe
    {
        return kind * 2 + (hasPriority ? 1 : 0);
    }

    Kind kind() const pure nothrow @nogc @property
    {
        return _kind;
    }

    bool hasPriority() const pure nothrow @nogc @property
    {
        return _hasPriority;
    }

    override string name() const pure nothrow @nogc
    {
        return syslogFormatInfo.name;
    }

    override const(ColumnInfo)[] columns() const pure nothrow @nogc
    {
        final switch (_kind)
        {
        case Kind.Bsd:
            return _hasPriority ? bsdLevelColumns : bsdColumns;
        case Kind.Iso:
            return _hasPriority ? isoLevelColumns : isoColumns;
        case Kind.Rfc5424:
            return rfc5424Columns;
        }
    }

    protected override bool decodeText(ref LogMessage!wchar msg, const(char)[] text) const nothrow @nogc
    {
        msg.beginRecord();

        SyslogLine line;
        if (!parseLine(_kind, text, line))
        {
            auto builder = msg.payloadBuilder();
            builder.appendUtf8(text);
            return true;
        }

        msg.timeNs = line.timeNs;
        msg.timeKind = line.timeKind;
        msg.level = line.level;
        if (line.host.length)
            msg.setText(SyslogField.Host, line.host);
        if (line.app.length)
            msg.setText(SyslogField.App, line.app);
        if (line.hasPid)
            msg.setNumber(SyslogField.Pid, line.pid);
        if (line.procId.length)
            msg.setText(SyslogField.ProcId, line.procId);
        if (line.msgId.length)
            msg.setText(SyslogField.MsgId, line.msgId);
        if (line.data.length)
            msg.setText(SyslogField.Data, line.data);
        auto builder = msg.payloadBuilder();
        builder.appendUtf8(line.message);
        return true;
    }
}

// ─── Columns ────────────────────────────────────────────────────────────────

private enum ColumnInfo hostColumn = ColumnInfo("host", "Host", ColumnKind.Text, SyslogField.Host, 80);
private enum ColumnInfo appColumn = ColumnInfo("app", "App", ColumnKind.Text, SyslogField.App, 100);
private enum ColumnInfo pidColumn = ColumnInfo("pid", "PID", ColumnKind.Integer, SyslogField.Pid, 50);
private enum ColumnInfo levelColumn = ColumnInfo("level", "Level", ColumnKind.Level, -1, 60);
private enum ColumnInfo payloadColumn = ColumnInfo("payload", "Message", ColumnKind.Payload);

private ColumnInfo timeColumn(TimeKind kind, ushort width)
{
    return ColumnInfo("time", "Time", ColumnKind.Time, -1, width, kind);
}

private static immutable ColumnInfo[] bsdColumns = [
    timeColumn(TimeKind.LocalNoYear, 120), hostColumn, appColumn, pidColumn, payloadColumn
];
private static immutable ColumnInfo[] bsdLevelColumns = [
    timeColumn(TimeKind.LocalNoYear, 120), hostColumn, appColumn, pidColumn, levelColumn, payloadColumn
];
private static immutable ColumnInfo[] isoColumns = [
    timeColumn(TimeKind.Absolute, 170), hostColumn, appColumn, pidColumn, payloadColumn
];
private static immutable ColumnInfo[] isoLevelColumns = [
    timeColumn(TimeKind.Absolute, 170), hostColumn, appColumn, pidColumn, levelColumn, payloadColumn
];
private static immutable ColumnInfo[] rfc5424Columns = [
    timeColumn(TimeKind.Absolute, 170), hostColumn, appColumn,
    ColumnInfo("pid", "PID", ColumnKind.Text, SyslogField.ProcId, 60),
    ColumnInfo("msgid", "MsgID", ColumnKind.Text, SyslogField.MsgId, 60), levelColumn,
    ColumnInfo("data", "Data", ColumnKind.Text, SyslogField.Data, 150), payloadColumn
];

final class SyslogDetector : FormatDetector
{
    override const(int)[] variants() const pure nothrow
    {
        import std.traits : EnumMembers;

        int[] all;
        foreach (kind; EnumMembers!(SyslogFormat.Kind))
            all ~= [SyslogFormat.variantOf(kind, false), SyslogFormat.variantOf(kind, true)];
        return all;
    }

    override FormatInfo info() const pure nothrow @nogc
    {
        return syslogFormatInfo;
    }

    override Detection detect(string path, const(ubyte)[] head) const
    {
        alias Kind = SyslogFormat.Kind;
        static immutable Kind[3] kinds = [Kind.Rfc5424, Kind.Iso, Kind.Bsd];

        size_t lines;
        size_t[Kind.max + 1] fits, withPriority;
        SyslogLine parsed;
        forEachSampleLine(head, (const(char)[] line) {
            if (line.length == 0)
                return;
            ++lines;
            foreach (kind; kinds)
            {
                if (parseLine(kind, line, parsed))
                {
                    ++fits[kind];
                    if (parsed.hasPriority)
                        ++withPriority[kind];
                    break;
                }
            }
        });
        size_t best = 0;
        foreach (kind, count; fits)
            if (count > fits[best])
                best = kind;
        const bool priority = withPriority[best] * 2 > fits[best];
        return detectionByShare(fits[best], lines, SyslogFormat.variantOf(cast(Kind) best, priority));
    }

    override LogFormat create(int variant, const(ubyte)[] head) const
    {
        import std.conv : to;

        if (variant < 0)
            throw new Exception("no syslog variant " ~ variant.to!string);
        return new SyslogFormat((variant / 2).to!(SyslogFormat.Kind), (variant & 1) != 0); // throws for a kind it has not
    }
}

// ─── Line parsing ───────────────────────────────────────────────────────────

private struct SyslogLine
{
    long timeNs;
    TimeKind timeKind;
    LogLevel level;
    bool hasPriority;
    const(char)[] host;
    const(char)[] app;
    bool hasPid;
    uint pid;
    const(char)[] procId;
    const(char)[] msgId;
    const(char)[] data;
    const(char)[] message;
}

private bool parseLine(SyslogFormat.Kind kind, const(char)[] s, out SyslogLine line) pure nothrow @nogc @safe
{
    string facility;
    if (!readPriority(s, line.hasPriority, line.level, facility))
        return false;

    final switch (kind)
    {
    case SyslogFormat.Kind.Bsd:
        if (!readBsdTime(s, line.timeNs))
            return false;
        line.timeKind = TimeKind.LocalNoYear;
        break;
    case SyslogFormat.Kind.Iso:
        long time, offset;
        bool hasZone;
        // Syslog writes a 'T' (rsyslog, journalctl): application logs a space
        if (s.length <= 10 || s[10] != 'T')
            return false;
        if (!readIsoDateTime(s, time, hasZone, offset))
            return false;
        line.timeNs = time - offset;
        line.timeKind = hasZone ? TimeKind.Absolute : TimeKind.Local;
        break;
    case SyslogFormat.Kind.Rfc5424:
        return line.hasPriority && parseRfc5424(s, line);
    }

    if (!readChar(s, ' '))
        return false;
    skipSpaces(s);
    // An application log has a level where syslog has the host
    if (!readWord(s, line.host) || isLevelWord(line.host))
        return false;
    readChar(s, ' ');
    readTag(s, line);
    return true;
}

//! @returns true if `word` is a level as application logs write it
private bool isLevelWord(const(char)[] word) pure nothrow @nogc @safe
{
    import std.uni : sicmp;

    static immutable string[13] levels = [
        "trace", "debug", "info", "notice", "warn", "warning", "err", "error",
        "crit", "critical", "fatal", "severe", "verbose"
    ];
    foreach (level; levels)
        if (sicmp(word, level) == 0)
            return true;
    return false;
}

//! "Mmm dd hh:mm:ss[.fraction]": no year
private bool readBsdTime(ref const(char)[] s, out long timeNs) pure nothrow @nogc @safe
{
    uint month, day;
    long timeOfDay;
    if (!readMonthDayTime(s, month, day, timeOfDay) || !isValidDate(noYear, month, day))
        return false;
    timeNs = toEpochNs(noYear, month, day, timeOfDay);
    return true;
}

//! "tag[pid]: message" or "tag: message"; without a tag the rest is the message
private void readTag(const(char)[] s, ref SyslogLine line) pure nothrow @nogc @safe
{
    line.message = s;
    size_t i = 0;
    while (i < s.length && s[i] != ':' && s[i] != '[' && s[i] != ' ')
        ++i;
    if (i == 0 || i == s.length || s[i] == ' ')
        return; // no tag

    const(char)[] rest = s[i .. $];
    bool hasPid;
    uint pid;
    if (rest[0] == '[')
    {
        rest = rest[1 .. $];
        if (!readNumber(rest, pid) || !readChar(rest, ']'))
            return;
        hasPid = true;
    }
    if (!readChar(rest, ':'))
        return;
    // "tag: message": a colon inside a word ("12:30", "Error:disk") is not a tag
    if (!hasPid && rest.length && rest[0] != ' ')
        return;
    readChar(rest, ' ');

    line.app = s[0 .. i];
    line.hasPid = hasPid;
    line.pid = pid;
    line.message = rest;
}

//! After "<priority>": "1 TIMESTAMP HOST APP PROCID MSGID DATA [MESSAGE]",
//! "-" for an absent value
private bool parseRfc5424(const(char)[] s, ref SyslogLine line) pure nothrow @nogc @safe
{
    uint version_;
    if (!readNumber(s, version_) || !readChar(s, ' '))
        return false;

    if (s.length && s[0] == '-')
        s = s[1 .. $]; // no time
    else
    {
        long time, offset;
        bool hasZone;
        if (!readIsoDateTime(s, time, hasZone, offset) || !hasZone)
            return false;
        line.timeNs = time - offset;
        line.timeKind = TimeKind.Absolute;
    }

    if (!readChar(s, ' ') || !readField(s, line.host) || !readChar(s, ' ') || !readField(s, line.app)
        || !readChar(s, ' ') || !readField(s, line.procId) || !readChar(s, ' ') || !readField(s, line.msgId)
        || !readChar(s, ' ') || !readStructuredData(s, line.data))
        return false;
    if (s.length && s[0] != ' ')
        return false; // the data must end the line or be followed by a space

    readChar(s, ' ');
    if (s.length >= 3 && s[0 .. 3] == "\xEF\xBB\xBF")
        s = s[3 .. $]; // the BOM that marks a UTF-8 message
    line.message = s;
    return true;
}

//! A field of RFC 5424: empty for "-"
private bool readField(ref const(char)[] s, out const(char)[] value) pure nothrow @nogc @safe
{
    if (!readWord(s, value))
        return false;
    if (value == "-")
        value = null;
    return true;
}

//! "-" or "[id param="value"...]" elements, a value may hold "\]"
private bool readStructuredData(ref const(char)[] s, out const(char)[] data) pure nothrow @nogc @safe
{
    if (s.length && s[0] == '-')
    {
        s = s[1 .. $];
        return true;
    }
    size_t n = 0;
    while (n < s.length && s[n] == '[')
    {
        bool quoted = false;
        for (++n; n < s.length; ++n)
        {
            if (s[n] == '\\' && quoted)
                ++n; // an escaped character
            else if (s[n] == '"')
                quoted = !quoted;
            else if (s[n] == ']' && !quoted)
                break;
        }
        if (n >= s.length)
            return false; // not closed
        ++n;
    }
    if (n == 0)
        return false;
    data = s[0 .. n];
    s = s[n .. $];
    return true;
}

// ─── Tests ──────────────────────────────────────────────────────────────────

version (unittest)
{
    private const(ubyte)[] bytes(string s)
    {
        return cast(const(ubyte)[]) s;
    }

    private void decodeLine(SyslogFormat.Kind kind, string text, ref LogMessage!wchar msg, bool priority = false)
    {
        assert(new SyslogFormat(kind, priority).decode(msg, bytes(text)));
    }

    private enum long second = 1_000_000_000L;
    private enum long minute = 60 * second;
    private enum long hour = 60 * minute;
}

@("SyslogFormat BSD: time without year, host, tag with pid, message")
unittest
{
    LogMessage!wchar msg;
    decodeLine(SyslogFormat.Kind.Bsd, "Nov  3 14:22:01 headunit sshd[812]: Accepted key for root\n", msg);
    assert(msg.timeKind == TimeKind.LocalNoYear);
    assert(msg.timeNs == toEpochNs(noYear, 11, 3, 14 * hour + 22 * minute + second));
    assert(msg.text(SyslogField.Host) == "headunit"w);
    assert(msg.text(SyslogField.App) == "sshd"w);
    assert(msg.number(SyslogField.Pid) == 812);
    assert(msg.level == LogLevel.None);
    assert(msg.payloadText == "Accepted key for root"w);
}

@("SyslogFormat BSD: a tag without pid, a message without tag, fractions of journalctl")
unittest
{
    LogMessage!wchar msg;
    decodeLine(SyslogFormat.Kind.Bsd, "Nov 13 14:22:01 host kernel: [    1.0] usb: x", msg);
    assert(msg.text(SyslogField.App) == "kernel"w && !msg.hasField(SyslogField.Pid));
    assert(msg.payloadText == "[    1.0] usb: x"w);

    decodeLine(SyslogFormat.Kind.Bsd, "Nov  3 14:22:01 host -- MARK --", msg);
    assert(msg.text(SyslogField.Host) == "host"w && !msg.hasField(SyslogField.App));
    assert(msg.payloadText == "-- MARK --"w);

    decodeLine(SyslogFormat.Kind.Bsd, "Nov 03 14:22:01.123456 host systemd[1]: Started x", msg);
    assert(msg.timeNs == toEpochNs(noYear, 11, 3, 14 * hour + 22 * minute + second + 123_456_000));
    assert(msg.number(SyslogField.Pid) == 1);
}

@("SyslogFormat BSD: the priority gives the level")
unittest
{
    LogMessage!wchar msg;
    decodeLine(SyslogFormat.Kind.Bsd, "<34>Nov  3 14:22:01 host su: 'su root' failed", msg, true);
    assert(msg.level == LogLevel.Fatal, "34 = auth (4) * 8 + crit (2)");
    assert(msg.text(SyslogField.App) == "su"w);
    assert(msg.payloadText == "'su root' failed"w);
}

@("SyslogFormat ISO: a zone makes a moment, no zone the time as written")
unittest
{
    LogMessage!wchar msg;
    const local = toEpochNs(2026, 11, 3, 14 * hour + 22 * minute + second);

    decodeLine(SyslogFormat.Kind.Iso, "2026-11-03T14:22:01.123456+01:00 host app[1]: m", msg);
    assert(msg.timeKind == TimeKind.Absolute);
    assert(msg.timeNs == local + 123_456_000 - hour, "the moment in UTC");
    assert(msg.text(SyslogField.Host) == "host"w && msg.text(SyslogField.App) == "app"w);
    assert(msg.payloadText == "m"w);

    // The same file may have lines without a zone: each keeps its fields
    decodeLine(SyslogFormat.Kind.Iso, "2026-11-03T14:22:01 host app: m", msg);
    assert(msg.timeKind == TimeKind.Local && msg.timeNs == local);
    assert(msg.text(SyslogField.Host) == "host"w && msg.payloadText == "m"w);
}

@("SyslogFormat RFC 5424: all the fields")
unittest
{
    LogMessage!wchar msg;
    decodeLine(SyslogFormat.Kind.Rfc5424, `<165>1 2026-11-03T14:22:01.003Z mymachine evntslog - ID47 `
            ~ `[exampleSDID@32473 iut="3" eventSource="App"] An application event`, msg);
    assert(msg.level == LogLevel.Info, "165 = local4 (20) * 8 + notice (5)");
    assert(msg.timeKind == TimeKind.Absolute);
    assert(msg.timeNs == toEpochNs(2026, 11, 3, 14 * hour + 22 * minute + second + 3_000_000));
    assert(msg.text(SyslogField.Host) == "mymachine"w);
    assert(msg.text(SyslogField.App) == "evntslog"w);
    assert(!msg.hasField(SyslogField.ProcId), "NILVALUE");
    assert(msg.text(SyslogField.MsgId) == "ID47"w);
    assert(msg.text(SyslogField.Data) == `[exampleSDID@32473 iut="3" eventSource="App"]`w);
    assert(msg.payloadText == "An application event"w);
}

@("SyslogFormat RFC 5424: NILVALUEs, several data elements, an escaped bracket")
unittest
{
    LogMessage!wchar msg;
    decodeLine(SyslogFormat.Kind.Rfc5424, "<34>1 2026-11-03T22:14:15Z host su 77 - - 'su root' failed", msg);
    assert(msg.text(SyslogField.ProcId) == "77"w);
    assert(!msg.hasField(SyslogField.MsgId) && !msg.hasField(SyslogField.Data));
    assert(msg.payloadText == "'su root' failed"w);

    decodeLine(SyslogFormat.Kind.Rfc5424, `<14>1 - host app - - [a x="1\]2"][b y="3"] text`, msg);
    assert(msg.timeKind == TimeKind.None, "no time: NILVALUE");
    assert(msg.text(SyslogField.Data) == `[a x="1\]2"][b y="3"]`w);
    assert(msg.payloadText == "text"w);

    decodeLine(SyslogFormat.Kind.Rfc5424, "<14>1 2026-11-03T22:14:15Z host app - - -", msg);
    assert(msg.text(SyslogField.Host) == "host"w && msg.payloadText.length == 0, "no message");
}

@("SyslogFormat: a line that doesn't fit keeps its text")
unittest
{
    LogMessage!wchar msg;
    foreach (kind; [SyslogFormat.Kind.Bsd, SyslogFormat.Kind.Iso, SyslogFormat.Kind.Rfc5424])
    {
        decodeLine(kind, "    a continued line", msg);
        assert(msg.timeKind == TimeKind.None && msg.level == LogLevel.None);
        assert(!msg.hasField(SyslogField.Host));
        assert(msg.payloadText == "    a continued line"w);
    }
}

@("SyslogFormat: the columns of each variant")
unittest
{
    string[] ids(SyslogFormat.Kind kind, bool priority)
    {
        string[] result;
        foreach (column; new SyslogFormat(kind, priority).columns)
            result ~= column.id;
        return result;
    }

    assert(ids(SyslogFormat.Kind.Bsd, false) == ["time", "host", "app", "pid", "payload"]);
    assert(ids(SyslogFormat.Kind.Bsd, true) == ["time", "host", "app", "pid", "level", "payload"]);
    assert(ids(SyslogFormat.Kind.Rfc5424, false)
            == ["time", "host", "app", "pid", "msgid", "level", "data", "payload"], "always a priority");
    assert(new SyslogFormat(SyslogFormat.Kind.Bsd, false).columns[0].timeKind == TimeKind.LocalNoYear);
    assert(new SyslogFormat(SyslogFormat.Kind.Iso, false).columns[0].timeKind == TimeKind.Absolute);
    assert(new SyslogFormat(SyslogFormat.Kind.Rfc5424, false).columns[0].timeKind == TimeKind.Absolute);
}

@("SyslogDetector: recognises the variants, not other logs")
unittest
{
    alias Kind = SyslogFormat.Kind;
    auto detector = new SyslogDetector();
    void expect(string sample, Kind kind, bool priority)
    {
        const d = detector.detect("syslog", bytes(sample));
        assert(d.score > 0.5f, sample);
        assert(d.variant == SyslogFormat.variantOf(kind, priority), sample);
    }

    expect("Nov  3 14:22:01 host sshd[812]: a\nNov  3 14:22:02 host kernel: b\n", Kind.Bsd, false);
    expect("<34>Nov  3 14:22:01 host su: a\n<13>Nov  3 14:22:02 host x: b\n", Kind.Bsd, true);
    expect("2026-11-03T14:22:01.1+01:00 host app[1]: a\n", Kind.Iso, false);
    expect("2026-11-03T14:22:01 host app[1]: a\n", Kind.Iso, false);
    expect("<165>1 2026-11-03T14:22:01.003Z host app - ID47 - a\n", Kind.Rfc5424, true);

    foreach (other; ["11-03 14:22:01.123  1234  1250 I Tag: logcat\n", "[    0.000000] Linux version\n",
            "just some\ntext lines\n"])
        assert(detector.detect("x.log", bytes(other)).score == 0, other);
}

@("SyslogDetector: application logs with an ISO time are not syslog")
unittest
{
    auto detector = new SyslogDetector();
    foreach (sample; [
        "2026-11-03 14:22:01,123 INFO server: started\n2026-11-03 14:22:02,500 WARN db: slow\n",
        "2026-11-03T14:22:01.123Z INFO server: started\n2026-11-03T14:22:02.500Z ERROR db: down\n",
    ])
        assert(detector.detect("app.log", bytes(sample)).score == 0, sample);
}

@("SyslogFormat BSD: a word with a colon is not a tag unless a space follows")
unittest
{
    LogMessage!wchar msg;
    decodeLine(SyslogFormat.Kind.Bsd, "Nov  3 14:22:01 host 12:30 backup done", msg);
    assert(!msg.hasField(SyslogField.App) && msg.payloadText == "12:30 backup done"w);

    decodeLine(SyslogFormat.Kind.Bsd, "Nov  3 14:22:01 host Error:disk full", msg);
    assert(!msg.hasField(SyslogField.App) && msg.payloadText == "Error:disk full"w);

    decodeLine(SyslogFormat.Kind.Bsd, "Nov  3 14:22:01 host kernel:", msg);
    assert(msg.text(SyslogField.App) == "kernel"w && msg.payloadText.length == 0, "a tag at the end");
}

@("SyslogFormat RFC 5424: the structured data must be followed by a space or the end")
unittest
{
    LogMessage!wchar msg;
    foreach (line; [`<14>1 - host app - - -oops`, `<14>1 - host app - - [a x="1"]junk`])
    {
        decodeLine(SyslogFormat.Kind.Rfc5424, line, msg);
        assert(!msg.hasField(SyslogField.Host), line ~ ": a malformed line is text");
    }
}

@("SyslogFormat RFC 5424: a PROCID is text, not only a number")
unittest
{
    LogMessage!wchar msg;
    decodeLine(SyslogFormat.Kind.Rfc5424, "<14>1 2026-11-03T22:14:15Z host app worker-1 - - msg", msg);
    assert(msg.text(SyslogField.ProcId) == "worker-1"w);

    const pid = new SyslogFormat(SyslogFormat.Kind.Rfc5424, true).columns[3];
    assert(pid.id == "pid" && pid.kind == ColumnKind.Text && pid.field == SyslogField.ProcId);
}
