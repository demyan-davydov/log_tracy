module dlt_core.decoded_message;

import std.traits;
import core.stdc.stdlib : malloc, free;
import std.ascii : isPrintable, isASCII;
import std.algorithm : copy, min;
import dlt_core.dlt_protocol : LogLevel, MessageType;

/// Represents a decoded DLT log message
struct DecodedMessage(Char) if (isSomeChar!Char)
{
    @disable this(ref DecodedMessage);
    @disable void opAssign(ref DecodedMessage);

    private LinearAllocator!Char _allocator;

    uint timestampSeconds;
    uint timestampMicroseconds;
    LogLevel level;
    MessageType type;
    uint messageId;

    // from extended header (if present)
    uint sessionId;
    uint relativeTimestamp_10000; // in 1/10000 of a second

    private Char[] _ecuId;
    private Char[] _appId;
    private Char[] _ctxId;
    private Char[] _payloadText;

    private Char* allocFor(size_t count)
    {
        return _allocator.allocAligned(count);
    }

    const(Char)[] ecuId() const pure nothrow @nogc @property
    {
        return _ecuId;
    }

    const(Char)[] appId() const pure nothrow @nogc @property
    {
        return _appId;
    }

    const(Char)[] ctxId() const pure nothrow @nogc @property
    {
        return _ctxId;
    }

    const(Char)[] payloadText() const pure nothrow @nogc @property
    {
        return _payloadText;
    }

    private Char[] allocAndCopyAscii(const(char)[] source) pure nothrow @nogc
    in
    {
        debug assert(isASCII(source));
    }
    body
    {
        Char[] allocatorTail = _allocator.tail;

        source = removeTrailedZeros(source);
        const auto newBuf = copyUtf8to(source, allocatorTail);
        const auto len = allocatorTail.length - newBuf.length;
        _allocator.spend(len);

        Char[] result = allocatorTail[0 .. len];
        replaceNonPrintable(result);
        return result;
    }

    PayloadBuilder!Char setupPayload(const(char)[] ecu, const(char)[] appId, const(char)[] ctxId) nothrow @nogc
    {
        import std.stdio;

        enum capacity = 16 * 1024 + 1024;
        _allocator.reset(capacity);

        this._ecuId = allocAndCopyAscii(ecu);
        this._appId = allocAndCopyAscii(appId);
        this._ctxId = allocAndCopyAscii(ctxId);

        // prepare buffer for payload
        _allocator.allocAligned(0);
        _allocator.tail[$ - 1] = 0; // set emergency null terminator
        // reserve last symbol for emergency null terminator
        auto buffer = _allocator.tail[0 .. $ - 1];
        return PayloadBuilder!Char(buffer, &_payloadText);
    }

    void clear() pure nothrow @nogc
    {
        _allocator.clear();
        timestampSeconds = 0;
        timestampMicroseconds = 0;
        level = LogLevel.Info;
        type = MessageType.Log;
        messageId = 0;
        sessionId = 0;
        relativeTimestamp_10000 = 0;
        _ecuId = null;
        _appId = null;
        _ctxId = null;
        _payloadText = null;
    }
}

//! Primitive allocator for decoded messages
private struct LinearAllocator(Char) if (isSomeChar!Char)
{
    enum alignment = 16;

    private Char[] _buffer;
    private Char* _ptr;

    this(size_t capacity)
    {
        allocateNew(capacity);
    }

    ~this()
    {
        if (_buffer.ptr)
            free(_buffer.ptr);
    }

    private void allocateNew(size_t capacity) nothrow @nogc
    {
        Char* ptr = cast(Char*) malloc(capacity * Char.sizeof);

        if (ptr)
        {
            _buffer = ptr[0 .. capacity];
            _ptr = ptr;
        }
        else
        {
            _buffer = null;
            _ptr = null;
        }
    }

    //! @returns remaining capacity in bytes
    size_t rest() const pure @nogc nothrow @property
    {
        return _buffer.ptr + _buffer.length - _ptr;
    }

    void reset(size_t capacity)
    {
        if (capacity <= _buffer.length)
        {
            clear();
            return;
        }
        else
        {
            if (_buffer.ptr)
                free(_buffer.ptr);
            allocateNew(capacity);
        }
    }

    void clear() pure @nogc nothrow
    {
        _ptr = _buffer.ptr;
    }

    Char* allocAligned(size_t count = 1) pure @nogc nothrow
    {
        void* bytePtr = cast(void*) _ptr;

        Char* alignedPtr = cast(Char*)((cast(size_t) bytePtr + alignment - 1) / alignment * alignment);

        if (alignedPtr + count > _buffer.ptr + _buffer.length)
            return null;

        _ptr = alignedPtr + count;

        return alignedPtr;
    }

    Char* alloc(size_t count = 1) pure @nogc nothrow
    {
        if (_ptr + count > _buffer.ptr + _buffer.length)
            return null;

        Char* result = _ptr;
        _ptr += count;

        return result;
    }

    Char[] tail() pure @nogc nothrow @property
    {
        const size_t itemsLeft = (_buffer.ptr + _buffer.length) - _ptr;
        return (cast(Char*) _ptr)[0 .. itemsLeft];
    }

    size_t spend(size_t count) pure @nogc nothrow @property
    {
        if (_ptr + count > _buffer.ptr + _buffer.length)
            count = _buffer.ptr + _buffer.length - _ptr;

        _ptr += count;
        return count;
    }
}

private struct PayloadBuilder(Char) if (isSomeChar!Char)
{
    //private DecodedMessage!Char* _message;
    private Char[]* _payloadText; // to save result
    private Char* _bufferBegin;
    private Char[] _tail;
    private bool _isFirstArg = true;
    private enum separator = " ";

    this(Char[] bufferTail, Char[]* payloadText) pure nothrow @nogc
    {
        _bufferBegin = bufferTail.ptr;
        _tail = bufferTail;
        _payloadText = payloadText;
    }

    ~this() pure nothrow @nogc
    {
        storePayload();
    }

    void storePayload() pure nothrow @nogc
    {
        // append null terminator if possible
        if (_tail.length != 0)
        {
            _tail[0] = '\0';
        }

        *_payloadText = sliceToStore();
    }

    //! @returns current slice to be saved in _payloadText
    private Char[] sliceToStore() pure nothrow @nogc
    {
        const auto length = _tail.ptr - _bufferBegin;
        return _bufferBegin[0 .. length];
    }

    private void appendSeparatorIfNeeded() pure nothrow @nogc
    {
        if (_isFirstArg)
        {
            _isFirstArg = false;
        }
        else
        {
            _tail = copyAsMuchAsPossible(separator, _tail);
        }
    }

    void appendAscii(const(char)[] text) pure nothrow @nogc
    {
        appendSeparatorIfNeeded();
        _tail = copyAsMuchAsPossible(text, _tail);
    }

    void appendUtf8(const(char)[] utf8) pure nothrow @nogc
    {
        appendSeparatorIfNeeded();
        _tail = copyUtf8to(utf8, _tail);
    }

    void appendBool(bool value) pure nothrow @nogc
    {
        appendSeparatorIfNeeded();
        _tail = copyAsMuchAsPossible(value ? "true" : "false", _tail);
    }

    /*
    void appendInt(long value) pure nothrow @nogc
    {
        appendSeparatorIfNeeded();

        auto buf = _message._allocator.tail;
        if (buf.length == 0)
            return;

        // Convert integer to string in buffer
        bool negative = value < 0;
        ulong uval = negative ? cast(ulong)(-value) : cast(ulong) value;

        // Write digits in reverse, then flip
        Char[20] tmp;
        size_t digits = 0;

        if (uval == 0)
        {
            tmp[0] = cast(Char) '0';
            digits = 1;
        }
        else
        {
            while (uval > 0 && digits < tmp.length)
            {
                tmp[digits++] = cast(Char)('0' + (uval % 10));
                uval /= 10;
            }
        }

        size_t totalLen = digits + (negative ? 1 : 0);
        if (totalLen > buf.length)
            return;

        size_t pos = 0;
        if (negative)
            buf[pos++] = cast(Char) '-';

        // Write reversed digits
        for (size_t i = digits; i > 0; --i)
            buf[pos++] = tmp[i - 1];

        spend(totalLen);
    }

    void appendUint(ulong value) pure nothrow @nogc
    {
        appendSeparatorIfNeeded();

        auto buf = _message._allocator.tail;
        if (buf.length == 0)
            return;

        Char[20] tmp;
        size_t digits = 0;

        if (value == 0)
        {
            tmp[0] = cast(Char) '0';
            digits = 1;
        }
        else
        {
            while (value > 0 && digits < tmp.length)
            {
                tmp[digits++] = cast(Char)('0' + (value % 10));
                value /= 10;
            }
        }

        if (digits > buf.length)
            return;

        for (size_t i = digits; i > 0; --i)
            buf[digits - i] = tmp[i - 1];

        spend(digits);
    }
*/
    void append(T)(T value) pure nothrow @nogc if (isIntegral!T)
    {
        import std.conv : toChars;

        appendSeparatorIfNeeded();
        auto resultRange = toChars(value);
        //_tail = copyAsMuchAsPossible(resultRange, _tail);
        _tail = copy(resultRange, _tail);
    }

    void append(T)(T value) nothrow @nogc if (isFloatingPoint!T)
    {
        import core.stdc.stdio : snprintf;

        appendSeparatorIfNeeded();
        char[64] numBuf;
        int written = snprintf(numBuf.ptr, numBuf.length, "%f", cast(double) value);
        if (written > 0 && written < numBuf.length)
        {
            _tail = copyAsMuchAsPossible(numBuf[0 .. written], _tail);
        }
    }

    void appendHex(const(char)[] hex) pure nothrow @nogc
    {
        appendSeparatorIfNeeded();

        enum Char delimiter = ' ';
        enum groupSize = 4; // bytes per group

        static Char toHexChar(uint nibble) pure nothrow @nogc
        {
            return cast(Char)(nibble < 10 ? '0' + nibble : 'A' + nibble - 10);
        }

        size_t posInGroup = 0;

        foreach (c; hex)
        {
            // Need at least 2 chars for the two hex digits
            if (_tail.length < 2)
                break;

            const uint b = cast(ubyte) c;
            _tail[0] = toHexChar(b >> 4); // high nibble first
            _tail[1] = toHexChar(b & 0x0F); // low nibble second
            _tail = _tail[2 .. $];

            if (++posInGroup == groupSize)
            {
                posInGroup = 0;
                if (_tail.length == 0)
                    break;
                _tail[0] = delimiter;
                _tail = _tail[1 .. $];
            }
        }

        // Write trailing delimiter after last (possibly partial) group
        if (posInGroup > 0 && _tail.length > 0)
        {
            _tail[0] = delimiter;
            _tail = _tail[1 .. $];
        }
    }
}

//! @brief copy as mach symbols as possible from Source range to Target range
//! @returns least size of Target range
private Target[] copyAsMuchAsPossible(Source, Target)(const(Source)[] src, Target[] dst) pure nothrow @nogc
{
    const auto length = min(src.length, dst.length);

    static if (is(Source == Target))
    {
        import core.stdc.string : memmove;

        memmove(dst.ptr, src.ptr, length * Source.sizeof);
    }
    else
    {
        for (size_t i = 0; i < src.length; ++i)
        {
            dst[i] = src[i];
        }
    }

    return dst[length .. $];
}

private const(Char)[] removeTrailedZeros(Char)(const(Char)[] src) pure nothrow @nogc
{
    size_t zeroes = 0;
    foreach_reverse (c; src)
    {
        if (c == 0)
            ++zeroes;
        else
            break;
    }

    return src[0 .. src.length - zeroes];
}

// @todo: it is naive implementation, we can do it better for Utf
private void replaceNonPrintable(Char)(Char[] str, Char replacement = '?') pure nothrow @nogc
in
{
    debug assert(replacement.isASCII);
    debug assert(replacement.isPrintable);
}
body
{
    static if (is(Char == char))
    {
        foreach (ref c; str)
        {
            if (!isPrintable(c))
                c = replacement;
        }
    }
    else
    {
        import std.utf : byCodeUnit;

        foreach (ref c; str.byCodeUnit)
        {
            if (isASCII(c) && !isPrintable(c))
                c = replacement;
        }
    }
}

//! @brief copy as mach symbols as possible from Source range to Target range
//! @returns least size of Target range
private Char[] copyUtf8to(Char)(const(char)[] utf8, Char[] dst) pure nothrow @nogc
{
    static if (is(Char == char))
    {
        return copyAsMuchAsPossible(utf8, dst);
    }
    else
    {
        // Decode UTF-8 into dchar codepoints, then write as Char (wchar/dchar)
        size_t i = 0;
        while (i < utf8.length && dst.length > 0)
        {
            dchar cp;
            ubyte b0 = cast(ubyte) utf8[i];

            if (b0 < 0x80)
            {
                cp = b0;
                i += 1;
            }
            else if ((b0 & 0xE0) == 0xC0 && i + 1 < utf8.length)
            {
                cp = ((b0 & 0x1F) << 6) | (cast(ubyte) utf8[i + 1] & 0x3F);
                i += 2;
            }
            else if ((b0 & 0xF0) == 0xE0 && i + 2 < utf8.length)
            {
                cp = ((b0 & 0x0F) << 12) |
                    ((cast(ubyte) utf8[i + 1] & 0x3F) << 6) |
                    (
                        cast(ubyte) utf8[i + 2] & 0x3F);
                i += 3;
            }
            else if ((b0 & 0xF8) == 0xF0 && i + 3 < utf8.length)
            {
                cp = ((b0 & 0x07) << 18) |
                    (
                        (cast(ubyte) utf8[i + 1] & 0x3F) << 12) |
                    (
                        (cast(ubyte) utf8[i + 2] & 0x3F) << 6) |
                    (cast(ubyte) utf8[i + 3] & 0x3F);
                i += 4;
            }
            else
            {
                // Invalid UTF-8 byte — replace with '?' and skip
                cp = '?';
                i += 1;
            }

            static if (is(Char == wchar))
            {
                if (cp <= 0xFFFF)
                {
                    dst[0] = cast(wchar) cp;
                    dst = dst[1 .. $];
                }
                else if (cp <= 0x10FFFF)
                {
                    // Surrogate pair
                    if (dst.length < 2)
                        break;
                    dst[0] = cast(wchar)(((cp - 0x10000) >> 10) + 0xD800);
                    dst[1] = cast(wchar)(((cp - 0x10000) & 0x3FF) + 0xDC00);
                    dst = dst[2 .. $];
                }
            }
            else static if (is(Char == dchar))
            {
                dst[0] = cast(dchar) cp;
                dst = dst[1 .. $];
            }
        }

        return dst;
    }
}

private bool isASCII(const(char)[] source) pure nothrow @nogc
{
    foreach (c; source)
    {
        if (!c.isASCII)
            return false;
    }
    return true;
}

// ─── LinearAllocator Tests ──────────────────────────────────────────────────────

@("LinearAllocator: construction and rest()")
unittest
{
    auto buf = LinearAllocator!char(1024);
    assert(buf.rest() == 1024);
}

@("LinearAllocator: allocBytes reduces rest()")
unittest
{
    auto buf = LinearAllocator!char(1024);
    auto p = buf.alloc(100);
    assert(p !is null);
    assert(buf.rest() == 924);
}

@("LinearAllocator: allocBytes returns null when full")
unittest
{
    auto buf = LinearAllocator!char(64);
    auto p1 = buf.alloc(64);
    assert(p1 !is null);
    assert(buf.rest() == 0);
    auto p2 = buf.alloc(1);
    assert(p2 is null);
}

@("LinearAllocator: clear resets pointer")
unittest
{
    auto buf = LinearAllocator!char(256);
    buf.alloc(128);
    assert(buf.rest() == 128);
    buf.clear();
    assert(buf.rest() == 256);
}

@("LinearAllocator: reset reallocates")
unittest
{
    auto buf = LinearAllocator!char(100);
    assert(buf.rest() == 100);
    buf.reset(200);
    assert(buf.rest() == 200);
}

@("LinearAllocator: tail returns remaining space as typed array")
unittest
{
    auto buf = LinearAllocator!char(128);
    auto t = buf.tail;
    assert(t.length == 128);

    buf.alloc(10);
    auto t2 = buf.tail;
    assert(t2.length == 118);
}

@("LinearAllocator: allocBytesAligned aligns pointer")
unittest
{
    auto buf = LinearAllocator!char(1024);
    buf.alloc(1);

    auto aligned = buf.allocAligned(16);
    assert(aligned !is null);
    assert(cast(size_t) aligned % LinearAllocator!char.alignment == 0);
}

@("LinearAllocator: multiple alloc/clear cycles")
unittest
{
    auto buf = LinearAllocator!char(128);

    // First cycle
    buf.alloc(64);
    assert(buf.rest() == 64);
    buf.clear();
    assert(buf.rest() == 128);

    // Second cycle
    buf.alloc(32);
    assert(buf.rest() == 96);
    buf.clear();
    assert(buf.rest() == 128);
}

// ─── DecodedMessage Tests ──────────────────────────────────────────────────────

@("DecodedMessage: allocAndCopy basic string")
unittest
{
    import std.stdio;

    writeln("allocAndCopy");
    DecodedMessage!char msg;
    msg._allocator = LinearAllocator!char(1024);

    auto result = msg.allocAndCopyAscii("HELLO");
    assert(result == "HELLO");
}

@("DecodedMessage: allocAndCopy cuts trailing zeros")
unittest
{
    DecodedMessage!char msg;
    msg._allocator = LinearAllocator!char(1024);

    auto result = msg.allocAndCopyAscii("ABCD\0\0");
    assert(result == "ABCD");
}

@("DecodedMessage: allocAndCopy replaces non-printable")
unittest
{
    DecodedMessage!char msg;
    msg._allocator = LinearAllocator!char(1024);

    char[4] input = ['A', 1, 'B', 2]; // 1 and 2 are non-printable
    auto result = msg.allocAndCopyAscii(input[]);

    assert(result == "A?B?");
}

@("DecodedMessage: allocAndCopy replaces non-printable wchar")
unittest
{
    DecodedMessage!wchar msg;
    msg._allocator = LinearAllocator!wchar(1024);

    char[4] input = ['A', 1, 'B', 2]; // 1 and 2 are non-printable
    auto result = msg.allocAndCopyAscii(input[]);

    assert(result == "A?B?"w);
}

@("DecodedMessage: allocAndCopy empty string")
unittest
{
    DecodedMessage!char msg;
    msg._allocator = LinearAllocator!char(1024);

    auto result = msg.allocAndCopyAscii("");
    assert(result.length == 0);
}

@("DecodedMessage: allocAndCopy null-only string")
unittest
{
    DecodedMessage!char msg;
    msg._allocator = LinearAllocator!char(1024);

    char[4] input = [0, 0, 0, 0];
    auto result = msg.allocAndCopyAscii(input[]);
    assert(result.length == 0);
}

@("DecodedMessage: allocAndCopy does not overflow buffer")
unittest
{
    DecodedMessage!char msg;
    msg._allocator = LinearAllocator!char(4); // Very small buffer

    auto result = msg.allocAndCopyAscii("ABCDEFGH");
    assert(result.length <= 4);
}

@("DecodedMessage: setupPayload sets ecu/appId/ctxId")
unittest
{
    DecodedMessage!char msg;

    auto builder = msg.setupPayload("ECU1", "APP1", "CTX1");
    assert(msg.ecuId == "ECU1");
    assert(msg.appId == "APP1");
    assert(msg.ctxId == "CTX1");
}

@("DecodedMessage: setupPayload cleans non-printable in IDs")
unittest
{
    DecodedMessage!char msg;

    char[4] ecuId = ['E', 'C', 0, 0];
    char[4] appId = ['A', 1, 'P', 0];
    char[4] ctxId = ['C', 'T', 'X', '1'];

    auto builder = msg.setupPayload(ecuId[], appId[], ctxId[]);
    assert(msg.ecuId == "EC");
    assert(msg.appId == "A?P");
    assert(msg.ctxId == "CTX1");
}

@("DecodedMessage: clear resets all fields")
unittest
{
    DecodedMessage!char msg;
    msg._allocator = LinearAllocator!char(256);

    msg.timestampSeconds = 100;
    msg.timestampMicroseconds = 200;
    msg.level = LogLevel.Fatal;
    msg.type = MessageType.Control;
    msg.messageId = 42;
    msg.sessionId = 0xBEEF;
    msg.relativeTimestamp_10000 = 999;

    msg.clear();

    assert(msg.timestampSeconds == 0);
    assert(msg.timestampMicroseconds == 0);
    assert(msg.level == LogLevel.Info);
    assert(msg.type == MessageType.Log);
    assert(msg.messageId == 0);
    assert(msg.sessionId == 0);
    assert(msg.relativeTimestamp_10000 == 0);
    assert(msg._ecuId is null);
    assert(msg._appId is null);
    assert(msg._ctxId is null);
    assert(msg._payloadText is null);
}

@("DecodedMessage: properties return correct values")
unittest
{
    DecodedMessage!char msg;
    msg._allocator = LinearAllocator!char(256);

    msg._ecuId = "ECU".dup;
    msg._appId = "APP".dup;
    msg._ctxId = "CTX".dup;
    msg._payloadText = "payload".dup;

    assert(msg.ecuId == "ECU");
    assert(msg.appId == "APP");
    assert(msg.ctxId == "CTX");
    assert(msg.payloadText == "payload");
}

// ─── PayloadBuilder Tests ──────────────────────────────────────────────────────

@("PayloadBuilder: appendAscii single string")
unittest
{
    DecodedMessage!char msg;
    auto builder = msg.setupPayload("ECU1", "APP1", "CTX1");
    builder.appendAscii("hello");
    builder.storePayload();

    assert(msg.payloadText == "hello");
}

@("PayloadBuilder: appendAscii multiple strings with separators")
unittest
{
    DecodedMessage!char msg;
    auto builder = msg.setupPayload("E", "A", "C");
    builder.appendAscii("foo");
    builder.appendAscii("bar");
    builder.appendAscii("baz");
    builder.storePayload();

    assert(msg.payloadText == "foo bar baz");
}

@("PayloadBuilder: appendBool true and false")
unittest
{
    DecodedMessage!char msg;
    auto builder = msg.setupPayload("E", "A", "C");
    builder.appendBool(true);
    builder.appendBool(false);
    builder.storePayload();

    assert(msg.payloadText == "true false");
}

@("PayloadBuilder: appendUtf8 ASCII text")
unittest
{
    DecodedMessage!char msg;
    auto builder = msg.setupPayload("E", "A", "C");
    builder.appendUtf8("hello utf8");
    builder.appendUtf8("привет");
    builder.storePayload();

    assert(msg.payloadText == "hello utf8 привет");
}

@("PayloadBuilder: appendUtf8 wide string")
unittest
{
    DecodedMessage!wchar msg;
    auto builder = msg.setupPayload("E", "A", "C");
    builder.appendUtf8("привет Андрей");
    builder.storePayload();

    assert(msg.payloadText == "привет Андрей"w);
}

@("PayloadBuilder: appendUtf8 dchar string")
unittest
{
    DecodedMessage!dchar msg;
    auto builder = msg.setupPayload("E", "A", "C");
    builder.appendUtf8("привет Андрей");
    builder.storePayload();

    assert(msg.payloadText == "привет Андрей"d);
}

@("PayloadBuilder: appendInt positive")
unittest
{
    DecodedMessage!char msg;
    auto builder = msg.setupPayload("E", "A", "C");
    builder.append(12_345);
    builder.storePayload();

    assert(msg.payloadText == "12345");
}

@("PayloadBuilder: appendInt negative")
unittest
{
    DecodedMessage!char msg;
    auto builder = msg.setupPayload("E", "A", "C");
    builder.append(-42);
    builder.storePayload();

    assert(msg.payloadText == "-42");
}

@("PayloadBuilder: appendInt zero")
unittest
{
    DecodedMessage!char msg;
    auto builder = msg.setupPayload("E", "A", "C");
    builder.append(cast(int) 0);
    builder.storePayload();

    assert(msg.payloadText == "0");
}

@("PayloadBuilder: appendUint")
unittest
{
    DecodedMessage!char msg;
    auto builder = msg.setupPayload("E", "A", "C");
    builder.append(99_999);
    builder.storePayload();

    assert(msg.payloadText == "99999");
}

@("PayloadBuilder: appendUint zero")
unittest
{
    DecodedMessage!char msg;
    auto builder = msg.setupPayload("E", "A", "C");
    builder.append(cast(uint) 0);
    builder.storePayload();

    assert(msg.payloadText == "0");
}

@("PayloadBuilder: append float")
unittest
{
    DecodedMessage!char msg;
    auto builder = msg.setupPayload("E", "A", "C");
    builder.append(cast(float) 0.1f);
    builder.storePayload();

    assert(msg.payloadText == "0.100000");
}

@("PayloadBuilder: append double")
unittest
{
    DecodedMessage!char msg;
    auto builder = msg.setupPayload("E", "A", "C");
    builder.append(cast(double) 0.1);
    builder.storePayload();

    assert(msg.payloadText == "0.100000");
}

@("PayloadBuilder: append float for wchar")
unittest
{
    DecodedMessage!wchar msg;
    auto builder = msg.setupPayload("E", "A", "C");
    builder.append(cast(float) 0.1f);
    builder.storePayload();

    assert(msg.payloadText == "0.100000"w);
}

@("PayloadBuilder: mixed types with separators")
unittest
{
    DecodedMessage!char msg;
    auto builder = msg.setupPayload("E", "A", "C");
    builder.appendAscii("count:");
    builder.append(42);
    builder.appendBool(true);
    builder.storePayload();

    assert(msg.payloadText == "count: 42 true");
}

@("PayloadBuilder: empty payload")
unittest
{
    DecodedMessage!char msg;
    auto builder = msg.setupPayload("E", "A", "C");
    builder.storePayload();

    assert(msg.payloadText.length == 0);
}

@("PayloadBuilder: appendAscii empty string")
unittest
{
    DecodedMessage!char msg;
    auto builder = msg.setupPayload("E", "A", "C");
    builder.appendAscii("");
    builder.storePayload();

    // Empty string still counts as first arg (separator not added)
    assert(msg.payloadText.length == 0);
}

// ─── Integration Tests ─────────────────────────────────────────────────────────

@("DecodedMessage: full workflow - setup, build, read, clear")
unittest
{
    DecodedMessage!char msg;

    msg.timestampSeconds = 1000;
    msg.level = LogLevel.Error;

    {
        auto builder = msg.setupPayload("ECU1", "MYAP", "CTX1");
        builder.appendAscii("Engine started");
        builder.append(42);
    }

    assert(msg.ecuId == "ECU1");
    assert(msg.appId == "MYAP");
    assert(msg.ctxId == "CTX1");
    assert(msg.payloadText == "Engine started 42");
    assert(msg.level == LogLevel.Error);

    msg.clear();
    assert(msg.payloadText is null);
    assert(msg.level == LogLevel.Info);
}

@("DecodedMessage: multiple setupPayload cycles reuse buffer")
unittest
{
    DecodedMessage!char msg;

    // First cycle
    {
        auto builder = msg.setupPayload("ECU1", "APP1", "CTX1");
        builder.appendAscii("first message");
    }
    assert(msg.payloadText == "first message");

    // Second cycle — reset
    {
        auto builder = msg.setupPayload("ECU2", "APP2", "CTX2");
        builder.appendAscii("second message");
    }
    assert(msg.ecuId == "ECU2");
    assert(msg.appId == "APP2");
    assert(msg.payloadText == "second message");
}

@("DecodedMessage: convertAndClean preserves printable ASCII range")
unittest
{
    DecodedMessage!char msg;
    msg._allocator = LinearAllocator!char(1024);

    // All printable ASCII chars (space to tilde)
    string printables;
    foreach (c; 32 .. 127)
        printables ~= cast(char) c;

    auto result = msg.allocAndCopyAscii(printables);
    assert(result == printables);
}

@("PayloadBuilder: large payload")
unittest
{
    DecodedMessage!char msg;
    auto builder = msg.setupPayload("E", "A", "C");

    // Append many items
    foreach (i; 0 .. 100)
    {
        builder.append(i);
    }
    builder.storePayload();

    // Just verify it didn't crash and has content
    assert(msg.payloadText.length > 0);
}

@("LinearAllocator: reset reuses buffer when capacity fits")
unittest
{
    // reset(<=current size) → clear only, no realloc
    auto buf = LinearAllocator!char(200);
    buf.alloc(50);
    assert(buf.rest() == 150);
    buf.reset(100); // 100 <= 200 → clear, full 200 available
    assert(buf.rest() == 200);
}

@("LinearAllocator: reset with same capacity clears")
unittest
{
    auto buf = LinearAllocator!char(128);
    buf.alloc(64);
    buf.reset(128);
    assert(buf.rest() == 128);
}

@("LinearAllocator: spend advances pointer and returns count")
unittest
{
    auto buf = LinearAllocator!char(100);
    auto spent = buf.spend(10);
    assert(spent == 10);
    assert(buf.rest() == 90);
}

@("LinearAllocator: spend clamps to remaining capacity")
unittest
{
    auto buf = LinearAllocator!char(32);
    auto spent = buf.spend(100); // more than available
    assert(spent == 32);
    assert(buf.rest() == 0);
}

// DecodedMessage.allocAndCopy additional tests
@("DecodedMessage: allocAndCopy dchar")
unittest
{
    DecodedMessage!dchar msg;
    msg._allocator = LinearAllocator!dchar(1024);

    auto result = msg.allocAndCopyAscii("HELLO");
    assert(result == "HELLO"d);
}

@("DecodedMessage: allocAndCopy embedded nulls")
unittest
{
    DecodedMessage!char msg;
    msg._allocator = LinearAllocator!char(1024);

    char[6] input = ['A', 'B', '\0', 'C', 'D', '\0'];
    auto result = msg.allocAndCopyAscii(input[]);
    assert(result == "AB?CD"); // Embedded nulls should be replaced
}

@("DecodedMessage: allocAndCopy UTF-8 decoded to wchar")
unittest
{
    // For char Char type, multi-byte UTF-8 bytes >127 are treated as non-printable
    // by std.ascii.isPrintable and replaced with '?'.
    // For wchar/dchar, copyUtf8to properly decodes them as Unicode codepoints.
    DecodedMessage!wchar msgW;
    msgW._allocator = LinearAllocator!wchar(1024);
    auto resultW = msgW.allocAndCopyAscii("hello");
    assert(resultW == "hello"w);
}

// PayloadBuilder additional tests
@("PayloadBuilder: appendHex single full group")
unittest
{
    // 4 bytes = one group → "DEADBEEF " (trailing space after each group)
    DecodedMessage!char msg;
    auto builder = msg.setupPayload("E", "A", "C");
    char[4] data = [
        cast(char) 0xDE, cast(char) 0xAD, cast(char) 0xBE, cast(char) 0xEF
    ];
    builder.appendHex(data[]);
    builder.storePayload();

    assert(msg.payloadText == "DEADBEEF ");
}

@("PayloadBuilder: appendHex two groups")
unittest
{
    // 8 bytes = two groups → "DEADBEEF 01020304 "
    DecodedMessage!char msg;
    auto builder = msg.setupPayload("E", "A", "C");
    char[8] data = [
        cast(char) 0xDE, cast(char) 0xAD, cast(char) 0xBE, cast(char) 0xEF,
        1, 2, 3, 4
    ];
    builder.appendHex(data[]);
    builder.storePayload();

    assert(msg.payloadText == "DEADBEEF 01020304 ");
}

@("PayloadBuilder: appendHex partial group")
unittest
{
    // 3 bytes = partial group → "010203 "
    DecodedMessage!char msg;
    auto builder = msg.setupPayload("E", "A", "C");
    char[3] data = [1, 2, 3];
    builder.appendHex(data[]);
    builder.storePayload();

    assert(msg.payloadText == "010203 ");
}

@("PayloadBuilder: appendHex empty")
unittest
{
    DecodedMessage!char msg;
    auto builder = msg.setupPayload("E", "A", "C");
    builder.appendHex([]);
    builder.storePayload();

    assert(msg.payloadText == "");
}

@("PayloadBuilder: destructor auto-store")
unittest
{
    DecodedMessage!char msg;
    msg._allocator = LinearAllocator!char(1024);

    {
        auto builder = msg.setupPayload("E", "A", "C");
        builder.appendAscii("auto stored");
        // No explicit storePayload() call
    } // builder goes out of scope, destructor should call storePayload

    assert(msg.payloadText == "auto stored");
}

@("PayloadBuilder: appendUtf8 surrogate pairs in wchar")
unittest
{
    DecodedMessage!wchar msg;
    // U+1F600 😀 UTF-8: F0 9F 98 80  →  UTF-16 surrogate pair: D83D DE00
    auto builder = msg.setupPayload("E", "A", "C");
    builder.appendUtf8("\U0001F600");
    builder.storePayload();

    assert(msg.payloadText == "\U0001F600"w);
}

// Helper function tests
@("removeTrailedZeros: basic functionality")
unittest
{
    assert(removeTrailedZeros("ABCD\0\0") == "ABCD");
    assert(removeTrailedZeros("ABCD") == "ABCD");
    assert(removeTrailedZeros("\0\0\0") == "");
    assert(removeTrailedZeros("") == "");
    assert(removeTrailedZeros("A\0B\0\0") == "A\0B"); // Only trailing zeros
}

@("replaceNonPrintable: char array")
unittest
{
    char[] testStr = ['A', 1, 'B', 2, '\n', 'C'];
    replaceNonPrintable(testStr);
    assert(testStr == ['A', '?', 'B', '?', '?', 'C']);

    char[] allPrintable = ['a', 'b', 'c'];
    replaceNonPrintable(allPrintable);
    assert(allPrintable == ['a', 'b', 'c']);
}

@("replaceNonPrintable: wchar array")
unittest
{
    wchar[] testStr = ['A', 1, 'B', 2, '\n', 'C'];
    replaceNonPrintable(testStr);
    assert(testStr == "A?B??"w ~ "C"w);

    wchar[] utf16NonPrintable = [cast(wchar) 0x0001, cast(wchar) 0x0002];
    replaceNonPrintable(utf16NonPrintable);
    assert(utf16NonPrintable == "??"w);
}

@("copyUtf8to: char target")
unittest
{
    char[10] buffer;
    auto remaining = copyUtf8to("hello", buffer[]);
    assert(buffer[0 .. 5] == "hello");
    assert(remaining.length == 5);

    char[5] smallBuffer;
    remaining = copyUtf8to("long string", smallBuffer[]);
    assert(smallBuffer[] == "long ");
    assert(remaining.length == 0);
}

@("copyUtf8to: wchar target")
unittest
{
    wchar[10] buffer;
    auto remaining = copyUtf8to("привет", buffer[]);
    assert(buffer[0 .. 6] == "привет"w);
    assert(remaining.length == 4);

    wchar[3] smallBuffer; // "при" is 3 wchar
    remaining = copyUtf8to("привет", smallBuffer[]);
    assert(smallBuffer[] == "при"w);
    assert(remaining.length == 0); // Buffer full
}

@("copyUtf8to: dchar target")
unittest
{
    dchar[10] buffer;
    auto remaining = copyUtf8to("привет", buffer[]);
    assert(buffer[0 .. 6] == "привет"d);
    assert(remaining.length == 4);

    dchar[3] smallBuffer; // "при" is 3 dchar
    remaining = copyUtf8to("привет", smallBuffer[]);
    assert(smallBuffer[] == "при"d);
    assert(remaining.length == 0); // Buffer full
}

/*@("copyUtf8to: invalid utf8 — char target")
unittest
{
    char[10] buffer;
    auto remaining = copyUtf8to("abc\x80def", buffer[]);
    assert(buffer[0 .. 7] == "abc?def");
    assert(remaining.length == 3);
}*/

@("copyUtf8to: invalid utf8 — wchar target")
unittest
{
    wchar[10] bufferW;
    auto remaining = copyUtf8to("abc\x80def", bufferW[]);
    assert(bufferW[0 .. 7] == "abc?def"w);
    assert(remaining.length == 3);
}

@("copyUtf8to: surrogate pairs to wchar")
unittest
{
    wchar[5] buffer; // Need 2 wchar for the emoji
    auto remaining = copyUtf8to("\U0001F600", buffer[]);
    assert(buffer[0 .. 2] == "\U0001F600"w);
    assert(remaining.length == 3);

    wchar[1] smallBuffer; // Not enough space for surrogate pair
    remaining = copyUtf8to("\U0001F600", smallBuffer[]);
    assert(remaining.length == 1); // The buffer is still 1, but nothing was written
}
