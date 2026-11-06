//! A text for the user made where it can't be translated (a lower layer, another thread): an
//! english template with its parameters, `uiText("no column \"{column}\" in this log",
//! "column", id)`, translated where it is shown (ui/translations.Catalog); its english is for
//! the log and the tests. A parameter is a text of its own (a reason in a reason) or a plain
//! string put in as it is (a name, a path, the message of the OS). The template is always a
//! literal: scripts/i18n-extract finds the texts by it.
module utils.ui_text;

/// A text for the user: a template with its parameters, or a plain string put in as it is.
struct UiText
{
    string text; /// the template ("Can't load the filter: {reason}"), or the plain string
    bool plain; /// put in as it is: no template, not translated
    immutable(string)[] names; /// of the parameters
    immutable(UiText)[] values; /// of the parameters, by their names: immutable, so a text is copied
                                /// as it is, also a const one (an event, a view)

    /// Whether there is no text (no error)
    bool empty() const pure nothrow @nogc @safe => text.length == 0;

    // Written out: the hash the compiler generates for this recursive type is neither nothrow
    // nor @safe, and AppSettings (recent files, their filters, the problems of their rules)
    // hashes it so. Keep it in step with the fields.
    size_t toHash() const nothrow @safe
    {
        size_t hash = hashOf(text, plain);
        foreach (name; names)
            hash = hashOf(name, hash);
        foreach (ref value; values)
            hash = hashOf(value.toHash(), hash);
        return hash;
    }

    /// The text as an immutable one, to be a parameter of another
    immutable(UiText) frozen() const pure nothrow @safe => immutable UiText(text, plain, names, values);
}

/// A plain string, put in as it is: a name, a path, a message of the OS.
UiText plainText(string text) pure nothrow @safe
{
    return UiText(text, true);
}

/// The template `text` with its parameters `args`: name, value, name, value...; a value is a
/// UiText (translated as well), a string (plain) or a number.
UiText uiText(Args...)(string text, Args args)
{
    import std.conv : to;

    static assert(Args.length % 2 == 0, "uiText: parameters go as name, value");
    UiText t = UiText(text);
    static foreach (i; 0 .. Args.length / 2)
    {{
        static assert(is(Args[2 * i] : string), "uiText: the name of a parameter is a string");
        alias Value = Args[2 * i + 1];
        t.names ~= args[2 * i];
        static if (is(Value : const UiText))
            t.values ~= args[2 * i + 1].frozen;
        else static if (is(Value : string))
            t.values ~= plainText(args[2 * i + 1]).frozen;
        else
            t.values ~= plainText(args[2 * i + 1].to!string).frozen;
    }}
    return t;
}

/// `t` put together by `translate` (the translation of a template): its parameters put in
/// ({name}), a text of a parameter put together the same way, a plain one as it is.
string render(const UiText t, scope string delegate(string) @safe translate) @safe
{
    import std.array : appender;
    import std.ascii : isAlphaNum;

    if (t.plain)
        return t.text;
    const translated = translate(t.text);
    auto result = appender!string;
    size_t i;
    while (i < translated.length)
    {
        if (translated[i] == '{')
        {
            size_t j = i + 1;
            while (j < translated.length && (isAlphaNum(translated[j]) || translated[j] == '_'))
                j++;
            if (j > i + 1 && j < translated.length && translated[j] == '}')
            {
                const name = translated[i + 1 .. j];
                bool found;
                foreach (k, n; t.names)
                    if (n == name)
                    {
                        result.put(render(t.values[k], translate));
                        found = true;
                        break;
                    }
                if (!found)
                    result.put(translated[i .. j + 1]);
                i = j + 1;
                continue;
            }
        }
        result.put(translated[i]);
        i++;
    }
    return result[];
}

/// `t` in english.
string english(const UiText t) @safe
{
    return render(t, (string text) => text);
}

/// An exception that carries a text for the user; its message is the english of the text.
class UiTextException : Exception
{
    UiText text;

    this(UiText text, string file = __FILE__, size_t line = __LINE__) @safe
    {
        super(english(text), file, line);
        this.text = text;
    }
}

/// The text of `e` for the user: that of a UiTextException, the message of another one
/// (of the OS, of a library) as a plain string.
UiText uiTextOf(const Throwable e) @safe
{
    if (auto ours = cast(const UiTextException) e)
        return ours.text;
    return plainText(e.msg.idup);
}

@("uiText: a template with no parameters is its english")
unittest
{
    assert(english(uiText("the file is no longer available")) == "the file is no longer available");
    assert(!uiText("x").plain && plainText("x").plain);
    assert(UiText.init.empty && !uiText("x").empty);
}

@("uiText: parameters by name, of any order, numbers and strings plain")
unittest
{
    const t = uiText("{a} of {b}, {c}", "b", 2, "a", "one", "c", 3.5);
    assert(english(t) == "one of 2, 3.5");
    assert(t.values[0].plain && t.values[1].plain);
}

@("uiText: a parameter that is a text of its own, put together the same way")
unittest
{
    const inner = uiText("no column \"{column}\" in this log", "column", "ecu");
    const t = uiText("Can't load the filter: {reason}", "reason", inner);
    assert(english(t) == "Can't load the filter: no column \"ecu\" in this log");
}

@("render: the templates translated, plain parameters as they are, an unknown parameter as written")
unittest
{
    string russian(string text) @safe
    {
        switch (text)
        {
        case "reason: {reason}, file {file} {missing}": return "причина: {reason}, файл {file} {missing}";
        case "gone": return "нет";
        case "a.dlt": return "не переводится";
        default: return text;
        }
    }

    const t = uiText("reason: {reason}, file {file} {missing}", "reason", uiText("gone"), "file", "a.dlt");
    assert(render(t, &russian) == "причина: нет, файл a.dlt {missing}");
}

@("render: a parameter in the translation only once, or twice, or not at all")
unittest
{
    string twice(string text) @safe => text == "{a}" ? "{a}{a}" : text;
    assert(render(uiText("{a}", "a", "x"), &twice) == "xx");
}

@("UiTextException: the message is the english, the text is kept")
unittest
{
    auto e = new UiTextException(uiText("no column \"{column}\" in this log", "column", "ecu"));
    assert(e.msg == "no column \"ecu\" in this log");
    assert(uiTextOf(e).text == "no column \"{column}\" in this log");
}

@("uiTextOf: the message of another exception is a plain string")
unittest
{
    const t = uiTextOf(new Exception("Permission denied"));
    assert(t.plain && t.text == "Permission denied");
}
