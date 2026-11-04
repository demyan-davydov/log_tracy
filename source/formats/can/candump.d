module formats.can.candump;

//! Log files of SocketCAN candump -l (can-utils), a frame per line:
//!   "(1762179721.123456) can0 123#DEADBEEF00112233"   classic CAN, 11-bit ID
//!   "(1762179721.123456) can0 18FEF100#0102"          29-bit ID (8 hex digits)
//!   "(1762179721.123456) can0 123#R" or "123#R3"      remote frame, with a length
//!   "(1762179721.123456) can0 123##1DEADBEEF..."      CAN FD: flags, then data
//!   "(1762179721.123456) can0 20000080#00..."         error frame: CAN_ERR_FLAG in the ID
//! The time is a moment (seconds since the epoch); error frames have the
//! level Error. Lines that don't fit keep their text as the payload.

import formats.can.frame;
import log_core.log_format;
import log_core.log_level : LogLevel;
import log_core.log_message : LogMessage, TimeKind;
import log_core.text.text_format;
import log_core.text.text_parsing;

//! How the user and the settings know CandumpFormat
enum FormatInfo candumpFormatInfo = FormatInfo("candump", "CAN trace (candump)", "CAN");

final class CandumpFormat : TextFormat
{
    this() pure nothrow @nogc @safe
    {
        super(false);
    }

    override string name() const pure nothrow @nogc
    {
        return candumpFormatInfo.name;
    }

    private static immutable ColumnInfo[] _columns = canColumns(TimeKind.Absolute, false);

    override const(ColumnInfo)[] columns() const pure nothrow @nogc
    {
        return _columns;
    }

    protected override bool decodeText(ref LogMessage!wchar msg, const(char)[] text) const nothrow @nogc
    {
        msg.beginRecord();

        CandumpLine line;
        if (!parseLine(text, line))
        {
            auto builder = msg.payloadBuilder();
            builder.appendUtf8(text);
            return true;
        }

        msg.timeNs = line.timeNs;
        msg.timeKind = TimeKind.Absolute;
        msg.setText(CanField.Channel, line.channel);
        msg.setNumber(CanField.Id, cast(long) line.id);
        msg.setNumber(CanField.Type, line.type);
        msg.setNumber(CanField.Dlc, line.dlc);
        if (line.type == CanFrameType.Error)
            msg.level = LogLevel.Error;

        char[3 * maxData] hex;
        auto builder = msg.payloadBuilder();
        builder.appendAscii(hexBytes(line.data[0 .. line.dataLength], hex[]));
        return true;
    }
}

final class CandumpDetector : FormatDetector
{
    override FormatInfo info() const pure nothrow @nogc
    {
        return candumpFormatInfo;
    }

    override Detection detect(string path, const(ubyte)[] head) const
    {
        size_t lines, fits;
        CandumpLine parsed;
        forEachSampleLine(head, (const(char)[] line) {
            if (line.length == 0)
                return;
            ++lines;
            if (parseLine(line, parsed))
                ++fits;
        });
        return detectionByShare(fits, lines, 0);
    }

    override LogFormat create(int variant, const(ubyte)[] head) const
    {
        return new CandumpFormat();
    }
}

// ─── Line parsing ───────────────────────────────────────────────────────────

//! The error flag of a SocketCAN ID (CAN_ERR_FLAG)
private enum uint errorFlag = 0x2000_0000;

private struct CandumpLine
{
    long timeNs;
    const(char)[] channel;
    ulong id;
    CanFrameType type;
    uint dlc;
    ubyte[maxData] data;
    size_t dataLength;
}

//! "(seconds.fraction) channel ID#data", see the module
private bool parseLine(const(char)[] s, out CandumpLine line) pure nothrow @nogc @safe
{
    ulong seconds;
    uint fraction;
    if (!readChar(s, '(') || !readNumber64(s, seconds) || !readChar(s, '.') || !readFraction(s, fraction)
        || !readChar(s, ')') || !readChar(s, ' ') || !readWord(s, line.channel) || !readChar(s, ' '))
        return false;
    line.timeNs = cast(long)(seconds * 1_000_000_000 + fraction);

    const digits = readHex(s, 8, line.id);
    if ((digits != 3 && digits != 8) || !readChar(s, '#'))
        return false;
    line.type = digits == 8 && (line.id & errorFlag) ? CanFrameType.Error : CanFrameType.Can;

    if (readChar(s, '#'))
    {
        ulong flags;
        if (readHex(s, 1, flags) != 1)
            return false;
        line.type = CanFrameType.CanFd;
    }
    else if (readChar(s, 'R'))
    {
        line.type = CanFrameType.Remote;
        readNumber(s, line.dlc); // the requested length, if written
        return s.length == 0 || s[0] == ' ';
    }

    // The data: pairs of hex digits up to the end of the frame
    while (s.length && s[0] != ' ')
    {
        ulong value;
        if (line.dataLength == maxData || readHex(s, 2, value) != 2)
            return false;
        line.data[line.dataLength++] = cast(ubyte) value;
    }
    line.dlc = cast(uint) line.dataLength;
    return true;
}

// ─── Tests ──────────────────────────────────────────────────────────────────

version (unittest)
{
    private const(ubyte)[] bytes(string s)
    {
        return cast(const(ubyte)[]) s;
    }

    private void decodeLine(string text, ref LogMessage!wchar msg)
    {
        assert(new CandumpFormat().decode(msg, bytes(text)));
    }

    private enum long time = 1_762_179_721 * 1_000_000_000L + 123_456_000;
}

@("CandumpFormat: a classic frame")
unittest
{
    LogMessage!wchar msg;
    decodeLine("(1762179721.123456) can0 123#DEADBEEF00112233\n", msg);
    assert(msg.timeKind == TimeKind.Absolute && msg.timeNs == time);
    assert(msg.text(CanField.Channel) == "can0"w);
    assert(msg.number(CanField.Id) == 0x123);
    assert(msg.number(CanField.Type) == CanFrameType.Can);
    assert(msg.number(CanField.Dlc) == 8);
    assert(msg.payloadText == "DE AD BE EF 00 11 22 33"w);
    assert(msg.level == LogLevel.None);
    assert(!msg.hasField(CanField.Dir), "candump -l doesn't tell");
}

@("CandumpFormat: 29-bit IDs, lower case, no data")
unittest
{
    LogMessage!wchar msg;
    decodeLine("(1762179721.123456) vcan1 18fef100#0102", msg);
    assert(msg.number(CanField.Id) == 0x18FEF100 && msg.payloadText == "01 02"w);

    decodeLine("(1762179721.123456) can0 7FF#", msg);
    assert(msg.number(CanField.Id) == 0x7FF && msg.number(CanField.Dlc) == 0 && msg.payloadText.length == 0);
}

@("CandumpFormat: remote frames, with or without a length")
unittest
{
    LogMessage!wchar msg;
    decodeLine("(1762179721.123456) can0 123#R", msg);
    assert(msg.number(CanField.Type) == CanFrameType.Remote && msg.number(CanField.Dlc) == 0);

    decodeLine("(1762179721.123456) can0 123#R3", msg);
    assert(msg.number(CanField.Type) == CanFrameType.Remote && msg.number(CanField.Dlc) == 3);
}

@("CandumpFormat: CAN FD frames")
unittest
{
    LogMessage!wchar msg;
    decodeLine("(1762179721.123456) can0 123##1DEADBEEF0011223344", msg);
    assert(msg.number(CanField.Type) == CanFrameType.CanFd);
    assert(msg.number(CanField.Dlc) == 9);
    assert(msg.payloadText == "DE AD BE EF 00 11 22 33 44"w);
}

@("CandumpFormat: error frames have the level Error")
unittest
{
    LogMessage!wchar msg;
    decodeLine("(1762179721.123456) can0 20000080#0000000000000000", msg);
    assert(msg.number(CanField.Type) == CanFrameType.Error);
    assert(msg.level == LogLevel.Error);
    assert(msg.number(CanField.Id) == 0x20000080, "the ID as written");
}

@("CandumpFormat: a line that doesn't fit keeps its text")
unittest
{
    LogMessage!wchar msg;
    foreach (line; ["not a frame", "(1762179721.123456) can0 123#ABC", "(1762179721.123456) can0 XYZ#00",
            "(1762179721.123456) can0 123"])
    {
        decodeLine(line, msg);
        assert(msg.timeKind == TimeKind.None && !msg.hasField(CanField.Id), line);
        import std.conv : to;

        assert(msg.payloadText == line.to!wstring);
    }
}

@("CandumpFormat: the columns")
unittest
{
    string[] ids;
    foreach (column; new CandumpFormat().columns)
        ids ~= column.id;
    assert(ids == ["time", "channel", "id", "type", "dlc", "payload"]);
    assert(new CandumpFormat().columns[0].timeKind == TimeKind.Absolute);
}

@("CandumpDetector: candump logs, not other text")
unittest
{
    auto detector = new CandumpDetector();
    const d = detector.detect("trace.log",
        bytes("(1762179721.123456) can0 123#DEADBEEF\n(1762179721.223456) can0 18FEF100#01\n"));
    assert(d.score > 0.5f);

    foreach (other; ["Nov  3 14:22:01 host sshd[812]: a\n", "[    0.000000] Linux version\n",
            "just some\ntext lines\n"])
        assert(detector.detect("x.log", bytes(other)).score == 0, other);
}
