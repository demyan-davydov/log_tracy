module domain.format_registry;

import log_core.log_format;
import dlt_core.dlt_format : DltDetector;
import formats.logcat : LogcatDetector;
import formats.plain_text : PlainTextDetector;

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
