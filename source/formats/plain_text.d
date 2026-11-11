//! PlainTextFormat: any text, a record per line; the fallback format.
module formats.plain_text;

import log_core.log_format;
import log_core.log_message : LogMessage;
import log_core.text.text_format;

//! How the user and the settings know PlainTextFormat
enum FormatInfo plainTextFormatInfo = FormatInfo("text", "Plain text", "TXT");

//! Any text: a record per line, only the payload. The fallback for text that
//! no other format recognises.
final class PlainTextFormat : TextFormat
{
    private static immutable ColumnInfo[] _columns = [
        ColumnInfo("payload", "Text", ColumnKind.Payload),
    ];

    this() pure nothrow @nogc @safe
    {
        super(false);
    }

    override string name() const pure nothrow @nogc
    {
        return plainTextFormatInfo.name;
    }

    override const(ColumnInfo)[] columns() const pure nothrow @nogc
    {
        return _columns;
    }

    protected override bool decodeText(ref LogMessage!wchar msg, const(char)[] text) const nothrow @nogc
    {
        msg.beginRecord();
        return decodeAsPlainText(msg, text);
    }
}

final class PlainTextDetector : FormatDetector
{
    override const(int)[] variants() const pure nothrow
    {
        return [0]; // one, whatever the variant
    }

    override FormatInfo info() const pure nothrow @nogc
    {
        return plainTextFormatInfo;
    }

    //! Low: any more specific format that fits wins
    enum float fallbackScore = 0.05f;

    //! An empty file: below a format's extension hint (e.g. ".dlt"), so a
    //! capture that has not been written yet keeps its format
    enum float emptyScore = 0.03f;

    override Detection detect(string path, const(ubyte)[] head) const
    {
        if (head.length == 0)
            return Detection(emptyScore);
        return Detection(looksLikeText(head) ? fallbackScore : 0);
    }

    override LogFormat create(int variant, const(ubyte)[] head) const
    {
        return new PlainTextFormat();
    }
}

@("PlainTextFormat: a record per line, the line is the payload")
unittest
{
    auto format = new PlainTextFormat();
    auto data = cast(const(ubyte)[]) "first line\r\nsecond line\n";
    size_t[4] offsets;
    const r = format.scanRecords(data, 0, offsets[], true);
    assert(r.count == 2 && offsets[0 .. 2] == [0, 12]);

    LogMessage!wchar msg;
    assert(format.decode(msg, format.recordAt(data, 12)));
    assert(msg.payloadText == "second line"w);
}

@("PlainTextDetector: text gets a low score, binary data none")
unittest
{
    auto detector = new PlainTextDetector();
    assert(detector.detect("x.txt", cast(const(ubyte)[]) "some text\n").score == PlainTextDetector.fallbackScore);
    assert(detector.detect("x.bin", cast(const(ubyte)[])[1, 0, 2]).score == 0);
}

@("PlainTextFormat: a line of the maximum record length is decoded whole")
unittest
{
    import std.array : replicate;

    const line = "a".replicate(TextFormat.maxRecordLength - 1) ~ "\n";
    auto format = new PlainTextFormat();
    const record = format.recordAt(cast(const(ubyte)[]) line, 0);
    assert(record.length == line.length, "one record");

    LogMessage!wchar msg;
    assert(format.decode(msg, record));
    assert(msg.payloadText.length == TextFormat.maxRecordLength - 1, "no text is cut");
}
