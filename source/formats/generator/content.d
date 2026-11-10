//! What the log generator puts into records, whatever the format: the options of a log,
//! a random generator that gives the same numbers for a seed on every system and compiler,
//! and the content of records (IDs, level, time, text). Not in the program: only in unittests
//! and with -d-version=LogGenerator (scripts/gen_log.d).
module formats.generator.content;

version (unittest)
    version = LogGeneratorCode;
else version (LogGenerator)
    version = LogGeneratorCode;

version (LogGeneratorCode):

import log_core.log_level : LogLevel;

//! The formats the generator writes
enum GenFormat : ubyte
{
    dlt, // protocol and storage header of version 1
    dltV2, // protocol and storage header of version 2
    text, // plain text, a record per line
}

//! The names of GenFormat on the command line, in its order
immutable string[] genFormatNames = ["dlt", "dlt-v2", "text"];

//! @throws Exception for a name that is not of a format
GenFormat parseGenFormat(string name)
{
    return parseName!GenFormat(genFormatNames, "format", name);
}

//! @returns the member of E whose name in `names` (in the order of E) is `name`
//! @throws Exception naming the names expected
private E parseName(E)(const string[] names, string what, string name)
{
    import std.algorithm : countUntil;
    import std.format : format;
    import std.string : join;

    const i = names.countUntil(name);
    if (i < 0)
        throw new Exception(format("unknown %s \"%s\", expected one of: %s", what, name, names.join(", ")));
    return cast(E) i;
}

//! The ways a record is broken; each format has some of them (corruptionsOf)
enum Corruption : ubyte
{
    garbage, // junk before the record (DLT: bytes with no storage header; text: a junk line instead)
    badHeader, // DLT: a protocol version that does not exist
    badLength, // DLT: the length of the standard header too long or too short
    timeBackwards, // DLT: the time of the record before that of the one before it
    longLine, // text: a line longer than a record holds
}

//! The names of Corruption on the command line and in the report of the tool, in its order
immutable string[] corruptionNames = ["garbage", "bad-header", "bad-length", "time-backwards",
    "long-line"];

//! @throws Exception for a name that is not of a corruption
Corruption parseCorruption(string name)
{
    return parseName!Corruption(corruptionNames, "corruption", name);
}

//! @returns the ways the records of a format are broken
immutable(Corruption)[] corruptionsOf(GenFormat format) pure nothrow @nogc @safe
{
    static immutable dlt = [Corruption.garbage, Corruption.badHeader, Corruption.badLength,
        Corruption.timeBackwards];
    static immutable text = [Corruption.garbage, Corruption.longLine];
    return format == GenFormat.text ? text : dlt;
}

//! What log to generate. Shares are of the records, 0 to 1.
struct GenOptions
{
    GenFormat format;
    ulong count; // records; 0: up to `size` bytes
    ulong size; // bytes: records are written until the log holds at least this many
    ulong seed = 1; // the same seed and options give the same log, byte for byte

    uint ecus = 2;
    uint apps = 5;
    uint contexts = 10;
    uint[6] levelWeights = [1, 4, 10, 60, 20, 5]; // fatal, error, warn, info, debug, verbose
    uint payloadMin = 10; // bytes of the text of a record
    uint payloadMax = 120; // the last word may go a little past it

    double multiline = 0; // texts of more than one line (formats whose records may have them)
    double cyrillic = 0.05; // of the words
    double invalidUtf8 = 0; // texts with a byte that is not UTF-8
    double nonVerbose = 0; // DLT: non-verbose messages (a message ID and raw data)
    double corrupt = 0; // broken records, of the kinds of the format (Corruption)
    const(Corruption)[] corruptions; // the kinds to break records by; none: all of the format
    bool truncate; // the last record is cut in half: a log still being written

    long startSeconds = 1_767_225_600; // the time of the first record: 2026-01-01 00:00 UTC
    uint stepMicroseconds = 1000; // the mean time between records

    //! @throws Exception for options that make no log
    void validate() const
    {
        import std.algorithm : sum;

        void check(bool ok, string what)
        {
            if (!ok)
                throw new Exception(what);
        }

        check((count == 0) != (size == 0), "give either a count of records or a size");
        check(ecus >= 1 && ecus <= maxIds && apps >= 1 && apps <= maxIds
            && contexts >= 1 && contexts <= maxIds, "ECUs, apps and contexts: 1 to 999 each");
        check(levelWeights[].sum > 0, "at least one level must have a weight");
        check(payloadMin <= payloadMax && payloadMax <= maxPayload,
            "the payload length: min no more than max, max no more than 60000");
        foreach (share; [multiline, cyrillic, invalidUtf8, nonVerbose, corrupt])
            check(share >= 0 && share <= 1, "a share is from 0 to 1 (0% to 100%)");
        // a DLT storage header of version 1 holds the seconds in 32 bits (up to 2106): years
        // are left for the records after the start
        check(startSeconds >= 0 && startSeconds < latestStart, "the start time: from 1970 to 2099");
        check(corruptionKinds().length > 0, "no corruption asked is of this format");
    }

    //! @returns the kinds records are broken by: those asked that the format has
    immutable(Corruption)[] corruptionKinds() const
    {
        import std.algorithm : canFind, filter;
        import std.array : array;

        auto all = corruptionsOf(format);
        if (corruptions.length == 0)
            return all;
        return all.filter!(kind => corruptions.canFind(kind)).array.idup;
    }
}

//! The start time must be before 2100-01-01 UTC
enum long latestStart = 4_102_444_800;

//! The most IDs of a kind: they are a letter and three digits
enum uint maxIds = 999;

//! The longest text of a record: a DLT message of version 1 holds 65535 bytes in all
enum uint maxPayload = 60_000;

//! SplitMix64: a few lines, the same numbers everywhere (Phobos' generators and `uniform`
//! may change between versions)
struct Rng
{
    ulong state;

    ulong next() pure nothrow @nogc @safe
    {
        ulong z = (state += 0x9E3779B97F4A7C15);
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }

    //! @returns a number from 0 to n - 1 (0 for n 0)
    ulong below(ulong n) pure nothrow @nogc @safe
    {
        return n == 0 ? 0 : next() % n;
    }

    //! @returns a number from lo to hi, both included
    ulong between(ulong lo, ulong hi) pure nothrow @nogc @safe
    {
        return lo + below(hi - lo + 1);
    }

    //! @returns true with the probability p
    bool chance(double p) pure nothrow @nogc @safe
    {
        return p > 0 && (next() >> 11) * (1.0 / (1UL << 53)) < p;
    }
}

//! The content of a record, the same for every format
struct RecordContent
{
    uint ecu; // indexes, from 0
    uint app;
    uint context;
    LogLevel level;
    long timeUs; // microseconds since the epoch
    long uptimeUs; // since the first record
    ubyte counter; // of the messages of its ECU
    bool nonVerbose;
    uint messageId; // of a non-verbose message
    bool withNumber; // a verbose message: a number argument after the text
    uint number;
    char[] text; // may be invalid UTF-8; reused from record to record
}

//! @returns the ID `index` of a kind: its letter and three digits ("E001")
char[4] shortId(char letter, uint index) pure nothrow @nogc @safe
{
    const n = index + 1;
    return [letter, cast(char)('0' + n / 100 % 10), cast(char)('0' + n / 10 % 10), cast(char)('0' + n % 10)];
}

//! Gives the content of the records of a log one after another
struct ContentSource
{
    private GenOptions _options;
    Rng rng; // shared with the format writer and the corruption: one stream for a seed
    private long _startUs;
    private long _timeUs;
    private ubyte[maxIds] _counters;
    private bool _multiline;
    private uint _levelTotal;

    //! @param multiline - the format may have records of more than one line
    this(in GenOptions options, bool multiline)
    {
        _options = options;
        rng = Rng(options.seed);
        _startUs = _timeUs = options.startSeconds * 1_000_000;
        _multiline = multiline;
        foreach (w; options.levelWeights)
            _levelTotal += w;
    }

    void next(ref RecordContent r)
    {
        _timeUs += rng.below(2 * cast(ulong) _options.stepMicroseconds + 1);
        r.timeUs = _timeUs;
        r.uptimeUs = _timeUs - _startUs;
        r.ecu = cast(uint) rng.below(_options.ecus);
        r.app = cast(uint) rng.below(_options.apps);
        r.context = cast(uint) rng.below(_options.contexts);
        r.counter = _counters[r.ecu]++;
        r.level = pickLevel();
        r.nonVerbose = rng.chance(_options.nonVerbose);
        r.messageId = cast(uint) rng.between(1, 10_000);
        r.withNumber = rng.chance(0.3);
        r.number = cast(uint) rng.below(100_000);
        makeText(r.text);
    }

    private LogLevel pickLevel()
    {
        auto pick = rng.below(_levelTotal);
        foreach (i, w; _options.levelWeights)
        {
            if (pick < w)
                return cast(LogLevel)(LogLevel.Fatal + i);
            pick -= w;
        }
        assert(false);
    }

    private void makeText(ref char[] text)
    {
        text.length = 0;
        text.assumeSafeAppend();
        const length = rng.between(_options.payloadMin, _options.payloadMax);
        const invalidAt = rng.chance(_options.invalidUtf8) ? rng.below(length + 1) : size_t.max;
        bool invalidDone = false;
        while (text.length < length)
        {
            if (text.length > 0)
                text ~= ' ';
            if (!invalidDone && text.length >= invalidAt)
            {
                text ~= rng.chance(0.5) ? '\xFF' : '\xD0'; // a stray byte, the start of a cut letter
                invalidDone = true;
            }
            const kind = rng.below(10);
            if (kind == 0)
                appendNumber(text, "id=", rng.below(100_000));
            else if (rng.chance(_options.cyrillic))
                text ~= cyrillicWords[rng.below(cyrillicWords.length)];
            else
                text ~= words[rng.below(words.length)];
        }
        if (!invalidDone && invalidAt != size_t.max)
            text ~= '\xFF';
        if (_multiline && rng.chance(_options.multiline))
            foreach (line; 0 .. rng.between(1, 3))
                appendNumber(text, "\n    at frame ", line);
    }
}

private void appendNumber(ref char[] text, string prefix, ulong n)
{
    import std.format : formattedWrite;

    text ~= prefix;
    formattedWrite((const(char)[] s) { text ~= s; }, "%d", n);
}

private immutable string[] words = [
    "connection", "timeout", "request", "buffer", "state", "changed", "sensor", "value",
    "started", "stopped", "failed", "retry", "socket", "frame", "received", "sent", "queue",
    "update", "config", "loaded", "error", "warning", "ok",
];

private immutable string[] cyrillicWords = [
    "соединение", "ошибка", "запрос", "датчик", "значение", "запущен", "остановлен", "кадр",
    "очередь", "настройка",
];

@("Rng: the numbers of SplitMix64, the same everywhere")
unittest
{
    auto rng = Rng(0);
    assert(rng.next() == 0xE220A8397B1DCDAF);
    assert(rng.next() == 0x6E789E6AA1B965F4);
}

@("shortId: a letter and three digits from 001")
unittest
{
    assert(shortId('E', 0) == "E001");
    assert(shortId('A', 41) == "A042");
    assert(shortId('C', 998) == "C999");
}

@("GenOptions.validate: a count or a size, not both")
unittest
{
    import std.exception : assertThrown, assertNotThrown;

    GenOptions o;
    assertThrown(o.validate());
    o.count = 10;
    assertNotThrown(o.validate());
    o.size = 10;
    assertThrown(o.validate());
    o.size = 0;
    o.corrupt = 1.5;
    assertThrown(o.validate());
}

@("ContentSource: a text has the length asked, the time grows")
unittest
{
    GenOptions o;
    o.count = 1;
    o.payloadMin = 30;
    o.payloadMax = 40;
    auto source = ContentSource(o, false);
    RecordContent r;
    long previous = 0;
    foreach (_; 0 .. 100)
    {
        source.next(r);
        assert(r.text.length >= 30 && r.text.length < 40 + 20, "the last word may go past the max");
        assert(r.timeUs >= previous);
        previous = r.timeUs;
    }
}
