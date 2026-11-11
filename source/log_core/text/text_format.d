//! TextFormat: the base of the line-oriented text formats.
module log_core.text.text_format;

import log_core.log_format;
import log_core.log_message : LogMessage;
static import log_core.log_message;
import log_core.text_encoding : bomLength, isHighSurrogate, TextEncoding, transcodeUtf16, unitAt;

import core.stdc.string : memchr;

//! Base of the line-oriented text formats (UTF-8, and UTF-16 through inEncoding()).
//!
//! A record is a line. A multiline format glues the lines that don't start a
//! record (a stack trace, a continued message) to the record before them; a
//! record never grows longer than maxRecordLength bytes and a line break: a
//! continuation line that doesn't fit starts a record, and a line longer than
//! that is cut into records of that size, so any data has records of bounded size.
//! The first line of the data always starts a record.
abstract class TextFormat : LogFormat
{
    //! A record longer than this is cut at its next line, a line longer than
    //! this is cut into records of this size (see log_core.log_message)
    enum size_t maxRecordLength = log_core.log_message.maxRecordLength;

    //! The most bytes scanRecords() looks at before returning control
    enum size_t maxScanBytes = 1024 * 1024;

    private immutable bool _multiline;

    this(bool multiline) pure nothrow @nogc @safe
    {
        _multiline = multiline;
    }

    //! @returns true if `line` (without its line break) starts a record.
    //! Called for every line when scanning: it should be cheap.
    protected bool isRecordStart(const(char)[] line) const nothrow @nogc
    {
        return true;
    }

    //! @brief Decodes the text of a record: its lines without the last line break
    protected abstract bool decodeText(ref LogMessage!wchar msg, const(char)[] text) const nothrow @nogc;

    //! @brief Puts the whole text into the payload of a record begun: how a
    //! format shows a record it can't parse, and plain text all of them
    //! @returns true: the record is decoded
    protected static bool decodeAsPlainText(ref LogMessage!wchar msg, const(char)[] text) nothrow @nogc
    {
        auto builder = msg.payloadBuilder();
        builder.appendUtf8(text);
        return true;
    }

    // scanRecords, recordAt and decode are final: inEncoding() reads UTF-16
    // past them, with isRecordStart() and decodeText() only; what a format
    // does differently goes into those two
    final override ScanResult scanRecords(const(ubyte)[] data, size_t from, size_t[] offsets, bool final_) const nothrow @nogc
    {
        return scanIn!(TextEncoding.utf8)(this, data, from, offsets, final_);
    }

    final override const(ubyte)[] recordAt(const(ubyte)[] data, size_t offset) const nothrow @nogc
    {
        return recordIn!(TextEncoding.utf8)(this, data, offset);
    }

    final override bool decode(ref LogMessage!wchar msg, const(ubyte)[] record) const nothrow @nogc
    {
        if (record.length == 0)
        {
            msg.clear();
            return false;
        }
        return decodeText(msg, withoutLineBreak(cast(const(char)[]) record));
    }
}

//! @returns `format` reading its text in `encoding`: itself for UTF-8, else a
//! format of the same records and columns that reads UTF-16
LogFormat inEncoding(TextFormat format, TextEncoding encoding) pure nothrow @safe
{
    final switch (encoding)
    {
    case TextEncoding.utf8:
        return format;
    case TextEncoding.utf16le:
        return new Utf16TextFormat!(TextEncoding.utf16le)(format);
    case TextEncoding.utf16be:
        return new Utf16TextFormat!(TextEncoding.utf16be)(format);
    }
}

//! A text format reading UTF-16: it finds the lines and records in UTF-16 and
//! gives the format their text in UTF-8
private final class Utf16TextFormat(TextEncoding encoding) : LogFormat
{
    private const TextFormat _text;

    this(const TextFormat text) pure nothrow @nogc @safe
    {
        _text = text;
    }

    override string name() const pure nothrow @nogc
    {
        return _text.name;
    }

    override const(ColumnInfo)[] columns() const pure nothrow @nogc
    {
        return _text.columns;
    }

    override ScanResult scanRecords(const(ubyte)[] data, size_t from, size_t[] offsets, bool final_) const nothrow @nogc
    {
        return scanIn!encoding(_text, data, from, offsets, final_);
    }

    override const(ubyte)[] recordAt(const(ubyte)[] data, size_t offset) const nothrow @nogc
    {
        return recordIn!encoding(_text, data, offset);
    }

    override bool decode(ref LogMessage!wchar msg, const(ubyte)[] record) const nothrow @nogc
    {
        if (record.length == 0)
        {
            msg.clear();
            return false;
        }
        Utf8Line buffer = void;
        return _text.decodeText(msg, withoutLineBreak(buffer[0 .. transcodeUtf16(record, encoding, buffer[])]));
    }
}

// ─── Records in an Encoding ─────────────────────────────────────────────────

//! The most bytes of a line, without its line break, and of a record in
//! `encoding`: their text in UTF-8 never takes more than maxRecordLength bytes
private template maxBytes(TextEncoding encoding)
{
    static if (encoding == TextEncoding.utf8)
        enum size_t maxBytes = TextFormat.maxRecordLength;
    else // UTF-8 takes at most 3 bytes for 2 bytes of UTF-16
        enum size_t maxBytes = TextFormat.maxRecordLength * 2 / 3 & ~cast(size_t) 1;
}

private enum size_t unitSize(TextEncoding encoding) = encoding == TextEncoding.utf8 ? 1 : 2;

//! The UTF-8 of a UTF-16 record of maxBytes and its line break, on the stack
private alias Utf8Line = char[TextFormat.maxRecordLength + 8];

private ScanResult scanIn(TextEncoding encoding)(const TextFormat format, const(ubyte)[] data, size_t from,
    size_t[] offsets, bool final_) nothrow @nogc
{
    size_t pos = from == 0 ? bomLength(data, encoding) : from;
    const size_t limit = pos + TextFormat.maxScanBytes;
    size_t count = 0;

    while (count < offsets.length && pos < data.length && pos < limit)
    {
        const end = recordEnd!encoding(format, data, pos, final_);
        if (end == 0) // the record may still grow: wait for more data
            break;
        offsets[count++] = pos;
        pos = end;
    }
    return ScanResult(count, pos);
}

private const(ubyte)[] recordIn(TextEncoding encoding)(const TextFormat format, const(ubyte)[] data, size_t offset) nothrow @nogc
{
    if (offset >= data.length)
        return null;
    return data[offset .. recordEnd!encoding(format, data, offset, true)];
}

//! @returns the end of the record starting at `start` (after its line
//! break), or 0 if it is not complete yet (only without final_)
private size_t recordEnd(TextEncoding encoding)(const TextFormat format, const(ubyte)[] data, size_t start,
    bool final_) nothrow @nogc
{
    const first = lineEnd!encoding(data, start);
    if (first == tooLong)
        return cutLine!encoding(data, start);
    if (first == incomplete)
        return final_ ? data.length : 0;
    size_t end = first;
    if (!format._multiline)
        return end;

    while (end < data.length)
    {
        const next = lineEnd!encoding(data, end);
        if (next == incomplete && !final_)
            return 0; // can't tell yet whether the line starts a record
        if (next == tooLong)
            return end; // a line that long is a record of its own
        const lineStop = next == incomplete ? data.length : next;
        if (startsRecord!encoding(format, data[end .. lineStop]))
            return end;
        if (withoutFinalNewline!encoding(data, start, lineStop) - start > maxBytes!encoding)
            return end; // the record would be too long with the line
        end = lineStop;
    }
    if (end == data.length && !final_)
        return 0; // the next lines may continue the record
    return end;
}

//! @returns true if the line (with its line break) starts a record of `format`
private bool startsRecord(TextEncoding encoding)(const TextFormat format, const(ubyte)[] line) nothrow @nogc
{
    static if (encoding == TextEncoding.utf8)
        return format.isRecordStart(withoutLineBreak(cast(const(char)[]) line));
    else
    {
        Utf8Line buffer = void;
        return format.isRecordStart(withoutLineBreak(buffer[0 .. transcodeUtf16(line, encoding, buffer[])]));
    }
}

private enum size_t incomplete = size_t.max; // lineEnd(): the data ends first
private enum size_t tooLong = size_t.max - 1; // lineEnd(): longer than maxBytes

//! @returns the end of the line starting at `start` (after its line break),
//! `incomplete` or `tooLong`: a line holds at most maxBytes and its "\n".
//! Looks at that many bytes at most.
private size_t lineEnd(TextEncoding encoding)(const(ubyte)[] data, size_t start) nothrow @nogc
{
    enum size_t room = maxBytes!encoding + unitSize!encoding;
    const limit = start + room < data.length ? start + room : data.length;
    const end = findLineEnd!encoding(data[0 .. limit], start);
    if (end != notFound)
        return end;
    return limit == data.length ? incomplete : tooLong;
}

//! @returns `end` without the "\n" just before it, if there is one after `start`
private size_t withoutFinalNewline(TextEncoding encoding)(const(ubyte)[] data, size_t start, size_t end) pure nothrow @nogc @safe
{
    static if (encoding == TextEncoding.utf8)
        return end > start && data[end - 1] == '\n' ? end - 1 : end;
    else
        return end >= start + 2 && (end - start) % 2 == 0 && unitAt!encoding(data, end - 2) == '\n' ? end - 2 : end;
}

//! @returns where a line too long for a record is cut: maxBytes after
//! `start`, moved back to the start of a character.
private size_t cutLine(TextEncoding encoding)(const(ubyte)[] data, size_t start) pure nothrow @nogc @safe
{
    const size_t limit = start + maxBytes!encoding;
    static if (encoding == TextEncoding.utf8)
    {
        // A character takes 4 bytes at most: data that is not UTF-8 is cut 3 bytes back at most
        size_t cut = limit;
        while (cut > limit - 3 && (data[cut] & 0xC0) == 0x80)
            --cut;
        return (data[cut] & 0xC0) == 0x80 ? limit : cut; // not UTF-8: cut at the limit
    }
    else
    {
        return isHighSurrogate(unitAt!encoding(data, limit - 2)) ? limit - 2 : limit; // a surrogate pair stays whole
    }
}

private enum size_t notFound = size_t.max;

//! @returns the end of the first line break of `encoding` after `from`
//! (code units start at even offsets of the data), or notFound
private size_t findLineEnd(TextEncoding encoding)(const(ubyte)[] data, size_t from) nothrow @nogc
{
    size_t pos = from;
    while (pos < data.length)
    {
        const p = cast(const(ubyte)*) memchr(data.ptr + pos, '\n', data.length - pos);
        if (p is null)
            return notFound;
        const size_t i = p - data.ptr;
        // A UTF-16 character such as U+0A0A has a 0x0A byte too: only the unit U+000A ends a line
        static if (encoding == TextEncoding.utf8)
            return i + 1;
        else static if (encoding == TextEncoding.utf16le)
        {
            if (i % 2 == 0 && i + 1 < data.length && data[i + 1] == 0)
                return i + 2;
        }
        else
        {
            if (i % 2 == 1 && data[i - 1] == 0)
                return i + 1;
        }
        pos = i + 1;
    }
    return notFound;
}

//! @returns `text` without its trailing line break: "\n" and the "\r"s
//! before it ("\r\r\n" comes from an old `adb shell` on Windows)
const(char)[] withoutLineBreak(const(char)[] text) pure nothrow @nogc @safe
{
    if (text.length && text[$ - 1] == '\n')
        text = text[0 .. $ - 1];
    while (text.length && text[$ - 1] == '\r')
        text = text[0 .. $ - 1];
    return text;
}

//! @returns true if `head` looks like text: no zero bytes and no UTF-16 mark
bool looksLikeText(const(ubyte)[] head) pure nothrow @nogc @safe
{
    if (head.length >= 2 && ((head[0] == 0xFF && head[1] == 0xFE) || (head[0] == 0xFE && head[1] == 0xFF)))
        return false; // UTF-16: the registry gives it to the detectors in UTF-8
    foreach (b; head)
        if (b == 0)
            return false;
    return true;
}

//! @brief The detection of a format whose best variant fits `fits` of the
//! `lines` sample lines: nothing below `minShare`, else above the plain text
//! fallback and a mere file extension
Detection detectionByShare(size_t fits, size_t lines, int variant, float minShare = 0.6f) pure nothrow @nogc @safe
{
    if (lines == 0)
        return Detection(0);
    const float share = cast(float) fits / lines;
    if (share < minShare)
        return Detection(0);
    return Detection(0.5f + 0.5f * share, variant);
}

//! @brief Calls `dg` for each complete line of `head` (a sample of the data),
//! without its line break; the last line is skipped if it may be cut
void forEachSampleLine(const(ubyte)[] head, scope void delegate(const(char)[] line) dg)
{
    size_t pos = bomLength(head, TextEncoding.utf8);
    while (pos < head.length)
    {
        const end = findLineEnd!(TextEncoding.utf8)(head, pos);
        if (end == notFound)
            break;
        dg(withoutLineBreak(cast(const(char)[]) head[pos .. end]));
        pos = end;
    }
}

// ─── Tests ──────────────────────────────────────────────────────────────────

version (unittest)
{
    //! Records start with '#'; other lines continue them
    private final class HashFormat : TextFormat
    {
        this(bool multiline)
        {
            super(multiline);
        }

        override string name() const pure nothrow @nogc
        {
            return "test";
        }

        override const(ColumnInfo)[] columns() const pure nothrow @nogc
        {
            return null;
        }

        override bool isRecordStart(const(char)[] line) const nothrow @nogc
        {
            return line.length && line[0] == '#';
        }

        override bool decodeText(ref LogMessage!wchar msg, const(char)[] text) const nothrow @nogc
        {
            msg.beginRecord();
            return decodeAsPlainText(msg, text);
        }
    }

    import log_core.text_encoding : utf16Bytes;

    private size_t[] scanAll(const(LogFormat) format, const(ubyte)[] data)
    {
        size_t[] result;
        size_t[3] offsets;
        size_t pos = 0;
        while (pos < data.length)
        {
            const r = format.scanRecords(data, pos, offsets[], true);
            result ~= offsets[0 .. r.count];
            assert(r.next > pos || r.count > 0, "scanning must make progress");
            pos = r.next;
        }
        return result;
    }

    private const(ubyte)[] bytes(string s)
    {
        return cast(const(ubyte)[]) s;
    }
}

@("TextFormat: every line is a record")
unittest
{
    auto format = new HashFormat(false);
    auto data = bytes("#a\nb\r\n\n#c");
    assert(scanAll(format, data) == [0, 3, 6, 7]);
    assert(format.recordAt(data, 3) == "b\r\n");

    LogMessage!wchar msg;
    assert(format.decode(msg, format.recordAt(data, 3)));
    assert(msg.payloadText == "b"w, "the line break is not part of the text");
    assert(format.decode(msg, format.recordAt(data, 7)) && msg.payloadText == "#c"w);
}

@("TextFormat: multiline records glue the continuation lines")
unittest
{
    auto format = new HashFormat(true);
    auto data = bytes("lead\n#a\n x\n y\n#b\n#c\n z");
    assert(scanAll(format, data) == [0, 5, 14, 17], "the first line always starts a record");
    assert(format.recordAt(data, 5) == "#a\n x\n y\n");
    assert(format.recordAt(data, 17) == "#c\n z");

    LogMessage!wchar msg;
    assert(format.decode(msg, format.recordAt(data, 5)));
    assert(msg.payloadText == "#a\n x\n y"w);
}

@("TextFormat: a multiline record is cut at maxRecordLength")
unittest
{
    auto format = new HashFormat(true);
    string data = "#start\n";
    while (data.length < 3 * TextFormat.maxRecordLength)
        data ~= "continuation line without a record start\n";
    auto offsets = scanAll(format, bytes(data));
    assert(offsets.length == 3 || offsets.length == 4);
    foreach (i; 1 .. offsets.length)
    {
        assert(offsets[i] - offsets[i - 1] <= TextFormat.maxRecordLength + 64);
        assert(data[offsets[i] - 1] == '\n', "cut at a line boundary");
        assert(format.recordAt(bytes(data), offsets[i - 1]).length == offsets[i] - offsets[i - 1],
            "recordAt agrees with the scan");
    }
}

@("TextFormat: without final_ a record waits until its end is known")
unittest
{
    auto lines = new HashFormat(false);
    auto multi = new HashFormat(true);
    size_t[4] offsets;

    // A line without its line break is not complete yet
    auto r = lines.scanRecords(bytes("#a\n#b"), 0, offsets[], false);
    assert(r.count == 1 && r.next == 3);

    // A multiline record is complete once the next record starts
    r = multi.scanRecords(bytes("#a\n x\n"), 0, offsets[], false);
    assert(r.count == 0 && r.next == 0, "more continuation lines may come");
    r = multi.scanRecords(bytes("#a\n x\n#b\n"), 0, offsets[], false);
    assert(r.count == 1 && offsets[0] == 0 && r.next == 6);
    r = multi.scanRecords(bytes("#a\n x\n#b\n"), r.next, offsets[], true);
    assert(r.count == 1 && offsets[0] == 6 && r.next == 9);
}

@("TextFormat: the UTF-8 byte order mark is skipped")
unittest
{
    auto format = new HashFormat(false);
    auto data = cast(const(ubyte)[])[0xEF, 0xBB, 0xBF] ~ bytes("#a\n#b\n");
    assert(scanAll(format, data) == [3, 6]);
}

@("TextFormat: text detection and sample lines")
unittest
{
    assert(looksLikeText(bytes("plain\ntext\n")));
    assert(!looksLikeText(cast(const(ubyte)[])[0x41, 0x00, 0x42]));
    assert(!looksLikeText(cast(const(ubyte)[])[0xFF, 0xFE, 0x41, 0x00]));

    const(char)[][] lines;
    forEachSampleLine(bytes("a\r\nb\ncut"), (const(char)[] line) { lines ~= line; });
    assert(lines == ["a", "b"], "the last line may be cut by the sample");
}

@("TextFormat: a line longer than maxRecordLength is cut at a character boundary")
unittest
{
    import std.array : replicate;

    enum max = TextFormat.maxRecordLength;
    // "é" takes 2 bytes, starting at odd offsets: a cut at max bytes would split one
    const string data = "#" ~ "é".replicate(max + max / 4); // ~2.5 * max, no line break

    foreach (multiline; [false, true])
    {
        auto format = new HashFormat(multiline);
        auto offsets = scanAll(format, bytes(data));
        assert(offsets.length == 3, "a long line is several records");
        foreach (i, offset; offsets)
        {
            assert((data[offset] & 0xC0) != 0x80, "a record starts at a character");
            const record = format.recordAt(bytes(data), offset);
            assert(record.length <= max);
            const next = i + 1 < offsets.length ? offsets[i + 1] : data.length;
            assert(offset + record.length == next, "recordAt agrees with the scan");
        }
    }

    // In a stream, the cut parts are complete before the line break arrives
    size_t[4] found;
    const r = new HashFormat(false).scanRecords(bytes(data), 0, found[], false);
    assert(r.count == 2, "the last part may still grow");
}

@("TextFormat: every carriage return before the line break is dropped")
unittest
{
    auto format = new HashFormat(false);
    auto data = bytes("#a\r\r\n#b\n");
    LogMessage!wchar msg;
    assert(format.decode(msg, format.recordAt(data, 0)));
    assert(msg.payloadText == "#a"w);
}

@("TextFormat: a record of maxRecordLength fits in the buffer of a message")
unittest
{
    // A UTF-8 byte makes at most one UTF-16 character: a buffer of that many
    // characters holds the text of any record
    assert(LogMessage!wchar.capacity >= TextFormat.maxRecordLength,
        "longer records would be cut when decoded");
}

@("TextFormat: a line of maxRecordLength bytes and its line break is one record")
unittest
{
    import std.array : replicate;

    enum max = TextFormat.maxRecordLength;
    auto format = new HashFormat(false);
    foreach (line; ["#".replicate(max) ~ "\n", "#".replicate(max - 1) ~ "\r\n"])
    {
        const data = line ~ "#next\n";
        assert(scanAll(format, bytes(data)) == [0, line.length], "no empty record after it");
        assert(format.recordAt(bytes(data), 0).length == line.length);
    }
}

@("TextFormat: a multiline record with long continuation lines stays within the limit")
unittest
{
    import std.array : replicate;

    enum max = TextFormat.maxRecordLength;
    const continuation = " ".replicate(40 * 1024 - 1) ~ "\n";
    const data = "#start\n" ~ continuation.replicate(3);

    auto format = new HashFormat(true);
    auto offsets = scanAll(format, bytes(data));
    foreach (i, offset; offsets)
    {
        const record = format.recordAt(bytes(data), offset);
        assert(record.length <= max + 1, "a record holds at most maxRecordLength bytes and a line break");
        const next = i + 1 < offsets.length ? offsets[i + 1] : data.length;
        assert(offset + record.length == next, "recordAt agrees with the scan");
    }
}

@("TextFormat: a long line of bytes that are not UTF-8 is cut into records of the limit")
unittest
{
    enum max = TextFormat.maxRecordLength;
    auto data = new ubyte[](3 * max);
    data[] = 0x80; // continuation bytes only: no character starts anywhere

    auto offsets = scanAll(new HashFormat(false), data);
    assert(offsets.length <= 4, "not thousands of tiny records");
}

@("inEncoding: UTF-16 lines, a character with a 0x0A or 0x0D byte ends none")
unittest
{
    foreach (encoding; [TextEncoding.utf16le, TextEncoding.utf16be])
    {
        auto format = inEncoding(new HashFormat(false), encoding);
        const data = utf16Bytes("#a\u0A0A\r\n#\u0D0Ab\n\n#c", encoding, true);
        assert(scanAll(format, data) == [2, 12, 20, 22], "after the byte order mark, a record per line");

        LogMessage!wchar msg;
        assert(format.decode(msg, format.recordAt(data, 2)) && msg.payloadText == "#a\u0A0A"w,
            "the line break is not part of the text");
        assert(format.decode(msg, format.recordAt(data, 12)) && msg.payloadText == "#\u0D0Ab"w);
        assert(format.decode(msg, format.recordAt(data, 20)) && msg.payloadText == ""w);
        assert(format.decode(msg, format.recordAt(data, 22)) && msg.payloadText == "#c"w);
    }
}

@("inEncoding: UTF-16 multiline records")
unittest
{
    foreach (encoding; [TextEncoding.utf16le, TextEncoding.utf16be])
    {
        auto format = inEncoding(new HashFormat(true), encoding);
        const data = utf16Bytes("lead\n#a\n x\n#b", encoding);
        assert(scanAll(format, data) == [0, 10, 22]);

        LogMessage!wchar msg;
        assert(format.decode(msg, format.recordAt(data, 10)) && msg.payloadText == "#a\n x"w);
    }
}

@("inEncoding: without final_ a UTF-16 line waits for its line break")
unittest
{
    auto format = inEncoding(new HashFormat(false), TextEncoding.utf16le);
    size_t[4] offsets;
    auto r = format.scanRecords(utf16Bytes("#a\n#b", TextEncoding.utf16le), 0, offsets[], false);
    assert(r.count == 1 && r.next == 6);
    r = format.scanRecords(utf16Bytes("#a\n", TextEncoding.utf16le) ~ cast(ubyte) '\n', 0, offsets[], false);
    assert(r.count == 1 && r.next == 6, "half a code unit is no line break");
}

@("inEncoding: a long UTF-16 line is cut between characters, its text within the limit")
unittest
{
    import std.algorithm : canFind;
    import std.array : replicate;
    import std.utf : toUTF16;

    enum max = TextFormat.maxRecordLength;
    // A surrogate pair at every odd unit: a cut at any even unit count splits one
    const line = "#" ~ "\U0001F600".replicate(max);
    const data = utf16Bytes(line, TextEncoding.utf16le);

    foreach (multiline; [false, true])
    {
        auto format = inEncoding(new HashFormat(multiline), TextEncoding.utf16le);
        auto offsets = scanAll(format, data);
        assert(offsets.length > 1, "a long line is several records");
        LogMessage!wchar msg;
        wstring joined;
        foreach (i, offset; offsets)
        {
            const record = format.recordAt(data, offset);
            const next = i + 1 < offsets.length ? offsets[i + 1] : data.length;
            assert(offset + record.length == next, "recordAt agrees with the scan");
            assert(format.decode(msg, record));
            assert(!msg.payloadText.canFind('\uFFFD'), "no surrogate pair is split");
            assert(msg.payloadText.length * 3 / 2 <= max, "its UTF-8 fits a record of UTF-8");
            joined ~= msg.payloadText;
        }
        assert(joined == line.toUTF16, "the parts hold the line, every character once");
    }
}

@("detectionByShare: nothing below the share, a score above the fallbacks")
unittest
{
    assert(detectionByShare(0, 0, 1).score == 0, "no lines");
    assert(detectionByShare(5, 10, 1).score == 0, "below 0.6");
    const d = detectionByShare(8, 10, 3);
    assert(d.variant == 3 && d.score > 0.5f && d.score < 1.0f);
    assert(detectionByShare(10, 10, 0).score == 1.0f);
}
