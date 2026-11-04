module formats.registry;

import log_core.log_format;
import formats.dlt.format : DltDetector;
import formats.access_log : AccessLogDetector;
import formats.can.candump : CandumpDetector;
import formats.dmesg : DmesgDetector;
import formats.logcat : LogcatDetector;
import formats.plain_text : PlainTextDetector;
import formats.syslog.syslog : SyslogDetector;
import formats.can.vector_asc : AscDetector;

import std.algorithm : canFind, countUntil, filter, map, min;
import std.array : array;

//! Bytes from the start of the data the detectors look at
enum size_t detectionHeadSize = 64 * 1024;

//! @brief Picks the format that fits the data best.
//! @param path - name of the source, a hint for the detectors (its extension)
//! @throws Exception if no format fits
LogFormat detectFormat(string path, const(ubyte)[] data)
{
    FormatChoice choice;
    return detectFormat(path, data, choice);
}

//! @brief Picks the format that fits the data best.
//! @param choice - set to the detector and variant picked, to open the data
//! the same way later with createFormat()
//! @throws Exception if no format fits
LogFormat detectFormat(string path, const(ubyte)[] data, out FormatChoice choice)
{
    const head = data[0 .. min(data.length, detectionHeadSize)];

    auto all = detectors();
    size_t best = all.length;
    Detection bestDetection;
    foreach (i, detector; all)
    {
        const detection = detector.detect(path, head);
        if (detection.score > bestDetection.score)
        {
            best = i;
            bestDetection = detection;
        }
    }

    if (best == all.length)
        throw new Exception("unknown log format");
    choice = FormatChoice(all[best].info.id, bestDetection.variant);
    return all[best].create(bestDetection.variant, head);
}

//! @brief Creates the format chosen before (by detection or by the user),
//! without detecting it again
//! @throws Exception if no format has the id of `choice`
LogFormat createFormat(FormatChoice choice, const(ubyte)[] data)
{
    foreach (detector; detectors())
        if (detector.info.id == choice.id)
            return detector.create(choice.variant, data[0 .. min(data.length, detectionHeadSize)]);
    throw new Exception("unknown log format \"" ~ choice.id ~ "\"");
}

//! @returns the format with the id, or FormatInfo.init if there is none
FormatInfo formatInfo(string id)
{
    foreach (detector; detectors())
        if (detector.info.id == id)
            return detector.info;
    return FormatInfo.init;
}

//! @returns every format this build has, in the order of detection
FormatInfo[] formatInfos()
{
    FormatInfo[] all;
    foreach (detector; detectors())
        all ~= detector.info;
    return all;
}

//! @brief The columns of the format with the id: those of all its variants,
//! each once, in the order of the format, Payload last.
//! @returns null if no format has the id
const(ColumnInfo)[] formatColumns(string id)
{
    import log_core.column_layout : mergeOrder, movableIds;

    foreach (detector; detectors())
    {
        if (detector.info.id != id)
            continue;
        const(ColumnInfo)[] all; // the first one of each id
        string[] order; // of the movable ones
        const(ColumnInfo)[] payload;
        foreach (variant; detector.variants())
        {
            const columns = detector.create(variant, null).columns;
            foreach (ref column; columns)
                if (!all.canFind!(c => c.id == column.id))
                    all ~= column;
            if (payload is null)
                payload = columns.filter!(c => c.kind == ColumnKind.Payload).array;
            order = mergeOrder(order, movableIds(columns));
        }
        return order.map!(o => all[all.countUntil!(c => c.id == o)]).array ~ payload;
    }
    return null;
}

private const(FormatDetector)[] detectors()
{
    // Built on each detection: a file is opened rarely
    const(FormatDetector)[] all;
    all ~= new DltDetector();
    all ~= new LogcatDetector();
    all ~= new DmesgDetector();
    all ~= new SyslogDetector();
    all ~= new AccessLogDetector();
    all ~= new CandumpDetector();
    all ~= new AscDetector();
    all ~= new PlainTextDetector();
    return all;
}

@("detectFormat: a DLT file is detected as DLT")
unittest
{
    import formats.dlt.format : DltFormat, buildDltMessage;

    auto format = detectFormat("x.dlt", buildDltMessage());
    assert(cast(DltFormat) format !is null);
}

@("detectFormat: logcat, plain text, and an error for binary data")
unittest
{
    import formats.logcat : LogcatFormat;
    import formats.plain_text : PlainTextFormat;
    import std.exception : assertThrown;

    auto logcat = cast(const(ubyte)[]) "11-03 14:22:01.123  1234  1250 I Tag: text\n";
    assert(cast(LogcatFormat) detectFormat("x.txt", logcat) !is null);
    assert(cast(PlainTextFormat) detectFormat("x.dlt", cast(const(ubyte)[]) "notes\n") !is null,
        "the content wins over the extension");
    assertThrown(detectFormat("x.bin", cast(const(ubyte)[])[0x01, 0x00, 0x02]));
}

@("detectFormat: an empty .dlt file is DLT, an empty file of another name is text")
unittest
{
    import formats.dlt.format : DltFormat;
    import formats.plain_text : PlainTextFormat;

    assert(cast(DltFormat) detectFormat("capture.dlt", null) !is null);
    assert(cast(PlainTextFormat) detectFormat("notes.log", null) !is null);
}

@("detectFormat: a kernel log is dmesg, not logcat or text")
unittest
{
    import formats.dmesg : DmesgFormat;

    auto dmesg = cast(const(ubyte)[]) "[    0.000000] Linux version 6.1\n[    0.000002] BIOS-provided map\n";
    assert(cast(DmesgFormat) detectFormat("dmesg.txt", dmesg) !is null);
}

@("detectFormat: a syslog file is syslog, not text")
unittest
{
    import formats.syslog.syslog : SyslogFormat;

    auto syslog = cast(const(ubyte)[]) "Nov  3 14:22:01 host sshd[812]: a\nNov  3 14:22:02 host cron[9]: b\n";
    assert(cast(SyslogFormat) detectFormat("syslog", syslog) !is null);
}

@("detectFormat: a logcat -v year file stays logcat when some lines don't parse")
unittest
{
    import formats.logcat : LogcatFormat;

    // The second line has an unknown level letter
    auto logcat = cast(const(ubyte)[]) ("2026-11-03 14:22:01.123  1  2 I T: a\n"
            ~ "2026-11-03 14:22:01.124  1  2 X T: b\n2026-11-03 14:22:01.125  1  2 D T: c\n");
    assert(cast(LogcatFormat) detectFormat("x.log", logcat) !is null);
}

@("detectFormat: a web server access log")
unittest
{
    import formats.access_log : AccessLogFormat;

    auto log = cast(const(ubyte)[]) (`127.0.0.1 - - [10/Oct/2026:13:55:36 -0700] "GET / HTTP/1.0" 200 2326` ~ "\n");
    assert(cast(AccessLogFormat) detectFormat("access.log", log) !is null);
}

@("detectFormat: CAN traces of candump and Vector ASC")
unittest
{
    import formats.can.candump : CandumpFormat;
    import formats.can.vector_asc : AscFormat;

    auto candump = cast(const(ubyte)[]) "(1762179721.123456) can0 123#DEADBEEF\n(1762179721.2) can0 7FF#\n";
    assert(cast(CandumpFormat) detectFormat("trace.log", candump) !is null);

    auto asc = cast(const(ubyte)[]) ("date Tue Nov 3 02:22:01.123 pm 2026\nbase hex  timestamps absolute\n"
            ~ "   0.000000 Start of measurement\n   0.001234 1  123  Rx   d 1 00\n");
    assert(cast(AscFormat) detectFormat("trace.asc", asc) !is null);
}

@("detectFormat: reports the detector and variant it picked")
unittest
{
    import formats.syslog.syslog : syslogFormatInfo;

    FormatChoice choice;
    auto syslog = cast(const(ubyte)[]) "Nov  3 14:22:01 host sshd[812]: a\nNov  3 14:22:02 host cron[9]: b\n";
    detectFormat("syslog", syslog, choice);
    assert(choice.id == syslogFormatInfo.id);
    assert(choice == FormatChoice(syslogFormatInfo.id, syslogDetection(syslog).variant));
}

version (unittest) private Detection syslogDetection(const(ubyte)[] head)
{
    import formats.syslog.syslog : SyslogDetector;

    return new SyslogDetector().detect("syslog", head);
}

@("createFormat: creates the chosen format even when another one fits better")
unittest
{
    import formats.logcat : LogcatFormat, logcatFormatInfo;
    import formats.plain_text : PlainTextFormat, plainTextFormatInfo;

    auto logcat = cast(const(ubyte)[]) "11-03 14:22:01.123  1234  1250 I Tag: text\n";
    assert(cast(PlainTextFormat) createFormat(FormatChoice(plainTextFormatInfo.id), logcat) !is null);

    FormatChoice choice;
    detectFormat("x.txt", logcat, choice);
    assert(cast(LogcatFormat) createFormat(choice, logcat) !is null);
    assert(createFormat(choice, logcat).columns == detectFormat("x.txt", logcat).columns,
        "the same variant");
}

@("createFormat: an unknown format id is an error")
unittest
{
    import std.exception : assertThrown;

    assertThrown(createFormat(FormatChoice("no-such-format"), null));
}

@("createFormat: a variant the format doesn't have is an error, not a broken format")
unittest
{
    import formats.access_log : accessLogFormatInfo;
    import formats.dmesg : dmesgFormatInfo;
    import formats.logcat : logcatFormatInfo;
    import formats.syslog.syslog : syslogFormatInfo;
    import std.exception : assertThrown;

    foreach (id; [accessLogFormatInfo.id, dmesgFormatInfo.id, logcatFormatInfo.id, syslogFormatInfo.id])
    {
        assertThrown(createFormat(FormatChoice(id, 99), null), id);
        assertThrown(createFormat(FormatChoice(id, -1), null), id);
    }
}

@("formatInfo: every format has a unique id and a three-letter badge")
unittest
{
    import std.ascii : isUpper, isDigit;
    import std.algorithm.searching : all;

    string[] ids;
    foreach (detector; detectors())
    {
        const info = detector.info;
        assert(info.id.length && info.name.length, info.id);
        assert(info.shortName.length == 3 && info.shortName.all!(c => isUpper(c) || isDigit(c)), info.shortName);
        foreach (id; ids)
            assert(id != info.id, "duplicate id " ~ id);
        ids ~= info.id;
        assert(formatInfo(info.id) == info);
    }
    assert(formatInfo("no-such-format") == FormatInfo.init);
}

@("formatInfos: every format, each once")
unittest
{
    import std.algorithm : canFind, map;
    import std.array : array;
    import formats.dlt.format : dltFormatInfo;
    import formats.plain_text : plainTextFormatInfo;

    const ids = formatInfos().map!(f => f.id).array;
    assert(ids.canFind(dltFormatInfo.id));
    assert(ids.canFind(plainTextFormatInfo.id));
    assert(ids.length == detectors().length);
}

@("formatColumns: the columns of all the variants of a format, Payload last")
unittest
{
    import std.algorithm : count, map;
    import std.array : array;
    import formats.logcat : logcatFormatInfo;
    import formats.syslog.syslog : syslogFormatInfo;

    // Brief has no time and no thread: the columns of Threadtime are kept in their place
    assert(formatColumns(logcatFormatInfo.id).map!(c => c.id).array
            == ["time", "pid", "tid", "level", "tag", "payload"]);

    const syslog = formatColumns(syslogFormatInfo.id).map!(c => c.id).array;
    assert(syslog[$ - 1] == "payload");
    foreach (id; ["time", "host", "app", "pid", "msgid", "level", "data"])
        assert(syslog.count(id) == 1, id);

    assert(formatColumns("no-such-format") is null);
}

@("formatColumns: every format has Payload last, and its ids are unique")
unittest
{
    import std.algorithm : count, map;
    import log_core.log_format : ColumnKind;

    foreach (info; formatInfos())
    {
        const columns = formatColumns(info.id);
        assert(columns.length && columns[$ - 1].kind == ColumnKind.Payload, info.id);
        foreach (column; columns)
            assert(columns.map!(c => c.id).count(column.id) == 1, info.id ~ ": " ~ column.id);
    }
}

@("formatColumns: the variants of a format agree on the order of their common columns")
unittest
{
    import std.algorithm : countUntil;
    import std.conv : to;
    import log_core.column_layout : movableIds;

    // One layout serves all the variants: a variant that ordered two columns
    // the other way would get them reordered by the default layout
    foreach (detector; detectors())
    {
        const order = movableIds(formatColumns(detector.info.id));
        foreach (variant; detector.variants())
        {
            const ids = movableIds(detector.create(variant, null).columns);
            foreach (i; 1 .. ids.length)
                assert(order.countUntil(ids[i - 1]) < order.countUntil(ids[i]),
                    detector.info.id ~ " variant " ~ variant.to!string ~ ": " ~ ids[i - 1] ~ ", " ~ ids[i]);
        }
    }
}
