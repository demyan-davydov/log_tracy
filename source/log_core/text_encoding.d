//! The encodings of text logs: which one some bytes are in (a byte order mark,
//! or the zero bytes of UTF-16 without one), and UTF-16 converted to UTF-8.
module log_core.text_encoding;

//! The encoding of a text log. Saved in the settings by encodingName().
enum TextEncoding : ubyte
{
    utf8, // also any text that is not UTF-16: shown as UTF-8
    utf16le,
    utf16be,
}

//! @returns the name of the encoding, as the settings keep it
string encodingName(TextEncoding encoding) pure nothrow @nogc @safe
{
    final switch (encoding)
    {
    case TextEncoding.utf8:
        return "utf-8";
    case TextEncoding.utf16le:
        return "utf-16le";
    case TextEncoding.utf16be:
        return "utf-16be";
    }
}

//! @returns false if no encoding has the name (a setting of another build)
bool encodingByName(string name, out TextEncoding encoding) pure nothrow @nogc @safe
{
    static foreach (e; __traits(allMembers, TextEncoding))
        if (name == encodingName(__traits(getMember, TextEncoding, e)))
        {
            encoding = __traits(getMember, TextEncoding, e);
            return true;
        }
    return false;
}

//! @returns the UTF-16 encoding whose byte order mark starts `head`, else utf8
TextEncoding utf16ByBom(const(ubyte)[] head) pure nothrow @nogc @safe
{
    if (head.length >= 2 && head[0] == 0xFF && head[1] == 0xFE)
        return TextEncoding.utf16le;
    if (head.length >= 2 && head[0] == 0xFE && head[1] == 0xFF)
        return TextEncoding.utf16be;
    return TextEncoding.utf8;
}

//! @brief Guesses UTF-16 without a byte order mark by its zero bytes: the
//! high bytes of ASCII (the digits, spaces and punctuation of any log) are
//! zero, on one side of the code units only.
//! @returns the UTF-16 encoding `head` looks like, else utf8
TextEncoding guessUtf16(const(ubyte)[] head) pure nothrow @nogc @safe
{
    const units = head.length / 2;
    if (units < 2)
        return TextEncoding.utf8;
    size_t zeroFirst, zeroSecond; // of the units, the first byte / the second byte is zero
    foreach (i; 0 .. units)
    {
        const first = head[2 * i] == 0, second = head[2 * i + 1] == 0;
        if (first && second)
            return TextEncoding.utf8; // U+0000 is no text
        zeroFirst += first;
        zeroSecond += second;
    }
    // Most units ASCII, and a zero low byte (U+4E00, U+0100) rare
    if (zeroSecond * 2 >= units && zeroFirst * 16 <= units)
        return TextEncoding.utf16le;
    if (zeroFirst * 2 >= units && zeroSecond * 16 <= units)
        return TextEncoding.utf16be;
    return TextEncoding.utf8;
}

//! @returns the length of the byte order mark of `encoding` at the start of
//! `data`, 0 if there is none
size_t bomLength(const(ubyte)[] data, TextEncoding encoding) pure nothrow @nogc @safe
{
    final switch (encoding)
    {
    case TextEncoding.utf8:
        return data.length >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF ? 3 : 0;
    case TextEncoding.utf16le:
    case TextEncoding.utf16be:
        return utf16ByBom(data) == encoding ? 2 : 0;
    }
}

//! @brief Converts UTF-16 to UTF-8 into `buffer`: as many whole characters as
//! fit. A lone surrogate and an odd last byte become U+FFFD.
//! @returns the length of the UTF-8 written
size_t transcodeUtf16(const(ubyte)[] utf16, TextEncoding encoding, char[] buffer) pure nothrow @nogc @safe
{
    const bool be = encoding == TextEncoding.utf16be;
    size_t i = 0, n = 0;
    while (i < utf16.length)
    {
        dchar c = 0xFFFD; // an odd last byte, a lone surrogate
        size_t used = utf16.length - i; // the odd last byte
        if (used >= 2)
        {
            used = 2;
            const wchar u = unitAt(utf16, i, be);
            if (u < 0xD800 || u > 0xDFFF)
                c = u;
            else if (isHighSurrogate(u) && i + 4 <= utf16.length)
            {
                const wchar low = unitAt(utf16, i + 2, be);
                if (low >= 0xDC00 && low <= 0xDFFF)
                {
                    c = 0x10000 + ((u - 0xD800) << 10) + (low - 0xDC00);
                    used = 4;
                }
            }
        }
        const size_t length = c < 0x80 ? 1 : c < 0x800 ? 2 : c < 0x10000 ? 3 : 4;
        if (n + length > buffer.length)
            break;
        final switch (length)
        {
        case 1:
            buffer[n] = cast(char) c;
            break;
        case 2:
            buffer[n] = cast(char)(0xC0 | (c >> 6));
            buffer[n + 1] = cast(char)(0x80 | (c & 0x3F));
            break;
        case 3:
            buffer[n] = cast(char)(0xE0 | (c >> 12));
            buffer[n + 1] = cast(char)(0x80 | ((c >> 6) & 0x3F));
            buffer[n + 2] = cast(char)(0x80 | (c & 0x3F));
            break;
        case 4:
            buffer[n] = cast(char)(0xF0 | (c >> 18));
            buffer[n + 1] = cast(char)(0x80 | ((c >> 12) & 0x3F));
            buffer[n + 2] = cast(char)(0x80 | ((c >> 6) & 0x3F));
            buffer[n + 3] = cast(char)(0x80 | (c & 0x3F));
            break;
        }
        n += length;
        i += used;
    }
    return n;
}

//! @returns the UTF-16 code unit of `encoding` at byte `i` of `data`
wchar unitAt(TextEncoding encoding)(const(ubyte)[] data, size_t i) pure nothrow @nogc @safe
    if (encoding != TextEncoding.utf8)
{
    static if (encoding == TextEncoding.utf16be)
        return cast(wchar)(data[i] << 8 | data[i + 1]);
    else
        return cast(wchar)(data[i + 1] << 8 | data[i]);
}

//! @returns true if `unit` is the first half of a surrogate pair
bool isHighSurrogate(wchar unit) pure nothrow @nogc @safe
{
    return unit >= 0xD800 && unit <= 0xDBFF;
}

private wchar unitAt(const(ubyte)[] data, size_t i, bool be) pure nothrow @nogc @safe
{
    return be ? unitAt!(TextEncoding.utf16be)(data, i) : unitAt!(TextEncoding.utf16le)(data, i);
}

//! @brief `head` in UTF-8, without its byte order mark: what the detectors of
//! the formats look at (they read UTF-8)
const(ubyte)[] utf8Head(const(ubyte)[] head, TextEncoding encoding) pure nothrow @safe
{
    if (encoding == TextEncoding.utf8)
        return head;
    const utf16 = head[bomLength(head, encoding) .. $];
    auto buffer = new char[utf16.length * 3 / 2 + 3];
    return cast(const(ubyte)[]) buffer[0 .. transcodeUtf16(utf16, encoding, buffer)];
}

version (unittest)
{
    //! @returns `text` in UTF-16 of `encoding`, with its byte order mark if `bom`
    const(ubyte)[] utf16Bytes(string text, TextEncoding encoding, bool bom = false) pure @safe
    {
        import std.utf : toUTF16;

        ubyte[] result;
        const units = (bom ? "﻿"w : ""w) ~ text.toUTF16;
        foreach (wchar u; units)
        {
            const ubyte lo = u & 0xFF, hi = u >> 8;
            result ~= encoding == TextEncoding.utf16be ? [hi, lo] : [lo, hi];
        }
        return result;
    }
}

// ─── Tests ──────────────────────────────────────────────────────────────────

version (unittest)
{
    private string utf8Of(const(ubyte)[] utf16, TextEncoding encoding, size_t bufferSize = 256)
    {
        auto buffer = new char[bufferSize];
        return buffer[0 .. transcodeUtf16(utf16, encoding, buffer)].idup;
    }
}

@("TextEncoding: names for the settings")
unittest
{
    TextEncoding e;
    assert(encodingByName("utf-16be", e) && e == TextEncoding.utf16be);
    assert(encodingByName(encodingName(TextEncoding.utf16le), e) && e == TextEncoding.utf16le);
    assert(!encodingByName("koi8-r", e));
}

@("utf16ByBom: the byte order marks of UTF-16")
unittest
{
    assert(utf16ByBom([0xFF, 0xFE, 0x41, 0x00]) == TextEncoding.utf16le);
    assert(utf16ByBom([0xFE, 0xFF, 0x00, 0x41]) == TextEncoding.utf16be);
    assert(utf16ByBom([0xEF, 0xBB, 0xBF, 0x41]) == TextEncoding.utf8);
    assert(utf16ByBom([0xFF]) == TextEncoding.utf8);
    assert(bomLength([0xFF, 0xFE, 0x41, 0x00], TextEncoding.utf16le) == 2);
    assert(bomLength([0xFF, 0xFE, 0x41, 0x00], TextEncoding.utf16be) == 0);
    assert(bomLength([0xFE, 0xFF, 0x00, 0x41], TextEncoding.utf16be) == 2);
}

@("guessUtf16: a log in UTF-16 without a byte order mark")
unittest
{
    const log = "2026-04-22 13:44:53 INFO Привет, 世界\n2026-04-22 13:44:54 WARN done\n";
    assert(guessUtf16(utf16Bytes(log, TextEncoding.utf16le)) == TextEncoding.utf16le);
    assert(guessUtf16(utf16Bytes(log, TextEncoding.utf16be)) == TextEncoding.utf16be);
    assert(guessUtf16(cast(const(ubyte)[]) log) == TextEncoding.utf8, "UTF-8 has no zeros");
    assert(guessUtf16(cast(const(ubyte)[]) "a\0b\0\0\0c\0d\0\0\0") == TextEncoding.utf8,
        "zero units are binary data");
    assert(guessUtf16([0, 0, 0, 0, 1, 0, 0, 0, 7, 0, 0, 0]) == TextEncoding.utf8, "zeros on both sides");
    assert(guessUtf16(utf16Bytes("Привет, мир! 世界", TextEncoding.utf16le)) == TextEncoding.utf8,
        "not enough ASCII to tell");
}

@("transcodeUtf16: characters of every length, both byte orders")
unittest
{
    const text = "a é Я 世 \U0001F600 ਊഊ\n";
    assert(utf8Of(utf16Bytes(text, TextEncoding.utf16le), TextEncoding.utf16le) == text);
    assert(utf8Of(utf16Bytes(text, TextEncoding.utf16be), TextEncoding.utf16be) == text);
}

@("transcodeUtf16: lone surrogates and an odd last byte become U+FFFD")
unittest
{
    const ubyte[] lone = [0x00, 0xD8, 0x41, 0x00]; // a high surrogate, then 'A'
    assert(utf8Of(lone, TextEncoding.utf16le) == "�A");
    const ubyte[] low = [0x00, 0xDC]; // a low surrogate alone
    assert(utf8Of(low, TextEncoding.utf16le) == "�");
    const ubyte[] high = [0x3D, 0xD8]; // a high surrogate at the end
    assert(utf8Of(high, TextEncoding.utf16le) == "�");
    assert(utf8Of([0x41, 0x00, 0x42], TextEncoding.utf16le) == "A�");
}

@("transcodeUtf16: only whole characters fit the buffer")
unittest
{
    const data = utf16Bytes("ab\U0001F600", TextEncoding.utf16le);
    assert(utf8Of(data, TextEncoding.utf16le, 5) == "ab", "the 4 bytes of 😀 don't fit in 3");
    assert(utf8Of(data, TextEncoding.utf16le, 6) == "ab\U0001F600");
    assert(utf8Of(data, TextEncoding.utf16le, 0) == "");
}

@("utf8Head: the head without its byte order mark")
unittest
{
    assert(utf8Head(utf16Bytes("Я\n", TextEncoding.utf16be, true), TextEncoding.utf16be) == "Я\n");
    assert(utf8Head(utf16Bytes("Я\n", TextEncoding.utf16le), TextEncoding.utf16le) == "Я\n");
}
