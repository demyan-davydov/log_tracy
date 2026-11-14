//! The protocol of the debug channel (ui/debug_channel, debug builds only): requests and
//! responses are lines of JSON over a TCP connection. Sciter-free, so it is tested here.
//!
//! A request: {"eval": "<js>"} runs the code in the window and answers the value of its last
//! expression ({"result": ...}) or what it threw ({"error": "..."}); {"shot": "<file.png>"}
//! renders the window into that file, and each open popup into a file beside it;
//! {"hover": "<x> <y>"} moves the mouse there (dips of the window from its top left),
//! {"key": "<combination>"} presses a key ("Cmd+A", utils/keys), {"type": "<text>"}
//! types a text, as events of the system (macOS only). Every request gets one response line.
module ui.debug_protocol;

import std.json : JSONValue;
import utils.keys : KeyPress;

/// What a request asks for
enum RequestKind
{
    eval, /// run code in the window: `text` is the code
    shot, /// render the window into a PNG file: `text` is its path
    hover, /// move the mouse over the window: `text` is "<x> <y>" (`parsePoint`)
    key, /// press and release a key: `text` is its combination (utils/keys)
    type, /// type a text, a key a character: `text` is the text
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

    enum known = `{"eval": "<js>"}, {"shot": "<file.png>"}, {"hover": "<x> <y>"}, {"key": "<combination>"}`
        ~ ` or {"type": "<text>"}`;
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

/// The point of a hover request: "<x> <y>", numbers of dips of the window from its top left;
/// false and why in `error` if `text` is none
bool parsePoint(string text, out double x, out double y, out string error)
{
    import std.array : split;
    import std.conv : ConvException, to;
    import std.math : isFinite;

    const parts = text.split;
    error = `a point is "<x> <y>", dips of the window from its top left, not "` ~ text ~ `"`;
    if (parts.length != 2)
        return false;
    try
    {
        x = parts[0].to!double;
        y = parts[1].to!double;
    }
    catch (ConvException)
        return false;
    if (!x.isFinite || !y.isFinite || x < 0 || y < 0)
        return false;
    error = null;
    return true;
}

/// What an input request (hover, key, type) hands the window as events of the system
struct InputRequest
{
    bool isHover; /// the mouse moved to (`x`, `y`), else `presses`
    double x, y; /// dips of the window from its top left
    KeyPress[] presses; /// keys pressed and released in order
}

/// The input of a hover, key or type request; false and why in `error` if its text is wrong
/// or it is no input request
bool parseInput(const DebugRequest request, out InputRequest input, out string error)
{
    import utils.keys : parseKeyPress, typingPresses;

    switch (request.kind)
    {
    case RequestKind.hover:
        input.isHover = true;
        return parsePoint(request.text, input.x, input.y, error);
    case RequestKind.key:
        KeyPress press;
        if (!parseKeyPress(request.text, press, error))
            return false;
        input.presses = [press];
        return true;
    case RequestKind.type:
        input.presses = typingPresses(request.text);
        return true;
    default:
        error = "not an input request";
        return false;
    }
}

/// Hands the window `input` on its thread: the mouse through `move`, each key through
/// `press`, stopping at the first that can't be handed (what they give: null, or why not).
/// Null, or why not
string sendInput(const InputRequest input, scope string delegate(double x, double y) move,
    scope string delegate(in KeyPress press) press)
{
    if (input.isHover)
        return move(input.x, input.y);
    foreach (key; input.presses)
        if (const why = press(key))
            return why;
    return null;
}

/// The response line of a request handed to the window as events of the system (hover, key,
/// type) whose run gave `run`: true, or why not
string inputResponse(const WindowRun run)
{
    return run.error.length ? errorLine(run.error) : resultLine(JSONValue(true));
}

/// The script SciterEval runs for an eval request: debug-eval.js called with `code`. Its value
/// is JSON text of what the code gave, {"value": ...} or {"thrown": "..."} (`evalResponse`).
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
    string error; /// the work didn't run: SciterEval failed, the window didn't answer in time,
                  /// the events of an input request couldn't be handed to it
    bool isText; /// its value was a string: `text`
    string text; /// its value as a string
    const(ubyte)[] bytes; /// its value was bytes
}

/// The response line of an eval request whose script gave `run`: the value of the code as the
/// result, what it threw as the error
string evalResponse(const WindowRun run)
{
    import std.json : JSONException, JSONType, parseJSON;

    if (run.error.length)
        return errorLine(run.error);
    if (!run.isText)
        return errorLine("the eval script gave no text: " ~ run.text);
    try
    {
        auto json = parseJSON(run.text);
        if (json.type == JSONType.object && json.object.length == 1)
        {
            if (auto value = "value" in json.object)
                return resultLine(*value);
            if (auto thrown = "thrown" in json.object)
                if (thrown.type == JSONType.string)
                    return errorLine(thrown.str);
        }
    }
    catch (JSONException)
    {
    }
    return errorLine("the eval script gave no value: " ~ run.text);
}

/// The script SciterEval runs to list the open popups: their summaries as debug-eval.js makes
/// them ({tag, id, class, text, box}), in the order of `popupShotScript`
enum string popupsCode = `Array.from(document.$$(":popup"))`;

/// The script SciterEval runs for the image of the open popup number `index` (from 0, in the
/// order of `popupsCode`), listed with `tag`, `className` and `box` (in the window; not
/// compared when it is no array): PNG bytes of its border box, null if it is no longer open
/// (another popup at that number, of another tag, class or place, is taken for closed: one
/// before it closed)
string popupShotScript(size_t index, string tag, string className, const JSONValue box)
{
    import std.conv : to;
    import std.json : JSONType;

    return `(function () {
    const popup = document.$$(":popup")[` ~ index.to!string ~ `];
    if (!popup || String(popup.tagName).toLowerCase() !== ` ~ JSONValue(tag).toString
        ~ ` || String(popup.className ?? "") !== ` ~ JSONValue(className).toString ~ `) return null;
    const listed = ` ~ (box.type == JSONType.array ? box.toString : "null") ~ `;
    if (listed) {
        const now = popup.state.box("xywh", "border", "window");
        if (!now || listed.some((v, i) => Math.abs(v - now[i]) >= 0.5)) return null;
    }
    const [width, height] = popup.state.box("dimension", "border");
    return new Graphics.Image(width, height, popup).toBytes("png");
})()`;
}

/// Whether `file` is a popup file of a shot into `path` (`popupPath` of some number)
bool isPopupFileOf(string path, string file)
{
    import std.algorithm : all, endsWith, startsWith;
    import std.ascii : isDigit;
    import std.path : extension, stripExtension;

    const ext = path.extension.length ? path.extension : ".png";
    const prefix = path.stripExtension ~ ".popup-";
    if (!file.startsWith(prefix) || !file.endsWith(ext) || file.length <= prefix.length + ext.length)
        return false;
    return file[prefix.length .. $ - ext.length].all!isDigit;
}

/// The file of the popup number `number` (from 1) of a shot into `path`: beside it,
/// "a.png" → "a.popup-1.png"
string popupPath(string path, size_t number)
{
    import std.conv : to;
    import std.path : extension, stripExtension;

    const ext = path.extension;
    return path.stripExtension ~ ".popup-" ~ number.to!string ~ (ext.length ? ext : ".png");
}

/// The response line of a shot request into `path`: the window's image there and the image of
/// every open popup beside it (`popupPath`), with its summary; a popup is a window of its own,
/// not in the window's image. A popup closed between the list and its image is told as
/// closed, without a file. `run` runs a script on the window's thread; `write` writes a file
/// and `clear` removes the popup files of an earlier shot into `path` (`isPopupFileOf`; std.file
/// in the channel), throwing when they can't
string shotResponse(string path, scope WindowRun delegate(string script) run,
    scope void delegate(string path, const(ubyte)[] image) write, scope void delegate(string path) clear)
{
    import std.json : JSONType;

    const window = run(shotScript);
    if (window.error.length)
        return errorLine(window.error);
    if (window.bytes is null)
        return errorLine("the window gave no image: " ~ window.text);
    string error;
    if (!writeImage(path, window.bytes, write, error))
        return errorLine(error);
    auto result = JSONValue(["path": JSONValue(path), "bytes": JSONValue(window.bytes.length)]);
    try
        clear(path); // the popups of an earlier shot into it, closed now or not
    catch (Exception e)
        return errorLine("can't remove the popup files of an earlier shot into " ~ path ~ ": " ~ e.msg);

    JSONValue[] popups;
    if (!listPopups(run(evalScript(popupsCode)), popups, error))
        return errorLine("can't list the popups: " ~ error);
    JSONValue[] shots;
    foreach (i, popup; popups)
    {
        import std.conv : to;

        const image = run(popupShotScript(i, summaryText(popup, "tag"), summaryText(popup, "class"),
            popup.type == JSONType.object && "box" in popup.object ? popup["box"] : JSONValue.init));
        if (image.error.length)
            return errorLine(image.error);
        if (image.bytes is null)
        {
            // closed by itself after the list (a tooltip, a notice): the rest of the shot stands
            shots ~= JSONValue(["closed": JSONValue(true), "element": popup]);
            continue;
        }
        const popupFile = popupPath(path, i + 1);
        if (!writeImage(popupFile, image.bytes, write, error))
            return errorLine(error);
        shots ~= JSONValue(["path": JSONValue(popupFile), "bytes": JSONValue(image.bytes.length), "element": popup]);
    }
    if (shots.length)
        result["popups"] = shots;
    return resultLine(result);
}

// A text field of an element's summary, "" if it has none (debug-eval.js leaves an empty
// class out)
private string summaryText(const JSONValue summary, string key)
{
    import std.json : JSONType;

    if (summary.type == JSONType.object)
        if (const value = key in summary.object)
            if (value.type == JSONType.string)
                return value.str;
    return "";
}

// Writes an image of a shot; false and why in `error` when it can't
private bool writeImage(string path, const(ubyte)[] image,
    scope void delegate(string path, const(ubyte)[] image) write, out string error)
{
    try
        write(path, image);
    catch (Exception e)
    {
        error = "can't write the shot to " ~ path ~ ": " ~ e.msg;
        return false;
    }
    return true;
}

// The summaries of the open popups out of what the script of `popupsCode` gave; false and why
// in `error` when it gave none
private bool listPopups(const WindowRun run, out JSONValue[] popups, out string error)
{
    import std.json : JSONException, JSONType, parseJSON;

    if (run.error.length)
    {
        error = run.error;
        return false;
    }
    try
    {
        auto json = parseJSON(run.text);
        if (json.type == JSONType.object)
        {
            if (auto value = "value" in json.object)
                if (value.type == JSONType.array)
                {
                    popups = value.array;
                    return true;
                }
            if (auto thrown = "thrown" in json.object)
                if (thrown.type == JSONType.string)
                {
                    error = thrown.str;
                    return false;
                }
        }
    }
    catch (JSONException)
    {
    }
    error = "the script gave no list: " ~ run.text;
    return false;
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

@("parseRequest: the requests")
unittest
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

@("parseRequest: the input requests")
unittest
{
    DebugRequest request;
    string error;
    assert(parseRequest(`{"hover": "10 20.5"}`, request, error) && request == DebugRequest(RequestKind.hover, "10 20.5"));
    assert(parseRequest(`{"key": "Cmd+A"}`, request, error) && request == DebugRequest(RequestKind.key, "Cmd+A"));
    assert(parseRequest(`{"type": "abc"}`, request, error) && request == DebugRequest(RequestKind.type, "abc"));
}

@("parsePoint: the point of a hover is two numbers in the window")
unittest
{
    double x, y;
    string error;
    assert(parsePoint("10 20.5", x, y, error) && x == 10 && y == 20.5, error);
    assert(parsePoint("  0   7 ", x, y, error) && x == 0 && y == 7, error);
    foreach (bad; ["", "10", "10 20 30", "a b", "10,20", "-1 5", "nan 1", "1 inf"])
    {
        assert(!parsePoint(bad, x, y, error), bad);
        assert(error.length, bad);
    }
}

@("inputResponse: true, or why it wasn't handed to the window")
unittest
{
    import std.json : parseJSON;

    assert(parseJSON(inputResponse(WindowRun.init)) == parseJSON(`{"result":true}`));
    assert(parseJSON(inputResponse(WindowRun("macOS only")))["error"].str == "macOS only");
}

@("parseInput: the point of a hover, the keys of a key or a type")
unittest
{
    import std.algorithm : canFind;
    import utils.keys : Modifier, NamedKey;

    InputRequest input;
    string error;
    assert(parseInput(DebugRequest(RequestKind.hover, "10 20.5"), input, error), error);
    assert(input.isHover && input.x == 10 && input.y == 20.5 && !input.presses.length);
    assert(parseInput(DebugRequest(RequestKind.key, "Cmd+A"), input, error), error);
    assert(!input.isHover && input.presses == [KeyPress(NamedKey.none, 'a', Modifier.command)]);
    assert(parseInput(DebugRequest(RequestKind.type, "a\n"), input, error), error);
    assert(input.presses == [KeyPress(NamedKey.none, 'a'), KeyPress(NamedKey.enter)]);

    assert(!parseInput(DebugRequest(RequestKind.hover, "10"), input, error) && error.canFind("<x> <y>"), error);
    assert(!parseInput(DebugRequest(RequestKind.key, "Hyper+a"), input, error) && error.canFind("Hyper"), error);
    assert(!parseInput(DebugRequest(RequestKind.eval, "1"), input, error) && error.length);
}

@("sendInput: the mouse or each key in order, stopping at the first refused")
unittest
{
    import utils.keys : NamedKey;

    string[] calls;
    string refuse;
    string move(double x, double y)
    {
        import std.conv : to;

        calls ~= "move " ~ x.to!string ~ " " ~ y.to!string;
        return null;
    }

    string press(in KeyPress key)
    {
        import std.conv : to;

        calls ~= "press " ~ key.character.to!string;
        return key.character == 'b' ? refuse : null;
    }

    assert(sendInput(InputRequest(true, 3, 4), &move, &press) is null);
    assert(calls == ["move 3 4"]);

    calls = null;
    auto typing = InputRequest(false, 0, 0, [KeyPress(NamedKey.none, 'a'), KeyPress(NamedKey.none, 'b'),
        KeyPress(NamedKey.none, 'c')]);
    assert(sendInput(typing, &move, &press) is null);
    assert(calls == ["press a", "press b", "press c"]);

    calls = null;
    refuse = "macOS only";
    assert(sendInput(typing, &move, &press) == "macOS only");
    assert(calls == ["press a", "press b"]);
}

@("evalScript: the wrapper called with the code as a JSON string")
unittest
{
    import std.algorithm : endsWith, startsWith;

    const script = evalScript("a\n\"b\"");
    assert(script.startsWith(import("debug-eval.js")), script);
    assert(script.endsWith(`("a\n\"b\"")`), script);
}

@("evalResponse: the value or what was thrown, as the protocol says them")
unittest
{
    import std.json : parseJSON;

    assert(parseJSON(evalResponse(WindowRun("", true, `{"value":{"a":[1,"x"]}}`)))
        == parseJSON(`{"result":{"a":[1,"x"]}}`));
    assert(parseJSON(evalResponse(WindowRun("", true, `{"value":null}`))) == parseJSON(`{"result":null}`));
    assert(parseJSON(evalResponse(WindowRun("", true, `{"thrown":"Error: boom"}`)))
        == parseJSON(`{"error":"Error: boom"}`));
    assert(parseJSON(evalResponse(WindowRun("SciterEval failed")))["error"].str == "SciterEval failed");
    // the wrapper gave nothing it should: a bug of debug-eval.js, said as such
    assert(parseJSON(evalResponse(WindowRun("", false, "undefined")))["error"].str
        == "the eval script gave no text: undefined");
    foreach (bad; [`not json`, `{}`, `{"thrown":1}`, `[1]`])
        assert(parseJSON(evalResponse(WindowRun("", true, bad)))["error"].str
            == "the eval script gave no value: " ~ bad, bad);
}

version (unittest)
{
    // A window for the shot tests: what each script of a shot gives, the files written
    private struct FakeWindow
    {
        WindowRun window; /// the window's image
        WindowRun popups; /// the list of the open popups
        WindowRun[] popupImages; /// the image of each popup
        string[] scripts; /// the scripts run, in order
        const(ubyte)[][string] files; /// the files written

        WindowRun run(string script)
        {
            scripts ~= script;
            if (script == shotScript)
                return window;
            if (script == evalScript(popupsCode))
                return popups;
            foreach (i, image; popupImages)
            {
                import std.algorithm : canFind;
                import std.conv : to;

                if (script.canFind(`document.$$(":popup")[` ~ i.to!string ~ `]`))
                    return image;
            }
            assert(false, "an unknown script: " ~ script);
        }

        void write(string path, const(ubyte)[] image)
        {
            files[path] = image;
        }

        void clear(string path)
        {
            foreach (file; files.keys)
                if (isPopupFileOf(path, file))
                    files.remove(file);
        }
    }

    private WindowRun bytesRun(const(ubyte)[] bytes) => WindowRun("", false, "", bytes);
    private WindowRun textRun(string text) => WindowRun("", true, text);
}

@("isPopupFileOf: beside the shot, of its name, a number")
unittest
{
    assert(isPopupFileOf("/s/a.png", "/s/a.popup-1.png"));
    assert(isPopupFileOf("/s/a.png", "/s/a.popup-12.png"));
    assert(isPopupFileOf("/s/a", "/s/a.popup-2.png"));
    foreach (other; ["/s/a.png", "/s/a.popup-.png", "/s/a.popup-x.png", "/s/b.popup-1.png", "/t/a.popup-1.png",
            "/s/a.popup-1.jpg", "/s/xa.popup-1.png"])
        assert(!isPopupFileOf("/s/a.png", other), other);
}

@("shotResponse: the popup files of an earlier shot into the same path go, they show popups closed now")
unittest
{
    import std.json : parseJSON;

    const ubyte[3] png = [1, 2, 3];
    const ubyte[1] old = [9];
    auto fake = FakeWindow(bytesRun(png[]), textRun(`{"value":[]}`));
    fake.files = ["/s/a.popup-1.png": old[], "/s/a.popup-2.png": old[], "/s/a.popup-x.png": old[],
        "/s/b.popup-1.png": old[]];
    assert("result" in parseJSON(shotResponse("/s/a.png", &fake.run, &fake.write, &fake.clear)).object);
    assert(fake.files == ["/s/a.png": png[], "/s/a.popup-x.png": old[], "/s/b.popup-1.png": old[]]);
}

@("popupPath: the file of a popup is beside the shot's")
unittest
{
    assert(popupPath("/s/a.png", 1) == "/s/a.popup-1.png");
    assert(popupPath("/s/a.b.png", 12) == "/s/a.b.popup-12.png");
    assert(popupPath("/s/a", 2) == "/s/a.popup-2.png");
}

@("popupShotScript: takes the popup of its number, at its border box")
unittest
{
    import std.algorithm : canFind;
    import std.json : parseJSON;

    const box = parseJSON(`[648,308.5,128,71]`);
    const script = popupShotScript(3, "menu", "context", box);
    assert(script.canFind(`document.$$(":popup")[3]`), script);
    assert(script.canFind(`"dimension", "border"`), script);
    // the popup of that number must be the one listed (tag, class, place in the window):
    // another moved to it gives no image
    assert(script.canFind(`"menu"`) && script.canFind(`"context"`), script);
    assert(script.canFind(`[648,308.5,128,71]`), script);
    assert(popupShotScript(0, "menu", "context", box) != script);
    assert(popupShotScript(3, `a"b`, "", box).canFind(`"a\"b"`)); // as JSON strings
    assert(popupShotScript(3, "menu", "", JSONValue.init).canFind("null")); // no box listed: not compared
}

@("shotResponse: without popups the window's image is written, the response as it always was")
unittest
{
    import std.json : parseJSON;

    const ubyte[3] png = [1, 2, 3];
    auto fake = FakeWindow(bytesRun(png[]), textRun(`{"value":[]}`));
    auto ok = parseJSON(shotResponse("/s/a.png", &fake.run, &fake.write, &fake.clear));
    assert(ok == parseJSON(`{"result":{"path":"/s/a.png","bytes":3}}`), ok.toString);
    assert(fake.files == ["/s/a.png": png[]]);
}

@("shotResponse: with popups an image of each beside the window's, with its summary")
unittest
{
    import std.json : parseJSON;

    const ubyte[3] png = [1, 2, 3];
    const ubyte[2] menu = [4, 5];
    const ubyte[1] tip = [6];
    enum popups = `{"value":[{"tag":"menu","class":"context","box":[648,308,128,71]},`
        ~ `{"tag":"popup","text":"hint","box":[10,20,30,40]}]}`;
    auto fake = FakeWindow(bytesRun(png[]), textRun(popups), [bytesRun(menu[]), bytesRun(tip[])]);
    auto ok = parseJSON(shotResponse("/s/a.png", &fake.run, &fake.write, &fake.clear));
    assert(ok == parseJSON(`{"result":{"path":"/s/a.png","bytes":3,"popups":[`
        ~ `{"path":"/s/a.popup-1.png","bytes":2,"element":{"tag":"menu","class":"context","box":[648,308,128,71]}},`
        ~ `{"path":"/s/a.popup-2.png","bytes":1,"element":{"tag":"popup","text":"hint","box":[10,20,30,40]}}]}}`),
        ok.toString);
    assert(fake.files == ["/s/a.png": png[], "/s/a.popup-1.png": menu[], "/s/a.popup-2.png": tip[]]);
}

@("shotResponse: the window's image failed: nothing written, why")
unittest
{
    import std.json : parseJSON;

    auto timedOut = FakeWindow(WindowRun("timed out"));
    assert(parseJSON(shotResponse("/s/a.png", &timedOut.run, &timedOut.write, &timedOut.clear))["error"].str == "timed out");
    auto noImage = FakeWindow(textRun("null"));
    assert(parseJSON(shotResponse("/s/a.png", &noImage.run, &noImage.write, &noImage.clear))["error"].str
        == "the window gave no image: null");
    assert(timedOut.files.length == 0 && noImage.files.length == 0);

    const ubyte[3] png = [1, 2, 3];
    auto readOnly = FakeWindow(bytesRun(png[]), textRun(`{"value":[]}`));
    void refuse(string, const(ubyte)[])
    {
        throw new Exception("read-only");
    }
    assert(parseJSON(shotResponse("/s/a.png", &readOnly.run, &refuse, &readOnly.clear))["error"].str
        == "can't write the shot to /s/a.png: read-only");
}

@("shotResponse: the popups can't be listed: said; one closed before its image: told as closed")
unittest
{
    import std.json : parseJSON;

    const ubyte[3] png = [1, 2, 3];
    auto failed = FakeWindow(bytesRun(png[]), WindowRun("timed out"));
    assert(parseJSON(shotResponse("/s/a.png", &failed.run, &failed.write, &failed.clear))["error"].str
        == "can't list the popups: timed out");
    auto thrown = FakeWindow(bytesRun(png[]), textRun(`{"thrown":"ReferenceError: x"}`));
    assert(parseJSON(shotResponse("/s/a.png", &thrown.run, &thrown.write, &thrown.clear))["error"].str
        == "can't list the popups: ReferenceError: x");

    // the window's image is kept, the popup told as closed (a tooltip, a notice hide by themselves)
    const ubyte[1] tip = [6];
    auto closed = FakeWindow(bytesRun(png[]), textRun(`{"value":[{"tag":"menu"},{"tag":"popup"}]}`),
        [textRun("null"), bytesRun(tip[])]);
    auto ok = parseJSON(shotResponse("/s/a.png", &closed.run, &closed.write, &closed.clear));
    assert(ok == parseJSON(`{"result":{"path":"/s/a.png","bytes":3,"popups":[{"closed":true,"element":{"tag":"menu"}},`
        ~ `{"path":"/s/a.popup-2.png","bytes":1,"element":{"tag":"popup"}}]}}`), ok.toString);
    assert(closed.files == ["/s/a.png": png[], "/s/a.popup-2.png": tip[]]);
}

@("resultLine: a result and an error (errorLine) as lines of the protocol")
unittest
{
    import std.json : parseJSON;

    const result = parseJSON(resultLine(JSONValue(["path": JSONValue("/a.png"), "bytes": JSONValue(10)])));
    assert(result["result"]["path"].str == "/a.png" && result["result"]["bytes"].integer == 10);
    const line = errorLine("bad \"x\"\nline");
    assert(parseJSON(line)["error"].str == "bad \"x\"\nline");
    assert(line[$ - 1] != '\n');
}

@("parsePort: a port or not")
unittest
{
    ushort port;
    assert(parsePort("4567", port) && port == 4567);
    assert(parsePort("0", port) && port == 0);
    foreach (bad; ["", "x", "-1", "65536", "12 "])
        assert(!parsePort(bad, port), bad);
}

@("LineReader: lines come in parts")
unittest
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
