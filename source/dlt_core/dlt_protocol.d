module dlt_core.dlt_protocol;

import dlt_core.log_item;
import std.bitmanip;

///
/// DLT Data Structures
///
//! @brief DLT Message structure:
//!   StorageHeader (16 bytes)
//!   StandardHeader (16 bytes)
//!   ExtendedHeader (optional)
//!   Payload

//! @brief The storage header used in DLT files (16 bytes)
align(1) struct StorageHeader
{
    char[4] pattern; // "DLT\01"
    uint seconds;
    uint microseconds;
    char[4] ecuId;
}

//! @brief Mark for beginning of DLT message
enum char[4] DLT_PATTERN = ['D', 'L', 'T', '\01'];

//! @brief Fixed part of the Standard Header (4 bytes)
align(1) struct StandardHeader
{
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

    ubyte headerType;
    ubyte messageCounter;
    ushort length; // Total length of the message

    bool useExtendedHeader() const pure nothrow @nogc
    {
        return (headerType & Type.UseExtendedHeader) != 0;
    }

    bool isBigEndian() const pure nothrow @nogc
    {
        return (headerType & Type.MostSignificantByteFirst) != 0;
    }

    bool withEcuId() const pure nothrow @nogc
    {
        return (headerType & Type.WithEcuId) != 0;
    }

    bool withSessionId() const pure nothrow @nogc
    {
        return (headerType & Type.WithSessionId) != 0;
    }

    bool withTimestamp() const pure nothrow @nogc
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
    ushort nativeLength() const pure nothrow @nogc
    {
        // Parse length (big endian usually in DLT, assume NATIVE for now or need bswap)
        // TODO: Handle Endianness properly based on system and file? 
        // DLT standard says Standard Header fields are Big Endian? 
        // Actually Storage Header is usually Little Endian (x86).
        // Standard Header fields are Big Endian.

        //if (headerType & StandardHeader.Type.MostSignificantByteFirst)
        //    return bigEndianToNative(length);
        //else
        //    return littleEndianToNative(length);
        return bigEndianToNative(length);
    }
}

enum MessageType : ubyte
{
    Log = 0x00, //< Log message type
    AppTrace = 0x01, //< Application trace message type
    NwTrace = 0x02, //< Network trace message type
    Control = 0x03, //< Control message type
}

enum LogLevel : ubyte
{
    Fatal = 0x1,
    Error = 0x2,
    Warn = 0x3,
    Info = 0x4,
    Debug = 0x5,
    Verbose = 0x6
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

    bool isVerbose() const pure nothrow @nogc
    {
        return (info & VerboseMask) != 0;
    }

    MessageType messageType() const pure nothrow @nogc
    {
        return cast(MessageType)((info & MessageTypeMask) >> 1);
    }

    ubyte messageTypeInfo() const pure nothrow @nogc
    {
        return (info & MessageTypeInfoMask) >> 4;
    }

    LogLevel logLevel() const pure nothrow @nogc
    {
        if (isVerbose() && messageType() == MessageType.Log)
        {
            // Verbose: Log Level is in bits 4..6 of info (Wait, standard says Message Type Info?)
            // Standard:
            // Byte 0: Mesage Info
            //   Bit 0: VERB (Verbose)
            //   Bit 1-3: MST (Message Type)
            //   Bit 4-7: MTIN (Message Type Info) -> This contains Log Level if MST=Log
            return cast(LogLevel)(messageTypeInfo());
        }

        return LogLevel.Info; // Default/Unknown for Non-Verbose
    }

    AppTraceType appTraceType() const pure nothrow @nogc
    {
        if (isVerbose() && messageType() == MessageType.AppTrace)
        {
            return cast(AppTraceType)(messageTypeInfo());
        }

        return AppTraceType.Variable;
    }

    NwTraceType nwTraceType() const pure nothrow @nogc
    {
        if (isVerbose() && messageType() == MessageType.NwTrace)
        {
            return cast(NwTraceType)(messageTypeInfo());
        }

        return NwTraceType.ToDo1;
    }

    ControlType controlType() const pure nothrow @nogc
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
    ubyte[4] applicationId; // 4 bytes
    ubyte[4] contextId; // 4 bytes
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
    TypeString = 1 << 8,
    TypeRaw = 1 << 9,
    VariableInfo = 1 << 11,
    FixedPoint = 1 << 12,
    TypeTraceInfo = 1 << 13,
    TypeStruct = 1 << 14,
    StringCodingMask = 0x00000007 << 15, // Bits 15-17
    StringCodingASCII = 0 << 15,
    StringCodingUTF8 = 1 << 15
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
    Error = 0x02
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

private ushort littleEndianToNative(ushort val) pure nothrow @nogc
{
    version (LittleEndian)
        return val;
    else
        return cast(ushort)((val >> 8) | (val << 8));
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
    assert(messageInfo.logLevel() == LogLevel.Info);
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

unittest
{
    import std.stdio;

    writeln("Running DLT Core Tests...");

    // Test 1: Standard Header only
    // HT: 001 (Use Extended) 0 (No) -> 0?
    // Let's verify getHeaderSize

    // Case A: Min Header (UEH=0)
    // HT: 0
    ubyte[] msgA = [0, 0, 0, 0];
    StandardHeader* shA = cast(StandardHeader*) msgA.ptr;
    shA.headerType = 0;
    assert(getHeaderSize(msgA.ptr) == 4);

    // Case B: With ECU ID (WEID=1) -> Bit 2? 
    // StandardHeader.Type Enum: UseExtendedHeader = 1, WithEcuId = 4
    ubyte[] msgB = [0, 0, 0, 0, 65, 66, 67, 68]; // +4 bytes ECU
    StandardHeader* shB = cast(StandardHeader*) msgB.ptr;
    shB.headerType = StandardHeader.Type.WithEcuId; // 4
    assert(getHeaderSize(msgB.ptr) == 8);

    // Case C: Extended Header
    // HT: UseExtendedHeader (1)
    ubyte[] msgC = new ubyte[4 + 10]; // 4 std + 10 ext
    StandardHeader* shC = cast(StandardHeader*) msgC.ptr;
    shC.headerType = StandardHeader.Type.UseExtendedHeader;
    assert(getHeaderSize(msgC.ptr) == 14);

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

    writeln("DLT Core Tests Passed.");
}
