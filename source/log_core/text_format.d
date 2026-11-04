module log_core.text_format;

import log_core.log_format;
import log_core.log_message : LogMessage;

import core.stdc.string : memchr;

//! Base of the line-oriented text formats (UTF-8).
//!
//! A record is a line. A multiline format glues the lines that don't start a
//! record (a stack trace, a continued message) to the record before them; a
//! record is cut at a line boundary once it is longer than maxRecordLength,
//! so a file that doesn't fit the format still has records of bounded size.
//! The first line of the data always starts a record.
abstract class TextFormat : LogFormat
{
    //! A record longer than this is cut at its next line
    enum size_t maxRecordLength = 64 * 1024;

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

    override size_t minRecordLength() const pure nothrow @nogc
    {
        return 1;
    }

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
        size_t newline = findNewline(data, start);
        if (newline == notFound)
            return final_ ? data.length : 0;
        size_t end = newline + 1;
        if (!_multiline)
            return end;

        while (end < data.length && end - start < maxRecordLength)
        {
            newline = findNewline(data, end);
            if (newline == notFound && !final_)
                return 0; // can't tell yet whether the line starts a record
            const lineEnd = newline == notFound ? data.length : newline;
            if (isRecordStart(withoutLineBreak(cast(const(char)[]) data[end .. lineEnd])))
                return end;
            end = newline == notFound ? data.length : newline + 1;
        }
        if (end == data.length && !final_)
            return 0; // the next lines may continue the record
        return end;
    }
}

private enum size_t notFound = size_t.max;

private size_t findNewline(const(ubyte)[] data, size_t from) nothrow @nogc
{
    if (from >= data.length)
        return notFound;
    const p = cast(const(ubyte)*) memchr(data.ptr + from, '\n', data.length - from);
    return p is null ? notFound : p - data.ptr;
}

//! @returns `text` without its trailing "\n" or "\r\n"
const(char)[] withoutLineBreak(const(char)[] text) pure nothrow @nogc @safe
{
    if (text.length && text[$ - 1] == '\n')
        text = text[0 .. $ - 1];
    if (text.length && text[$ - 1] == '\r')
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
