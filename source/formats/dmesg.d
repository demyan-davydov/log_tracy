module formats.dmesg;

//! Kernel messages as printed by `dmesg` or read from /dev/kmsg, a record per line:
//!   "[    3.141592] usb 1-1: new device"          time since boot
//!   "<3>[    3.141592] ..."                         with the level (kmsg, console)
//!   "kern  :err   : [    3.141592] ..."            dmesg -x: facility and level
//!   "[Tue Nov  3 14:22:01 2026] ..."               dmesg -T: wall-clock time
//! Lines that don't fit keep their text as the payload.

import log_core.log_format;
import log_core.log_level : LogLevel;
import log_core.log_message : LogMessage, TimeKind;
import log_core.text_format;
import log_core.text_parsing;

//! Field indexes of a dmesg record in LogMessage
enum DmesgField : ubyte
{
    Facility, // text: kern, user, daemon... (dmesg -x)
}

final class DmesgFormat : TextFormat
{
    enum Variant
    {
        Monotonic, // [seconds since boot], an optional <level>
        Decoded, // dmesg -x: facility :level : [seconds since boot]
        WallClock, // dmesg -T: [Www Mmm dd hh:mm:ss yyyy], an optional <level>
    }

    private immutable Variant _variant;

    private static immutable ColumnInfo[] _monotonicColumns = [
        ColumnInfo("time", "Time", ColumnKind.Time, -1, 100, TimeKind.SinceBoot),
        ColumnInfo("level", "Level", ColumnKind.Level, -1, 60),
        ColumnInfo("payload", "Message", ColumnKind.Payload),
    ];

    private static immutable ColumnInfo[] _decodedColumns = [
        _monotonicColumns[0],
        ColumnInfo("facility", "Facility", ColumnKind.Text, DmesgField.Facility, 60),
        _monotonicColumns[1],
        _monotonicColumns[2],
    ];

    private static immutable ColumnInfo[] _wallClockColumns = [
        ColumnInfo("time", "Time", ColumnKind.Time, -1, 120, TimeKind.Local),
        _monotonicColumns[1],
        _monotonicColumns[2],
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
        return "Kernel log (dmesg)";
    }

    override const(ColumnInfo)[] columns() const pure nothrow @nogc
    {
        final switch (_variant)
        {
        case Variant.Monotonic:
            return _monotonicColumns;
        case Variant.Decoded:
            return _decodedColumns;
        case Variant.WallClock:
            return _wallClockColumns;
        }
    }

    protected override bool decodeText(ref LogMessage!wchar msg, const(char)[] text) const nothrow @nogc
    {
        msg.beginRecord();

        DmesgLine line;
        if (!parseLine(_variant, text, line))
        {
            auto builder = msg.payloadBuilder();
            builder.appendUtf8(text);
            return true;
        }

        msg.timeNs = line.timeNs;
        msg.timeKind = line.timeKind;
        msg.level = line.level;
        if (line.facility.length)
            msg.setText(DmesgField.Facility, line.facility);
        auto builder = msg.payloadBuilder();
        builder.appendUtf8(line.message);
        return true;
    }
}

final class DmesgDetector : FormatDetector
{
    //! Share of the sample lines that must fit
    enum float minShare = 0.6f;

    override Detection detect(string path, const(ubyte)[] head) const
    {
        size_t lines;
        size_t[DmesgFormat.Variant.max + 1] fits;
        DmesgLine parsed;
        forEachSampleLine(head, (const(char)[] line) {
            if (line.length == 0)
                return;
            ++lines;
            foreach (variant; [DmesgFormat.Variant.Decoded, DmesgFormat.Variant.WallClock,
                    DmesgFormat.Variant.Monotonic])
            {
                if (parseLine(variant, line, parsed))
                {
                    ++fits[variant];
                    break;
                }
            }
        });
        if (lines == 0)
            return Detection(0);

        size_t best = 0;
        foreach (variant, count; fits)
            if (count > fits[best])
                best = variant;

        const float share = cast(float) fits[best] / lines;
        if (share < minShare)
            return Detection(0);
        return Detection(0.5f + 0.5f * share, cast(int) best);
    }

    override LogFormat create(int variant, const(ubyte)[] head) const
    {
        return new DmesgFormat(cast(DmesgFormat.Variant) variant);
    }
}

// ─── Line parsing ───────────────────────────────────────────────────────────

private struct DmesgLine
{
    long timeNs;
    TimeKind timeKind;
    LogLevel level;
    const(char)[] facility;
    const(char)[] message;
}

//! Kernel level 0..7 (emerg .. debug)
private LogLevel kernelLevel(uint value) pure nothrow @nogc @safe
{
    static immutable LogLevel[8] levels = [
        LogLevel.Fatal, LogLevel.Fatal, LogLevel.Fatal, // emerg, alert, crit
        LogLevel.Error, LogLevel.Warn, // err, warning
        LogLevel.Info, LogLevel.Info, LogLevel.Debug // notice, info, debug
    ];
    return value < levels.length ? levels[value] : LogLevel.None;
}

//! The level names of dmesg -x
private bool levelByName(const(char)[] name, out LogLevel level) pure nothrow @nogc @safe
{
    static immutable string[8] names = ["emerg", "alert", "crit", "err", "warn", "notice", "info", "debug"];
    foreach (i, n; names)
    {
        if (name == n)
        {
            level = kernelLevel(cast(uint) i);
            return true;
        }
    }
    return false;
}

//! An optional "<n>" prefix
private bool readLevelPrefix(ref const(char)[] s, out LogLevel level) pure nothrow @nogc @safe
{
    if (s.length < 3 || s[0] != '<')
        return true; // no prefix
    const(char)[] rest = s[1 .. $];
    uint value;
    if (!readNumber(rest, value) || !readChar(rest, '>') || value > 7)
        return false;
    level = kernelLevel(value);
    s = rest;
    return true;
}

//! "[  seconds.fraction]" since boot
private bool readMonotonic(ref const(char)[] s, out long timeNs) pure nothrow @nogc @safe
{
    uint seconds, fraction;
    if (!readChar(s, '['))
        return false;
    skipSpaces(s);
    if (!readNumber(s, seconds) || !readChar(s, '.') || !readFraction(s, fraction) || !readChar(s, ']'))
        return false;
    timeNs = seconds * 1_000_000_000L + fraction;
    return true;
}

//! "[Www Mmm dd hh:mm:ss yyyy]"
private bool readWallClock(ref const(char)[] s, out long timeNs) pure nothrow @nogc @safe
{
    uint month, day, year;
    long timeOfDay;
    if (!readChar(s, '[') || s.length < 4 || s[3] != ' ')
        return false;
    s = s[4 .. $]; // the weekday
    if (!readMonthName(s, month) || !skipSpaces(s) || !readNumber(s, day) || !skipSpaces(s)
        || !readTimeOfDay(s, timeOfDay) || !skipSpaces(s) || !readDigits(s, 4, year)
        || !readChar(s, ']') || !isValidDate(year, month, day))
        return false;
    timeNs = toEpochNs(year, month, day, timeOfDay);
    return true;
}

//! "facility:level : " of dmesg -x, the names padded with spaces
private bool readDecodedPrefix(ref const(char)[] s, out const(char)[] facility, out LogLevel level) pure nothrow @nogc @safe
{
    import std.string : indexOf, strip;

    const colon = s.indexOf(':');
    if (colon <= 0)
        return false;
    facility = s[0 .. colon].strip;
    s = s[colon + 1 .. $];
    const colon2 = s.indexOf(':');
    if (colon2 <= 0 || !levelByName(s[0 .. colon2].strip, level) || facility.length == 0)
        return false;
    s = s[colon2 + 1 .. $];
    return skipSpaces(s);
}

private bool parseLine(DmesgFormat.Variant variant, const(char)[] s, out DmesgLine line) pure nothrow @nogc @safe
{
    final switch (variant)
    {
    case DmesgFormat.Variant.Monotonic:
        line.timeKind = TimeKind.SinceBoot;
        if (!readLevelPrefix(s, line.level) || !readMonotonic(s, line.timeNs))
            return false;
        break;
    case DmesgFormat.Variant.Decoded:
        line.timeKind = TimeKind.SinceBoot;
        if (!readDecodedPrefix(s, line.facility, line.level) || !readMonotonic(s, line.timeNs))
            return false;
        break;
    case DmesgFormat.Variant.WallClock:
        line.timeKind = TimeKind.Local;
        if (!readLevelPrefix(s, line.level) || !readWallClock(s, line.timeNs))
            return false;
        break;
    }
    if (s.length && s[0] == ' ')
        s = s[1 .. $];
    line.message = s;
    return true;
}

// ─── Tests ──────────────────────────────────────────────────────────────────

version (unittest)
{
    private const(ubyte)[] bytes(string s)
    {
        return cast(const(ubyte)[]) s;
    }

    private void decodeLine(DmesgFormat.Variant variant, string text, ref LogMessage!wchar msg)
    {
        assert(new DmesgFormat(variant).decode(msg, bytes(text)));
    }

    private enum long second = 1_000_000_000L;
}

@("DmesgFormat: time since boot and the message")
unittest
{
    LogMessage!wchar msg;
    decodeLine(DmesgFormat.Variant.Monotonic, "[    3.141592] usb 1-1: new high-speed USB device\n", msg);
    assert(msg.timeKind == TimeKind.SinceBoot);
    assert(msg.timeNs == 3 * second + 141_592_000);
    assert(msg.level == LogLevel.None);
    assert(msg.payloadText == "usb 1-1: new high-speed USB device"w);

    decodeLine(DmesgFormat.Variant.Monotonic, "[12345.000001] x", msg);
    assert(msg.timeNs == 12_345 * second + 1000);
}

@("DmesgFormat: the <level> prefix maps the kernel levels")
unittest
{
    LogMessage!wchar msg;
    const LogLevel[8] expected = [
        LogLevel.Fatal, LogLevel.Fatal, LogLevel.Fatal, LogLevel.Error,
        LogLevel.Warn, LogLevel.Info, LogLevel.Info, LogLevel.Debug
    ];
    foreach (kernelLevel, level; expected)
    {
        import std.conv : to;

        decodeLine(DmesgFormat.Variant.Monotonic, "<" ~ kernelLevel.to!string ~ ">[    0.5] text", msg);
        assert(msg.level == level, kernelLevel.to!string);
        assert(msg.timeNs == second / 2 && msg.payloadText == "text"w);
    }
}

@("DmesgFormat: dmesg -x gives the facility and the level by name")
unittest
{
    LogMessage!wchar msg;
    decodeLine(DmesgFormat.Variant.Decoded, "kern  :err   : [    1.000000] disk failure", msg);
    assert(msg.text(DmesgField.Facility) == "kern"w);
    assert(msg.level == LogLevel.Error);
    assert(msg.timeKind == TimeKind.SinceBoot && msg.timeNs == second);
    assert(msg.payloadText == "disk failure"w);

    decodeLine(DmesgFormat.Variant.Decoded, "daemon:warn  : [    2.000000] w", msg);
    assert(msg.text(DmesgField.Facility) == "daemon"w && msg.level == LogLevel.Warn);
}

@("DmesgFormat: dmesg -T gives the wall-clock time")
unittest
{
    LogMessage!wchar msg;
    decodeLine(DmesgFormat.Variant.WallClock, "[Tue Nov  3 14:22:01 2026] eth0: link up", msg);
    assert(msg.timeKind == TimeKind.Local);
    assert(msg.timeNs == toEpochNs(2026, 11, 3, ((14 * 60 + 22) * 60 + 1) * second));
    assert(msg.payloadText == "eth0: link up"w);
}

@("DmesgFormat: a line that doesn't fit keeps its text")
unittest
{
    LogMessage!wchar msg;
    foreach (variant; [DmesgFormat.Variant.Monotonic, DmesgFormat.Variant.Decoded, DmesgFormat.Variant.WallClock])
    {
        decodeLine(variant, "    continued without a header", msg);
        assert(msg.timeKind == TimeKind.None && msg.level == LogLevel.None);
        assert(msg.payloadText == "    continued without a header"w);
    }
}

@("DmesgFormat: each variant has its columns")
unittest
{
    string[] ids(DmesgFormat.Variant variant)
    {
        string[] result;
        foreach (column; new DmesgFormat(variant).columns)
            result ~= column.id;
        return result;
    }

    assert(ids(DmesgFormat.Variant.Monotonic) == ["time", "level", "payload"]);
    assert(ids(DmesgFormat.Variant.Decoded) == ["time", "facility", "level", "payload"]);
    assert(ids(DmesgFormat.Variant.WallClock) == ["time", "level", "payload"]);
    assert(new DmesgFormat(DmesgFormat.Variant.Monotonic).columns[0].timeKind == TimeKind.SinceBoot);
    assert(new DmesgFormat(DmesgFormat.Variant.WallClock).columns[0].timeKind == TimeKind.Local);
}

@("DmesgDetector: recognises the variants, not other logs")
unittest
{
    auto detector = new DmesgDetector();

    auto d = detector.detect("dmesg.txt", bytes("[    0.000000] Linux version 6.1\n<6>[    0.000001] Command line: x\n"));
    assert(d.score == 1.0f && d.variant == DmesgFormat.Variant.Monotonic);

    d = detector.detect("x.log", bytes("kern  :info  : [    0.000000] Linux version 6.1\n"));
    assert(d.score == 1.0f && d.variant == DmesgFormat.Variant.Decoded);

    d = detector.detect("x.log", bytes("[Tue Nov  3 14:22:01 2026] eth0: link up\n"));
    assert(d.score == 1.0f && d.variant == DmesgFormat.Variant.WallClock);

    assert(detector.detect("x.log", bytes("11-03 14:22:01.123  1234  1250 I Tag: logcat\n")).score == 0);
    assert(detector.detect("x.log", bytes("just some\ntext lines\n")).score == 0);
}
