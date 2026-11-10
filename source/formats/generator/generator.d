//! The log generator: writes a log of a format, size and content as the options ask
//! (formats/generator/content), the same bytes for the same seed, with records broken on
//! purpose if asked. For big files, edge cases and benchmarks on data everyone has; the tool
//! is scripts/gen_log.d. Not in the program: only in unittests and with -d-version=LogGenerator.
module formats.generator.generator;

version (unittest)
    version = LogGeneratorCode;
else version (LogGenerator)
    version = LogGeneratorCode;

version (LogGeneratorCode):

public import formats.generator.content : Corruption, GenFormat, GenOptions, corruptionNames,
    corruptionsOf, genFormatNames, parseCorruption, parseGenFormat;
import formats.generator.content : Rng;

//! What was written
struct GenStats
{
    ulong records; // whole or broken (a junk line of text stands for a record)
    ulong bytes;
    ulong[Corruption.max + 1] corrupted; // records broken, by the way
    bool truncated; // the last record is cut

    ulong totalCorrupted() const pure nothrow @nogc @safe
    {
        ulong total = 0;
        foreach (n; corrupted)
            total += n;
        return total;
    }
}

//! @brief Generates a log, giving its bytes to `sink` record by record: nothing is kept
//! but the record being made.
//! @throws Exception for options that make no log (GenOptions.validate)
GenStats generateLog(in GenOptions options, scope void delegate(const(ubyte)[] bytes) sink)
{
    import formats.generator.content : ContentSource, RecordContent;
    import formats.generator.dlt : breakHeaderType, dltRecord, lengthOf, setLength;
    import formats.generator.text : junkLine, longLine, plainTextRecord;
    import log_core.text.text_format : TextFormat;

    options.validate();
    const isText = options.format == GenFormat.text;
    const v2 = options.format == GenFormat.dltV2;
    auto content = ContentSource(options, !isText); // a plain text record is one line
    auto kinds = options.corruptionKinds();
    RecordContent r;
    GenStats stats;
    ubyte[] pending; // the last record is held back: it may be cut

    while (options.count ? stats.records < options.count : stats.bytes < options.size)
    {
        content.next(r);
        const broken = content.rng.chance(options.corrupt);
        const kind = broken ? kinds[content.rng.below(kinds.length)] : Corruption.init;

        ubyte[] bytes;
        if (isText)
        {
            if (broken && kind == Corruption.garbage)
                bytes = junkLine(content.rng);
            else if (broken && kind == Corruption.longLine)
                bytes = longLine(content.rng, TextFormat.maxRecordLength);
            else
                bytes = plainTextRecord(r);
        }
        else
        {
            long timeUs = r.timeUs;
            if (broken && kind == Corruption.timeBackwards)
            {
                const back = content.rng.between(1, 3600) * 1_000_000;
                timeUs -= back < timeUs ? back : timeUs; // not before the epoch
            }
            bytes = dltRecord(r, timeUs, v2);
            if (broken && kind == Corruption.badHeader)
                breakHeaderType(bytes, v2);
            else if (broken && kind == Corruption.badLength)
            {
                const length = lengthOf(bytes, v2);
                setLength(bytes, v2, content.rng.chance(0.5)
                    ? cast(ushort) content.rng.below(4) // shorter than any header
                    : cast(ushort)(length + content.rng.between(1, ushort.max - length)));
            }
            else if (broken && kind == Corruption.garbage)
                bytes = dltGarbage(content.rng) ~ bytes;
        }
        if (broken)
            stats.corrupted[kind]++;

        if (pending !is null)
            sink(pending);
        pending = bytes;
        stats.records++;
        stats.bytes += bytes.length;
    }
    if (pending !is null)
    {
        if (options.truncate)
        {
            stats.bytes -= pending.length - pending.length / 2;
            pending = pending[0 .. pending.length / 2];
            stats.truncated = true;
        }
        sink(pending);
    }
    return stats;
}

//! @returns 1 to 64 bytes that hold no storage header: no 'D' starts one
private ubyte[] dltGarbage(ref Rng rng)
{
    auto bytes = new ubyte[rng.between(1, 64)];
    foreach (ref b; bytes)
    {
        b = cast(ubyte) rng.below(256);
        if (b == 'D')
            b = 'd';
    }
    return bytes;
}

// ─── Tests ──────────────────────────────────────────────────────────────────

version (unittest)
{
    import formats.registry : detectFormat;
    import log_core.log_format : FormatChoice;
    import log_core.log_message : LogMessage;

    private ubyte[] generated(in GenOptions options, out GenStats stats)
    {
        ubyte[] all;
        stats = generateLog(options, (const(ubyte)[] bytes) { all ~= bytes; });
        return all;
    }

    private ubyte[] generated(in GenOptions options)
    {
        GenStats stats;
        return generated(options, stats);
    }

    private GenOptions optionsOf(GenFormat format, ulong count)
    {
        GenOptions o;
        o.format = format;
        o.count = count;
        return o;
    }

    //! What the program finds in a log, as its index reads a file
    private struct Read
    {
        string formatId;
        size_t records; // found by the scan
        size_t decoded; // of them, decoded
    }

    private Read readAll(const(ubyte)[] data, GenFormat format)
    {
        FormatChoice choice;
        auto logFormat = detectFormat(format == GenFormat.text ? "generated.log" : "generated.dlt",
            data, choice);
        Read read;
        read.formatId = choice.id;
        LogMessage!wchar msg;
        size_t[64] offsets;
        size_t pos = 0;
        while (pos < data.length)
        {
            const r = logFormat.scanRecords(data, pos, offsets[], true);
            assert(r.next > pos || r.count > 0, "scanning must make progress");
            foreach (offset; offsets[0 .. r.count])
                if (logFormat.decode(msg, logFormat.recordAt(data, offset)))
                    read.decoded++;
            read.records += r.count;
            pos = r.next;
        }
        return read;
    }

    private immutable string[] formatIds = ["dlt", "dlt", "text"]; // of GenFormat in the program
}

@("generateLog: the same seed gives the same bytes, another seed others")
unittest
{
    foreach (format; [GenFormat.dlt, GenFormat.dltV2, GenFormat.text])
    {
        auto o = optionsOf(format, 200);
        o.cyrillic = 0.2;
        o.invalidUtf8 = 0.05;
        o.nonVerbose = 0.1;
        o.corrupt = 0.05;
        const first = generated(o);
        assert(first.length > 0);
        assert(generated(o) == first, genFormatNames[format]);
        o.seed = 2;
        assert(generated(o) != first, genFormatNames[format]);
    }
}

@("generateLog: a log is detected as its format and every record of it is read")
unittest
{
    foreach (format; [GenFormat.dlt, GenFormat.dltV2, GenFormat.text])
    {
        auto o = optionsOf(format, 1000);
        o.ecus = 3;
        o.cyrillic = 0.2;
        o.invalidUtf8 = 0.02;
        o.multiline = 0.05;
        o.nonVerbose = format == GenFormat.text ? 0 : 0.1;
        GenStats stats;
        const read = readAll(generated(o, stats), format);
        assert(stats.records == 1000);
        assert(read.formatId == formatIds[format], genFormatNames[format]);
        assert(read.records == 1000 && read.decoded == 1000, genFormatNames[format]);
    }
}

@("generateLog: a size is reached by whole records")
unittest
{
    foreach (format; [GenFormat.dlt, GenFormat.dltV2, GenFormat.text])
    {
        GenOptions o;
        o.format = format;
        o.size = 100_000;
        GenStats stats;
        const data = generated(o, stats);
        assert(data.length == stats.bytes);
        assert(data.length >= 100_000 && data.length < 100_000 + 1000, genFormatNames[format]);
        assert(readAll(data, format).records == stats.records, genFormatNames[format]);
    }
}

@("generateLog: about the share of records asked is broken, by every kind of the format")
unittest
{
    foreach (format; [GenFormat.dlt, GenFormat.dltV2, GenFormat.text])
    {
        auto o = optionsOf(format, 4000);
        o.corrupt = 0.05;
        GenStats stats;
        generated(o, stats);
        assert(stats.totalCorrupted >= 150 && stats.totalCorrupted <= 250, genFormatNames[format]);
        foreach (kind; corruptionsOf(format))
            assert(stats.corrupted[kind] > 0, corruptionNames[kind]);
    }
}

@("generateLog: only the corruptions asked")
unittest
{
    auto o = optionsOf(GenFormat.dlt, 1000);
    o.corrupt = 0.1;
    o.corruptions = [Corruption.garbage, Corruption.longLine]; // the long line is of text only
    GenStats stats;
    generated(o, stats);
    assert(stats.corrupted[Corruption.garbage] == stats.totalCorrupted && stats.totalCorrupted > 0);

    import std.exception : assertThrown;

    o.corruptions = [Corruption.longLine];
    assertThrown(generated(o), "no corruption of the format");
}

@("generateLog: DLT junk between records and broken times hide no record")
unittest
{
    foreach (format; [GenFormat.dlt, GenFormat.dltV2])
    {
        auto o = optionsOf(format, 2000);
        o.corrupt = 0.1;
        o.corruptions = [Corruption.garbage, Corruption.timeBackwards];
        const read = readAll(generated(o), format);
        assert(read.records == 2000 && read.decoded == 2000, genFormatNames[format]);
    }
}

@("generateLog: a time going back stops at the epoch")
unittest
{
    import std.bitmanip : littleEndianToNative;

    auto o = optionsOf(GenFormat.dlt, 200);
    o.startSeconds = 0;
    o.corrupt = 0.5;
    o.corruptions = [Corruption.timeBackwards];
    const data = generated(o);
    auto format = detectFormat("generated.dlt", data);
    size_t[256] offsets;
    const r = format.scanRecords(data, 0, offsets[], true);
    assert(r.count == 200);
    foreach (offset; offsets[0 .. r.count])
    {
        ubyte[4] seconds = data[offset + 4 .. offset + 8];
        assert(littleEndianToNative!uint(seconds) < 1000, "not wrapped past 1970");
    }
}

@("generateLog: a DLT record with a broken header is not read, the next ones are")
unittest
{
    foreach (format; [GenFormat.dlt, GenFormat.dltV2])
    {
        auto o = optionsOf(format, 2000);
        o.corrupt = 0.05;
        o.corruptions = [Corruption.badHeader];
        GenStats stats;
        const read = readAll(generated(o, stats), format);
        assert(read.decoded == 2000 - stats.totalCorrupted, genFormatNames[format]);
    }
}

@("generateLog: a DLT log with broken lengths reads to its end")
unittest
{
    foreach (format; [GenFormat.dlt, GenFormat.dltV2])
    {
        auto o = optionsOf(format, 2000);
        o.corrupt = 0.05;
        o.corruptions = [Corruption.badLength];
        GenStats stats;
        // readAll asserts the scan makes progress to the end; how many records a broken
        // length hides is up to the scanner (docs/backlog.md, "сломанная длина")
        const read = readAll(generated(o, stats), format);
        assert(stats.corrupted[Corruption.badLength] > 0 && read.decoded > 0, genFormatNames[format]);
    }
}

@("generateLog: a broken text is a junk line or a long line cut in two")
unittest
{
    auto o = optionsOf(GenFormat.text, 2000);
    o.corrupt = 0.05;
    GenStats stats;
    const read = readAll(generated(o, stats), GenFormat.text);
    assert(stats.corrupted[Corruption.garbage] > 0 && stats.corrupted[Corruption.longLine] > 0);
    assert(read.formatId == "text");
    assert(read.records == stats.records + stats.corrupted[Corruption.longLine]);
}

@("generateLog: the last record cut is left out by the reader")
unittest
{
    foreach (format; [GenFormat.dlt, GenFormat.dltV2, GenFormat.text])
    {
        auto o = optionsOf(format, 100);
        o.truncate = true;
        GenStats stats;
        const data = generated(o, stats);
        assert(stats.truncated);
        const read = readAll(data, format);
        // a text line cut is still a line, without its end
        assert(read.records == (format == GenFormat.text ? 100 : 99), genFormatNames[format]);
    }
}

@("generateLog: refuses options that make no log")
unittest
{
    import std.exception : assertThrown;

    GenOptions o;
    assertThrown(generateLog(o, (const(ubyte)[]) {}));
}
