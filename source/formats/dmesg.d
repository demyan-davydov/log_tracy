module formats.dmesg;

//! Kernel messages as printed by `dmesg` or read from /dev/kmsg, a record per line:
//!   "[    3.141592] usb 1-1: new device"          time since boot
//!   "<30>[    3.141592] ..."                        with the priority (dmesg -r, /proc/kmsg)
//!   "6,339,5140900,-;..."                          /dev/kmsg: priority, sequence, usec, flags,
//!                                                  then dictionary lines starting with a space
//!   "kern  :err   : [    3.141592] ..."            dmesg -x: facility and level
//!   "[Tue Nov  3 14:22:01 2026] ..."               dmesg -T: wall-clock time
//! Lines that don't fit keep their text as the payload.

import log_core.log_format;
import log_core.log_level : LogLevel;
import log_core.log_message : LogMessage, TimeKind;
import log_core.text.text_format;
import log_core.text.text_parsing;
import formats.syslog.priority : readPriority, severityByName, splitPriority;

//! Field indexes of a dmesg record in LogMessage
enum DmesgField : ubyte
{
    Facility, // text: kern, user, daemon... (dmesg -x)
    Seq, // number: the sequence number of /dev/kmsg
}

//! How the user and the settings know DmesgFormat
enum FormatInfo dmesgFormatInfo = FormatInfo("dmesg", "Kernel log (dmesg)", "KRN");

final class DmesgFormat : TextFormat
{
    enum Variant
    {
        Monotonic, // [seconds since boot], an optional <level>
        Decoded, // dmesg -x: facility :level : [seconds since boot]
        WallClock, // dmesg -T: [Www Mmm dd hh:mm:ss yyyy], an optional <level>
        Raw, // dmesg -r, /dev/kmsg: <priority>[seconds since boot], the facility shown
        Kmsg, // /dev/kmsg: priority,sequence,microseconds,flags;message and dictionary lines
    }

    private immutable Variant _variant;

    private static immutable ColumnInfo[] _monotonicColumns = [
        ColumnInfo("time", "Time", ColumnKind.Time, -1, TimeKind.SinceBoot),
        ColumnInfo("level", "Level", ColumnKind.Level, -1),
        ColumnInfo("payload", "Message", ColumnKind.Payload),
    ];

    private static immutable ColumnInfo[] _decodedColumns = [
        _monotonicColumns[0],
        ColumnInfo("facility", "Facility", ColumnKind.Text, DmesgField.Facility),
        _monotonicColumns[1],
        _monotonicColumns[2],
    ];

    private static immutable ColumnInfo[] _kmsgColumns = [
        _decodedColumns[0], _decodedColumns[1], _decodedColumns[2],
        ColumnInfo("seq", "Seq", ColumnKind.Integer, DmesgField.Seq),
        _decodedColumns[3],
    ];

    private static immutable ColumnInfo[] _wallClockColumns = [
        ColumnInfo("time", "Time", ColumnKind.Time, -1, TimeKind.Local),
        _monotonicColumns[1],
        _monotonicColumns[2],
    ];

    this(Variant variant) pure nothrow @nogc @safe
    {
        // Every line has its own header, but for the dictionary lines of /dev/kmsg
        super(variant == Variant.Kmsg);
        _variant = variant;
    }

    Variant variant() const pure nothrow @nogc @property
    {
        return _variant;
    }

    override string name() const pure nothrow @nogc
    {
        return dmesgFormatInfo.name;
    }

    //! The dictionary lines of /dev/kmsg start with a space
    protected override bool isRecordStart(const(char)[] line) const nothrow @nogc
    {
        return line.length == 0 || line[0] != ' ';
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
        case Variant.Raw:
            return _decodedColumns; // the same columns: time, facility, level
        case Variant.Kmsg:
            return _kmsgColumns;
        }
    }

    protected override bool decodeText(ref LogMessage!wchar msg, const(char)[] text) const nothrow @nogc
    {
        msg.beginRecord();

        DmesgLine line;
        if (!parseLine(_variant, text, line))
            return decodeAsPlainText(msg, text);

        msg.timeNs = line.timeNs;
        msg.timeKind = line.timeKind;
        msg.level = line.level;
        if (line.facility.length)
            msg.setText(DmesgField.Facility, line.facility);
        if (_variant == Variant.Kmsg)
            msg.setNumber(DmesgField.Seq, cast(long) line.seq);
        auto builder = msg.payloadBuilder();
        builder.appendUtf8(line.message);
        return true;
    }
}

final class DmesgDetector : FormatDetector
{
    override const(int)[] variants() const pure nothrow
    {
        import std.traits : EnumMembers;

        int[] all;
        foreach (variant; EnumMembers!(DmesgFormat.Variant))
            all ~= variant;
        return all;
    }

    override FormatInfo info() const pure nothrow @nogc
    {
        return dmesgFormatInfo;
    }

    override Detection detect(string path, const(ubyte)[] head) const
    {
        size_t lines;
        size_t[DmesgFormat.Variant.max + 1] fits;
        size_t withPriority; // of the lines that fit Monotonic
        DmesgLine parsed;
        forEachSampleLine(head, (const(char)[] line) {
            if (line.length == 0 || line[0] == ' ')
                return; // empty, or a dictionary line of /dev/kmsg
            ++lines;
            foreach (variant; [DmesgFormat.Variant.Kmsg, DmesgFormat.Variant.Decoded,
                    DmesgFormat.Variant.WallClock, DmesgFormat.Variant.Monotonic])
            {
                if (parseLine(variant, line, parsed))
                {
                    ++fits[variant];
                    if (variant == DmesgFormat.Variant.Monotonic && parsed.hasPriority)
                        ++withPriority;
                    break;
                }
            }
        });
        size_t best = 0;
        foreach (variant, count; fits)
            if (count > fits[best])
                best = variant;

        // Most lines with a priority: show the facility too
        auto variant = cast(DmesgFormat.Variant) best;
        if (variant == DmesgFormat.Variant.Monotonic && withPriority * 2 > fits[best])
            variant = DmesgFormat.Variant.Raw;
        return detectionByShare(fits[best], lines, variant);
    }

    override LogFormat create(int variant, const(ubyte)[] head) const
    {
        import std.conv : to;

        return new DmesgFormat(variant.to!(DmesgFormat.Variant)); // throws for a variant it has not
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
    bool hasPriority; // the line starts with <priority>
    ulong seq; // /dev/kmsg
}

//! "priority,sequence,microseconds,flags[,more];message" of /dev/kmsg
private bool parseKmsg(const(char)[] s, ref DmesgLine line) pure nothrow @nogc @safe
{
    import std.string : indexOf;

    uint priority;
    string facility;
    if (!readNumber(s, priority) || !readChar(s, ',') || !splitPriority(priority, line.level, facility))
        return false;
    line.facility = facility;
    line.hasPriority = true;

    ulong microseconds;
    if (!readNumber64(s, line.seq) || !readChar(s, ',') || !readNumber64(s, microseconds) || !readChar(s, ','))
        return false;
    const semicolon = s.indexOf(';');
    if (semicolon < 0)
        return false; // the flags and further fields end with ';'
    line.timeNs = cast(long) microseconds * 1000;
    line.timeKind = TimeKind.SinceBoot;
    line.message = s[semicolon + 1 .. $];
    return true;
}

//! An optional "<priority>" prefix (formats.syslog.priority). The kernel's
//! own messages have facility 0 (kern); others write to the kernel buffer
//! too, e.g. systemd as daemon (<30> is daemon.info).
private bool readLinePriority(ref const(char)[] s, ref DmesgLine line) pure nothrow @nogc @safe
{
    string facility;
    if (!readPriority(s, line.hasPriority, line.level, facility))
        return false;
    line.facility = facility;
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
    if (!readMonthDayTime(s, month, day, timeOfDay) || !skipSpaces(s) || !readDigits(s, 4, year)
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
    if (colon2 <= 0 || !severityByName(s[0 .. colon2].strip, level) || facility.length == 0)
        return false;
    s = s[colon2 + 1 .. $];
    return skipSpaces(s);
}

private bool parseLine(DmesgFormat.Variant variant, const(char)[] s, out DmesgLine line) pure nothrow @nogc @safe
{
    final switch (variant)
    {
    case DmesgFormat.Variant.Monotonic:
    case DmesgFormat.Variant.Raw:
        line.timeKind = TimeKind.SinceBoot;
        if (!readLinePriority(s, line) || !readMonotonic(s, line.timeNs))
            return false;
        break;
    case DmesgFormat.Variant.Decoded:
        line.timeKind = TimeKind.SinceBoot;
        if (!readDecodedPrefix(s, line.facility, line.level) || !readMonotonic(s, line.timeNs))
            return false;
        break;
    case DmesgFormat.Variant.Kmsg:
        return parseKmsg(s, line);
    case DmesgFormat.Variant.WallClock:
        line.timeKind = TimeKind.Local;
        if (!readLinePriority(s, line) || !readWallClock(s, line.timeNs))
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

@("DmesgFormat: a raw priority gives the facility and the level (dmesg -r, /dev/kmsg)")
unittest
{
    LogMessage!wchar msg;
    decodeLine(DmesgFormat.Variant.Raw, "<30>[    4.500000] systemd[1]: Started x", msg);
    assert(msg.level == LogLevel.Info, "30 = daemon (3) * 8 + info (6)");
    assert(msg.text(DmesgField.Facility) == "daemon"w);
    assert(msg.timeKind == TimeKind.SinceBoot && msg.timeNs == 4 * second + second / 2);
    assert(msg.payloadText == "systemd[1]: Started x"w);

    decodeLine(DmesgFormat.Variant.Raw, "<3>[    1.000000] disk", msg);
    assert(msg.level == LogLevel.Error && msg.text(DmesgField.Facility) == "kern"w);

    decodeLine(DmesgFormat.Variant.Raw, "<134>[    1.000000] l", msg);
    assert(msg.level == LogLevel.Info && msg.text(DmesgField.Facility) == "local0"w);

    // The plain variant reads such lines too instead of keeping them as text
    decodeLine(DmesgFormat.Variant.Monotonic, "<30>[    4.500000] systemd[1]: x", msg);
    assert(msg.level == LogLevel.Info && msg.payloadText == "systemd[1]: x"w);
}

@("DmesgFormat: the raw variant shows the facility")
unittest
{
    string[] ids;
    foreach (column; new DmesgFormat(DmesgFormat.Variant.Raw).columns)
        ids ~= column.id;
    assert(ids == ["time", "facility", "level", "payload"]);
}

@("DmesgDetector: lines with a priority are the raw variant")
unittest
{
    auto d = new DmesgDetector().detect("x.log",
        bytes("<6>[    0.000000] Linux version\n<30>[    4.5] systemd[1]: x\n[    5.0] no prefix\n"));
    assert(d.score > 0.5f && d.variant == DmesgFormat.Variant.Raw, "most lines have a priority");
}

@("DmesgDetector: takes no memory per sample line")
unittest
{
    import core.memory : GC;
    import std.array : replicate;

    const sample = bytes("[    0.000000] Linux version 6.1\n".replicate(2000));
    auto detector = new DmesgDetector();
    const before = GC.allocatedInCurrentThread;
    detector.detect("dmesg.txt", sample);
    assert(GC.allocatedInCurrentThread - before < 1024, "allocates per line");
}

@("DmesgFormat /dev/kmsg: priority, sequence number, time and message")
unittest
{
    LogMessage!wchar msg;
    decodeLine(DmesgFormat.Variant.Kmsg, "6,339,5140900,-;usb 1-1: new device", msg);
    assert(msg.level == LogLevel.Info && msg.text(DmesgField.Facility) == "kern"w);
    assert(msg.number(DmesgField.Seq) == 339);
    assert(msg.timeKind == TimeKind.SinceBoot && msg.timeNs == 5_140_900_000);
    assert(msg.payloadText == "usb 1-1: new device"w);

    decodeLine(DmesgFormat.Variant.Kmsg, "6,1234567890,12345678901,-;late", msg);
    assert(msg.number(DmesgField.Seq) == 1_234_567_890 && msg.timeNs == 12_345_678_901_000,
        "past 9 digits: an hour after boot");

    decodeLine(DmesgFormat.Variant.Kmsg, "30,12,4500000,-,caller=T1;systemd[1]: x", msg);
    assert(msg.text(DmesgField.Facility) == "daemon"w && msg.payloadText == "systemd[1]: x"w,
        "fields after the flags are skipped");
}

@("DmesgFormat /dev/kmsg: the dictionary lines belong to their record")
unittest
{
    auto format = new DmesgFormat(DmesgFormat.Variant.Kmsg);
    const data = bytes("6,1,100,-;first\n SUBSYSTEM=usb\n DEVICE=c189:1\n6,2,200,-;second\n");
    size_t[4] offsets;
    const r = format.scanRecords(data, 0, offsets[], true);
    assert(r.count == 2 && offsets[1] == data.length - "6,2,200,-;second\n".length);

    LogMessage!wchar msg;
    assert(format.decode(msg, format.recordAt(data, 0)));
    assert(msg.payloadText == "first\n SUBSYSTEM=usb\n DEVICE=c189:1"w);
}

@("DmesgFormat /dev/kmsg: columns, detection, and lines that don't fit")
unittest
{
    string[] ids;
    foreach (column; new DmesgFormat(DmesgFormat.Variant.Kmsg).columns)
        ids ~= column.id;
    assert(ids == ["time", "facility", "level", "seq", "payload"]);

    const d = new DmesgDetector().detect("kmsg", bytes("6,1,100,-;a\n SUBSYSTEM=usb\n4,2,200,-;b\n"));
    assert(d.score > 0.5f && d.variant == DmesgFormat.Variant.Kmsg);

    LogMessage!wchar msg;
    decodeLine(DmesgFormat.Variant.Kmsg, "6,x,100,-;bad sequence", msg);
    assert(msg.timeKind == TimeKind.None && msg.payloadText == "6,x,100,-;bad sequence"w);
}
