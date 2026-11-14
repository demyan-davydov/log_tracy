//! Reads FIBEX files: the descriptions of the non-verbose DLT messages by their message ID,
//! the subset of FIBEX the tools of DLT generate. A FRAME "ID_<message id>" is a
//! message: its type, level, AppId and CtxId from its MANUFACTURER-EXTENSION and its parts in
//! the order of its PDU-REFs; a PDU is a static text (DESC) or a value, of the type its
//! SIGNAL-REF names (S_UINT16, S_STRG_ASCII, ...) and of its BYTE-LENGTH. A Fibex is never
//! changed once read: the threads of a document's format look it up concurrently.
module formats.dlt.fibex;

import formats.dlt.protocol : MessageType;
import log_core.log_level : LogLevel;
import utils.ui_text : uiText, uiTextOf, UiTextException;

//! What a value part of a message is in the payload
enum FibexValue : ubyte
{
    text, //< not a value: the static text of the part
    boolean,
    unsigned,
    signed,
    floating,
    ascii, //< a string, its length in 2 bytes before it
    utf8, //< a string, its length in 2 bytes before it
    raw, //< bytes, their length in 2 bytes before them
    unknown, //< a signal of no known type: `byteLength` bytes
}

//! A part of a message: a static text or a value read from the payload
struct FibexPart
{
    FibexValue value;
    string text; //< of FibexValue.text
    uint byteLength; //< of a value of fixed length
}

//! The description of a non-verbose message
struct FibexMessage
{
    uint id;
    string appId, ctxId;
    MessageType type;
    LogLevel level; //< of a log message, None for another type
    string sourceFile;
    uint line;
    immutable(FibexPart)[] parts;
}

//! The messages of one or more FIBEX files
final class Fibex
{
    private immutable(FibexMessage)[] _messages;
    private size_t[uint] _byId; // the first message of each ID
    private size_t[Key] _byKey;
    private string[] _duplicates;

    // The IDs whole: those of version 2 have any length
    private static struct Key
    {
        uint id;
        string appId;
        string ctxId;
    }

    private this()
    {
    }

    //! How many messages it describes
    size_t length() const pure nothrow @nogc @safe
    {
        return _messages.length;
    }

    //! The frames left out because one with their ID, AppId and CtxId came before, by the
    //! ID of the frame ("ID_11"); the first one is kept
    const(string)[] duplicates() const pure nothrow @nogc @safe
    {
        return _duplicates;
    }

    //! @brief The description of message `id`: of the ID, AppId and CtxId if the message has
    //! both, otherwise the first one of the ID
    //! @returns null if there is none
    const(FibexMessage)* find(uint id, scope const(char)[] appId, scope const(char)[] ctxId)
        const nothrow @nogc @trusted
    {
        // The key only looks up: its IDs are not kept
        const(size_t)* at = appId.length && ctxId.length
            ? Key(id, cast(string) appId, cast(string) ctxId) in _byKey : id in _byId;
        return at is null ? null : &_messages[*at];
    }

    // Adds `m` unless a message of its ID, AppId and CtxId is in already; `frameId` names it
    // then
    private void add(immutable FibexMessage m, string frameId)
    {
        const key = Key(m.id, m.appId, m.ctxId);
        if (key in _byKey)
        {
            _duplicates ~= frameId.idup; // a slice of the text would keep it alive
            return;
        }
        _byKey[key] = _messages.length;
        if (m.id !in _byId)
            _byId[m.id] = _messages.length;
        _messages ~= m;
    }
}

//! @brief Reads the FIBEX file at `path`, or every `*.xml` of the folder at `path`
//! @throws Exception if a file can't be read or isn't FIBEX
immutable(Fibex) loadFibex(string path)
{
    import std.algorithm : filter, map, sort;
    import std.array : array;
    import std.file : dirEntries, isDir, readText, SpanMode;
    import std.path : extension;
    import std.uni : toLower;

    string[] files = [path];
    bool folder;
    try
        folder = isDir(path);
    catch (Exception e)
        throw new UiTextException(uiText("can't read the FIBEX file {file}: {reason}",
                "file", path, "reason", uiTextOf(e)));
    if (folder)
    {
        try
            files = dirEntries(path, SpanMode.shallow)
                .filter!(e => e.isFile && e.name.extension.toLower == ".xml")
                .map!(e => e.name)
                .array;
        catch (Exception e)
            throw new UiTextException(uiText("can't read the FIBEX folder {folder}: {reason}",
                    "folder", path, "reason", uiTextOf(e)));
        sort(files);
        if (!files.length)
            throw new UiTextException(uiText("no FIBEX files (*.xml) in {folder}", "folder", path));
    }
    auto fibex = new Fibex;
    foreach (file; files)
    {
        try
            readInto(fibex, readText(file));
        catch (Exception e)
            throw new UiTextException(uiText("can't read the FIBEX file {file}: {reason}",
                    "file", file, "reason", uiTextOf(e)));
    }
    return frozen(fibex);
}

//! @brief Reads FIBEX files from their texts; a PDU is referred to only from its own file, the
//! frames of all of them are looked up together
//! @throws Exception if one isn't FIBEX
immutable(Fibex) parseFibex(scope const(string)[] texts...)
{
    auto fibex = new Fibex;
    foreach (text; texts)
        readInto(fibex, text);
    return frozen(fibex);
}

// `fibex` once read, never changed again: nothing else refers to it
private immutable(Fibex) frozen(Fibex fibex) pure nothrow @nogc @trusted
{
    return cast(immutable) fibex;
}

// A PDU as it is read, before a frame refers to it
private struct PduDraft
{
    string id;
    string text; // DESC
    FibexValue value = FibexValue.unknown;
    uint byteLength;
    uint signalSize; // of a value of fixed size by its signal, used if BYTE-LENGTH is 0
}

// A FRAME as it is read
private struct FrameDraft
{
    string id;
    string appId, ctxId;
    MessageType type;
    LogLevel level;
    string sourceFile;
    uint line;
    string[] pduRefs;
}

// Adds the messages of the FIBEX `text` to `fibex`. An element is taken by its name wherever
// it is, inside the PDU or the FRAME being read
private void readInto(Fibex fibex, string text)
{
    import dxml.parser : EntityType, parseXML, simpleXML;

    if (text.length >= 3 && text[0 .. 3] == "\uFEFF")
        text = text[3 .. $];
    auto entities = parseXML!simpleXML(text); // throws XMLParsingException
    if (localName(entities.front.name) != "FIBEX")
        throw new UiTextException(uiText("its root element is <{root}>, not <FIBEX>",
                "root", entities.front.name));

    PduDraft[string] pdus;
    FrameDraft[] frames;
    PduDraft pdu;
    bool inPdu;
    FrameDraft* frame;
    for (; !entities.empty; entities.popFront())
    {
        const type = entities.front.type;
        if (type != EntityType.elementStart && type != EntityType.elementEnd)
            continue;
        const name = localName(entities.front.name);
        if (type == EntityType.elementEnd)
        {
            if (name == "PDU" && inPdu)
            {
                pdus[pdu.id] = pdu;
                inPdu = false;
            }
            else if (name == "FRAME")
                frame = null;
            continue;
        }
        switch (name)
        {
        case "PDU":
            if (!inPdu)
            {
                pdu = PduDraft(attribute(entities.front, "ID"));
                inPdu = true;
            }
            break;
        case "DESC":
            if (inPdu)
                pdu.text = textOf(entities);
            break;
        case "BYTE-LENGTH":
            if (inPdu)
                pdu.byteLength = numberOf(textOf(entities));
            break;
        case "SIGNAL-REF":
            if (inPdu)
            {
                const signal = attribute(entities.front, "ID-REF");
                pdu.value = valueOfSignal(signal);
                pdu.signalSize = sizeOfSignal(signal);
            }
            break;
        case "FRAME":
            if (frame is null)
            {
                frames ~= FrameDraft(attribute(entities.front, "ID"));
                frame = &frames[$ - 1];
            }
            break;
        case "MESSAGE_TYPE":
            if (frame !is null)
                frame.type = messageTypeOf(textOf(entities));
            break;
        case "MESSAGE_INFO":
            if (frame !is null)
                frame.level = levelOf(textOf(entities));
            break;
        case "APPLICATION_ID":
            if (frame !is null)
                frame.appId = textOf(entities);
            break;
        case "CONTEXT_ID":
            if (frame !is null)
                frame.ctxId = textOf(entities);
            break;
        case "MESSAGE_SOURCE_FILE":
            if (frame !is null)
                frame.sourceFile = textOf(entities);
            break;
        case "MESSAGE_LINE_NUMBER":
            if (frame !is null)
                frame.line = numberOf(textOf(entities));
            break;
        case "PDU-REF":
            if (frame !is null)
                frame.pduRefs ~= attribute(entities.front, "ID-REF");
            break;
        default:
            break;
        }
    }

    foreach (ref f; frames)
    {
        uint id;
        if (!messageIdOf(f.id, id))
            continue;
        FibexPart[] parts;
        foreach (ref_; f.pduRefs)
            if (auto p = ref_ in pdus)
                parts ~= p.text.length ? FibexPart(FibexValue.text, p.text)
                    : FibexPart(p.value, null, p.byteLength ? p.byteLength : p.signalSize);
        fibex.add(immutable FibexMessage(id, f.appId, f.ctxId,
                f.type, f.type == MessageType.Log ? f.level : LogLevel.None,
                f.sourceFile, f.line, parts.idup), f.id);
    }
}

// The name of an element without its namespace prefix
private string localName(string name) pure nothrow @nogc @safe
{
    foreach_reverse (i, c; name)
        if (c == ':')
            return name[i + 1 .. $];
    return name;
}

// The value of attribute `name` of the element `entity`, decoded; empty if it has none
private string attribute(Entity)(Entity entity, string name)
{
    import dxml.util : decodeXML;

    foreach (a; entity.attributes)
        if (localName(a.name) == name)
            return decodeXML(a.value);
    return null;
}

// The text of the element at the front of `entities`, decoded and stripped, the range left at
// its end; the texts of the elements inside it are left out
private string textOf(Entities)(ref Entities entities)
{
    import dxml.parser : EntityType;
    import dxml.util : decodeXML;
    import std.string : strip;

    string text;
    size_t depth = 0;
    for (entities.popFront(); !entities.empty; entities.popFront())
    {
        final switch (entities.front.type)
        {
        case EntityType.elementStart:
            depth++;
            break;
        case EntityType.elementEnd:
            if (depth == 0)
                return strip(text);
            depth--;
            break;
        case EntityType.text:
            if (depth == 0)
                text ~= decodeXML(entities.front.text);
            break;
        case EntityType.cdata:
            if (depth == 0)
                text ~= entities.front.text;
            break;
        case EntityType.comment, EntityType.pi, EntityType.elementEmpty:
            break;
        }
    }
    return strip(text);
}

// `text` as a number, 0 if it isn't one
private uint numberOf(string text) pure @safe
{
    import std.conv : ConvException, to;

    try
        return text.to!uint;
    catch (ConvException)
        return 0;
}

// The message ID of the frame `frameId` ("ID_<decimal>")
private bool messageIdOf(string frameId, out uint id) pure @safe
{
    import std.algorithm : all, startsWith;
    import std.ascii : isDigit;
    import std.conv : ConvException, to;

    if (!frameId.startsWith("ID_") || frameId.length == 3 || !frameId[3 .. $].all!isDigit)
        return false;
    try
        id = frameId[3 .. $].to!uint;
    catch (ConvException)
        return false;
    return true;
}

// The type of a value by the name of its signal, as the tools of DLT name them
private FibexValue valueOfSignal(string signal) pure nothrow @nogc @safe
{
    switch (signal)
    {
    case "S_BOOL":
        return FibexValue.boolean;
    case "S_SINT8", "S_SINT16", "S_SINT32", "S_SINT64":
        return FibexValue.signed;
    case "S_UINT8", "S_UINT16", "S_UINT32", "S_UINT64":
        return FibexValue.unsigned;
    case "S_FLOA16", "S_FLOA32", "S_FLOA64":
        return FibexValue.floating;
    case "S_STRG_ASCII":
        return FibexValue.ascii;
    case "S_STRG_UTF8":
        return FibexValue.utf8;
    case "S_RAWD", "S_RAW":
        return FibexValue.raw;
    default:
        return FibexValue.unknown;
    }
}

// The size of a value of fixed size by the name of its signal, 0 for another one
private uint sizeOfSignal(string signal) pure nothrow @nogc @safe
{
    switch (signal)
    {
    case "S_BOOL", "S_SINT8", "S_UINT8":
        return 1;
    case "S_SINT16", "S_UINT16", "S_FLOA16":
        return 2;
    case "S_SINT32", "S_UINT32", "S_FLOA32":
        return 4;
    case "S_SINT64", "S_UINT64", "S_FLOA64":
        return 8;
    default:
        return 0;
    }
}

// The type of a message by its name in MESSAGE_TYPE
private MessageType messageTypeOf(string name) pure nothrow @nogc @safe
{
    switch (name)
    {
    case "DLT_TYPE_APP_TRACE":
        return MessageType.AppTrace;
    case "DLT_TYPE_NW_TRACE":
        return MessageType.NwTrace;
    case "DLT_TYPE_CONTROL":
        return MessageType.Control;
    default:
        return MessageType.Log;
    }
}

// The level of a log message by its name in MESSAGE_INFO
private LogLevel levelOf(string name) pure nothrow @nogc @safe
{
    switch (name)
    {
    case "DLT_LOG_FATAL":
        return LogLevel.Fatal;
    case "DLT_LOG_ERROR":
        return LogLevel.Error;
    case "DLT_LOG_WARN":
        return LogLevel.Warn;
    case "DLT_LOG_INFO":
        return LogLevel.Info;
    case "DLT_LOG_DEBUG":
        return LogLevel.Debug;
    case "DLT_LOG_VERBOSE":
        return LogLevel.Verbose;
    default:
        return LogLevel.None;
    }
}

version (unittest)
{
    import std.conv : octal;

    // A FIBEX of the usual layout: `pdus` and `frames` inside; also for the tests of the decoding,
    // the registry and the documents
    string fibexOf(string pdus, string frames)
    {
        return `<?xml version="1.0"?>
<fx:FIBEX xmlns:fx="http://www.asam.net/xml/fbx" xmlns:ho="http://www.asam.net/xml" VERSION="3.1.0">
  <!-- a comment -->
  <fx:ELEMENTS>
    <fx:PDUS>` ~ pdus ~ `</fx:PDUS>
    <fx:FRAMES>` ~ frames ~ `</fx:FRAMES>
  </fx:ELEMENTS>
</fx:FIBEX>`;
    }

    string textPdu(string id, string text)
    {
        return `<fx:PDU ID="` ~ id ~ `"><ho:SHORT-NAME>` ~ id ~ `</ho:SHORT-NAME><ho:DESC>` ~ text
            ~ `</ho:DESC><fx:BYTE-LENGTH>0</fx:BYTE-LENGTH><fx:PDU-TYPE>OTHER</fx:PDU-TYPE></fx:PDU>`;
    }

    string valuePdu(string id, string signal, uint byteLength)
    {
        import std.conv : to;

        return `<fx:PDU ID="` ~ id ~ `"><ho:SHORT-NAME>` ~ id ~ `</ho:SHORT-NAME><fx:BYTE-LENGTH>`
            ~ byteLength.to!string ~ `</fx:BYTE-LENGTH><fx:PDU-TYPE>OTHER</fx:PDU-TYPE>
            <fx:SIGNAL-INSTANCES><fx:SIGNAL-INSTANCE ID="S_` ~ id ~ `">
              <fx:SEQUENCE-NUMBER>0</fx:SEQUENCE-NUMBER><fx:SIGNAL-REF ID-REF="` ~ signal ~ `"/>
            </fx:SIGNAL-INSTANCE></fx:SIGNAL-INSTANCES></fx:PDU>`;
    }

    string frame(string id, string type, string info, string app, string ctx,
        const(string)[] pdus...)
    {
        string refs;
        foreach (pdu; pdus)
            refs ~= `<fx:PDU-INSTANCE ID="P_` ~ pdu ~ `"><fx:PDU-REF ID-REF="` ~ pdu
                ~ `"/><fx:SEQUENCE-NUMBER>0</fx:SEQUENCE-NUMBER></fx:PDU-INSTANCE>`;
        return `<fx:FRAME ID="` ~ id ~ `"><ho:SHORT-NAME>` ~ id
            ~ `</ho:SHORT-NAME><fx:BYTE-LENGTH>0</fx:BYTE-LENGTH><fx:FRAME-TYPE>OTHER</fx:FRAME-TYPE>
            <fx:PDU-INSTANCES>` ~ refs ~ `</fx:PDU-INSTANCES>
            <fx:MANUFACTURER-EXTENSION>
              <MESSAGE_TYPE>` ~ type ~ `</MESSAGE_TYPE>
              <MESSAGE_INFO>` ~ info ~ `</MESSAGE_INFO>
              <APPLICATION_ID>` ~ app ~ `</APPLICATION_ID>
              <CONTEXT_ID>` ~ ctx ~ `</CONTEXT_ID>
              <MESSAGE_SOURCE_FILE>main.c</MESSAGE_SOURCE_FILE>
              <MESSAGE_LINE_NUMBER>42</MESSAGE_LINE_NUMBER>
            </fx:MANUFACTURER-EXTENSION></fx:FRAME>`;
    }

    string logFrame(string id, string app, string ctx, const(string)[] pdus...)
    {
        return frame(id, "DLT_TYPE_LOG", "DLT_LOG_INFO", app, ctx, pdus);
    }
}

@("parseFibex: a message of a static text, its header fields from the frame")
unittest
{
    const fibex = parseFibex(fibexOf(textPdu("PDU_10_0", "Started."),
            frame("ID_10", "DLT_TYPE_LOG", "DLT_LOG_WARN", "APP1", "CON1", "PDU_10_0")));
    assert(fibex.length == 1, "one frame, one message");
    const m = fibex.find(10, "APP1", "CON1");
    assert(m !is null, "found by its ID, AppId and CtxId");
    assert(m.id == 10 && m.appId == "APP1" && m.ctxId == "CON1");
    assert(m.type == MessageType.Log && m.level == LogLevel.Warn);
    assert(m.sourceFile == "main.c" && m.line == 42);
    assert(m.parts == [FibexPart(FibexValue.text, "Started.")]);
}

@("parseFibex: the parts in the order of the PDU-REFs, a value of its BYTE-LENGTH")
unittest
{
    const fibex = parseFibex(fibexOf(textPdu("PDU_11_0", "Free size:")
            ~ valuePdu("PDU_11_1", "S_UINT16", 2) ~ textPdu("PDU_11_2", "bytes"),
            logFrame("ID_11", "APP1", "CON1", "PDU_11_0", "PDU_11_1", "PDU_11_2")));
    const m = fibex.find(11, "APP1", "CON1");
    assert(m !is null);
    assert(m.parts == [
        FibexPart(FibexValue.text, "Free size:"),
        FibexPart(FibexValue.unsigned, null, 2),
        FibexPart(FibexValue.text, "bytes"),
    ]);
}

@("parseFibex: the type of a value by the name of its signal, of an unknown one its bytes")
unittest
{
    const FibexValue[string] kinds = [
        "S_BOOL": FibexValue.boolean,
        "S_SINT8": FibexValue.signed, "S_UINT8": FibexValue.unsigned,
        "S_SINT16": FibexValue.signed, "S_UINT16": FibexValue.unsigned,
        "S_SINT32": FibexValue.signed, "S_UINT32": FibexValue.unsigned,
        "S_SINT64": FibexValue.signed, "S_UINT64": FibexValue.unsigned,
        "S_FLOA16": FibexValue.floating, "S_FLOA32": FibexValue.floating,
        "S_FLOA64": FibexValue.floating,
        "S_STRG_ASCII": FibexValue.ascii, "S_STRG_UTF8": FibexValue.utf8,
        "S_RAWD": FibexValue.raw, "S_RAW": FibexValue.raw,
        "S_MY_STRUCT": FibexValue.unknown,
    ];
    foreach (signal, kind; kinds)
    {
        const fibex = parseFibex(fibexOf(valuePdu("PDU_1", signal, 3),
                logFrame("ID_1", "APP1", "CON1", "PDU_1")));
        const m = fibex.find(1, "APP1", "CON1");
        assert(m !is null && m.parts.length == 1, signal);
        assert(m.parts[0].value == kind && m.parts[0].byteLength == 3, signal);
    }
}

@("parseFibex: the type and the level of a message by their names")
unittest
{
    import std.typecons : tuple;

    foreach (c; [
        tuple("DLT_TYPE_LOG", "DLT_LOG_FATAL", MessageType.Log, LogLevel.Fatal),
        tuple("DLT_TYPE_LOG", "DLT_LOG_ERROR", MessageType.Log, LogLevel.Error),
        tuple("DLT_TYPE_LOG", "DLT_LOG_INFO", MessageType.Log, LogLevel.Info),
        tuple("DLT_TYPE_LOG", "DLT_LOG_DEBUG", MessageType.Log, LogLevel.Debug),
        tuple("DLT_TYPE_LOG", "DLT_LOG_VERBOSE", MessageType.Log, LogLevel.Verbose),
        tuple("DLT_TYPE_LOG", "DLT_LOG_DEFAULT", MessageType.Log, LogLevel.None),
        tuple("DLT_TYPE_LOG", "DLT_LOG_OFF", MessageType.Log, LogLevel.None),
        tuple("DLT_TYPE_APP_TRACE", "DLT_TRACE_VARIABLE", MessageType.AppTrace, LogLevel.None),
        tuple("DLT_TYPE_NW_TRACE", "", MessageType.NwTrace, LogLevel.None),
    ])
    {
        const fibex = parseFibex(fibexOf(textPdu("PDU_1", "x"),
                frame("ID_1", c[0], c[1], "APP1", "CON1", "PDU_1")));
        const m = fibex.find(1, "APP1", "CON1");
        assert(m !is null && m.type == c[2] && m.level == c[3], c[0] ~ " " ~ c[1]);
    }
}

@("Fibex.find: by ID, AppId and CtxId if the message has both, otherwise by ID")
unittest
{
    const fibex = parseFibex(fibexOf(textPdu("PDU_A", "of APP1") ~ textPdu("PDU_B", "of APP2"),
            logFrame("ID_7", "APP1", "CON1", "PDU_A") ~ logFrame("ID_7", "APP2", "CON2", "PDU_B")));
    assert(fibex.length == 2);
    assert(fibex.find(7, "APP2", "CON2").parts[0].text == "of APP2");
    assert(fibex.find(7, "APP1", "CON1").parts[0].text == "of APP1");
    assert(fibex.find(7, "", "").parts[0].text == "of APP1", "the first one of the ID");
    assert(fibex.find(7, "APP3", "CON1") is null, "an AppId and CtxId of no frame");
    assert(fibex.find(8, "", "") is null, "an ID of no frame");
}

@("parseFibex: a frame of the ID, AppId and CtxId of an earlier one is left out and named")
unittest
{
    const fibex = parseFibex(fibexOf(textPdu("PDU_A", "first") ~ textPdu("PDU_B", "second"),
            logFrame("ID_7", "APP1", "CON1", "PDU_A") ~ logFrame("ID_7", "APP1", "CON1", "PDU_B")));
    assert(fibex.length == 1);
    assert(fibex.find(7, "APP1", "CON1").parts[0].text == "first");
    assert(fibex.duplicates == ["ID_7"]);
}

@("parseFibex: a frame whose ID is not ID_<decimal> is not a message")
unittest
{
    const fibex = parseFibex(fibexOf(textPdu("PDU_A", "x"),
            logFrame("ID_x", "APP1", "CON1", "PDU_A") ~ logFrame("FRAME_3", "APP1", "CON1", "PDU_A")
            ~ logFrame("ID_", "APP1", "CON1", "PDU_A") ~ logFrame("ID_99999999999", "APP1",
            "CON1", "PDU_A")));
    assert(fibex.length == 0);
}

@("parseFibex: PDUs after the frames, a reference to no PDU left out")
unittest
{
    const xml = `<fx:FIBEX xmlns:fx="f" xmlns:ho="h"><fx:ELEMENTS><fx:FRAMES>`
        ~ logFrame("ID_5", "APP1", "CON1", "PDU_1", "PDU_MISSING", "PDU_2")
        ~ `</fx:FRAMES><fx:PDUS>` ~ textPdu("PDU_1", "one") ~ textPdu("PDU_2", "two")
        ~ `</fx:PDUS></fx:ELEMENTS></fx:FIBEX>`;
    const m = parseFibex(xml).find(5, "APP1", "CON1");
    assert(m !is null);
    assert(m.parts == [FibexPart(FibexValue.text, "one"), FibexPart(FibexValue.text, "two")]);
}

@("parseFibex: the entities of a text decoded, a byte order mark ignored")
unittest
{
    const xml = "﻿" ~ fibexOf(textPdu("PDU_1", "a &lt; b &amp;&amp; c &#x41;"),
            logFrame("ID_1", "APP1", "CON1", "PDU_1"));
    assert(parseFibex(xml).find(1, "APP1", "CON1").parts[0].text == "a < b && c A");
}

@("parseFibex: several files, a PDU referred to only from its own file, the first frame kept")
unittest
{
    const one = fibexOf(textPdu("PDU_1", "one"), logFrame("ID_1", "APP1", "CON1", "PDU_1"));
    const two = fibexOf(textPdu("PDU_2", "two"),
            logFrame("ID_2", "APP1", "CON1", "PDU_1", "PDU_2")
            ~ logFrame("ID_1", "APP1", "CON1", "PDU_2"));
    const fibex = parseFibex(one, two);
    assert(fibex.length == 2);
    assert(fibex.find(1, "APP1", "CON1").parts == [FibexPart(FibexValue.text, "one")]);
    assert(fibex.find(2, "APP1", "CON1").parts == [FibexPart(FibexValue.text, "two")],
        "PDU_1 is of the other file");
    assert(fibex.duplicates == ["ID_1"]);
}

@("parseFibex: XML that isn't FIBEX or isn't XML is refused")
unittest
{
    import std.exception : assertThrown;

    assertThrown!UiTextException(parseFibex(`<dltfilter><filter/></dltfilter>`));
    assertThrown!Exception(parseFibex(`<fx:FIBEX xmlns:fx="f"><fx:FRAMES>`));
    assertThrown!Exception(parseFibex(`not xml`));
}

@("Fibex.find: AppIds and CtxIds longer than 4 characters (version 2) are told apart")
unittest
{
    const fibex = parseFibex(fibexOf(textPdu("PDU_A", "media") ~ textPdu("PDU_B", "medic"),
            logFrame("ID_7", "MEDIA", "CONTEXT1", "PDU_A") ~ logFrame("ID_7", "MEDIC", "CONTEXT1", "PDU_B")));
    assert(fibex.length == 2 && fibex.duplicates.length == 0);
    assert(fibex.find(7, "MEDIA", "CONTEXT1").parts[0].text == "media");
    assert(fibex.find(7, "MEDIC", "CONTEXT1").parts[0].text == "medic");
    assert(fibex.find(7, "MEDI", "CONTEXT1") is null);
}

@("parseFibex: a value with no BYTE-LENGTH takes the size of its signal")
unittest
{
    const fibex = parseFibex(fibexOf(valuePdu("PDU_1", "S_UINT16", 0) ~ valuePdu("PDU_2", "S_FLOA64", 0)
            ~ valuePdu("PDU_3", "S_BOOL", 0), logFrame("ID_1", "APP1", "CON1", "PDU_1", "PDU_2", "PDU_3")));
    const m = fibex.find(1, "APP1", "CON1");
    assert(m.parts[0].byteLength == 2 && m.parts[1].byteLength == 8 && m.parts[2].byteLength == 1);
}

@("loadFibex: a path that isn't there is refused with a text for the user")
unittest
{
    import std.exception : assertThrown;
    import std.file : tempDir;
    import std.path : buildPath;

    assertThrown!UiTextException(loadFibex(buildPath(tempDir(), "log_tracy_no_such_fibex")));
}

@("parseFibex: the name of a duplicate is a copy, not a slice of the text it was read from")
unittest
{
    const xml = fibexOf(textPdu("PDU_A", "first"),
            logFrame("ID_7", "APP1", "CON1", "PDU_A") ~ logFrame("ID_7", "APP1", "CON1", "PDU_A"));
    const name = parseFibex(xml).duplicates[0];
    assert(name == "ID_7");
    assert(name.ptr < xml.ptr || name.ptr >= xml.ptr + xml.length,
        "a slice would keep the whole text alive as long as the Fibex");
}

@("loadFibex: a folder with no *.xml, a file that isn't FIBEX: a text for the user naming it")
unittest
{
    import std.algorithm : canFind;
    import std.exception : collectException;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;

    const folder = buildPath(tempDir(), "log_tracy_fibex_errors_test");
    mkdirRecurse(folder);
    scope (exit)
        rmdirRecurse(folder);
    write(buildPath(folder, "notes.txt"), "not FIBEX");
    auto none = cast(UiTextException) collectException(loadFibex(folder));
    assert(none !is null && none.msg == "no FIBEX files (*.xml) in " ~ folder, none.msg);

    const filter = buildPath(folder, "filter.xml");
    write(filter, "<dltfilter><filter/></dltfilter>");
    auto wrong = cast(UiTextException) collectException(loadFibex(filter));
    assert(wrong !is null && wrong.msg == "can't read the FIBEX file " ~ filter
        ~ ": its root element is <dltfilter>, not <FIBEX>", wrong.msg);
}

@("loadFibex: a folder that can't be listed: a text for the user naming it")
unittest
{
    version (Posix)
    {
        import core.sys.posix.sys.stat : chmod;
        import std.algorithm : canFind;
        import std.exception : collectException;
        import std.file : mkdirRecurse, rmdirRecurse, tempDir;
        import std.path : buildPath;
        import std.string : toStringz;

        const folder = buildPath(tempDir(), "log_tracy_fibex_unlisted_test");
        mkdirRecurse(folder);
        scope (exit)
        {
            chmod(folder.toStringz, octal!755);
            rmdirRecurse(folder);
        }
        import core.sys.posix.unistd : geteuid;

        if (geteuid() == 0)
            return; // the superuser lists a folder of no permissions: nothing to check
        chmod(folder.toStringz, 0);
        auto e = cast(UiTextException) collectException(loadFibex(folder));
        assert(e !is null && e.text.text == "can't read the FIBEX folder {folder}: {reason}",
            e is null ? "listed: run as a user the permissions stop" : e.msg);
        assert(e.msg.canFind(folder));
    }
}

@("loadFibex: a file, or every *.xml of a folder")
unittest
{
    import std.exception : assertThrown;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;

    const folder = buildPath(tempDir(), "log_tracy_fibex_test");
    mkdirRecurse(folder);
    scope (exit)
        rmdirRecurse(folder);
    const one = buildPath(folder, "one.xml");
    write(one, fibexOf(textPdu("PDU_1", "one"), logFrame("ID_1", "APP1", "CON1", "PDU_1")));
    write(buildPath(folder, "two.XML"),
        fibexOf(textPdu("PDU_2", "two"), logFrame("ID_2", "APP1", "CON1", "PDU_2")));
    write(buildPath(folder, "notes.txt"), "not FIBEX");

    assert(loadFibex(one).length == 1);
    const all = loadFibex(folder);
    assert(all.length == 2);
    assert(all.find(2, "APP1", "CON1").parts[0].text == "two");
    assertThrown!Exception(loadFibex(buildPath(folder, "none.xml")));
}
