//! The structures of the DLT protocol: the storage, standard, extra and extended headers.
//!
//! DLT Message structure:
//! [ Storage Header ]        (16 bytes, always in file)
//! [ Standard Header ]       (minimum 4 bytes)
//! [ Extra Header Fields ]   (up to 12 bytes, depends on 'StandardHeader.headerType', byte order depends on 'StandardHeader.isBigEndian()')
//! [ Extended Header ]       (if 'StandardHeader.headerType' has 'UseExtendedHeader' flag)
//! [ Payload ]
module formats.dlt.protocol;

public import log_core.log_level : LogLevel;
import std.bitmanip;

//! @brief The storage header used in DLT files (16 bytes)
//! @note Byte order is always little-endian
//! @note Storage Header is always in file, it is skipped for network messages
align(1) struct StorageHeader
{
    char[4] pattern = 0; // "DLT\01"
    private uint _seconds;
    private uint _microseconds;
    char[4] ecuId = 0;

    uint nativeSeconds() const pure nothrow @nogc @property
    {
        return littleEndianToNative(_seconds);
    }

    void nativeSeconds(uint value) pure nothrow @nogc @property
    {
        _seconds = nativeToLittleEndian(value);
    }

    uint nativeMicroseconds() const pure nothrow @nogc @property
    {
        return littleEndianToNative(_microseconds);
    }

    void nativeMicroseconds(uint value) pure nothrow @nogc @property
    {
        _microseconds = nativeToLittleEndian(value);
    }
}

//! @brief Mark for beginning of DLT message
enum ubyte[4] DLT_PATTERN = ['D', 'L', 'T', '\01'];

//! The storage header of either version, as read from a file
struct StorageInfo
{
    size_t size; // 0: no storage header
    ulong seconds; // since the Unix epoch
    ulong nanoseconds; // more than a second in a corrupt header
    const(char)[] ecuId;
}

//! Converts a time to nanoseconds since the epoch.
//! @returns false if it doesn't fit (a corrupt or garbage time)
bool toTimeNs(ulong seconds, ulong nanoseconds, out long timeNs) pure nothrow @nogc
{
    enum ulong perSecond = 1_000_000_000;
    if (nanoseconds > long.max || seconds > (long.max - nanoseconds) / perSecond)
        return false;
    timeNs = cast(long)(seconds * perSecond + nanoseconds);
    return true;
}

//! @returns true if `data` starts with the pattern of a storage header,
//! "DLT" and the version: 1 (16 bytes) or 2 (14 bytes and the ECU ID)
bool startsWithStoragePattern(const(ubyte)[] data) pure nothrow @nogc
{
    return data.length >= 4 && data[0 .. 3] == DLT_PATTERN[0 .. 3] && (data[3] == 1 || data[3] == 2);
}

//! Reads the storage header at the start of `data`.
//! Version 1: pattern, seconds (4), microseconds (4), ECU ID (4), little-endian.
//! Version 2: pattern, nanoseconds (4), seconds (5), ECU ID length (1), ECU ID.
//! @returns size 0 if there is none or it is cut
StorageInfo readStorageHeader(const(ubyte)[] data) pure nothrow @nogc
{
    StorageInfo info;
    if (!startsWithStoragePattern(data))
        return info;

    static uint uint32(const(ubyte)[] bytes) pure nothrow @nogc
    {
        return std.bitmanip.littleEndianToNative!uint(bytes[0 .. 4]);
    }

    if (data[3] == 1)
    {
        if (data.length < StorageHeader.sizeof)
            return info;
        info.seconds = uint32(data[4 .. 8]);
        info.nanoseconds = uint32(data[8 .. 12]) * 1000UL;
        info.ecuId = cast(const(char)[]) data[12 .. 16];
        info.size = StorageHeader.sizeof;
        return info;
    }

    enum fixedSize = 14;
    if (data.length < fixedSize || data.length < fixedSize + data[13])
        return info;
    info.nanoseconds = uint32(data[4 .. 8]);
    foreach_reverse (b; data[8 .. 13]) // 40 bits, little-endian
        info.seconds = info.seconds << 8 | b;
    info.ecuId = cast(const(char)[]) data[fixedSize .. fixedSize + data[13]];
    info.size = fixedSize + data[13];
    return info;
}

//! @brief Fixed part of the Standard Header (4 bytes)
//! @note Byte order is always big-endian
align(1) struct StandardHeader
{
    ubyte headerType;
    ubyte messageCounter;
    private ushort _length; // Total length of the message (big endian)

    //! @brief Standard Header Flags
    enum Type : ubyte
    {
        UseExtendedHeader = 1 << 0,
        MostSignificantByteFirst = 1 << 1,
        WithEcuId = 1 << 2,
        WithSessionId = 1 << 3,
        WithTimestamp = 1 << 4,
        VersionMask = 0xE0
    }

    bool useExtendedHeader() const pure nothrow @nogc @property
    {
        return (headerType & Type.UseExtendedHeader) != 0;
    }

    bool isBigEndian() const pure nothrow @nogc @property
    {
        return (headerType & Type.MostSignificantByteFirst) != 0;
    }

    bool withEcuId() const pure nothrow @nogc @property
    {
        return (headerType & Type.WithEcuId) != 0;
    }

    bool withSessionId() const pure nothrow @nogc @property
    {
        return (headerType & Type.WithSessionId) != 0;
    }

    bool withTimestamp() const pure nothrow @nogc @property
    {
        return (headerType & Type.WithTimestamp) != 0;
    }

    uint fullHeaderSize() const pure nothrow @nogc
    {
        uint size = StandardHeader.sizeof;

        if (withEcuId())
            size += 4;
        if (withSessionId())
            size += 4;
        if (withTimestamp())
            size += 4;

        return size;
    }

    uint fullHeaderAndExtendedHeaderSize() const pure nothrow @nogc
    {
        uint size = fullHeaderSize();

        if (useExtendedHeader())
            size += ExtendedHeader.sizeof;

        return size;
    }

    //! @brief Get the version of the DLT header
    ubyte getVersion() const pure nothrow @nogc
    {
        return (headerType >> 5) & 0x07;
    }

    //! @brief Get the length of the message converted to host byte order
    ushort nativeLength() const pure nothrow @nogc @property
    {
        // Parse length (big endian usually in DLT, assume NATIVE for now or need bswap)
        // TODO: Handle Endianness properly based on system and file? 
        // DLT standard says Standard Header fields are Big Endian? 
        // Actually Storage Header is usually Little Endian (x86).
        // Standard Header fields are Big Endian.

        return bigEndianToNative(_length);
    }

    //! @brief Set the length of the message converted to big endian
    void nativeLength(ushort value) pure nothrow @nogc @property
    {
        _length = nativeToBigEndian(value);
    }
}

enum MessageType : ubyte
{
    Log = 0x00, //< Log message type
    AppTrace = 0x01, //< Application trace message type
    NwTrace = 0x02, //< Network trace message type
    Control = 0x03, //< Control message type
}

enum AppTraceType : ubyte
{
    Variable = 0x01, //< tracing of a variable
    FunctionIn = 0x02, //< tracing of function calls
    FunctionOut = 0x03, //< tracing of function return values
    State = 0x04, //< tracing of states of a state machine
    Vfb = 0x05, //< tracing of virtual function bus
}

enum NwTraceType : ubyte
{
    ToDo1 = 0x01, //< tracing of data
    ToDo2 = 0x02, //< tracing of control
    // todo: add more types
}

enum ControlType : ubyte
{
    Request = 0x01, //< Request message
    Response = 0x02, //< Response to request message
    Time = 0x03, //< keep-alive message
}

align(1) struct MessageInfo
{
    ubyte info;
    alias info this;

    enum ubyte VerboseMask = 0b0000_0001;
    enum ubyte MessageTypeMask = 0b0000_1110; // MST, 0x0E, // Bits 1-3
    enum ubyte MessageTypeInfoMask = 0b1111_0000; // MTIN, 0x0F, // Bits 4-7

    bool isVerbose() const pure nothrow @nogc @property
    {
        return (info & VerboseMask) != 0;
    }

    MessageType messageType() const pure nothrow @nogc @property
    {
        return cast(MessageType)((info & MessageTypeMask) >> 1);
    }

    ubyte messageTypeInfo() const pure nothrow @nogc @property
    {
        return (info & MessageTypeInfoMask) >> 4;
    }

    //! The level of a log message, verbose or not: MTIN holds it when MSTP is
    //! Log. Other message types, and values outside Fatal..Verbose, have no level.
    LogLevel logLevel() const pure nothrow @nogc @property
    {
        if (messageType() != MessageType.Log)
            return LogLevel.None;

        const mtin = messageTypeInfo();
        if (mtin < LogLevel.Fatal || mtin > LogLevel.Verbose)
            return LogLevel.None;
        return cast(LogLevel) mtin;
    }

    AppTraceType appTraceType() const pure nothrow @nogc @property
    {
        if (isVerbose() && messageType() == MessageType.AppTrace)
        {
            return cast(AppTraceType)(messageTypeInfo());
        }

        return AppTraceType.Variable;
    }

    NwTraceType nwTraceType() const pure nothrow @nogc @property
    {
        if (isVerbose() && messageType() == MessageType.NwTrace)
        {
            return cast(NwTraceType)(messageTypeInfo());
        }

        return NwTraceType.ToDo1;
    }

    ControlType controlType() const pure nothrow @nogc @property
    {
        if (isVerbose() && messageType() == MessageType.Control)
        {
            return cast(ControlType)(messageTypeInfo());
        }

        return ControlType.Request;
    }
}

//! @brief Extended Header (optional, 10 bytes)
align(1) struct ExtendedHeader
{
    MessageInfo messageInfo; // 1 byte
    ubyte numberOfArguments; // 1 byte
    char[4] applicationId; // 4 bytes
    char[4] contextId; // 4 bytes
}

/** 
dlt_protocol.h
//
// Definitions of types of arguments in payload.
//
#define DLT_TYPE_INFO_TYLE	0x0000000f //< Length of standard data: 1 = 8bit, 2 = 16bit, 3 = 32 bit, 4 = 64 bit, 5 = 128 bit
#define DLT_TYPE_INFO_BOOL	0x00000010 //< Boolean data 
#define DLT_TYPE_INFO_SINT	0x00000020 //< Signed integer data 
#define DLT_TYPE_INFO_UINT	0x00000040 //< Unsigned integer data 
#define DLT_TYPE_INFO_FLOA	0x00000080 //< Float data 
#define DLT_TYPE_INFO_ARAY	0x00000100 //< Array of standard types 
#define DLT_TYPE_INFO_STRG	0x00000200 //< String 
#define DLT_TYPE_INFO_RAWD	0x00000400 //< Raw data 
#define DLT_TYPE_INFO_VARI	0x00000800 //< Set, if additional information to a variable is available 
#define DLT_TYPE_INFO_FIXP	0x00001000 //< Set, if quantization and offset are added 
#define DLT_TYPE_INFO_TRAI	0x00002000 //< Set, if additional trace information is added 
#define DLT_TYPE_INFO_STRU	0x00004000 //< Struct 
#define DLT_TYPE_INFO_SCOD	0x00038000 //< coding of the type string: 0 = ASCII, 1 = UTF-8 

#define DLT_TYLE_8BIT		0x00000001
#define DLT_TYLE_16BIT		0x00000002
#define DLT_TYLE_32BIT		0x00000003
#define DLT_TYLE_64BIT		0x00000004
#define DLT_TYLE_128BIT		0x00000005

#define DLT_SCOD_ASCII      0x00000000
#define DLT_SCOD_UTF8       0x00008000
#define DLT_SCOD_HEX        0x00010000
#define DLT_SCOD_BIN        0x00018000

// for parsing look at https://github.com/COVESA/dlt-viewer/blob/master/qdlt/dlt_common.c
 */

enum Tyle : uint
{
    Tyle8Bit = 0x00000001,
    Tyle16Bit = 0x00000002,
    Tyle32Bit = 0x00000003,
    Tyle64Bit = 0x00000004,
    Tyle128Bit = 0x00000005
}

enum StringCoding : uint
{
    StringCodingASCII = 0x00000000,
    StringCodingUTF8 = 0x00008000,
    StringCodingHEX = 0x00010000,
    StringCodingBIN = 0x00018000
}

//! @brief Type Info flags for Verbose arguments
enum TypeInfoFlags : uint
{
    // DLT_TYPE_INFO_TYLE
    LengthMask = 0x0000000f, //< Length of standard data: 1 = 8bit, 2 = 16bit, 3 = 32 bit, 4 = 64 bit, 5 = 128 bit

    TypeBoolean = 1 << 4,
    TypeSigned = 1 << 5,
    TypeUnsigned = 1 << 6,
    TypeFloat = 1 << 7,
    TypeArray = 1 << 8,
    TypeString = 1 << 9,
    TypeRaw = 1 << 10,
    VariableInfo = 1 << 11,
    FixedPoint = 1 << 12,
    TypeTraceInfo = 1 << 13,
    TypeStruct = 1 << 14,
    StringCodingMask = 0x00000007 << 15, // Bits 15-17
    StringCodingASCII = 0 << 15,
    StringCodingUTF8 = 1 << 15,
    StringCodingHEX = 2 << 15, // integers: shown in hex
    StringCodingBIN = 3 << 15, // integers: shown in binary
}

//! @brief Definitions of DLT services.
enum ServiceID : ushort
{
    SetLogLevel = 0x01, //< Service ID: Set log level
    SetTraceStatus = 0x02, //< Service ID: Set trace status
    GetLogInfo = 0x03, //< Service ID: Get log info
    GetDefaultLogLevel = 0x04, //< Service ID: Get dafault log level
    StoreConfig = 0x05, //< Service ID: Store configuration
    ResetToFactoryDefault = 0x06, //< Service ID: Reset to factory defaults
    SetComInterfaceStatus = 0x07, //< Service ID: Set communication interface status
    SetComInterfaceMaxBandwidth = 0x08, //< Service ID: Set communication interface maximum bandwidth
    SetVerboseMode = 0x09, //< Service ID: Set verbose mode
    SetMessageFiltering = 0x0A, //< Service ID: Set message filtering
    SetTimingPackets = 0x0B, //< Service ID: Set timing packets
    GetLocalTime = 0x0C, //< Service ID: Get local time
    UseEcuId = 0x0D, //< Service ID: Use ECU id
    UseSessionId = 0x0E, //< Service ID: Use session id
    UseTimestamp = 0x0F, //< Service ID: Use timestamp
    UseExtendedHeader = 0x10, //< Service ID: Use extended header
    SetDefaultLogLevel = 0x11, //< Service ID: Set default log level
    SetDefaultTraceStatus = 0x12, //< Service ID: Set default trace status
    GetSoftwareVersion = 0x13, //< Service ID: Get software version
    MessageBufferOverflow = 0x14, //< Service ID: Message buffer overflow
    UnregisterContext = 0xf01, //< Service ID: Message unregister context
    ConnectionInfo = 0xf02, //< Service ID: Message connection info
    Timezone = 0xf03, //< Service ID: Timezone
    Marker = 0xf04, //< Service ID: Timezone
    CallswCinjection = 0xFFF //< Service ID: Message Injection (minimal ID)
}

//! @brief Definitions of DLT service response status
enum ServiceResponseStatus : ubyte
{
    Ok = 0x00,
    NotSupported = 0x01,
    Error = 0x02,
    PermissionDenied = 0x03, // dlt-daemon
    Warning = 0x04, // dlt-daemon
    // get_log_info answers 3..7 (the options it was asked for) when it succeeds
    NoMatchingContextId = 0x08, // get_log_info
    Overflow = 0x09, // get_log_info
}

//! @brief Definitions of DLT service connection state
enum ServiceConnectionState : ubyte
{
    Disconnected = 0x01,
    Connected = 0x02
}

//! @brief Helper to check if extended header is present
bool useExtendedHeader(ubyte ht) pure nothrow @nogc
{
    return (ht & StandardHeader.Type.UseExtendedHeader) != 0;
}

//! @brief Helper to get Log Level from Extended Header Message Info
/*LogLevel getLogLevel(ubyte info) pure nothrow @nogc
{
    // Bit 0: Verbose.
    if (info & MessageInfo.Verbose)
    {
        // Verbose: Log Level is in bits 4..6 of info (Wait, standard says Message Type Info?)
        // Standard:
        // Byte 0: Mesage Info
        //   Bit 0: VERB (Verbose)
        //   Bit 1-3: MST (Message Type)
        //   Bit 4-7: MTIN (Message Type Info) -> This contains Log Level if MST=Logic
        return cast(LogLevel)((info >> 4) & 0x0F);
    }
    return LogLevel.Info; // Default/Unknown for Non-Verbose
}
*/

//! @brief Calculate the full header length (Standard + Extras + Extended)
uint getHeaderSize(const(ubyte)* ptr) pure nothrow @nogc
{
    // Ptr points to Standard Header (after Storage Header)
    const auto sh = cast(const(StandardHeader)*) ptr;
    uint size = StandardHeader.sizeof;

    const ubyte ht = sh.headerType;

    if (ht & StandardHeader.Type.WithEcuId)
        size += 4;
    if (ht & StandardHeader.Type.WithSessionId)
        size += 4;
    if (ht & StandardHeader.Type.WithTimestamp)
        size += 4;

    if (ht & StandardHeader.Type.UseExtendedHeader)
        size += ExtendedHeader.sizeof;

    return size;
}

/// Helper to read integers with correct endianness
T readValue(T)(const(ubyte)[] buffer, bool msbf) pure nothrow @nogc
{
    import std.bitmanip : bigEndianToNative, littleEndianToNative;

    if (buffer.length < T.sizeof)
        return T.init;

    ubyte[T.sizeof] tmp = buffer[0 .. T.sizeof];
    if (msbf)
        return bigEndianToNative!T(tmp);
    else
        return littleEndianToNative!T(tmp);
}

/// Extract Message ID from Non-Verbose message (returns 0 if not found/verbose)
uint peekMessageId(const(ubyte)* ptr) pure nothrow @nogc
{
    // Ptr points to Standard Header
    const auto sh = cast(const(StandardHeader)*) ptr;
    const ubyte ht = sh.headerType;
    const bool msbf = (ht & StandardHeader.Type.MostSignificantByteFirst) != 0;

    // Calculate header size (Standard + Extras + Extended)
    uint offset = StandardHeader.sizeof;
    if (ht & StandardHeader.Type.WithEcuId)
        offset += 4;
    if (ht & StandardHeader.Type.WithSessionId)
        offset += 4;
    if (ht & StandardHeader.Type.WithTimestamp)
        offset += 4;

    if (ht & StandardHeader.Type.UseExtendedHeader)
    {
        auto eh = cast(const(ExtendedHeader)*)(ptr + offset);
        if (eh.messageInfo.isVerbose())
            return 0; // Verbose message has no ID
        offset += ExtendedHeader.sizeof;
    }

    // Non-Verbose: Message ID is in the first 4 bytes of payload
    // Standard DLT says for Non-Verbose, Message ID is mandatory? 
    // Usually yes. Some implementations might vary, but we'll follow common practice.
    const(ubyte)[] payload = (ptr + offset)[0 .. 4];
    return readValue!uint(payload, msbf);
}

private ushort bigEndianToNative(ushort val) pure nothrow @nogc
{
    version (BigEndian)
        return val;
    else
        return cast(ushort)((val >> 8) | (val << 8));
}

private ushort nativeToBigEndian(ushort val) pure nothrow @nogc
{
    return bigEndianToNative(val);
}

private ushort littleEndianToNative(ushort val) pure nothrow @nogc
{
    version (LittleEndian)
        return val;
    else
        return cast(ushort)((val >> 8) | (val << 8));
}

private ushort nativeToLittleEndian(ushort val) pure nothrow @nogc
{
    return littleEndianToNative(val);
}

private uint littleEndianToNative(uint val) pure nothrow @nogc
{
    version (LittleEndian)
        return val;
    else
        return cast(uint)((val >> 24) | ((val >> 8) & 0xFF00) | ((val << 8) & 0xFF0000) | (val << 24));
}

private uint nativeToLittleEndian(uint val) pure nothrow @nogc
{
    return littleEndianToNative(val);
}

@("MessageInfo: Log")
unittest
{
    assert(MessageInfo.sizeof == 1);
    assert(ExtendedHeader.sizeof == 10);

    MessageInfo messageInfo;
    messageInfo.info = 0x00;
    assert(messageInfo.isVerbose() == false);
    assert(messageInfo.messageType() == MessageType.Log);
    assert(messageInfo.messageTypeInfo() == 0x00);
    assert(messageInfo.logLevel() == LogLevel.None, "level 0 is not a level");
}

@("getHeaderSize: Min Header (UEH=0)")
unittest
{
    // Test 1: Standard Header only
    // HT: 001 (Use Extended) 0 (No) -> 0?
    // Let's verify getHeaderSize

    // Case A: Min Header (UEH=0)
    // HT: 0
    ubyte[] msg = [0, 0, 0, 0];
    StandardHeader* header = cast(StandardHeader*) msg.ptr;
    header.headerType = 0;
    assert(getHeaderSize(msg.ptr) == 4);
}

@("getHeaderSize: With ECU ID (WEID=1)")
unittest
{
    // Case B: With ECU ID (WEID=1) -> Bit 2? 
    // StandardHeader.Type Enum: UseExtendedHeader = 1, WithEcuId = 4
    ubyte[] msg = [0, 0, 0, 0, 65, 66, 67, 68]; // +4 bytes ECU
    StandardHeader* header = cast(StandardHeader*) msg.ptr;
    header.headerType = StandardHeader.Type.WithEcuId; // 4
    assert(getHeaderSize(msg.ptr) == 8);
}

@("getHeaderSize: Extended Header")
unittest
{
    // Case C: Extended Header
    // HT: UseExtendedHeader (1)
    ubyte[] msg = new ubyte[4 + 10]; // 4 std + 10 ext
    StandardHeader* header = cast(StandardHeader*) msg.ptr;
    header.headerType = StandardHeader.Type.UseExtendedHeader;
    assert(getHeaderSize(msg.ptr) == 14);
}

@("peekMessageId: the id of a non-verbose message, with an extended header and without; 0 for a verbose one")
unittest
{
    // Test 2: peekMessageId
    // Need Extended Header + Verbose=0
    // HT = UseExtendedHeader
    // ExtHeader: Verbose = 0.
    // Payload: ID = 0xDEADBEEF

    ubyte[] msgD = new ubyte[20];
    StandardHeader* shD = cast(StandardHeader*) msgD.ptr;
    shD.headerType = StandardHeader.Type.UseExtendedHeader | StandardHeader
        .Type.MostSignificantByteFirst;

    ExtendedHeader* ehD = cast(ExtendedHeader*)(msgD.ptr + 4);
    ehD.messageInfo = 0; // Not verbose

    // Payload starts at 4 + 10 = 14
    msgD[14] = 0xDE;
    msgD[15] = 0xAD;
    msgD[16] = 0xBE;
    msgD[17] = 0xEF;

    assert(peekMessageId(msgD.ptr) == 0xDEADBEEF);

    // Case E: Verbose message (Should return 0)
    ehD.messageInfo = MessageInfo.VerboseMask;
    assert(peekMessageId(msgD.ptr) == 0);

    // Case F: Non-Verbose WITHOUT Extended Header
    ubyte[] msgF = new ubyte[12];
    StandardHeader* shF = cast(StandardHeader*) msgF.ptr;
    shF.headerType = StandardHeader.Type.MostSignificantByteFirst; // UEH = 0
    // Payload starts at 4
    msgF[4] = 0x12;
    msgF[5] = 0x34;
    msgF[6] = 0x56;
    msgF[7] = 0x78;
    assert(peekMessageId(msgF.ptr) == 0x12345678);
}

@("readStorageHeader: version 1")
unittest
{
    StorageHeader header;
    header.pattern = cast(char[4]) DLT_PATTERN;
    header.nativeSeconds = 1_700_000_000;
    header.nativeMicroseconds = 123_456;
    header.ecuId = "ECU1";
    const bytes = (cast(const(ubyte)*) &header)[0 .. StorageHeader.sizeof];

    const info = readStorageHeader(bytes);
    assert(info.size == 16);
    assert(info.seconds == 1_700_000_000 && info.nanoseconds == 123_456_000);
    assert(info.ecuId == "ECU1");
    assert(readStorageHeader(bytes[0 .. 15]).size == 0, "cut");
}

@("readStorageHeader: version 2 has nanoseconds, 40-bit seconds and an ECU ID of any length")
unittest
{
    ubyte[] bytes = cast(ubyte[]) "DLT\x02".dup;
    bytes ~= [0x15, 0xCD, 0x5B, 0x07]; // 123456789 ns, little-endian
    bytes ~= [0x00, 0xF1, 0x53, 0x65, 0x01]; // 0x016553F100 s, little-endian
    bytes ~= 5;
    bytes ~= cast(ubyte[]) "ECU12".dup;
    bytes ~= [0xAA, 0xBB]; // the message

    const info = readStorageHeader(bytes);
    assert(info.size == 19);
    assert(info.nanoseconds == 123_456_789);
    assert(info.seconds == 0x01_6553_F100);
    assert(info.ecuId == "ECU12");
    assert(startsWithStoragePattern(bytes));

    assert(readStorageHeader(bytes[0 .. 18]).size == 0, "cut ECU ID");
    assert(readStorageHeader(bytes[0 .. 13]).size == 0, "cut before the ECU ID length");
    bytes[3] = 3;
    assert(readStorageHeader(bytes).size == 0, "unknown version");
    assert(!startsWithStoragePattern(bytes));
}
