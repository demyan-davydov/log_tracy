//! The command line of the log generator (scripts/gen_log.d): its help and the options it
//! turns into GenOptions. Not in the program: only in unittests and with -d-version=LogGenerator.
module formats.generator.command_line;

version (unittest)
    version = LogGeneratorCode;
else version (LogGenerator)
    version = LogGeneratorCode;

version (LogGeneratorCode):

import std.conv : to;
import std.exception : enforce;
import std.format : format;

import formats.generator.content;

//! What --help prints
enum genLogUsage = `Writes a test log of a format, size and content: the same options and seed give the
same file, byte for byte.

Usage: node scripts/build.mjs gen-log <file> --format <format> (--count N | --size N) [options]
       (or build/tools/gen_log <file> ... once built)

  --format F          dlt (protocol and storage header of version 1), dlt-v2, text
  --count N           records
  --size N            bytes: records until the file holds as many; K, M, G (1024s): --size 1G
  --seed N            1 by default
Content:
  --ecus N --apps N --contexts N
                      how many of each (2, 5, 10; up to 999)
  --levels F,E,W,I,D,V
                      weights of fatal, error, warn, info, debug, verbose (1,4,10,60,20,5)
  --payload MIN..MAX  bytes of the text of a record (10..120; up to 60000)
  --multiline P       texts of more than one line (DLT; plain text has a record per line)
  --cyrillic P        Cyrillic words (5%)
  --invalid-utf8 P    texts with a byte that is not UTF-8
  --non-verbose P     DLT: non-verbose messages
  --start DATE        the time of the first record: 2026-01-01 or 2026-01-01T08:30:00 (UTC)
  --step-us N         the mean time between records, microseconds (1000)
Broken on purpose:
  --corrupt P         records broken by the kinds of the format
  --corruptions K,... only these kinds: garbage, bad-header, bad-length, time-backwards (DLT);
                      garbage, long-line (text)
  --truncate          the last record cut in half
A share P is 10% or 0.1.
`;

//! What the command line asks: the file to write and the log
struct GenCommand
{
    string path;
    GenOptions options;
    bool help;
}

//! @throws Exception for a command line not understood
GenCommand parseGenCommand(string[] args)
{
    import std.algorithm : canFind, map, splitter;
    import std.array : array;
    import std.getopt : getopt, config;

    GenCommand command;
    if (args[1 .. $].canFind("--help") || args[1 .. $].canFind("-h"))
    {
        command.help = true;
        return command;
    }
    string formatName, size, levels, payload, start, corruptions;
    string multiline, cyrillic, invalidUtf8, nonVerbose, corrupt;
    auto o = &command.options;
    getopt(args, config.passThrough,
        "format", &formatName, "count", &o.count, "size", &size, "seed", &o.seed,
        "ecus", &o.ecus, "apps", &o.apps, "contexts", &o.contexts, "levels", &levels,
        "payload", &payload, "multiline", &multiline, "cyrillic", &cyrillic,
        "invalid-utf8", &invalidUtf8, "non-verbose", &nonVerbose, "start", &start,
        "step-us", &o.stepMicroseconds, "corrupt", &corrupt, "corruptions", &corruptions,
        "truncate", &o.truncate);

    foreach (arg; args[1 .. $])
        enforce(arg.length == 0 || arg[0] != '-', format("unknown option %s", arg));
    enforce(args.length == 2, args.length < 2 ? "no file to write" : "one file only");
    command.path = args[1];
    enforce(formatName.length, "no --format: one of dlt, dlt-v2, text");
    o.format = parseGenFormat(formatName);
    if (size.length)
        o.size = parseSize(size);
    if (levels.length)
    {
        const weights = levels.splitter(',').map!(to!uint).array;
        enforce(weights.length == 6, "--levels: six weights, fatal to verbose");
        o.levelWeights = weights[0 .. 6];
    }
    if (payload.length)
        parseRange(payload, o.payloadMin, o.payloadMax);
    void share(string text, ref double value)
    {
        if (text.length)
            value = parseShare(text);
    }

    share(multiline, o.multiline);
    share(cyrillic, o.cyrillic);
    share(invalidUtf8, o.invalidUtf8);
    share(nonVerbose, o.nonVerbose);
    share(corrupt, o.corrupt);
    if (corruptions.length)
        o.corruptions = corruptions.splitter(',').map!parseCorruption.array;
    if (start.length)
        o.startSeconds = parseStart(start);
    o.validate();
    return command;
}

//! @returns the bytes of "512", "64K", "500M", "1G" (in 1024s)
ulong parseSize(string text)
{
    import core.checkedint : mulu;

    enforce(text.length, "an empty size");
    ulong unit = 1;
    switch (text[$ - 1])
    {
    case 'K', 'k':
        unit = 1UL << 10;
        break;
    case 'M', 'm':
        unit = 1UL << 20;
        break;
    case 'G', 'g':
        unit = 1UL << 30;
        break;
    default:
        return text.to!ulong;
    }
    bool overflow;
    const size = mulu(text[0 .. $ - 1].to!ulong, unit, overflow);
    enforce(!overflow, format("\"%s\": too big a size", text));
    return size;
}

//! @returns the share of "10%" or "0.1"
double parseShare(string text)
{
    enforce(text.length, "an empty share");
    if (text[$ - 1] == '%')
        return text[0 .. $ - 1].to!double / 100;
    return text.to!double;
}

//! Reads "MIN..MAX"
void parseRange(string text, out uint min, out uint max)
{
    import std.string : indexOf;

    const dots = text.indexOf("..");
    enforce(dots > 0, format("\"%s\": MIN..MAX expected", text));
    min = text[0 .. dots].to!uint;
    max = text[dots + 2 .. $].to!uint;
}

//! @returns the seconds since the epoch of "2026-01-01" or "2026-01-01T08:30:00", in UTC
long parseStart(string text)
{
    import std.datetime : Date, DateTime, SysTime, TimeOfDay, UTC;

    import std.ascii : isDigit;

    static immutable shape = "0000-00-00T00:00:00"; // 0: a digit
    bool fits = text.length == 10 || text.length == shape.length;
    foreach (i, c; fits ? text : null)
        fits &= shape[i] == '0' ? c.isDigit : c == shape[i];
    enforce(fits, format("\"%s\": a date YYYY-MM-DD or YYYY-MM-DDTHH:MM:SS expected", text));
    const month = text[5 .. 7].to!int;
    // std.datetime halts the process on a month outside 1..12 instead of throwing
    enforce(month >= 1 && month <= 12, format("\"%s\": no month %s", text, month));
    const date = Date(text[0 .. 4].to!int, month, text[8 .. 10].to!int);
    const time = text.length == 19
        ? TimeOfDay(text[11 .. 13].to!int, text[14 .. 16].to!int, text[17 .. 19].to!int) : TimeOfDay(0, 0, 0);
    return SysTime(DateTime(date, time), UTC()).toUnixTime;
}

@("parseGenCommand: the file, the format, a size and shares")
unittest
{
    const c = parseGenCommand(["gen_log", "big.dlt", "--format", "dlt-v2", "--size", "1G",
        "--seed", "7", "--non-verbose", "10%", "--payload", "5..50", "--corruptions", "garbage,bad-length",
        "--corrupt", "0.01", "--levels", "0,0,1,1,0,0", "--start", "2025-03-04T05:06:07", "--truncate"]);
    assert(c.path == "big.dlt" && !c.help);
    assert(c.options.format == GenFormat.dltV2);
    assert(c.options.size == 1UL << 30 && c.options.count == 0 && c.options.seed == 7);
    assert(c.options.nonVerbose == 0.1 && c.options.corrupt == 0.01);
    assert(c.options.payloadMin == 5 && c.options.payloadMax == 50);
    assert(c.options.corruptions == [Corruption.garbage, Corruption.badLength]);
    assert(c.options.levelWeights == [0, 0, 1, 1, 0, 0]);
    assert(c.options.startSeconds == 1_741_064_767);
    assert(c.options.truncate);
}

@("parseGenCommand: what is not understood is refused, --help is asked anywhere")
unittest
{
    import std.exception : assertThrown;

    assert(parseGenCommand(["gen_log", "x", "--format", "zzz", "--help"]).help);
    assertThrown(parseGenCommand(["gen_log", "x.dlt", "--count", "5"]), "no format");
    assertThrown(parseGenCommand(["gen_log", "--format", "dlt", "--count", "5"]), "no file");
    assertThrown(parseGenCommand(["gen_log", "x", "--format", "dlt", "--count", "5", "--fast"]));
    assertThrown(parseGenCommand(["gen_log", "x", "--format", "dlt", "--count", "5", "--start", "2026-13-01"]));
    assertThrown(parseGenCommand(["gen_log", "x", "--format", "dlt"]), "no count or size");
    assertThrown(parseGenCommand(["gen_log", "x", "--format", "dlt", "--count", "5", "--start", "2026/01/01"]));
    assertThrown(parseGenCommand(["gen_log", "x", "--format", "dlt", "--count", "5", "--start", "2100-01-01"]));
    assertThrown(parseGenCommand(["gen_log", "x", "--format", "dlt", "--size", "20000000000G"]));
}

@("parseSize, parseShare: units and percents")
unittest
{
    assert(parseSize("512") == 512 && parseSize("64K") == 65_536 && parseSize("3m") == 3 << 20);
    assert(parseShare("25%") == 0.25 && parseShare("0.5") == 0.5);
}
