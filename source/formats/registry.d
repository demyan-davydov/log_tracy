//! The formats this build reads: detection of the format and the text encoding of some
//! data, creation of a format chosen before, a format decoding by a file of descriptions
//! (takesDescriptions, withDescriptions), their infos and columns.
module formats.registry;

import utils.ui_text : uiText, UiTextException;

import log_core.log_format;
import log_core.text_encoding : guessUtf16, TextEncoding, utf16ByBom, utf8Head;
import log_core.text.text_format : TextFormat;
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

version (unittest) import log_core.log_message : LogMessage;
version (unittest) import std.exception : collectException;

//! @returns true if the records of `format` can be decoded by a file of descriptions
//! (withDescriptions): a FIBEX for DLT
bool takesDescriptions(const(LogFormat) format) pure nothrow @nogc
{
    import formats.dlt.format : takesFibex;

    return takesFibex(format);
}

//! @brief `format` decoding by the file of descriptions at `path` (FormatChoice.descriptions),
//! by none for an empty one: the same records, decoded another way
//! @param stop - asked while the file is read: true gives the read up
//! @returns null if `format` takes no descriptions (takesDescriptions) or `stop` gave the read up
//! @throws UiTextException if the file can't be read or isn't one of descriptions
LogFormat withDescriptions(const(LogFormat) format, string path, scope bool delegate() nothrow stop = null)
{
    import formats.dlt.fibex : loadFibex;
    import formats.dlt.format : withFibex;

    if (!takesDescriptions(format))
        return null;
    if (!path.length)
        return withFibex(format, null);
    auto fibex = loadFibex(path, stop);
    return fibex is null ? null : withFibex(format, fibex);
}

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
//! @param choice - set to the detector, variant and encoding picked, to open
//! the data the same way later with createFormat()
//! @throws Exception if no format fits
LogFormat detectFormat(string path, const(ubyte)[] data, out FormatChoice choice)
{
    const head = data[0 .. min(data.length, detectionHeadSize)];
    auto all = detectors();

    auto best = bestDetector(all, path, head);
    const(ubyte)[] text = head;
    const bool bom = utf16ByBom(head) != TextEncoding.utf8;
    auto encoding = encodingOf(head);
    if (encoding != TextEncoding.utf8)
    {
        // With a byte order mark UTF-16 is taken when a format reads it; a guess
        // only over a weaker reading of the data as it is (a mere extension):
        // a binary format may have zero bytes, or bytes like a byte order mark
        const utf8Text = utf8Head(head, encoding);
        const utf16 = bestDetector(all, path, utf8Text);
        if (!utf16.isNone && (bom || utf16.detection.score > best.detection.score))
        {
            best = utf16;
            text = utf8Text;
        }
        else
            encoding = TextEncoding.utf8;
    }

    if (best.isNone)
        throw new FormatException(FormatException.Kind.unrecognized, uiText("not a log of a format Log Tracy can read"));
    choice = FormatChoice(all[best.index].info.id, best.detection.variant, encoding);
    return withEncoding(all[best.index].create(best.detection.variant, text), encoding, FormatException.Kind.unrecognized);
}

//! @brief Creates the format chosen before (by detection or by the user),
//! without detecting it again
//! @throws Exception if no format has the id of `choice`, or the data is
//! not in its encoding: the format is to be detected again
LogFormat createFormat(FormatChoice choice, const(ubyte)[] data)
{
    const raw = data[0 .. min(data.length, detectionHeadSize)];
    // The file may have been written again in another encoding since (a log
    // rotated over the same path): every line would come out broken
    if (encodingOf(raw) != choice.encoding)
        throw new FormatException(FormatException.Kind.unreadable, uiText("not a log of a format Log Tracy can read"));
    const head = utf8Head(raw, choice.encoding);
    foreach (detector; detectors())
        if (detector.info.id == choice.id)
            return withEncoding(detector.create(choice.variant, head), choice.encoding);
    throw new FormatException(FormatException.Kind.unreadable, uiText("unknown log format \"{format}\"", "format", choice.id));
}

//! @returns the id of the format detection picks for `data` (the first bytes of the file at
//! `path`), "" if no format fits: what "Detect automatically" would open it as
string detectedFormatId(string path, const(ubyte)[] data)
{
    try
    {
        FormatChoice choice;
        detectFormat(path, data, choice);
        return choice.id;
    }
    catch (Exception)
        return "";
}

//! @brief The choice that opens `data` as the format with `id`, picked by hand: the variant that
//! format reads in the data (the best of its own reading, its first variant when it finds none)
//! and the encoding the data is in, if the format reads it
//! @throws FormatException (unreadable) if no format has the id
FormatChoice choiceFor(string id, string path, const(ubyte)[] data)
{
    const head = data[0 .. min(data.length, detectionHeadSize)];
    foreach (detector; detectors())
    {
        if (detector.info.id != id)
            continue;
        const encoding = encodingOf(head);
        if (encoding != TextEncoding.utf8)
        {
            // Only a text format reads UTF-16 (withEncoding): another reads the bytes
            const text = utf8Head(head, encoding);
            const variant = variantIn(detector, path, text);
            if (cast(TextFormat) detector.create(variant, text) !is null)
                return FormatChoice(id, variant, encoding);
        }
        return FormatChoice(id, variantIn(detector, path, head));
    }
    throw new FormatException(FormatException.Kind.unreadable, uiText("unknown log format \"{format}\"", "format", id));
}

//! @returns the encoding the text in `head` looks to be in: by its byte order mark, else guessed
private TextEncoding encodingOf(const(ubyte)[] head)
{
    const marked = utf16ByBom(head);
    return marked != TextEncoding.utf8 ? marked : guessUtf16(head);
}

private int variantIn(const(FormatDetector) detector, string path, const(ubyte)[] head)
{
    const detection = detector.detect(path, head);
    if (detection.score > 0)
        return detection.variant;
    const all = detector.variants();
    return all.length ? all[0] : 0;
}

private struct Best
{
    size_t index = size_t.max; // in the detectors
    Detection detection;

    bool isNone() const pure nothrow @nogc @safe
    {
        return index == size_t.max;
    }
}

private Best bestDetector(const(FormatDetector)[] all, string path, const(ubyte)[] head)
{
    Best best;
    foreach (i, detector; all)
    {
        const detection = detector.detect(path, head);
        if (detection.score > best.detection.score)
            best = Best(i, detection);
    }
    return best;
}

//! @returns `format` reading text in `encoding`
//! @throws FormatException (`kind`) if the format is not a text one but the encoding is UTF-16: what
//! it is depends on who asked, detection (no format fits the data) or a choice made before (the
//! format asked for can't read it)
private LogFormat withEncoding(LogFormat format, TextEncoding encoding, FormatException.Kind kind = FormatException.Kind.unreadable)
{
    static import log_core.text.text_format;

    if (encoding == TextEncoding.utf8)
        return format;
    auto text = cast(TextFormat) format;
    if (text is null)
        throw new FormatException(kind, uiText("not a log of a format Log Tracy can read"));
    return log_core.text.text_format.inEncoding(text, encoding);
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

@("every format tells the info of its detector, in UTF-16 too")
unittest
{
    foreach (detector; detectors())
    {
        auto format = detector.create(0, null);
        assert(format.info == detector.info, detector.info.id);
        if (cast(TextFormat) format)
            assert(withEncoding(format, TextEncoding.utf16le).info == detector.info, detector.info.id);
    }
}

@("withEncoding: UTF-16 for a format that is not a text one is an error of the kind of who asked")
unittest
{
    import formats.dlt.format : dltFormatInfo;

    auto dlt = detectorOf(dltFormatInfo.id).create(0, null);
    foreach (kind; [FormatException.Kind.unrecognized, FormatException.Kind.unreadable])
    {
        auto e = collectException!FormatException(withEncoding(dlt, TextEncoding.utf16le, kind));
        assert(e !is null && e.kind == kind);
    }
}

@("detectFormat: a DLT file is detected as DLT")
unittest
{
    import formats.dlt.format : DltFormat;
    import formats.dlt.testing_utils : buildDltMessage;

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

@("detectFormat: a log in UTF-16 with or without a byte order mark")
unittest
{
    import log_core.text_encoding : TextEncoding, utf16Bytes;
    import formats.plain_text : plainTextFormatInfo;

    const text = "notes: Привет \u0A0A\r\nmore, 世界\r\n";
    foreach (encoding; [TextEncoding.utf16le, TextEncoding.utf16be])
        foreach (bom; [true, false])
        {
            const data = utf16Bytes(text, encoding, bom);
            FormatChoice choice;
            auto format = detectFormat("x.txt", data, choice);
            assert(choice == FormatChoice(plainTextFormatInfo.id, 0, encoding));

            size_t[4] offsets;
            const r = format.scanRecords(data, 0, offsets[], true);
            assert(r.count == 2, "a record per line");
            LogMessage!wchar msg;
            assert(format.decode(msg, format.recordAt(data, offsets[0])));
            assert(msg.payloadText == "notes: Привет \u0A0A"w);
        }
}

@("detectFormat: a syslog in UTF-16 is syslog, read from UTF-16")
unittest
{
    import log_core.text_encoding : TextEncoding, utf16Bytes;
    import formats.syslog.syslog : syslogFormatInfo;

    const text = "Nov  3 14:22:01 host sshd[812]: a\nNov  3 14:22:02 host cron[9]: b\n";
    const data = utf16Bytes(text, TextEncoding.utf16le, true);
    FormatChoice choice;
    auto format = detectFormat("syslog", data, choice);
    assert(choice.id == syslogFormatInfo.id && choice.encoding == TextEncoding.utf16le);

    LogMessage!wchar msg;
    assert(format.decode(msg, format.recordAt(data, 2)) && msg.payloadText == "a"w);
}

@("createFormat: the saved encoding is read again")
unittest
{
    import log_core.text_encoding : TextEncoding, utf16Bytes;
    import formats.plain_text : plainTextFormatInfo;

    const data = utf16Bytes("one\ntwo\n", TextEncoding.utf16be);
    auto format = createFormat(FormatChoice(plainTextFormatInfo.id, 0, TextEncoding.utf16be), data);
    LogMessage!wchar msg;
    assert(format.decode(msg, format.recordAt(data, 8)) && msg.payloadText == "two"w);
}

@("detectFormat: text and binary data without a UTF-16 look stay as they are (a guard, not of the order of the passes)")
unittest
{
    import log_core.text_encoding : TextEncoding;
    import std.exception : assertThrown;

    FormatChoice choice;
    detectFormat("x.txt", cast(const(ubyte)[]) "plain\n", choice);
    assert(choice.encoding == TextEncoding.utf8);
    assertThrown(detectFormat("x.bin", cast(const(ubyte)[])[0x01, 0x00, 0x00, 0x00, 0x02, 0x00]),
        "binary data is no UTF-16");
}

@("detectFormat: binary data after a UTF-16 byte order mark is still read as it is")
unittest
{
    import formats.dlt.format : DltFormat;
    import formats.dlt.testing_utils : buildDltMessage;
    import log_core.text_encoding : TextEncoding;

    FormatChoice choice;
    auto format = detectFormat("x.log", cast(const(ubyte)[])[0xFF, 0xFE] ~ buildDltMessage(), choice);
    assert(cast(DltFormat) format !is null);
    assert(choice.encoding == TextEncoding.utf8);
}

@("detectFormat: UTF-16 text without a byte order mark wins over a mere .dlt extension")
unittest
{
    import log_core.text_encoding : TextEncoding, utf16Bytes;
    import formats.plain_text : plainTextFormatInfo;

    FormatChoice choice;
    detectFormat("trace.dlt", utf16Bytes("notes\nmore notes\n", TextEncoding.utf16le), choice);
    assert(choice == FormatChoice(plainTextFormatInfo.id, 0, TextEncoding.utf16le));
}

@("createFormat: data in another encoding than the saved one is an error, to detect it again")
unittest
{
    import log_core.text_encoding : TextEncoding, utf16Bytes;
    import formats.plain_text : plainTextFormatInfo;
    import std.exception : assertNotThrown, assertThrown;

    const id = plainTextFormatInfo.id;
    assertThrown(createFormat(FormatChoice(id, 0, TextEncoding.utf16le), cast(const(ubyte)[]) "one\n"));
    assertThrown(createFormat(FormatChoice(id), utf16Bytes("one\n", TextEncoding.utf16le, true)));
    assertThrown(createFormat(FormatChoice(id, 0, TextEncoding.utf16le), utf16Bytes("one\n", TextEncoding.utf16be)));
    assertNotThrown(createFormat(FormatChoice(id, 0, TextEncoding.utf16le), utf16Bytes("one\n", TextEncoding.utf16le)));
    assertNotThrown(createFormat(FormatChoice(id), null), "nothing to contradict the choice");
}

@("createFormat: UTF-16 for a format that is not a text one is an error")
unittest
{
    import log_core.text_encoding : TextEncoding, utf16Bytes;
    import formats.dlt.format : dltFormatInfo;
    import std.exception : assertThrown;

    assertThrown(createFormat(FormatChoice(dltFormatInfo.id, 0, TextEncoding.utf16le),
        utf16Bytes("text\n", TextEncoding.utf16le, true)));
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

@("detectedFormatId: the format detection picks for some data, none for what no format reads")
unittest
{
    assert(detectedFormatId("x.log", cast(const(ubyte)[]) "11-03 14:22:01.123  1234  1250 I Tag: text\n") == "logcat");
    assert(detectedFormatId("x.bin", cast(const(ubyte)[]) [0x01, 0x00, 0x02]) == "", "no format reads it");
}

@("choiceFor: a format picked by hand gets the variant it reads in the data")
unittest
{
    import formats.logcat : LogcatFormat, logcatFormatInfo;
    import formats.plain_text : plainTextFormatInfo;

    auto threadtime = cast(const(ubyte)[]) "11-03 14:22:01.123  1234  1250 I Tag: text\n";
    auto brief = cast(const(ubyte)[]) "I/Tag( 1234): text\nI/Tag( 1234): more\n";
    assert(choiceFor(logcatFormatInfo.id, "x.log", threadtime) == FormatChoice(logcatFormatInfo.id, LogcatFormat.Variant.Threadtime));
    assert(choiceFor(logcatFormatInfo.id, "x.log", brief) == FormatChoice(logcatFormatInfo.id, LogcatFormat.Variant.Brief));
    assert(choiceFor(plainTextFormatInfo.id, "x.log", threadtime) == FormatChoice(plainTextFormatInfo.id),
        "a format that fits less than another is made of the data all the same");
}

version (unittest) private const(FormatDetector) detectorOf(string id)
{
    foreach (detector; detectors())
        if (detector.info.id == id)
            return detector;
    assert(false, id);
}

@("choiceFor: a format that finds nothing of its own in the data gets its first variant, and can be made")
unittest
{
    import formats.logcat : logcatFormatInfo;

    auto notes = cast(const(ubyte)[]) "just notes\nnothing else\n";
    const choice = choiceFor(logcatFormatInfo.id, "x.log", notes);
    assert(choice.id == logcatFormatInfo.id && choice.variant == detectorOf(logcatFormatInfo.id).variants()[0]);
    assert(createFormat(choice, notes) !is null);
}

@("choiceFor: the encoding of text data is kept for a text format, a binary format reads bytes")
unittest
{
    import log_core.text_encoding : TextEncoding, utf16Bytes;
    import formats.dlt.format : dltFormatInfo;
    import formats.plain_text : plainTextFormatInfo;

    const data = utf16Bytes("notes: Привет\r\nmore\r\n", TextEncoding.utf16le, true);
    assert(choiceFor(plainTextFormatInfo.id, "x.txt", data).encoding == TextEncoding.utf16le);
    assert(choiceFor(dltFormatInfo.id, "x.txt", data).encoding == TextEncoding.utf8, "DLT is not text");
}

@("choiceFor: an unknown format id is an unreadable-format error")
unittest
{
    auto e = collectException!FormatException(choiceFor("nope", "x.log", cast(const(ubyte)[]) "a\n"));
    assert(e !is null && e.kind == FormatException.Kind.unreadable);
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

@("withDescriptions: a FIBEX for a DLT log, none for an empty path, null for a format that takes none")
unittest
{
    import formats.dlt.fibex : fibexOf, logFrame, textPdu;
    import formats.dlt.format : DltFormat;
    import formats.plain_text : PlainTextFormat;
    import std.exception : assertThrown;
    import std.file : remove, tempDir, write;
    import std.path : buildPath;

    const path = buildPath(tempDir(), "log_tracy_registry_fibex_test.xml");
    write(path, fibexOf(textPdu("P_T", "x"), logFrame("ID_1", "APP1", "CON1", "P_T")));
    scope (exit)
        remove(path);

    assert(takesDescriptions(new DltFormat()) && !takesDescriptions(new PlainTextFormat()));
    auto described = cast(DltFormat) withDescriptions(new DltFormat(), path);
    assert(described !is null && described.fibex !is null && described.fibex.length == 1);
    assert((cast(DltFormat) withDescriptions(described, "")).fibex is null);
    assert(withDescriptions(new PlainTextFormat(), path) is null);
    assertThrown!UiTextException(withDescriptions(new DltFormat(), path ~ ".missing"));
}

@("withDescriptions: stopped, null without an error")
unittest
{
    import formats.dlt.fibex : fibexOf, logFrame, textPdu;
    import formats.dlt.format : DltFormat;
    import std.file : remove, tempDir, write;
    import std.path : buildPath;

    const path = buildPath(tempDir(), "log_tracy_registry_fibex_stop_test.xml");
    write(path, fibexOf(textPdu("P_T", "x"), logFrame("ID_1", "APP1", "CON1", "P_T")));
    scope (exit)
        remove(path);
    assert(withDescriptions(new DltFormat(), path, () => true) is null);
    assert(withDescriptions(new DltFormat(), path, () => false) !is null);
}
