module domain.format_registry;

import log_core.log_format;
import dlt_core.dlt_format : DltDetector;
import formats.access_log : AccessLogDetector;
import formats.dmesg : DmesgDetector;
import formats.logcat : LogcatDetector;
import formats.plain_text : PlainTextDetector;
import formats.syslog : SyslogDetector;

import std.algorithm.comparison : min;

//! Bytes from the start of the data the detectors look at
enum size_t detectionHeadSize = 64 * 1024;

//! @brief Picks the format that fits the data best.
//! @param path - name of the source, a hint for the detectors (its extension)
//! @throws Exception if no format fits
LogFormat detectFormat(string path, const(ubyte)[] data)
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
    return all[best].create(bestDetection.variant, head);
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
    all ~= new PlainTextDetector();
    return all;
}

@("detectFormat: a DLT file is detected as DLT")
unittest
{
    import dlt_core.dlt_format : DltFormat, buildDltMessage;

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
    import dlt_core.dlt_format : DltFormat;
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
    import formats.syslog : SyslogFormat;

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
