//! A key press (`utils/keys`) as macOS describes it in an NSEvent: the virtual key code
//! (kVK_*), the characters with and without the modifiers, the modifier flags. Characters are
//! placed by the US layout; one of no key of it (another layout) is typed by its character
//! alone. Pure, so it is tested on every system.
module utils.mac_keys;

import utils.keys : KeyPress, Modifier, NamedKey;

/// A key press as an NSEvent of a key takes it
struct MacKeyEvent
{
    string characters; /// what the key types with its modifiers ("A" for Shift+a)
    string charactersIgnoringModifiers; /// what it types without them ("a")
    ushort keyCode; /// the virtual key code: the key, whatever the layout types
    ulong modifierFlags; /// NSEventModifierFlags
}

/// The key code of a character no key of the US layout types: the window gets the
/// character, its key is "none"
enum ushort unknownKeyCode = 0xFFFF;

/// NSEventModifierFlags of the modifiers
enum : ulong
{
    nsShiftKeyMask = 1 << 17,
    nsControlKeyMask = 1 << 18,
    nsAlternateKeyMask = 1 << 19,
    nsCommandKeyMask = 1 << 20,
}

/// The event of `press`: a character of the US layout typed with Shift ("A", "!") has Shift
/// even if the press doesn't say it
MacKeyEvent macKeyEvent(in KeyPress press)
{
    import std.conv : to;

    ulong flags = flagsOf(press.modifiers);
    if (press.named != NamedKey.none)
    {
        const named = namedKeys[press.named];
        // Shift+Tab types the back tab
        const characters = press.named == NamedKey.tab && (flags & nsShiftKeyMask) ? "\x19" : named.characters;
        return MacKeyEvent(characters, named.characters, named.code, flags);
    }
    const character = press.character.to!string;
    foreach (key; characterKeys)
    {
        if (key.shifted == press.character)
            flags |= nsShiftKeyMask;
        else if (key.plain != press.character)
            continue;
        const plain = [key.plain].idup;
        string typed = flags & nsShiftKeyMask ? [key.shifted].idup : plain;
        // Control with a letter types its control character (Ctrl+A: 0x01)
        if ((flags & nsControlKeyMask) && key.plain >= 'a' && key.plain <= 'z')
            typed = [cast(char)(key.plain - 'a' + 1)].idup;
        return MacKeyEvent(typed, plain, key.code, flags);
    }
    return MacKeyEvent(character, character, unknownKeyCode, flags);
}

private ulong flagsOf(uint modifiers)
{
    ulong flags;
    if (modifiers & Modifier.shift)
        flags |= nsShiftKeyMask;
    if (modifiers & Modifier.control)
        flags |= nsControlKeyMask;
    if (modifiers & Modifier.alt)
        flags |= nsAlternateKeyMask;
    if (modifiers & Modifier.command)
        flags |= nsCommandKeyMask;
    return flags;
}

// A key of the US layout that types a character: without Shift, with it, its kVK code
private struct CharacterKey
{
    char plain;
    char shifted;
    ushort code;
}

private immutable CharacterKey[] characterKeys = [
    CharacterKey('a', 'A', 0), CharacterKey('s', 'S', 1), CharacterKey('d', 'D', 2),
    CharacterKey('f', 'F', 3), CharacterKey('h', 'H', 4), CharacterKey('g', 'G', 5),
    CharacterKey('z', 'Z', 6), CharacterKey('x', 'X', 7), CharacterKey('c', 'C', 8),
    CharacterKey('v', 'V', 9), CharacterKey('b', 'B', 11), CharacterKey('q', 'Q', 12),
    CharacterKey('w', 'W', 13), CharacterKey('e', 'E', 14), CharacterKey('r', 'R', 15),
    CharacterKey('y', 'Y', 16), CharacterKey('t', 'T', 17), CharacterKey('1', '!', 18),
    CharacterKey('2', '@', 19), CharacterKey('3', '#', 20), CharacterKey('4', '$', 21),
    CharacterKey('6', '^', 22), CharacterKey('5', '%', 23), CharacterKey('=', '+', 24),
    CharacterKey('9', '(', 25), CharacterKey('7', '&', 26), CharacterKey('-', '_', 27),
    CharacterKey('8', '*', 28), CharacterKey('0', ')', 29), CharacterKey(']', '}', 30),
    CharacterKey('o', 'O', 31), CharacterKey('u', 'U', 32), CharacterKey('[', '{', 33),
    CharacterKey('i', 'I', 34), CharacterKey('p', 'P', 35), CharacterKey('l', 'L', 37),
    CharacterKey('j', 'J', 38), CharacterKey('\'', '"', 39), CharacterKey('k', 'K', 40),
    CharacterKey(';', ':', 41), CharacterKey('\\', '|', 42), CharacterKey(',', '<', 43),
    CharacterKey('/', '?', 44), CharacterKey('n', 'N', 45), CharacterKey('m', 'M', 46),
    CharacterKey('.', '>', 47), CharacterKey('`', '~', 50),
];

// A named key: the character macOS gives it (the function keys' are of the private use area,
// NSUpArrowFunctionKey and the like) and its kVK code
private struct MacNamedKey
{
    string characters;
    ushort code;
}

private immutable MacNamedKey[NamedKey.max + 1] namedKeys = [
    NamedKey.none: MacNamedKey("", unknownKeyCode),
    NamedKey.enter: MacNamedKey("\r", 36), NamedKey.tab: MacNamedKey("\t", 48),
    NamedKey.space: MacNamedKey(" ", 49), NamedKey.backspace: MacNamedKey("\x7f", 51),
    NamedKey.delete_: MacNamedKey("", 117), NamedKey.escape: MacNamedKey("\x1b", 53),
    NamedKey.up: MacNamedKey("", 126), NamedKey.down: MacNamedKey("", 125),
    NamedKey.left: MacNamedKey("", 123), NamedKey.right: MacNamedKey("", 124),
    NamedKey.home: MacNamedKey("", 115), NamedKey.end: MacNamedKey("", 119),
    NamedKey.pageUp: MacNamedKey("", 116), NamedKey.pageDown: MacNamedKey("", 121),
    NamedKey.f1: MacNamedKey("", 122), NamedKey.f2: MacNamedKey("", 120),
    NamedKey.f3: MacNamedKey("", 99), NamedKey.f4: MacNamedKey("", 118),
    NamedKey.f5: MacNamedKey("", 96), NamedKey.f6: MacNamedKey("", 97),
    NamedKey.f7: MacNamedKey("", 98), NamedKey.f8: MacNamedKey("", 100),
    NamedKey.f9: MacNamedKey("", 101), NamedKey.f10: MacNamedKey("", 109),
    NamedKey.f11: MacNamedKey("", 103), NamedKey.f12: MacNamedKey("", 111),
];

unittest // a character key: its code, Shift when the character is typed with it
{
    assert(macKeyEvent(KeyPress(NamedKey.none, 'a')) == MacKeyEvent("a", "a", 0, 0));
    assert(macKeyEvent(KeyPress(NamedKey.none, '5')) == MacKeyEvent("5", "5", 23, 0));
    assert(macKeyEvent(KeyPress(NamedKey.none, 'A')) == MacKeyEvent("A", "a", 0, nsShiftKeyMask));
    assert(macKeyEvent(KeyPress(NamedKey.none, '!')) == MacKeyEvent("!", "1", 18, nsShiftKeyMask));
    assert(macKeyEvent(KeyPress(NamedKey.none, 'a', Modifier.shift)) == MacKeyEvent("A", "a", 0, nsShiftKeyMask));
    assert(macKeyEvent(KeyPress(NamedKey.none, '.')) == MacKeyEvent(".", ".", 47, 0));
}

unittest // the modifiers as the flags of NSEvent
{
    assert(macKeyEvent(KeyPress(NamedKey.none, 'z', Modifier.command | Modifier.shift))
        == MacKeyEvent("Z", "z", 6, nsCommandKeyMask | nsShiftKeyMask));
    assert(macKeyEvent(KeyPress(NamedKey.none, 'c', Modifier.control | Modifier.alt))
        == MacKeyEvent("\x03", "c", 8, nsControlKeyMask | nsAlternateKeyMask));
    assert(nsShiftKeyMask == 0x20000 && nsControlKeyMask == 0x40000);
    assert(nsAlternateKeyMask == 0x80000 && nsCommandKeyMask == 0x100000);
}

unittest // a named key: its code and the character macOS gives it
{
    assert(macKeyEvent(KeyPress(NamedKey.enter)) == MacKeyEvent("\r", "\r", 36, 0));
    assert(macKeyEvent(KeyPress(NamedKey.escape)) == MacKeyEvent("\x1b", "\x1b", 53, 0));
    assert(macKeyEvent(KeyPress(NamedKey.backspace)) == MacKeyEvent("\x7f", "\x7f", 51, 0));
    assert(macKeyEvent(KeyPress(NamedKey.down)) == MacKeyEvent("", "", 125, 0));
    assert(macKeyEvent(KeyPress(NamedKey.f5)) == MacKeyEvent("", "", 96, 0));
    assert(macKeyEvent(KeyPress(NamedKey.space)) == MacKeyEvent(" ", " ", 49, 0));
}

unittest // the characters macOS gives with Control and with Shift+Tab
{
    assert(macKeyEvent(KeyPress(NamedKey.none, 'a', Modifier.control))
        == MacKeyEvent("\x01", "a", 0, nsControlKeyMask));
    assert(macKeyEvent(KeyPress(NamedKey.none, 'e', Modifier.control | Modifier.shift))
        == MacKeyEvent("\x05", "e", 14, nsControlKeyMask | nsShiftKeyMask));
    assert(macKeyEvent(KeyPress(NamedKey.tab, dchar.init, Modifier.shift))
        == MacKeyEvent("\x19", "\t", 48, nsShiftKeyMask));
}

unittest // a character of no key of the US layout: typed by itself
{
    assert(macKeyEvent(KeyPress(NamedKey.none, 'ы')) == MacKeyEvent("ы", "ы", unknownKeyCode, 0));
    assert(macKeyEvent(KeyPress(NamedKey.none, 'Я', Modifier.command))
        == MacKeyEvent("Я", "Я", unknownKeyCode, nsCommandKeyMask));
}
