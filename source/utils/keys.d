//! Keys by name, whatever the system: a combination ("Cmd+Shift+A", "Enter", "a") and a text
//! as the key presses that type it. Each system's own codes are made of them elsewhere
//! (`utils/mac_keys` for macOS).
module utils.keys;

/// The modifier keys of a press
enum Modifier : uint
{
    shift = 1,
    control = 2,
    alt = 4, /// Option on macOS
    command = 8, /// Cmd on macOS, the Windows key elsewhere
}

/// A key that types no character of its own
enum NamedKey
{
    none, /// the press is of a character key
    enter,
    tab,
    space,
    backspace,
    delete_,
    escape,
    up,
    down,
    left,
    right,
    home,
    end,
    pageUp,
    pageDown,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
}

/// One key pressed and released
struct KeyPress
{
    NamedKey named; /// the key, or none for a character key
    dchar character; /// the character as written ("A", "!", "ы") when `named` is none
    uint modifiers; /// Modifier flags as written: "A" alone has none, the character tells it
}

/// The names of the keys parseKeyPress knows besides a character, for the error and the help
enum string keyNames = "Enter, Tab, Space, Backspace, Delete, Escape, Up, Down, Left, Right, "
    ~ "Home, End, PageUp, PageDown, F1..F12; Shift, Ctrl, Alt (Option), Cmd";

/// The press of a combination: modifiers and a key joined by "+" ("Cmd+Shift+A", "Ctrl+Tab"),
/// a key alone ("Enter", "a", "ы", "+"); names are case-insensitive, and so is a letter after
/// modifiers ("Cmd+A" is Cmd and a: Shift is written). False and why in `error` if it names no
/// key: a key is one character or one of `keyNames`
bool parseKeyPress(string combination, out KeyPress press, out string error)
{
    import std.algorithm : splitter;
    import std.array : array;
    import std.range : walkLength;
    import std.uni : toLower;

    import std.algorithm : endsWith;

    // the key "+" is the last "+": "+" alone, "Cmd++"
    string[] parts;
    if (combination == "+")
        parts = ["+"];
    else if (combination.length > 2 && combination.endsWith("++"))
        parts = combination[0 .. $ - 2].splitter('+').array ~ "+";
    else
        parts = combination.length ? combination.splitter('+').array : [""];
    uint modifiers;
    foreach (name; parts[0 .. $ - 1])
    {
        const modifier = modifierOf(name.toLower);
        if (!modifier)
        {
            error = `no modifier "` ~ name ~ `" in "` ~ combination ~ `"; known: ` ~ keyNames;
            return false;
        }
        modifiers |= modifier;
    }
    const key = parts[$ - 1];
    if (key.walkLength == 1)
    {
        import std.uni : toLowerChar = toLower;

        // with modifiers the letter names the key, as menus write it ("Cmd+A"); alone, its case
        // is the character typed ("A" with Shift)
        press = KeyPress(NamedKey.none, modifiers ? toLowerChar(key.front) : key.front, modifiers);
    }
    else if (const named = namedKeyOf(key.toLower))
        press = KeyPress(named, dchar.init, modifiers);
    else
    {
        error = (key.length ? `no key "` ~ key ~ `"` : "no key") ~ ` in "` ~ combination
            ~ `"; a key is one character or one of: ` ~ keyNames;
        return false;
    }
    return true;
}

/// The presses that type `text`, one a character: "\n" is Enter, "\t" Tab
KeyPress[] typingPresses(string text)
{
    KeyPress[] presses;
    foreach (dchar c; text)
        presses ~= c == '\n' ? KeyPress(NamedKey.enter) : c == '\t' ? KeyPress(NamedKey.tab)
            : KeyPress(NamedKey.none, c);
    return presses;
}

private dchar front(string text)
{
    import std.utf : decodeFront;

    return text.decodeFront;
}

// The named key of a name (lower case), none if it names none
private NamedKey namedKeyOf(string name)
{
    import std.conv : to;
    import std.traits : EnumMembers;

    switch (name)
    {
    case "return":
        return NamedKey.enter;
    case "esc":
        return NamedKey.escape;
    case "arrowup":
        return NamedKey.up;
    case "arrowdown":
        return NamedKey.down;
    case "arrowleft":
        return NamedKey.left;
    case "arrowright":
        return NamedKey.right;
    default:
        import std.string : chomp;
        import std.uni : toLower;

        foreach (key; EnumMembers!NamedKey[1 .. $])
            if (name == key.to!string.chomp("_").toLower) // delete_: "delete"
                return key;
        return NamedKey.none;
    }
}

// The flag of a modifier's name (lower case), 0 if it is none
private uint modifierOf(string name)
{
    switch (name)
    {
    case "shift":
        return Modifier.shift;
    case "ctrl", "control":
        return Modifier.control;
    case "alt", "option", "opt":
        return Modifier.alt;
    case "cmd", "command", "meta":
        return Modifier.command;
    default:
        return 0;
    }
}

@("parseKeyPress: a key alone, a character as written or a named key")
unittest
{
    KeyPress press;
    string error;
    assert(parseKeyPress("a", press, error), error);
    assert(press == KeyPress(NamedKey.none, 'a', 0));
    assert(parseKeyPress("A", press, error) && press == KeyPress(NamedKey.none, 'A', 0));
    assert(parseKeyPress("ы", press, error) && press == KeyPress(NamedKey.none, 'ы', 0));
    assert(parseKeyPress("Enter", press, error) && press == KeyPress(NamedKey.enter, dchar.init, 0));
    assert(parseKeyPress("return", press, error) && press.named == NamedKey.enter);
    assert(parseKeyPress("ESC", press, error) && press.named == NamedKey.escape);
    assert(parseKeyPress("ArrowDown", press, error) && press.named == NamedKey.down);
    assert(parseKeyPress("PageUp", press, error) && press.named == NamedKey.pageUp);
    assert(parseKeyPress("f12", press, error) && press.named == NamedKey.f12);
    assert(parseKeyPress("Delete", press, error) && press.named == NamedKey.delete_);
}

@("parseKeyPress: modifiers by their names, in any case and order")
unittest
{
    KeyPress press;
    string error;
    assert(parseKeyPress("Shift+a", press, error) && press == KeyPress(NamedKey.none, 'a', Modifier.shift));
    assert(parseKeyPress("Cmd+Shift+z", press, error));
    assert(press == KeyPress(NamedKey.none, 'z', Modifier.command | Modifier.shift));
    assert(parseKeyPress("ctrl+alt+Tab", press, error));
    assert(press == KeyPress(NamedKey.tab, dchar.init, Modifier.control | Modifier.alt));
    assert(parseKeyPress("Option+Meta+Left", press, error));
    assert(press == KeyPress(NamedKey.left, dchar.init, Modifier.alt | Modifier.command));
    assert(parseKeyPress("Control+Command+1", press, error));
    assert(press == KeyPress(NamedKey.none, '1', Modifier.control | Modifier.command));
}

@("parseKeyPress: with modifiers a letter is the key whatever its case, Shift is written")
unittest
{
    KeyPress press;
    string error;
    assert(parseKeyPress("Cmd+A", press, error) && press == KeyPress(NamedKey.none, 'a', Modifier.command));
    assert(parseKeyPress("Ctrl+Shift+Z", press, error));
    assert(press == KeyPress(NamedKey.none, 'z', Modifier.control | Modifier.shift));
    assert(parseKeyPress("Cmd+Я", press, error) && press == KeyPress(NamedKey.none, 'я', Modifier.command));
    // alone, the case tells the character: "A" is typed with Shift
    assert(parseKeyPress("A", press, error) && press == KeyPress(NamedKey.none, 'A', 0));
}

@("parseKeyPress: the key \"+\" alone and after modifiers")
unittest
{
    KeyPress press;
    string error;
    assert(parseKeyPress("+", press, error) && press == KeyPress(NamedKey.none, '+', 0), error);
    assert(parseKeyPress("Cmd++", press, error) && press == KeyPress(NamedKey.none, '+', Modifier.command), error);
    assert(parseKeyPress("Cmd+Shift++", press, error));
    assert(press == KeyPress(NamedKey.none, '+', Modifier.command | Modifier.shift));
}

@("parseKeyPress: what names no key is an error that says what is known")
unittest
{
    import std.algorithm : canFind;

    KeyPress press;
    string error;
    foreach (bad; ["", "Cmd+", "Cmd", "Hyper+a", "Enterr", "ab", "a+b", "++", "Cmd+++"])
    {
        assert(!parseKeyPress(bad, press, error), bad);
        assert(error.length, bad);
    }
    assert(!parseKeyPress("Enterr", press, error) && error.canFind("Enterr") && error.canFind("PageDown"), error);
    assert(!parseKeyPress("Hyper+a", press, error) && error.canFind("Hyper"), error);
}

@("typingPresses: a press a character, Enter and Tab for their characters")
unittest
{
    assert(typingPresses("aB\n") == [KeyPress(NamedKey.none, 'a', 0), KeyPress(NamedKey.none, 'B', 0),
        KeyPress(NamedKey.enter, dchar.init, 0)]);
    assert(typingPresses("\tЯ") == [KeyPress(NamedKey.tab, dchar.init, 0), KeyPress(NamedKey.none, 'Я', 0)]);
    assert(typingPresses("") is null);
}
