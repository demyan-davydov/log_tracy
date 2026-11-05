module formats.can.vector_asc;

//! Vector ASC traces (CANoe, CANalyzer). The header says how to read the lines:
//!   date Tue Nov 3 02:22:01.123 pm 2026        the start: time = start + offset
//!   base hex  timestamps absolute               ID and data in hex or dec
//! then a record per line, after the offset in seconds:
//!   "   0.001234 1  123   Rx   d 8 DE AD BE EF 00 11 22 33  Length = ..."   CAN, "123x": 29-bit
//!   "   0.002000 1  123   Tx   r 4"                                          remote frame
//!   "   0.003000 CANFD   1 Rx 123 Name 1 0 8 8 DE AD ..."                   CAN FD, name optional
//!   "   0.004000 1  ErrorFrame"                                            error frame
//! Other records with a time (start of measurement, statistics, LIN...) are
//! events, their text the payload. Without a date the time is the offset from
//! the start. With "timestamps relative" the offsets are shown as written.

import formats.can.frame;
import log_core.log_format;
import log_core.log_level : LogLevel;
import log_core.log_message : LogMessage, TimeKind;
import log_core.text.text_format;
import log_core.text.text_parsing;

//! What the header of an ASC file says
struct AscHeader
{
    bool decimal; // "base dec": IDs and data bytes in decimal
    bool relative; // "timestamps relative": each offset from the previous record
    bool hasDate; // a "date" line: startNs is set
    long startNs; // the start, as written (no zone)
}

//! How the user and the settings know AscFormat
enum FormatInfo ascFormatInfo = FormatInfo("vector-asc", "CAN trace (Vector ASC)", "ASC");

final class AscFormat : TextFormat
{
    private immutable AscHeader _header;

    this(AscHeader header) pure nothrow @nogc @safe
    {
        super(false);
        _header = header;
    }

    AscHeader header() const pure nothrow @nogc @property
    {
        return _header;
    }

    override string name() const pure nothrow @nogc
    {
        return ascFormatInfo.name;
    }

    private static immutable ColumnInfo[] _localColumns = canColumns(TimeKind.Local, true);
    private static immutable ColumnInfo[] _offsetColumns = canColumns(TimeKind.SinceBoot, true);

    //! The time is the start and the offset, or the offset only
    private bool showsStart() const pure nothrow @nogc
    {
        return _header.hasDate && !_header.relative;
    }

    override const(ColumnInfo)[] columns() const pure nothrow @nogc
    {
        return showsStart ? _localColumns : _offsetColumns;
    }

    protected override bool decodeText(ref LogMessage!wchar msg, const(char)[] text) const nothrow @nogc
    {
        msg.beginRecord();

        AscLine line;
        if (!parseLine(_header, text, line))
            return decodeAsPlainText(msg, text);

        if (showsStart)
        {
            msg.timeNs = _header.startNs + line.offsetNs;
            msg.timeKind = TimeKind.Local;
        }
        else
        {
            msg.timeNs = line.offsetNs;
            msg.timeKind = TimeKind.SinceBoot; // seconds from the start
        }
        msg.setNumber(CanField.Type, line.type);
        if (line.channel.length)
            msg.setText(CanField.Channel, line.channel);
        if (line.hasId)
            msg.setNumber(CanField.Id, cast(long) line.id);
        if (line.dir.length)
            msg.setText(CanField.Dir, line.dir);
        if (line.hasDlc)
            msg.setNumber(CanField.Dlc, line.dlc);
        if (line.type == CanFrameType.Error)
            msg.level = LogLevel.Error;

        auto builder = msg.payloadBuilder();
        if (line.type == CanFrameType.Event || line.type == CanFrameType.Error)
            builder.appendUtf8(line.text);
        else
        {
            char[3 * maxData] hex;
            builder.appendAscii(hexBytes(line.data[0 .. line.dataLength], hex[]));
        }
        return true;
    }
}

final class AscDetector : FormatDetector
{
    override const(int)[] variants() const pure nothrow
    {
        // One, whatever the variant. The columns depend on the header (a start
        // date or not), but only by the kind and the width of the time: the
        // ids and the titles, all a layout needs, are the same
        return [0];
    }

    override FormatInfo info() const pure nothrow @nogc
    {
        return ascFormatInfo;
    }

    override Detection detect(string path, const(ubyte)[] head) const
    {
        bool hasBase, hasDate;
        readHeader(head, hasBase, hasDate);
        // The header lines are certain: other text has no "base hex" line
        return Detection(hasBase ? 1.0f : hasDate ? 0.9f : 0);
    }

    override LogFormat create(int variant, const(ubyte)[] head) const
    {
        bool hasBase, hasDate;
        return new AscFormat(readHeader(head, hasBase, hasDate));
    }
}

// ─── Header ─────────────────────────────────────────────────────────────────

//! Reads the "date" and "base" lines of the header from the start of a file
private AscHeader readHeader(const(ubyte)[] head, out bool hasBase, out bool hasDate)
{
    AscHeader header;
    bool base, date;
    forEachSampleLine(head, (const(char)[] line) {
        if (!date && line.length > 5 && line[0 .. 5] == "date " && readDate(line[5 .. $], header.startNs))
            date = true;
        else if (!base && line.length > 5 && line[0 .. 5] == "base ")
            base = readBase(line[5 .. $], header);
    });
    header.hasDate = date;
    hasBase = base;
    hasDate = date;
    return header;
}

//! "Tue Nov 3 02:22:01.123 pm 2026" or "Tue Nov 03 14:22:01 2026"
private bool readDate(const(char)[] s, out long startNs) pure nothrow @nogc @safe
{
    import std.uni : sicmp;

    const(char)[] weekday, marker;
    uint month, day, year;
    long timeOfDay;
    if (!readWord(s, weekday) || !skipSpaces(s) || !readMonthDayTime(s, month, day, timeOfDay) || !skipSpaces(s))
        return false;

    enum long hour = 3600 * 1_000_000_000L;
    const(char)[] rest = s;
    if (readWord(rest, marker) && (sicmp(marker, "am") == 0 || sicmp(marker, "pm") == 0))
    {
        const hours = timeOfDay / hour;
        if (hours < 1 || hours > 12)
            return false;
        if (sicmp(marker, "am") == 0 && hours == 12)
            timeOfDay -= 12 * hour; // 12 am: midnight
        else if (sicmp(marker, "pm") == 0 && hours != 12)
            timeOfDay += 12 * hour;
        s = rest;
        skipSpaces(s);
    }
    if (!readDigits(s, 4, year) || !isValidDate(year, month, day))
        return false;
    startNs = toEpochNs(year, month, day, timeOfDay);
    return true;
}

//! "hex  timestamps absolute" after "base"
private bool readBase(const(char)[] s, ref AscHeader header) pure nothrow @nogc @safe
{
    const(char)[] base, word, timestamps;
    if (!readWord(s, base) || (base != "hex" && base != "dec"))
        return false;
    header.decimal = base == "dec";
    skipSpaces(s);
    if (readWord(s, word) && word == "timestamps" && skipSpaces(s) && readWord(s, timestamps))
        header.relative = timestamps == "relative";
    return true;
}

// ─── Lines ──────────────────────────────────────────────────────────────────

private struct AscLine
{
    long offsetNs;
    CanFrameType type;
    const(char)[] channel;
    bool hasId;
    ulong id;
    const(char)[] dir;
    bool hasDlc;
    uint dlc;
    ubyte[maxData] data;
    size_t dataLength;
    const(char)[] text; // an event
}

//! "offset record": a frame, or an event
private bool parseLine(ref const(AscHeader) header, const(char)[] s, out AscLine line) pure nothrow @nogc @safe
{
    ulong seconds;
    uint fraction;
    skipSpaces(s);
    if (!readNumber64(s, seconds) || !readChar(s, '.') || !readFraction(s, fraction) || !skipSpaces(s))
        return false;
    line.offsetNs = cast(long)(seconds * 1_000_000_000 + fraction);

    line.type = CanFrameType.Event;
    line.text = s;
    AscLine frame = line;
    if (parseFrame(header, s, frame))
        line = frame;
    return true;
}

private bool parseFrame(ref const(AscHeader) header, const(char)[] s, ref AscLine line) pure nothrow @nogc @safe
{
    const(char)[] first;
    if (!readWord(s, first))
        return false;
    if (first == "CANFD")
        return parseFdFrame(header, s, line);

    // "channel ErrorFrame" or "channel ID dir d|r ..."
    const(char)[] digits = first, word;
    uint channel;
    if (!readNumber(digits, channel) || digits.length || !skipSpaces(s) || !readWord(s, word))
        return false;
    line.channel = first;
    if (word == "ErrorFrame")
    {
        line.type = CanFrameType.Error;
        skipSpaces(s);
        line.text = s; // the details Vector writes after it (flags, codes)
        return true;
    }

    const(char)[] dir, kind;
    if (!readId(header, word, line) || !skipSpaces(s) || !readWord(s, dir) || (dir != "Rx" && dir != "Tx")
        || !skipSpaces(s) || !readWord(s, kind))
        return false;
    line.dir = dir;

    if (kind == "r")
    {
        line.type = CanFrameType.Remote;
        line.hasDlc = true;
        skipSpaces(s);
        readNumber(s, line.dlc); // the requested length, if written
        return true;
    }
    if (kind != "d" || !skipSpaces(s) || !readNumber(s, line.dlc) || line.dlc > 8)
        return false;
    line.type = CanFrameType.Can;
    line.hasDlc = true;
    return readData(header, s, line.dlc, line);
}

//! After "CANFD": "channel dir ID [name] BRS ESI DLC length data..."
private bool parseFdFrame(ref const(AscHeader) header, const(char)[] s, ref AscLine line) pure nothrow @nogc @safe
{
    const(char)[] channel, dir, id;
    if (!skipSpaces(s) || !readWord(s, channel) || !skipSpaces(s) || !readWord(s, dir)
        || (dir != "Rx" && dir != "Tx") || !skipSpaces(s) || !readWord(s, id) || !readId(header, id, line))
        return false;
    line.channel = channel;
    line.dir = dir;

    // The symbolic name is optional: the fields after it start with BRS and ESI (0 or 1)
    foreach (skipName; [false, true])
    {
        const(char)[] rest = s, name, brs, esi, dlcCode;
        uint length;
        skipSpaces(rest);
        if (skipName && !readWord(rest, name))
            continue;
        skipSpaces(rest);
        if (!readWord(rest, brs) || (brs != "0" && brs != "1") || !skipSpaces(rest) || !readWord(rest, esi)
            || (esi != "0" && esi != "1") || !skipSpaces(rest) || !readWord(rest, dlcCode) || dlcCode.length != 1
            || !skipSpaces(rest) || !readNumber(rest, length) || length > maxData)
            continue;
        line.type = CanFrameType.CanFd;
        line.hasDlc = true;
        line.dlc = length;
        return readData(header, rest, length, line);
    }
    return false;
}

//! An ID in the base of the file, "x" after a 29-bit one
private bool readId(ref const(AscHeader) header, const(char)[] word, ref AscLine line) pure nothrow @nogc @safe
{
    if (word.length > 1 && word[$ - 1] == 'x')
        word = word[0 .. $ - 1];
    if (header.decimal)
    {
        if (!readNumber64(word, line.id))
            return false;
    }
    else if (readHex(word, 8, line.id) == 0)
        return false;
    line.hasId = word.length == 0;
    return line.hasId;
}

//! `count` data bytes, separated by spaces, in the base of the file
private bool readData(ref const(AscHeader) header, const(char)[] s, uint count, ref AscLine line) pure nothrow @nogc @safe
{
    foreach (i; 0 .. count)
    {
        const(char)[] word;
        ulong value;
        if (!skipSpaces(s) || !readWord(s, word))
            return false;
        const ok = header.decimal ? readNumber64(word, value) && value <= 255 : readHex(word, 2, value) == 2;
        if (!ok || word.length)
            return false;
        line.data[line.dataLength++] = cast(ubyte) value;
    }
    return true;
}

// ─── Tests ──────────────────────────────────────────────────────────────────

version (unittest)
{
    private const(ubyte)[] bytes(string s)
    {
        return cast(const(ubyte)[]) s;
    }

    private enum header = "date Tue Nov 3 02:22:01.123 pm 2026\n"
        ~ "base hex  timestamps absolute\n"
        ~ "internal events logged\n"
        ~ "// version 13.0.0\n"
        ~ "Begin Triggerblock Tue Nov 3 02:22:01.123 pm 2026\n";

    private AscFormat ascFormat(string head)
    {
        return cast(AscFormat) new AscDetector().create(0, bytes(head));
    }

    private void decodeLine(AscFormat format, string text, ref LogMessage!wchar msg)
    {
        assert(format.decode(msg, bytes(text)));
    }

    private enum long ms = 1_000_000;
    private enum long start = toEpochNs(2026, 11, 3, ((14 * 60 + 22) * 60 + 1) * 1000 * ms + 123 * ms);
}

@("AscFormat: the header gives the base and the start of the time")
unittest
{
    const h = ascFormat(header).header;
    assert(!h.decimal && !h.relative && h.hasDate);
    assert(h.startNs == start, "02:22:01.123 pm");

    const d = ascFormat("date Tue Nov 03 14:22:01 2026\nbase dec  timestamps relative\n").header;
    assert(d.decimal && d.relative && d.hasDate, "24-hour clock, no fraction");
    assert(d.startNs == toEpochNs(2026, 11, 3, ((14 * 60 + 22) * 60 + 1) * 1000 * ms));

    const none = ascFormat("base hex  timestamps absolute\n").header;
    assert(!none.hasDate);
}

@("AscFormat: a classic frame, its time the start and the offset")
unittest
{
    LogMessage!wchar msg;
    decodeLine(ascFormat(header),
        "   0.001234 1  123             Rx   d 8 DE AD BE EF 00 11 22 33  Length = 0 BitCount = 64 ID = 291\n", msg);
    assert(msg.timeKind == TimeKind.Local && msg.timeNs == start + 1_234_000);
    assert(msg.text(CanField.Channel) == "1"w);
    assert(msg.number(CanField.Id) == 0x123);
    assert(msg.text(CanField.Dir) == "Rx"w);
    assert(msg.number(CanField.Type) == CanFrameType.Can);
    assert(msg.number(CanField.Dlc) == 8);
    assert(msg.payloadText == "DE AD BE EF 00 11 22 33"w);
    assert(msg.level == LogLevel.None);
}

@("AscFormat: 29-bit IDs, decimal base, remote frames")
unittest
{
    LogMessage!wchar msg;
    decodeLine(ascFormat(header), "   0.002000 2  18FEF100x       Tx   d 2 01 02", msg);
    assert(msg.number(CanField.Id) == 0x18FEF100 && msg.text(CanField.Dir) == "Tx"w);
    assert(msg.payloadText == "01 02"w);

    decodeLine(ascFormat("base dec  timestamps absolute\n"), "   0.5 1  291  Rx   d 2 222 173", msg);
    assert(msg.number(CanField.Id) == 0x123 && msg.payloadText == "DE AD"w, "decimal ID and data");

    decodeLine(ascFormat(header), "   1.000000 1  123  Rx   r", msg);
    assert(msg.number(CanField.Type) == CanFrameType.Remote && msg.number(CanField.Dlc) == 0);
    decodeLine(ascFormat(header), "   1.000000 1  123  Rx   r 4", msg);
    assert(msg.number(CanField.Dlc) == 4);
}

@("AscFormat: error frames have the level Error")
unittest
{
    LogMessage!wchar msg;
    decodeLine(ascFormat(header), "   2.000000 1  ErrorFrame", msg);
    assert(msg.number(CanField.Type) == CanFrameType.Error && msg.level == LogLevel.Error);
    assert(msg.text(CanField.Channel) == "1"w && !msg.hasField(CanField.Id));
}

@("AscFormat: CAN FD frames, with or without a symbolic name")
unittest
{
    LogMessage!wchar msg;
    foreach (line; [
        "   3.000000 CANFD   1 Rx        123                                   1 0 8  8 DE AD BE EF 00 11 22 33   0    0",
        "   3.000000 CANFD   1 Rx        123  EngineData                       1 0 8  8 DE AD BE EF 00 11 22 33   0    0",
    ])
    {
        decodeLine(ascFormat(header), line, msg);
        assert(msg.number(CanField.Type) == CanFrameType.CanFd, line);
        assert(msg.text(CanField.Channel) == "1"w && msg.text(CanField.Dir) == "Rx"w);
        assert(msg.number(CanField.Id) == 0x123 && msg.number(CanField.Dlc) == 8);
        assert(msg.payloadText == "DE AD BE EF 00 11 22 33"w);
    }
}

@("AscFormat: other records with a time are events, the header is text")
unittest
{
    LogMessage!wchar msg;
    auto format = ascFormat(header);
    decodeLine(format, "   0.000000 Start of measurement", msg);
    assert(msg.number(CanField.Type) == CanFrameType.Event && msg.timeNs == start);
    assert(msg.payloadText == "Start of measurement"w && !msg.hasField(CanField.Id));

    foreach (line; ["date Tue Nov 3 02:22:01.123 pm 2026", "Begin Triggerblock Tue Nov 3 02:22:01.123 pm 2026",
            "End TriggerBlock"])
    {
        import std.conv : to;

        decodeLine(format, line, msg);
        assert(msg.timeKind == TimeKind.None && msg.payloadText == line.to!wstring, line);
    }
}

@("AscFormat: without a date the time is the offset from the start")
unittest
{
    LogMessage!wchar msg;
    auto format = ascFormat("base hex  timestamps absolute\n");
    decodeLine(format, "   1.500000 1  123  Rx   d 1 00", msg);
    assert(msg.timeKind == TimeKind.SinceBoot && msg.timeNs == 1500 * ms);
    assert(format.columns[0].timeKind == TimeKind.SinceBoot);
    assert(ascFormat(header).columns[0].timeKind == TimeKind.Local);

    string[] ids;
    foreach (column; format.columns)
        ids ~= column.id;
    assert(ids == ["time", "channel", "id", "dir", "type", "dlc", "payload"]);
}

@("AscDetector: an ASC header, not other logs")
unittest
{
    auto detector = new AscDetector();
    assert(detector.detect("trace.asc", bytes(header ~ "   0.0 Start of measurement\n")).score > 0.5f);

    foreach (other; ["(1762179721.123456) can0 123#DEADBEEF\n", "just some\ntext lines\n",
            "date of the meeting: Tuesday\n"])
        assert(detector.detect("x.asc", bytes(other)).score == 0, other);
}

@("AscFormat: an error frame keeps the details after it")
unittest
{
    LogMessage!wchar msg;
    decodeLine(ascFormat(header), "   2.000000 1  ErrorFrame Flags = 0x0 CodeExt = 0x20A2 Code = 0x82", msg);
    assert(msg.number(CanField.Type) == CanFrameType.Error);
    assert(msg.payloadText == "Flags = 0x0 CodeExt = 0x20A2 Code = 0x82"w);
}

@("AscFormat: with relative timestamps the time is the offset as written, even with a date")
unittest
{
    LogMessage!wchar msg;
    auto format = ascFormat("date Tue Nov 3 02:22:01.123 pm 2026\nbase hex  timestamps relative\n");
    decodeLine(format, "   0.250000 1  123  Rx   d 1 00", msg);
    assert(msg.timeKind == TimeKind.SinceBoot && msg.timeNs == 250 * ms, "not the start and the offset");
    assert(format.columns[0].timeKind == TimeKind.SinceBoot);
}
