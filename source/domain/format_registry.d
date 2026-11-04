module domain.format_registry;

import log_core.log_format;
import dlt_core.dlt_format : DltDetector;

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
    return [new DltDetector()];
}

@("detectFormat: a DLT file is detected as DLT")
unittest
{
    import dlt_core.dlt_format : DltFormat, buildDltMessage;

    auto format = detectFormat("x.dlt", buildDltMessage());
    assert(cast(DltFormat) format !is null);
}
