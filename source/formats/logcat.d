//! LogcatFormat: the output of Android `adb logcat` (threadtime, brief) as a LogFormat.
module formats.logcat;

import log_core.log_format;
import log_core.log_level : LogLevel;
import log_core.log_message : LogMessage, TimeKind;
import log_core.text.text_format;
import log_core.text.text_parsing;

//! Field indexes of a logcat record in LogMessage
enum LogcatField : ubyte
{
    Pid, // number
    Tid, // number
    Tag, // text
}

//! How the user and the settings know LogcatFormat
enum FormatInfo logcatFormatInfo = FormatInfo("logcat", "Android logcat", "ADB");

//! Output of Android `adb logcat`, a record per line:
//!   threadtime (default): "11-03 14:22:01.123  1234  1250 I Tag     : message"
//!                         "2026-11-03 14:22:01.123 ..." with -v year
//!   brief:                "I/Tag     ( 1234): message"
//! Lines that don't fit ("--------- beginning of main") keep their text as
//! the payload.
final class LogcatFormat : TextFormat
{
    enum Variant
    {
        Threadtime, // time with or without a year (-v year): each record has its kind
        Brief, // no time, no thread
    }

    private immutable Variant _variant;

    private static immutable ColumnInfo[] _threadtimeColumns = [
        ColumnInfo("time", "Time", ColumnKind.Time, -1, TimeKind.LocalNoYear),
        ColumnInfo("pid", "PID", ColumnKind.Integer, LogcatField.Pid),
        ColumnInfo("tid", "TID", ColumnKind.Integer, LogcatField.Tid),
        ColumnInfo("level", "Level", ColumnKind.Level, -1),
        ColumnInfo("tag", "Tag", ColumnKind.Text, LogcatField.Tag),
        ColumnInfo("payload", "Message", ColumnKind.Payload),
    ];


    private static immutable ColumnInfo[] _briefColumns = [
        ColumnInfo("pid", "PID", ColumnKind.Integer, LogcatField.Pid),
        ColumnInfo("level", "Level", ColumnKind.Level, -1),
        ColumnInfo("tag", "Tag", ColumnKind.Text, LogcatField.Tag),
        ColumnInfo("payload", "Message", ColumnKind.Payload),
    ];

    this(Variant variant) pure nothrow @nogc @safe
    {
        super(false); // every line has its own header
        _variant = variant;
    }

    Variant variant() const pure nothrow @nogc @property
    {
        return _variant;
    }

    override string name() const pure nothrow @nogc
    {
        return logcatFormatInfo.name;
    }

    override const(ColumnInfo)[] columns() const pure nothrow @nogc
    {
        final switch (_variant)
        {
        case Variant.Threadtime:
            return _threadtimeColumns;
        case Variant.Brief:
            return _briefColumns;
        }
    }

    protected override bool decodeText(ref LogMessage!wchar msg, const(char)[] text) const nothrow @nogc
    {
        msg.beginRecord();

        LogcatLine line;
        const bool parsed = _variant == Variant.Brief ? parseBrief(text, line) : parseThreadtime(text, line);
        if (!parsed)
            return decodeAsPlainText(msg, text);

        msg.timeNs = line.timeNs;
        msg.timeKind = line.timeKind;
        msg.level = line.level;
        msg.setNumber(LogcatField.Pid, line.pid);
        msg.setNumber(LogcatField.Tid, line.tid);
        msg.setText(LogcatField.Tag, line.tag);
        auto builder = msg.payloadBuilder();
        builder.appendUtf8(line.message);
        return true;
    }
}

final class LogcatDetector : FormatDetector
{
    override const(int)[] variants() const pure nothrow
    {
        import std.traits : EnumMembers;

        int[] all;
        foreach (variant; EnumMembers!(LogcatFormat.Variant))
            all ~= variant;
        return all;
    }

    override FormatInfo info() const pure nothrow @nogc
    {
        return logcatFormatInfo;
    }

    override Detection detect(string path, const(ubyte)[] head) const
    {
        size_t lines, threadtime, brief;
        LogcatLine parsed;
        forEachSampleLine(head, (const(char)[] line) {
            if (line.length == 0 || isDivider(line))
                return;
            ++lines;
            if (parseThreadtime(line, parsed))
                ++threadtime;
            else if (parseBrief(line, parsed))
                ++brief;
        });
        auto variant = LogcatFormat.Variant.Threadtime;
        size_t best = threadtime;
        if (brief > best)
        {
            variant = LogcatFormat.Variant.Brief;
            best = brief;
        }

        return detectionByShare(best, lines, variant);
    }

    override LogFormat create(int variant, const(ubyte)[] head) const
    {
        import std.conv : to;

        return new LogcatFormat(variant.to!(LogcatFormat.Variant)); // throws for a variant it has not
    }
}

// ─── Line parsing ───────────────────────────────────────────────────────────

private struct LogcatLine
{
    long timeNs;
    TimeKind timeKind;
    uint pid;
    uint tid;
    LogLevel level;
    const(char)[] tag;
    const(char)[] message;
}

//! "--------- beginning of main" and the like
private bool isDivider(const(char)[] line) pure nothrow @nogc @safe
{
    return line.length >= 10 && line[0 .. 10] == "--------- ";
}

private bool levelOf(char c, out LogLevel level) pure nothrow @nogc @safe
{
    switch (c)
    {
    case 'V':
        level = LogLevel.Verbose;
        return true;
    case 'D':
        level = LogLevel.Debug;
        return true;
    case 'I':
        level = LogLevel.Info;
        return true;
    case 'W':
        level = LogLevel.Warn;
        return true;
    case 'E':
        level = LogLevel.Error;
        return true;
    case 'F':
    case 'A': // assert
        level = LogLevel.Fatal;
        return true;
    default:
        return false;
    }
}

//! Splits "Tag   : message" at the first ": "; the tag loses its padding
private bool splitTag(const(char)[] s, out const(char)[] tag, out const(char)[] message) pure nothrow @nogc @safe
{
    foreach (i; 0 .. s.length)
    {
        if (s[i] == ':' && (i + 1 == s.length || s[i + 1] == ' '))
        {
            size_t tagEnd = i;
            while (tagEnd > 0 && s[tagEnd - 1] == ' ')
                --tagEnd;
            tag = s[0 .. tagEnd];
            message = i + 2 <= s.length ? s[i + 2 .. $] : s[$ .. $];
            return true;
        }
    }
    return false;
}

//! "[YYYY-]MM-DD HH:MM:SS.mmm  PID  TID L Tag: message"
private bool parseThreadtime(const(char)[] s, out LogcatLine line) pure nothrow @nogc @safe
{
    int year = noYear;
    line.timeKind = TimeKind.LocalNoYear;
    uint value, month, day;
    if (s.length > 4 && s[4] == '-')
    {
        if (!readDigits(s, 4, value) || !readChar(s, '-'))
            return false;
        year = value;
        line.timeKind = TimeKind.Local;
    }

    long timeOfDay;
    if (!readDigits(s, 2, month) || !readChar(s, '-') || !readDigits(s, 2, day)
        || !skipSpaces(s) || !readTimeOfDay(s, timeOfDay) || !isValidDate(year, month, day))
        return false;
    line.timeNs = toEpochNs(year, month, day, timeOfDay);

    if (!skipSpaces(s) || !readNumber(s, line.pid) || !skipSpaces(s) || !readNumber(s, line.tid)
        || !skipSpaces(s) || s.length < 2 || !levelOf(s[0], line.level) || s[1] != ' ')
        return false;
    s = s[2 .. $];
    skipSpaces(s);
    return splitTag(s, line.tag, line.message);
}

//! "L/Tag( PID): message"
private bool parseBrief(const(char)[] s, out LogcatLine line) pure nothrow @nogc @safe
{
    if (s.length < 2 || !levelOf(s[0], line.level) || s[1] != '/')
        return false;
    s = s[2 .. $];

    // The PID is in the parentheses before the first "): "
    foreach (i; 0 .. s.length)
    {
        if (s[i] != ')' || i + 1 >= s.length || s[i + 1] != ':')
            continue;
        size_t open = i;
        while (open > 0 && s[open - 1] != '(')
            --open;
        if (open == 0)
            return false;
        const(char)[] pid = s[open .. i];
        skipSpaces(pid);
        if (!readNumber(pid, line.pid) || pid.length != 0)
            return false;

        size_t tagEnd = open - 1;
        while (tagEnd > 0 && s[tagEnd - 1] == ' ')
            --tagEnd;
        line.tag = s[0 .. tagEnd];
        size_t messageStart = i + 2; // after "):"
        if (messageStart < s.length && s[messageStart] == ' ')
            ++messageStart;
        line.message = s[messageStart .. $];
        return true;
    }
    return false;
}

// ─── Tests ──────────────────────────────────────────────────────────────────

version (unittest)
{
    private const(ubyte)[] bytes(string s)
    {
        return cast(const(ubyte)[]) s;
    }

    private bool decodeLine(const(LogcatFormat) format, string text, ref LogMessage!wchar msg)
    {
        return format.decode(msg, bytes(text));
    }
}

@("LogcatFormat threadtime: header fields and message")
unittest
{
    auto format = new LogcatFormat(LogcatFormat.Variant.Threadtime);
    LogMessage!wchar msg;
    assert(decodeLine(format, "11-03 14:22:01.123  1234  1250 I ActivityManager: Start proc 4321:com.foo\n", msg));

    assert(msg.timeKind == TimeKind.LocalNoYear);
    assert(msg.timeNs == toEpochNs(noYear, 11, 3, ((14 * 60 + 22) * 60 + 1) * 1_000_000_000L + 123_000_000));
    assert(msg.number(LogcatField.Pid) == 1234);
    assert(msg.number(LogcatField.Tid) == 1250);
    assert(msg.level == LogLevel.Info);
    assert(msg.text(LogcatField.Tag) == "ActivityManager"w);
    assert(msg.payloadText == "Start proc 4321:com.foo"w, "a colon in the message stays");
}

@("LogcatFormat threadtime: padded tag, empty message, year, microseconds")
unittest
{
    auto format = new LogcatFormat(LogcatFormat.Variant.Threadtime);
    LogMessage!wchar msg;

    assert(decodeLine(format, "2026-02-28 00:00:00.000123   1     2 E Tag     : ", msg));
    assert(msg.timeKind == TimeKind.Local);
    assert(msg.timeNs == toEpochNs(2026, 2, 28, 123_000));
    assert(msg.level == LogLevel.Error);
    assert(msg.text(LogcatField.Tag) == "Tag"w);
    assert(msg.payloadText.length == 0);
}

@("LogcatFormat: a line that doesn't fit keeps its text")
unittest
{
    auto format = new LogcatFormat(LogcatFormat.Variant.Threadtime);
    LogMessage!wchar msg;
    assert(decodeLine(format, "--------- beginning of main", msg));
    assert(msg.payloadText == "--------- beginning of main"w);
    assert(msg.timeKind == TimeKind.None);
    assert(msg.level == LogLevel.None);
    assert(msg.text(LogcatField.Tag) is null);
}

@("LogcatFormat brief: level, tag and pid")
unittest
{
    auto format = new LogcatFormat(LogcatFormat.Variant.Brief);
    LogMessage!wchar msg;
    assert(decodeLine(format, "W/Some Tag( 4321): low memory (x): y", msg));
    assert(msg.level == LogLevel.Warn);
    assert(msg.text(LogcatField.Tag) == "Some Tag"w);
    assert(msg.number(LogcatField.Pid) == 4321);
    assert(msg.payloadText == "low memory (x): y"w);
    assert(msg.timeKind == TimeKind.None);
}

@("LogcatDetector: recognises the variants, not other text")
unittest
{
    auto detector = new LogcatDetector();
    auto threadtime = bytes("--------- beginning of main\n"
            ~ "11-03 14:22:01.123  1234  1250 I Tag: a\n"
            ~ "11-03 14:22:01.124  1234  1250 W Tag: b\n");
    auto d = detector.detect("x.txt", threadtime);
    assert(d.score == 1.0f && d.variant == LogcatFormat.Variant.Threadtime);

    d = detector.detect("x.log", bytes("2026-11-03 14:22:01.123  1  2 D T: a\n"));
    assert(d.score == 1.0f && d.variant == LogcatFormat.Variant.Threadtime, "-v year: the same variant");

    d = detector.detect("x.log", bytes("I/Tag( 12): a\nE/Other(  3): b\nnoise\n"));
    assert(d.score > 0.5f && d.variant == LogcatFormat.Variant.Brief);

    assert(detector.detect("x.log", bytes("just some\ntext lines\n")).score == 0);
    assert(detector.detect("x.log", bytes("Nov  3 14:22:01 host app[1]: syslog\n")).score == 0);
}

@("LogcatFormat brief: a message right after the colon keeps its first character")
unittest
{
    auto format = new LogcatFormat(LogcatFormat.Variant.Brief);
    LogMessage!wchar msg;
    assert(decodeLine(format, "I/Tag( 123):started", msg));
    assert(msg.payloadText == "started"w);
}

@("LogcatFormat threadtime: lines with and without a year keep their fields, each its time kind")
unittest
{
    LogMessage!wchar msg;
    auto format = new LogcatFormat(LogcatFormat.Variant.Threadtime);

    assert(decodeLine(format, "11-03 14:22:01.123  1  2 I T: x", msg));
    assert(msg.timeKind == TimeKind.LocalNoYear && msg.number(LogcatField.Pid) == 1);

    assert(decodeLine(format, "2026-11-03 14:22:01.123  1  2 I T: x", msg));
    assert(msg.timeKind == TimeKind.Local, "the year is shown for this line");
    assert(msg.number(LogcatField.Pid) == 1 && msg.text(LogcatField.Tag) == "T"w);
}

@("Logcat: a line with month 00 is text, for the detector and the decoder")
unittest
{
    enum line = "00-05 12:00:00.000  1  2 I Tag: x";
    assert(new LogcatDetector().detect("x.log", bytes(line ~ "\n")).score == 0);

    auto format = new LogcatFormat(LogcatFormat.Variant.Threadtime);
    LogMessage!wchar msg;
    assert(decodeLine(format, line, msg));
    assert(msg.timeKind == TimeKind.None && msg.payloadText == line ~ ""w);
}
