module log_core.log_message;

import std.traits;
import core.stdc.stdlib : malloc, free;
import std.ascii : isPrintable, isASCII;
import std.algorithm : copy, min;
import log_core.log_level : LogLevel;

//! What the time of a record means.
enum TimeKind : ubyte
{
    None, // the record has no time
    Absolute, // wall-clock time, nanoseconds since the Unix epoch (UTC)
    AbsoluteNoYear, // wall-clock time whose source has no year (logcat, syslog)
    SinceBoot, // nanoseconds since the device started (dmesg)
}

//! A log record of any format, decoded for display and filtering.
//!
//! The core (time, level, payload) is common to all formats. Everything else
//! is a format field: its meaning, title and kind come from the column schema
//! of the format, the message only stores values by field index. A field holds
//! a text or a number, the schema says which one is used.
//!
//! Texts live in one buffer reused by every decode, so decoding allocates
//! nothing once the buffer exists. They stay valid until the next decode.
//! A decode is: beginRecord(), setText()/setNumber() for the fields, then
//! payloadBuilder() last: the payload takes the rest of the buffer.
struct LogMessage(Char) if (isSomeChar!Char)
{
    @disable this(ref LogMessage);
    @disable void opAssign(ref LogMessage);

    //! Most fields a format can have
    enum maxFields = 8;

    //! Characters for the fields and the payload of one record
    enum capacity = 16 * 1024 + 1024;

    private LinearAllocator!Char _allocator;

    long timeNs; // see timeKind
    TimeKind timeKind;
    LogLevel level;

    private Char[][maxFields] _texts;
    private long[maxFields] _numbers;
    private Char[] _payloadText;
    debug private bool _payloadStarted;

    const(Char)[] payloadText() const pure nothrow @nogc @property
    {
        return _payloadText;
    }

    const(Char)[] text(size_t field) const pure nothrow @nogc
    {
        return _texts[field];
    }

    long number(size_t field) const pure nothrow @nogc
    {
        return _numbers[field];
    }

    void setNumber(size_t field, long value) pure nothrow @nogc
    {
        _numbers[field] = value;
    }

    //! Starts decoding a new record: clears the previous one
    void beginRecord() nothrow @nogc
    {
        clear();
        _allocator.reset(capacity);
    }

    //! Copies a UTF-8 text into the field, non-printable characters become '?'.
    //! Must be called before payloadBuilder().
    void setText(size_t field, const(char)[] utf8) pure nothrow @nogc
    {
        debug assert(!_payloadStarted, "fields must be set before the payload");

        Char[] allocatorTail = _allocator.tail;
        const auto newBuf = copyUtf8to(utf8, allocatorTail);
        const auto len = allocatorTail.length - newBuf.length;
        _allocator.spend(len);

        Char[] result = allocatorTail[0 .. len];
        replaceNonPrintable(result);
        _texts[field] = result;
    }

    //! The payload takes the rest of the buffer: no setText() after this
    PayloadBuilder!Char payloadBuilder() nothrow @nogc
    {
        debug _payloadStarted = true;

        _allocator.allocAligned(0);
        if (_allocator.tail.length == 0)
            return PayloadBuilder!Char(_allocator.tail, &_payloadText);

        _allocator.tail[$ - 1] = 0; // set emergency null terminator
        // reserve last symbol for emergency null terminator
        auto buffer = _allocator.tail[0 .. $ - 1];
        return PayloadBuilder!Char(buffer, &_payloadText);
    }

    void clear() pure nothrow @nogc
    {
        _allocator.clear();
        timeNs = 0;
        timeKind = TimeKind.None;
        level = LogLevel.None;
        _texts[] = null;
        _numbers[] = 0;
        _payloadText = null;
        debug _payloadStarted = false;
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
    //private LogMessage!Char* _message;
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

// ─── LogMessage Tests ──────────────────────────────────────────────────────

@("LogMessage: setText copies a field")
unittest
{
    LogMessage!char msg;
    msg.beginRecord();
    msg.setText(0, "HELLO");
    msg.setText(3, "WORLD");
    assert(msg.text(0) == "HELLO");
    assert(msg.text(3) == "WORLD");
    assert(msg.text(1) is null, "unset fields are empty");
}

@("LogMessage: setText replaces non-printable")
unittest
{
    LogMessage!wchar msg;
    msg.beginRecord();
    char[4] input = ['A', 1, 'B', 2]; // 1 and 2 are non-printable
    msg.setText(0, input[]);
    assert(msg.text(0) == "A?B?"w);
}

@("LogMessage: setText decodes UTF-8")
unittest
{
    LogMessage!wchar msg;
    msg.beginRecord();
    msg.setText(0, "Grüße");
    assert(msg.text(0) == "Grüße"w);
}

@("LogMessage: fields and payload share the buffer without overlap")
unittest
{
    LogMessage!char msg;
    msg.beginRecord();
    msg.setText(0, "ECU1");
    msg.setText(1, "APP1");
    msg.setNumber(2, -42);
    {
        auto builder = msg.payloadBuilder();
        builder.appendAscii("payload");
    }
    assert(msg.text(0) == "ECU1");
    assert(msg.text(1) == "APP1");
    assert(msg.number(2) == -42);
    assert(msg.payloadText == "payload");
}

@("LogMessage: clear resets all fields")
unittest
{
    LogMessage!char msg;
    msg.beginRecord();
    msg.timeNs = 100;
    msg.timeKind = TimeKind.Absolute;
    msg.level = LogLevel.Fatal;
    msg.setText(0, "ECU");
    msg.setNumber(1, 42);
    {
        auto builder = msg.payloadBuilder();
        builder.appendAscii("x");
    }

    msg.clear();

    assert(msg.timeNs == 0);
    assert(msg.timeKind == TimeKind.None);
    assert(msg.level == LogLevel.None);
    assert(msg.text(0) is null);
    assert(msg.number(1) == 0);
    assert(msg.payloadText is null);
}

// ─── PayloadBuilder Tests ──────────────────────────────────────────────────────

@("PayloadBuilder: appendAscii single string")
unittest
{
    LogMessage!char msg;
    msg.beginRecord();
    auto builder = msg.payloadBuilder();
    builder.appendAscii("hello");
    builder.storePayload();

    assert(msg.payloadText == "hello");
}

@("PayloadBuilder: appendAscii multiple strings with separators")
unittest
{
    LogMessage!char msg;
    msg.beginRecord();
    auto builder = msg.payloadBuilder();
    builder.appendAscii("foo");
    builder.appendAscii("bar");
    builder.appendAscii("baz");
    builder.storePayload();

    assert(msg.payloadText == "foo bar baz");
}

@("PayloadBuilder: appendBool true and false")
unittest
{
    LogMessage!char msg;
    msg.beginRecord();
    auto builder = msg.payloadBuilder();
    builder.appendBool(true);
    builder.appendBool(false);
    builder.storePayload();

    assert(msg.payloadText == "true false");
}

@("PayloadBuilder: appendUtf8 ASCII text")
unittest
{
    LogMessage!char msg;
    msg.beginRecord();
    auto builder = msg.payloadBuilder();
    builder.appendUtf8("hello utf8");
    builder.appendUtf8("привет");
    builder.storePayload();

    assert(msg.payloadText == "hello utf8 привет");
}

@("PayloadBuilder: appendUtf8 wide string")
unittest
{
    LogMessage!wchar msg;
    msg.beginRecord();
    auto builder = msg.payloadBuilder();
    builder.appendUtf8("привет Андрей");
    builder.storePayload();

    assert(msg.payloadText == "привет Андрей"w);
}

@("PayloadBuilder: appendUtf8 dchar string")
unittest
{
    LogMessage!dchar msg;
    msg.beginRecord();
    auto builder = msg.payloadBuilder();
    builder.appendUtf8("привет Андрей");
    builder.storePayload();

    assert(msg.payloadText == "привет Андрей"d);
}

@("PayloadBuilder: appendInt positive")
unittest
{
    LogMessage!char msg;
    msg.beginRecord();
    auto builder = msg.payloadBuilder();
    builder.append(12_345);
    builder.storePayload();

    assert(msg.payloadText == "12345");
}

@("PayloadBuilder: appendInt negative")
unittest
{
    LogMessage!char msg;
    msg.beginRecord();
    auto builder = msg.payloadBuilder();
    builder.append(-42);
    builder.storePayload();

    assert(msg.payloadText == "-42");
}

@("PayloadBuilder: appendInt zero")
unittest
{
    LogMessage!char msg;
    msg.beginRecord();
    auto builder = msg.payloadBuilder();
    builder.append(cast(int) 0);
    builder.storePayload();

    assert(msg.payloadText == "0");
}

@("PayloadBuilder: appendUint")
unittest
{
    LogMessage!char msg;
    msg.beginRecord();
    auto builder = msg.payloadBuilder();
    builder.append(99_999);
    builder.storePayload();

    assert(msg.payloadText == "99999");
}

@("PayloadBuilder: appendUint zero")
unittest
{
    LogMessage!char msg;
    msg.beginRecord();
    auto builder = msg.payloadBuilder();
    builder.append(cast(uint) 0);
    builder.storePayload();

    assert(msg.payloadText == "0");
}

@("PayloadBuilder: append float")
unittest
{
    LogMessage!char msg;
    msg.beginRecord();
    auto builder = msg.payloadBuilder();
    builder.append(cast(float) 0.1f);
    builder.storePayload();

    assert(msg.payloadText == "0.100000");
}

@("PayloadBuilder: append double")
unittest
{
    LogMessage!char msg;
    msg.beginRecord();
    auto builder = msg.payloadBuilder();
    builder.append(cast(double) 0.1);
    builder.storePayload();

    assert(msg.payloadText == "0.100000");
}

@("PayloadBuilder: append float for wchar")
unittest
{
    LogMessage!wchar msg;
    msg.beginRecord();
    auto builder = msg.payloadBuilder();
    builder.append(cast(float) 0.1f);
    builder.storePayload();

    assert(msg.payloadText == "0.100000"w);
}

@("PayloadBuilder: mixed types with separators")
unittest
{
    LogMessage!char msg;
    msg.beginRecord();
    auto builder = msg.payloadBuilder();
    builder.appendAscii("count:");
    builder.append(42);
    builder.appendBool(true);
    builder.storePayload();

    assert(msg.payloadText == "count: 42 true");
}

@("PayloadBuilder: empty payload")
unittest
{
    LogMessage!char msg;
    msg.beginRecord();
    auto builder = msg.payloadBuilder();
    builder.storePayload();

    assert(msg.payloadText.length == 0);
}

@("PayloadBuilder: appendAscii empty string")
unittest
{
    LogMessage!char msg;
    msg.beginRecord();
    auto builder = msg.payloadBuilder();
    builder.appendAscii("");
    builder.storePayload();

    // Empty string still counts as first arg (separator not added)
    assert(msg.payloadText.length == 0);
}

// ─── Integration Tests ─────────────────────────────────────────────────────────

@("LogMessage: beginRecord clears the previous record and reuses the buffer")
unittest
{
    LogMessage!char msg;

    msg.beginRecord();
    msg.level = LogLevel.Error;
    msg.setText(0, "first");
    {
        auto builder = msg.payloadBuilder();
        builder.appendAscii("first message");
    }
    assert(msg.payloadText == "first message");

    msg.beginRecord();
    assert(msg.level == LogLevel.None);
    assert(msg.text(0) is null);
    msg.setText(0, "second");
    {
        auto builder = msg.payloadBuilder();
        builder.appendAscii("second message");
    }
    assert(msg.text(0) == "second");
    assert(msg.payloadText == "second message");
}

@("LogMessage: setText preserves printable ASCII range")
unittest
{
    LogMessage!char msg;
    msg.beginRecord();

    // All printable ASCII chars (space to tilde)
    string printables;
    foreach (c; 32 .. 127)
        printables ~= cast(char) c;

    msg.setText(0, printables);
    assert(msg.text(0) == printables);
}

@("PayloadBuilder: large payload")
unittest
{
    LogMessage!char msg;
    msg.beginRecord();
    auto builder = msg.payloadBuilder();

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

@("LogMessage: setText dchar")
unittest
{
    LogMessage!dchar msg;
    msg.beginRecord();
    msg.setText(0, "HELLO");
    assert(msg.text(0) == "HELLO"d);
}

@("LogMessage: setText replaces embedded nulls")
unittest
{
    LogMessage!char msg;
    msg.beginRecord();
    char[6] input = ['A', 'B', '\0', 'C', 'D', '\0'];
    msg.setText(0, input[]);
    assert(msg.text(0) == "AB?CD?");
}

// PayloadBuilder additional tests
@("PayloadBuilder: appendHex single full group")
unittest
{
    // 4 bytes = one group → "DEADBEEF " (trailing space after each group)
    LogMessage!char msg;
    msg.beginRecord();
    auto builder = msg.payloadBuilder();
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
    LogMessage!char msg;
    msg.beginRecord();
    auto builder = msg.payloadBuilder();
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
    LogMessage!char msg;
    msg.beginRecord();
    auto builder = msg.payloadBuilder();
    char[3] data = [1, 2, 3];
    builder.appendHex(data[]);
    builder.storePayload();

    assert(msg.payloadText == "010203 ");
}

@("PayloadBuilder: appendHex empty")
unittest
{
    LogMessage!char msg;
    msg.beginRecord();
    auto builder = msg.payloadBuilder();
    builder.appendHex([]);
    builder.storePayload();

    assert(msg.payloadText == "");
}

@("PayloadBuilder: destructor auto-store")
unittest
{
    LogMessage!char msg;
    msg._allocator = LinearAllocator!char(1024);

    {
        msg.beginRecord();
        auto builder = msg.payloadBuilder();
        builder.appendAscii("auto stored");
        // No explicit storePayload() call
    } // builder goes out of scope, destructor should call storePayload

    assert(msg.payloadText == "auto stored");
}

@("PayloadBuilder: appendUtf8 surrogate pairs in wchar")
unittest
{
    LogMessage!wchar msg;
    // U+1F600 😀 UTF-8: F0 9F 98 80  →  UTF-16 surrogate pair: D83D DE00
    msg.beginRecord();
    auto builder = msg.payloadBuilder();
    builder.appendUtf8("\U0001F600");
    builder.storePayload();

    assert(msg.payloadText == "\U0001F600"w);
}

// Helper function tests
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
