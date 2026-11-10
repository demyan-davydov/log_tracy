//! The protocol of the debug channel (ui/debug_channel, debug builds only): requests and
//! responses are lines of JSON over a TCP connection. Sciter-free, so it is tested here.
//!
//! A request: {"eval": "<js>"} runs the code in the window and answers the value of its last
//! expression ({"result": ...}) or what it threw ({"error": "..."}); {"shot": "<file.png>"}
//! renders the window into that file. Every request gets one response line.
module ui.debug_protocol;

import std.json : JSONValue;

/// What a request asks for
enum RequestKind
{
    eval, /// run code in the window: `text` is the code
    shot, /// render the window into a PNG file: `text` is its path
}

/// A request of a client
struct DebugRequest
{
    RequestKind kind;
    string text;
}

/// The request of a `line`; false and why in `error` if the line is no request
bool parseRequest(const(char)[] line, out DebugRequest request, out string error)
{
    import std.json : JSONException, JSONType, parseJSON;
    import std.traits : EnumMembers;
    import std.conv : to;

    enum known = `{"eval": "<js>"} or {"shot": "<file.png>"}`;
    JSONValue json;
    try
        json = parseJSON(line);
    catch (JSONException e)
    {
        error = "not JSON: " ~ e.msg ~ "; a request is " ~ known;
        return false;
    }
    if (json.type != JSONType.object || json.object.length != 1)
    {
        error = "a request is one of " ~ known;
        return false;
    }
    foreach (kind; EnumMembers!RequestKind)
        if (const value = kind.to!string in json.object)
        {
            if (value.type != JSONType.string)
            {
                error = `"` ~ kind.to!string ~ `" takes a string`;
                return false;
            }
            request = DebugRequest(kind, value.str);
            return true;
        }
    error = "unknown request; a request is one of " ~ known;
    return false;
}

/// The script SciterEval runs for an eval request: debug-eval.js called with `code`. Its value
/// is the response line.
string evalScript(string code)
{
    return import("debug-eval.js") ~ "(" ~ JSONValue(code).toString() ~ ")";
}

/// The script SciterEval runs for a shot request: its value is the window rendered as PNG bytes
/// (an ArrayBuffer, bytes for SciterEval)
enum string shotScript = `(function () {
    const [width, height] = document.state.box("dimension");
    return new Graphics.Image(width, height, document).toBytes("png");
})()`;

/// A response line with `result`, without the line end
string resultLine(JSONValue result)
{
    return JSONValue(["result": result]).toString();
}

/// A response line with an error, without the line end
string errorLine(string message)
{
    return JSONValue(["error": message]).toString();
}

/// What a script run on the window's thread gave
struct WindowRun
{
    string error; /// the script didn't run (SciterEval failed, the window didn't answer in time)
    bool isText; /// its value was a string: `text`
    string text; /// its value as a string
    const(ubyte)[] bytes; /// its value was bytes
}

/// The response line of an eval request whose script gave `run`: the line debug-eval.js made
string evalResponse(const WindowRun run)
{
    if (run.error.length)
        return errorLine(run.error);
    if (!run.isText)
        return errorLine("the eval script gave no text: " ~ run.text);
    return run.text;
}

/// The response line of a shot request into `path` whose script gave `run`; the image is
/// written by `write` (std.file in the channel), which throws when it can't
string shotResponse(const WindowRun run, string path,
    scope void delegate(string path, const(ubyte)[] image) write)
{
    if (run.error.length)
        return errorLine(run.error);
    if (run.bytes is null)
        return errorLine("the window gave no image: " ~ run.text);
    try
        write(path, run.bytes);
    catch (Exception e)
        return errorLine("can't write the shot to " ~ path ~ ": " ~ e.msg);
    return resultLine(JSONValue(["path": JSONValue(path), "bytes": JSONValue(run.bytes.length)]));
}

/// The port of the channel from SCITER_DEBUG_PORT: 0 is any free port; false if `text` is no
/// port number
bool parsePort(const(char)[] text, out ushort port)
{
    import std.conv : ConvException, to;

    try
        port = text.to!ushort;
    catch (ConvException)
        return false;
    return true;
}

/// The lines of a connection out of the bytes as they come: a line ends with "\n" ("\r\n" too)
struct LineReader
{
    private char[] _buffer;
    private size_t _start; // the lines before it are taken

    /// Takes the bytes received
    void put(const(char)[] bytes)
    {
        import core.stdc.string : memmove;

        // The lines taken are dropped here, once per receive: what is moved is at most a part
        // of a line, and the buffer is reused instead of growing with the connection
        const rest = _buffer.length - _start;
        if (_start > 0)
        {
            memmove(_buffer.ptr, _buffer.ptr + _start, rest);
            _buffer.length = rest;
            _buffer.assumeSafeAppend();
            _start = 0;
        }
        _buffer ~= bytes;
    }

    /// The next complete line, without its end; false while there is none
    bool next(out string line)
    {
        import std.string : indexOf;

        const found = _buffer[_start .. $].indexOf('\n');
        if (found < 0)
            return false;
        auto text = _buffer[_start .. _start + found];
        if (text.length && text[$ - 1] == '\r')
            text = text[0 .. $ - 1];
        line = text.idup;
        _start += found + 1;
        return true;
    }
}

unittest // requests
{
    DebugRequest request;
    string error;
    assert(parseRequest(`{"eval": "document.title"}`, request, error));
    assert(request == DebugRequest(RequestKind.eval, "document.title"));
    assert(parseRequest(` {"shot":"/tmp/a.png"} `, request, error));
    assert(request == DebugRequest(RequestKind.shot, "/tmp/a.png"));

    foreach (bad; [`not json`, `[1]`, `{}`, `{"eval": 1}`, `{"click": "x"}`, `{"eval": "a", "shot": "b"}`])
    {
        assert(!parseRequest(bad, request, error), bad);
        assert(error.length, bad);
    }
}

unittest // the eval script: the wrapper called with the code as a JSON string
{
    import std.algorithm : endsWith, startsWith;

    const script = evalScript("a\n\"b\"");
    assert(script.startsWith(import("debug-eval.js")), script);
    assert(script.endsWith(`("a\n\"b\"")`), script);
}

unittest // the response of an eval: the script's own line, or why there is none
{
    import std.json : parseJSON;

    assert(evalResponse(WindowRun("", true, `{"result":1}`)) == `{"result":1}`);
    assert(parseJSON(evalResponse(WindowRun("SciterEval failed"))) ["error"].str == "SciterEval failed");
    // the wrapper gave no text: a bug of debug-eval.js, said as such
    assert(parseJSON(evalResponse(WindowRun("", false, "undefined")))["error"].str
        == "the eval script gave no text: undefined");
}

unittest // the response of a shot: the image written, or why it isn't
{
    import std.json : parseJSON;

    string writtenTo;
    const(ubyte)[] written;
    void write(string path, const(ubyte)[] image)
    {
        writtenTo = path;
        written = image;
    }

    const ubyte[3] png = [1, 2, 3];
    auto ok = parseJSON(shotResponse(WindowRun("", false, "", png[]), "/s/a.png", &write));
    assert(ok["result"]["path"].str == "/s/a.png" && ok["result"]["bytes"].integer == 3);
    assert(writtenTo == "/s/a.png" && written == png[]);

    writtenTo = null;
    assert(parseJSON(shotResponse(WindowRun("timed out"), "/s/a.png", &write))["error"].str == "timed out");
    assert(parseJSON(shotResponse(WindowRun("", true, "null"), "/s/a.png", &write))["error"].str
        == "the window gave no image: null");
    assert(writtenTo is null); // nothing written without an image

    void refuse(string, const(ubyte)[])
    {
        throw new Exception("read-only");
    }
    assert(parseJSON(shotResponse(WindowRun("", false, "", png[]), "/s/a.png", &refuse))["error"].str
        == "can't write the shot to /s/a.png: read-only");
}

unittest // responses
{
    import std.json : parseJSON;

    const result = parseJSON(resultLine(JSONValue(["path": JSONValue("/a.png"), "bytes": JSONValue(10)])));
    assert(result["result"]["path"].str == "/a.png" && result["result"]["bytes"].integer == 10);
    const line = errorLine("bad \"x\"\nline");
    assert(parseJSON(line)["error"].str == "bad \"x\"\nline");
    assert(line[$ - 1] != '\n');
}

unittest // ports
{
    ushort port;
    assert(parsePort("4567", port) && port == 4567);
    assert(parsePort("0", port) && port == 0);
    foreach (bad; ["", "x", "-1", "65536", "12 "])
        assert(!parsePort(bad, port), bad);
}

unittest // lines come in parts
{
    LineReader reader;
    string line;
    assert(!reader.next(line));
    reader.put(`{"eval":`);
    assert(!reader.next(line));
    reader.put("1}\r\n{\"shot\"");
    assert(reader.next(line) && line == `{"eval":1}`);
    assert(!reader.next(line));
    reader.put(":\"a\"}\n\n");
    assert(reader.next(line) && line == `{"shot":"a"}`);
    assert(reader.next(line) && line == ""); // an empty line is a line: it gets an error
    assert(!reader.next(line));
}
