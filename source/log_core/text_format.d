module log_core.text_format;

import log_core.log_format;
import log_core.log_message : LogMessage;
static import log_core.log_message;

import core.stdc.string : memchr;

//! Base of the line-oriented text formats (UTF-8).
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

    override ScanResult scanRecords(const(ubyte)[] data, size_t from, size_t[] offsets, bool final_) const nothrow @nogc
    {
        size_t pos = from == 0 ? bomLength(data) : from;
        const size_t limit = pos + maxScanBytes;
        size_t count = 0;

        while (count < offsets.length && pos < data.length && pos < limit)
        {
            const end = recordEnd(data, pos, final_);
            if (end == 0) // the record may still grow: wait for more data
                break;
            offsets[count++] = pos;
            pos = end;
        }
        return ScanResult(count, pos);
    }

    override const(ubyte)[] recordAt(const(ubyte)[] data, size_t offset) const nothrow @nogc
    {
        if (offset >= data.length)
            return null;
        return data[offset .. recordEnd(data, offset, true)];
    }

    override bool decode(ref LogMessage!wchar msg, const(ubyte)[] record) const nothrow @nogc
    {
        if (record.length == 0)
        {
            msg.clear();
            return false;
        }
        return decodeText(msg, withoutLineBreak(cast(const(char)[]) record));
    }

    //! @returns the end of the record starting at `start` (after its line
    //! break), or 0 if it is not complete yet (only without final_)
    private size_t recordEnd(const(ubyte)[] data, size_t start, bool final_) const nothrow @nogc
    {
        const first = lineEnd(data, start);
        if (first == tooLong)
            return cutLine(data, start);
        if (first == incomplete)
            return final_ ? data.length : 0;
        size_t end = first;
        if (!_multiline)
            return end;

        while (end < data.length)
        {
            const next = lineEnd(data, end);
            if (next == incomplete && !final_)
                return 0; // can't tell yet whether the line starts a record
            if (next == tooLong)
                return end; // a line that long is a record of its own
            const lineStop = next == incomplete ? data.length : next;
            if (isRecordStart(withoutLineBreak(cast(const(char)[]) data[end .. lineStop])))
                return end;
            if (withoutFinalNewline(data, start, lineStop) - start > maxRecordLength)
                return end; // the record would be too long with the line
            end = lineStop;
        }
        if (end == data.length && !final_)
            return 0; // the next lines may continue the record
        return end;
    }
}

private enum size_t incomplete = size_t.max; // lineEnd(): the data ends first
private enum size_t tooLong = size_t.max - 1; // lineEnd(): longer than maxRecordLength

//! @returns the end of the line starting at `start` (after its line break),
//! `incomplete` or `tooLong`: a line holds at most maxRecordLength bytes and
//! its "\n". Looks at that many bytes at most.
private size_t lineEnd(const(ubyte)[] data, size_t start) nothrow @nogc
{
    const limit = start + TextFormat.maxRecordLength + 1 < data.length
        ? start + TextFormat.maxRecordLength + 1 : data.length;
    const newline = findNewline(data[0 .. limit], start);
    if (newline != notFound)
        return newline + 1;
    return limit == data.length ? incomplete : tooLong;
}

//! @returns `end` without the "\n" just before it, if there is one after `start`
private size_t withoutFinalNewline(const(ubyte)[] data, size_t start, size_t end) pure nothrow @nogc @safe
{
    return end > start && data[end - 1] == '\n' ? end - 1 : end;
}

//! @returns where a line too long for a record is cut: maxRecordLength bytes
//! after `start`, moved back to the start of a UTF-8 character. A character
//! takes 4 bytes at most: data that is not UTF-8 is cut 3 bytes back at most.
private size_t cutLine(const(ubyte)[] data, size_t start) pure nothrow @nogc @safe
{
    const size_t limit = start + TextFormat.maxRecordLength;
    size_t cut = limit;
    while (cut > limit - 3 && (data[cut] & 0xC0) == 0x80)
        --cut;
    return (data[cut] & 0xC0) == 0x80 ? limit : cut; // not UTF-8: cut at the limit
}

private enum size_t notFound = size_t.max;

private size_t findNewline(const(ubyte)[] data, size_t from) nothrow @nogc
{
    if (from >= data.length)
        return notFound;
    const p = cast(const(ubyte)*) memchr(data.ptr + from, '\n', data.length - from);
    return p is null ? notFound : p - data.ptr;
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

//! @returns the length of the UTF-8 byte order mark at the start of `data`
size_t bomLength(const(ubyte)[] data) pure nothrow @nogc @safe
{
    return data.length >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF ? 3 : 0;
}

//! @returns true if `head` looks like text: no zero bytes and no UTF-16 mark
bool looksLikeText(const(ubyte)[] head) pure nothrow @nogc @safe
{
    if (head.length >= 2 && ((head[0] == 0xFF && head[1] == 0xFE) || (head[0] == 0xFE && head[1] == 0xFF)))
        return false; // UTF-16: not supported yet
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
    size_t pos = bomLength(head);
    while (pos < head.length)
    {
        const newline = findNewline(head, pos);
        if (newline == notFound)
            break;
        dg(withoutLineBreak(cast(const(char)[]) head[pos .. newline + 1]));
        pos = newline + 1;
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
            auto builder = msg.payloadBuilder();
            builder.appendUtf8(text);
            return true;
        }
    }

    private size_t[] scanAll(const(TextFormat) format, const(ubyte)[] data)
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

@("detectionByShare: nothing below the share, a score above the fallbacks")
unittest
{
    assert(detectionByShare(0, 0, 1).score == 0, "no lines");
    assert(detectionByShare(5, 10, 1).score == 0, "below 0.6");
    const d = detectionByShare(8, 10, 3);
    assert(d.variant == 3 && d.score > 0.5f && d.score < 1.0f);
    assert(detectionByShare(10, 10, 0).score == 1.0f);
}
