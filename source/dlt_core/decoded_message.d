module dlt_core.decoded_message;

import std.traits;
import core.stdc.stdlib : malloc, free;
import std.ascii : isPrintable;
import dlt_core.dlt_protocol : LogLevel, MessageType;

/// Represents a decoded DLT log message
struct DecodedMessage(Char = char) if (isSomeChar!Char)
{
    @disable this(ref DecodedMessage);
    @disable void opAssign(ref DecodedMessage);

    private LinearAllocator _allocator;

    uint timestampSeconds;
    uint timestampMicroseconds;
    LogLevel level;
    MessageType type;
    uint messageId;

    // from extended header (if present)
    uint ecuId;
    uint sessionId;
    uint relativeTimestampMs;

    private Char[] _ecu;
    private Char[] _appId;
    private Char[] _ctxId;
    private Char[] _payloadText;

    const(Char)[] ecu() const pure nothrow @nogc @property
    {
        return _ecu;
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

    private Char[] convertAndClean(const(char)[] source) pure nothrow @nogc
    {
        Char[] buf = _allocator.tail!Char();
        size_t count = 0;

        foreach (c; source)
        {
            if (c == 0)
                break; // Stop at null terminator
            if (count >= buf.length)
                break;
            if (isPrintable(c))
                buf[count] = cast(Char) c;
            else
                buf[count] = cast(Char) '.'; // Replace non-printable with dot
            count++;
        }
        _allocator.spendBytes(count * Char.sizeof);
        return buf[0 .. count];
    }

    PayloadBuilder!Char setupPayload(const(char)[] ecu, const(char)[] appId, const(char)[] ctxId)
    {
        enum capacity = 16 * 1024 * Char.sizeof + 1024;
        _allocator.reset(capacity);

        this._ecu = convertAndClean(ecu);
        this._appId = convertAndClean(appId);
        this._ctxId = convertAndClean(ctxId);

        return PayloadBuilder!Char(&this);
    }

    void clear() pure nothrow @nogc
    {
        _allocator.clear();
        timestampSeconds = 0;
        timestampMicroseconds = 0;
        level = LogLevel.Info;
        type = MessageType.Log;
        messageId = 0;
        ecuId = 0;
        sessionId = 0;
        relativeTimestampMs = 0;
        _ecu = null;
        _appId = null;
        _ctxId = null;
        _payloadText = null;
    }
}

//! Primitive allocator for decoded messages
package struct LinearAllocator
{
    enum alignment = 16;

    private void[] _buffer;
    private void* _ptr;

    this(size_t capacity)
    {
        void* ptr = malloc(capacity);

        if (ptr)
        {
            _buffer = ptr[0 .. capacity];
            _ptr = ptr;
        }
    }

    ~this()
    {
        if (_buffer)
            free(_buffer.ptr);
    }

    //! @returns remaining capacity in bytes
    size_t rest() const pure @nogc nothrow
    {
        return _buffer.ptr + _buffer.length - _ptr;
    }

    void reset(size_t capacity)
    {
        if (_buffer)
            free(_buffer.ptr);
        _buffer = null;
        _ptr = null;

        void* ptr = malloc(capacity);

        if (ptr)
        {
            _buffer = ptr[0 .. capacity];
            _ptr = ptr;
        }
    }

    void clear() pure @nogc nothrow
    {
        _ptr = _buffer.ptr;
    }

    void* allocBytesAligned(size_t size) pure @nogc nothrow
    {
        void* alignedPtr = cast(void*)((cast(size_t) _ptr + alignment - 1) / alignment * alignment);

        if (alignedPtr + size > _buffer.ptr + _buffer.length)
            return null;

        _ptr = alignedPtr + size;

        return alignedPtr;
    }

    void* allocBytes(size_t size) pure @nogc nothrow
    {
        if (_ptr + size > _buffer.ptr + _buffer.length)
            return null;

        void* result = _ptr;
        _ptr += size;

        return result;
    }

    T* allocAligned(T)(size_t count = 1) pure @nogc nothrow
    {
        return cast(T*) allocBytesAligned(count * T.sizeof);
    }

    T* alloc(T)(size_t count = 1) pure @nogc nothrow
    {
        return cast(T*) allocBytes(count * T.sizeof);
    }

    T[] tail(T)() pure @nogc nothrow
    {
        size_t bytesLeft = _buffer.ptr + _buffer.length - _ptr;
        size_t count = bytesLeft / T.sizeof;

        return (cast(T*) _ptr)[0 .. count];
    }

    void spendBytes(size_t count) pure @nogc nothrow
    {
        _ptr += count;
    }
}

private struct PayloadBuilder(Char) if (isSomeChar!Char)
{
    private DecodedMessage!Char* _message;
    private bool _isFirstArg = true;
    private enum separator = " ";

    this(DecodedMessage!Char* message) pure nothrow @nogc
    {
        _message = message;

        // Mark the start of payload text in the buffer
        _message._payloadText = _message._allocator.tail!Char()[0 .. 0];
    }

    ~this() pure nothrow @nogc
    {
        // finalize: update the slice length to include everything written
        auto fullTail = _message._allocator.tail!Char();
        auto startPtr = _message._payloadText.ptr;
        auto currentPtr = fullTail.ptr;
        size_t len = (currentPtr - startPtr);
        _message._payloadText = startPtr[0 .. len];

        // replace invisible chars with space

        foreach (ref c; _message._payloadText)
        {
            if (!isPrintable(c))
                c = ' ';
        }

        /*
        if (_message._allocator.rest() == 0)
            _message._payloadText[$ - 1] = 0;
        else
            _message._payloadText[$] = 0;
        */
    }

    // raw append without separator logic
    private void rawAppendChars(const(char)[] text) pure nothrow @nogc
    {
        auto buf = _message._allocator.tail!Char();
        size_t count = 0;
        foreach (c; text)
        {
            if (count >= buf.length)
                break;
            buf[count++] = cast(Char) c;
        }
        spend(count);
    }

    private void appendSeparatorIfNeeded() pure nothrow @nogc
    {
        if (_isFirstArg)
        {
            _isFirstArg = false;
        }
        else
        {
            if (_message._allocator.rest() < separator.length * Char.sizeof)
                return;
            rawAppendChars(separator);
        }
    }

    Char[] tail() pure nothrow @nogc
    {
        return _message._allocator.tail!Char();
    }

    void spend(size_t count) pure nothrow @nogc
    {
        _message._allocator.spendBytes(count * Char.sizeof);
    }

    void appendAscii(const(char)[] text) pure nothrow @nogc
    {
        appendSeparatorIfNeeded();
        rawAppendChars(text);
    }

    void appendUtf8(const(char)[] utf8) pure nothrow @nogc
    {
        appendSeparatorIfNeeded();

        static if (is(Char == char))
        {
            rawAppendChars(utf8);
        }
        else
        {
            // For wchar/dchar: simple ASCII fallback for now
            rawAppendChars(utf8);
        }
    }

    void appendBool(bool value) pure nothrow @nogc
    {
        appendAscii(value ? "true" : "false");
    }
    /*
    void appendInt(long value) pure nothrow @nogc
    {
        appendSeparatorIfNeeded();

        auto buf = _message._allocator.tail!Char();
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

        auto buf = _message._allocator.tail!Char();
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
        import std.algorithm : copy;

        appendSeparatorIfNeeded();
        auto resultRange = toChars(value);
        auto remaining = copy(resultRange, tail());
        auto len = tail().length - remaining.length;
        spend(len);
    }

    void append(T)(T value) nothrow @nogc if (isFloatingPoint!T)
    {
        import core.stdc.stdio : snprintf;

        appendSeparatorIfNeeded();
        int len = snprintf(tail().ptr, tail().length, "%f", value);
        spend(len);
    }
}

// ─── LinearAllocator Tests ──────────────────────────────────────────────────────

@("LinearAllocator: construction and rest()")
unittest
{
    auto buf = LinearAllocator(1024);
    assert(buf.rest() == 1024);
}

@("LinearAllocator: allocBytes reduces rest()")
unittest
{
    auto buf = LinearAllocator(1024);
    auto p = buf.allocBytes(100);
    assert(p !is null);
    assert(buf.rest() == 924);
}

@("LinearAllocator: allocBytes returns null when full")
unittest
{
    auto buf = LinearAllocator(64);
    auto p1 = buf.allocBytes(64);
    assert(p1 !is null);
    assert(buf.rest() == 0);
    auto p2 = buf.allocBytes(1);
    assert(p2 is null);
}

@("LinearAllocator: clear resets pointer")
unittest
{
    auto buf = LinearAllocator(256);
    buf.allocBytes(128);
    assert(buf.rest() == 128);
    buf.clear();
    assert(buf.rest() == 256);
}

@("LinearAllocator: reset reallocates")
unittest
{
    auto buf = LinearAllocator(100);
    assert(buf.rest() == 100);
    buf.reset(200);
    assert(buf.rest() == 200);
}

@("LinearAllocator: tail returns remaining space as typed array")
unittest
{
    auto buf = LinearAllocator(128);
    auto t = buf.tail!char();
    assert(t.length == 128);

    buf.allocBytes(10);
    auto t2 = buf.tail!char();
    assert(t2.length == 118);
}

@("LinearAllocator: spend advances pointer")
unittest
{
    auto buf = LinearAllocator(256);
    auto initial = buf.rest();
    buf.spendBytes(50);
    assert(buf.rest() == initial - 50);
}

@("LinearAllocator: alloc typed allocation")
unittest
{
    auto buf = LinearAllocator(256);
    auto p = buf.alloc!int(4);
    assert(p !is null);
    assert(buf.rest() == 256 - 4 * int.sizeof);
}

@("LinearAllocator: allocBytesAligned aligns pointer")
unittest
{
    auto buf = LinearAllocator(1024);
    // Advance by 1 unaligned byte
    buf.allocBytes(1);

    auto aligned = buf.allocBytesAligned(16);
    assert(aligned !is null);
    assert(cast(size_t) aligned % LinearAllocator.alignment == 0);
}

@("LinearAllocator: multiple alloc/clear cycles")
unittest
{
    auto buf = LinearAllocator(128);

    // First cycle
    buf.allocBytes(64);
    assert(buf.rest() == 64);
    buf.clear();
    assert(buf.rest() == 128);

    // Second cycle
    buf.allocBytes(32);
    assert(buf.rest() == 96);
    buf.clear();
    assert(buf.rest() == 128);
}

@("LinearAllocator: tail with different types")
unittest
{
    auto buf = LinearAllocator(256);

    auto charTail = buf.tail!char();
    assert(charTail.length == 256);

    auto intTail = buf.tail!int();
    assert(intTail.length == 256 / int.sizeof);

    auto longTail = buf.tail!long();
    assert(longTail.length == 256 / long.sizeof);
}

// ─── DecodedMessage Tests ──────────────────────────────────────────────────────

@("DecodedMessage: convertAndClean basic string")
unittest
{
    DecodedMessage!char msg;
    msg._allocator = LinearAllocator(1024);

    auto result = msg.convertAndClean("HELLO");
    assert(result == "HELLO");
}

@("DecodedMessage: convertAndClean stops at null")
unittest
{
    DecodedMessage!char msg;
    msg._allocator = LinearAllocator(1024);

    auto result = msg.convertAndClean("AB\0CD");
    assert(result == "AB");
}

@("DecodedMessage: convertAndClean replaces non-printable")
unittest
{
    DecodedMessage!char msg;
    msg._allocator = LinearAllocator(1024);

    char[4] input = ['A', 1, 'B', 2]; // 1 and 2 are non-printable
    auto result = msg.convertAndClean(input[]);
    assert(result == "A.B.");
}

@("DecodedMessage: convertAndClean empty string")
unittest
{
    DecodedMessage!char msg;
    msg._allocator = LinearAllocator(1024);

    auto result = msg.convertAndClean("");
    assert(result.length == 0);
}

@("DecodedMessage: convertAndClean null-only string")
unittest
{
    DecodedMessage!char msg;
    msg._allocator = LinearAllocator(1024);

    char[4] input = [0, 0, 0, 0];
    auto result = msg.convertAndClean(input[]);
    assert(result.length == 0);
}

@("DecodedMessage: convertAndClean does not overflow buffer")
unittest
{
    DecodedMessage!char msg;
    msg._allocator = LinearAllocator(4); // Very small buffer

    auto result = msg.convertAndClean("ABCDEFGH");
    assert(result.length <= 4);
}

@("DecodedMessage: setupPayload sets ecu/appId/ctxId")
unittest
{
    DecodedMessage!char msg;

    auto builder = msg.setupPayload("ECU1", "APP1", "CTX1");
    assert(msg.ecu == "ECU1");
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
    assert(msg.ecu == "EC");
    assert(msg.appId == "A.P");
    assert(msg.ctxId == "CTX1");
}

@("DecodedMessage: clear resets all fields")
unittest
{
    DecodedMessage!char msg;
    msg._allocator = LinearAllocator(256);

    msg.timestampSeconds = 100;
    msg.timestampMicroseconds = 200;
    msg.level = LogLevel.Fatal;
    msg.type = MessageType.Control;
    msg.messageId = 42;
    msg.ecuId = 0xDEAD;
    msg.sessionId = 0xBEEF;
    msg.relativeTimestampMs = 999;

    msg.clear();

    assert(msg.timestampSeconds == 0);
    assert(msg.timestampMicroseconds == 0);
    assert(msg.level == LogLevel.Info);
    assert(msg.type == MessageType.Log);
    assert(msg.messageId == 0);
    assert(msg.ecuId == 0);
    assert(msg.sessionId == 0);
    assert(msg.relativeTimestampMs == 0);
    assert(msg._ecu is null);
    assert(msg._appId is null);
    assert(msg._ctxId is null);
    assert(msg._payloadText is null);
}

@("DecodedMessage: properties return correct values")
unittest
{
    DecodedMessage!char msg;
    msg._allocator = LinearAllocator(256);

    msg._ecu = "ECU".dup;
    msg._appId = "APP".dup;
    msg._ctxId = "CTX".dup;
    msg._payloadText = "payload".dup;

    assert(msg.ecu == "ECU");
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
    builder.__xdtor();

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
    builder.__xdtor();

    assert(msg.payloadText == "foo bar baz");
}

@("PayloadBuilder: appendBool true and false")
unittest
{
    DecodedMessage!char msg;
    auto builder = msg.setupPayload("E", "A", "C");
    builder.appendBool(true);
    builder.appendBool(false);
    builder.__xdtor();

    assert(msg.payloadText == "true false");
}

@("PayloadBuilder: appendUtf8 ASCII text")
unittest
{
    DecodedMessage!char msg;
    auto builder = msg.setupPayload("E", "A", "C");
    builder.appendUtf8("hello utf8");
    builder.__xdtor();

    assert(msg.payloadText == "hello utf8");
}

@("PayloadBuilder: appendInt positive")
unittest
{
    DecodedMessage!char msg;
    auto builder = msg.setupPayload("E", "A", "C");
    builder.append(12345);
    builder.__xdtor();

    assert(msg.payloadText == "12345");
}

@("PayloadBuilder: appendInt negative")
unittest
{
    DecodedMessage!char msg;
    auto builder = msg.setupPayload("E", "A", "C");
    builder.append(-42);
    builder.__xdtor();

    assert(msg.payloadText == "-42");
}

@("PayloadBuilder: appendInt zero")
unittest
{
    DecodedMessage!char msg;
    auto builder = msg.setupPayload("E", "A", "C");
    builder.append(cast(int) 0);
    builder.__xdtor();

    assert(msg.payloadText == "0");
}

@("PayloadBuilder: appendUint")
unittest
{
    DecodedMessage!char msg;
    auto builder = msg.setupPayload("E", "A", "C");
    builder.append(99999);
    builder.__xdtor();

    assert(msg.payloadText == "99999");
}

@("PayloadBuilder: appendUint zero")
unittest
{
    DecodedMessage!char msg;
    auto builder = msg.setupPayload("E", "A", "C");
    builder.append(cast(uint) 0);
    builder.__xdtor();

    assert(msg.payloadText == "0");
}

@("PayloadBuilder: append float")
unittest
{
    DecodedMessage!char msg;
    auto builder = msg.setupPayload("E", "A", "C");
    builder.append(cast(float) 0.1f);
    builder.__xdtor();

    assert(msg.payloadText == "0.100000");
}

@("PayloadBuilder: append double")
unittest
{
    DecodedMessage!char msg;
    auto builder = msg.setupPayload("E", "A", "C");
    builder.append(cast(double) 0.1);
    builder.__xdtor();

    assert(msg.payloadText == "0.100000");
}

@("PayloadBuilder: mixed types with separators")
unittest
{
    DecodedMessage!char msg;
    auto builder = msg.setupPayload("E", "A", "C");
    builder.appendAscii("count:");
    builder.append(42);
    builder.appendBool(true);
    builder.__xdtor();

    assert(msg.payloadText == "count: 42 true");
}

@("PayloadBuilder: empty payload")
unittest
{
    DecodedMessage!char msg;
    auto builder = msg.setupPayload("E", "A", "C");
    builder.__xdtor();

    assert(msg.payloadText.length == 0);
}

@("PayloadBuilder: appendAscii empty string")
unittest
{
    DecodedMessage!char msg;
    auto builder = msg.setupPayload("E", "A", "C");
    builder.appendAscii("");
    builder.__xdtor();

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

    assert(msg.ecu == "ECU1");
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
    assert(msg.ecu == "ECU2");
    assert(msg.appId == "APP2");
    assert(msg.payloadText == "second message");
}

@("DecodedMessage: convertAndClean preserves printable ASCII range")
unittest
{
    DecodedMessage!char msg;
    msg._allocator = LinearAllocator(1024);

    // All printable ASCII chars (space to tilde)
    string printables;
    foreach (c; 32 .. 127)
        printables ~= cast(char) c;

    auto result = msg.convertAndClean(printables);
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
    builder.__xdtor();

    // Just verify it didn't crash and has content
    assert(msg.payloadText.length > 0);
}
