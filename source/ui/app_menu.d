//! The main menu of the window, described once for every platform: its entries by the
//! conventions of each platform (`appMenu`), the texts of their shortcuts, and the menu as
//! JSON for the script, which draws it as its menu bar on Windows and Linux (`menuJson`:
//! what the items are, not how they are drawn). Free of Sciter: the native macOS menu is
//! built from it by `ui/main_menu_loader`.
module ui.app_menu;


/// The platform whose conventions a menu follows.
enum MenuPlatform
{
    mac,
    windows,
    linux,
}

/// The platform this build runs on.
MenuPlatform hostMenuPlatform() pure nothrow @nogc @safe
{
    version (OSX)
        return MenuPlatform.mac;
    else version (Windows)
        return MenuPlatform.windows;
    else
        return MenuPlatform.linux;
}

/// The menu the window has: of which platform, and whether the script draws it as its menu
/// bar (not on macOS, where the menu is native; the script still uses its shortcut texts).
struct WindowMenu
{
    MenuPlatform platform;
    bool menuBar;
}

/// The menu of the window on `host`.
/// @param forced - "windows" or "linux": the menu bar of that platform on any platform, for a
///     try (the environment variable MENU_BAR_PLATFORM); anything else is ignored
WindowMenu windowMenu(MenuPlatform host, string forced) pure nothrow @safe
{
    if (forced == "windows")
        return WindowMenu(MenuPlatform.windows, true);
    if (forced == "linux")
        return WindowMenu(MenuPlatform.linux, true);
    return WindowMenu(host, host != MenuPlatform.mac);
}

/// A label as shown, with its mnemonic.
struct Label
{
    string text; /// without the `&` of the mnemonic
    ptrdiff_t mnemonic = -1; /// the index of its letter in `text`, in UTF-16 units (as script strings); -1: none
}

/// The label "E&xit": "Exit" with the mnemonic "x" (after `&`); "&&" is a `&`, a trailing `&` is dropped.
Label parseLabel(string label) pure @safe
{
    import std.array : appender;
    import std.utf : codeLength, decode;

    auto text = appender!string;
    Label parsed;
    size_t units; // of the text so far, in UTF-16
    for (size_t i = 0; i < label.length;)
    {
        if (label[i] == '&')
        {
            i++;
            if (i == label.length)
                break; // a trailing &
            if (label[i] != '&' && parsed.mnemonic < 0)
                parsed.mnemonic = units;
        }
        const start = i;
        const c = decode(label, i);
        text.put(label[start .. i]);
        units += codeLength!wchar(c);
    }
    parsed.text = text[];
    return parsed;
}

/// The commands of the menu, given to the script's `onMenuCommand(id)` on every platform.
enum MenuCommand : string
{
    settings = "app.settings",
    quit = "app.quit",
    openFile = "file.open",
    minimize = "window.minimize",
    goToMessage = "navigation.goToMessage",
}

/// A key combination, independent of the platform.
struct Shortcut
{
    string key; /// "O", ",", "F4"; empty: no shortcut
    bool primary; /// Cmd on macOS, Ctrl elsewhere
    bool shift;
    bool alt; /// Option on macOS
    bool bySystem; /// the OS handles it itself (Alt+F4): only shown next to the item

    bool isNone() const scope pure nothrow @nogc @safe => key.length == 0;
}

/// The primary modifier (Cmd / Ctrl) with `key`.
Shortcut primary(string key, bool shift = false) pure nothrow @nogc @safe
{
    return Shortcut(key, true, shift, false);
}

/// What an entry of the bar is on macOS.
enum MenuRole
{
    none,
    app, /// the application menu: merged into the one macOS already has
}

/// What an item of the menu is.
enum MenuItemKind
{
    command,
    separator,
    submenu, /// an entry of the bar, or a nested menu; may be empty
}

/// An item of the menu: a command, a separator or a submenu.
struct MenuItem
{
    MenuItemKind kind;
    string id; /// the command; empty for a separator or a submenu
    string label; /// as shown, without the `&` of its mnemonic
    ptrdiff_t mnemonic = -1; /// see Label
    Shortcut shortcut;
    MenuItem[] items; /// of a submenu
    MenuRole role;
}

/// A command; `&` in its label marks the mnemonic letter (Windows, Linux): parseLabel
MenuItem command(string id, string label, Shortcut shortcut = Shortcut.init) pure @safe
{
    const parsed = parseLabel(label);
    return MenuItem(MenuItemKind.command, id, parsed.text, parsed.mnemonic, shortcut);
}

MenuItem separator() pure nothrow @safe
{
    return MenuItem(MenuItemKind.separator);
}

/// A submenu; `&` in its label marks the mnemonic letter, as of a command
MenuItem submenu(string label, MenuItem[] items, MenuRole role = MenuRole.none) pure @safe
{
    const parsed = parseLabel(label);
    MenuItem item;
    item.kind = MenuItemKind.submenu;
    item.label = parsed.text;
    item.mnemonic = parsed.mnemonic;
    item.items = items;
    item.role = role;
    return item;
}

/// The items of the macOS application menu to put at the top of the one macOS already has:
/// without Quit (it has its own), without separators left at the edges or doubled, and a
/// separator after them, before the system items. Empty if nothing is left.
MenuItem[] macAppMenuMerge(MenuItem[] items) pure nothrow @safe
{
    MenuItem[] merged;
    foreach (ref item; items)
    {
        if (item.kind == MenuItemKind.command && item.id == MenuCommand.quit)
            continue;
        if (item.kind == MenuItemKind.separator
            && (merged.length == 0 || merged[$ - 1].kind == MenuItemKind.separator))
            continue;
        merged ~= item;
    }
    while (merged.length && merged[$ - 1].kind == MenuItemKind.separator)
        merged = merged[0 .. $ - 1];
    if (merged.length)
        merged ~= separator();
    return merged;
}

/// What translates the texts of the menu: the english text to the language of the interface.
alias Translate = string delegate(string text) pure @safe;

/// The menu bar of the window on `platform`, in english.
MenuItem[] appMenu(MenuPlatform platform) pure @safe
{
    return appMenu(platform, delegate(string text) => text);
}

/// The menu bar of the window on `platform`, its labels translated by `tr`; the mnemonic is
/// marked in the translation ("&Файл").
MenuItem[] appMenu(MenuPlatform platform, scope Translate tr) pure @safe
{
    // `&` marks the mnemonic letter of Windows and Linux; macOS has none
    auto openFile = command(MenuCommand.openFile, tr("&Open File..."), primary("O"));
    auto settings = command(MenuCommand.settings, tr("&Settings..."), primary(","));
    auto navigation = submenu(tr("&Navigation"), [command(MenuCommand.goToMessage, tr("&Go to Message..."), primary("G"))]);
    final switch (platform)
    {
    case MenuPlatform.mac:
        return [
            submenu("Log Tracy", [
                settings, separator(), command(MenuCommand.quit, tr("Quit"), primary("Q")),
            ], MenuRole.app),
            submenu(tr("&File"), [openFile]),
            navigation,
            submenu(tr("&Window"), [command(MenuCommand.minimize, tr("&Minimize"), primary("M"))]),
        ];
    case MenuPlatform.windows:
        return [
            submenu(tr("&File"), [
                openFile, separator(), settings, separator(),
                command(MenuCommand.quit, tr("E&xit"), Shortcut("F4", false, false, true, true)),
            ]),
            navigation,
        ];
    case MenuPlatform.linux:
        return [
            submenu(tr("&File"), [
                openFile, separator(), settings, separator(),
                command(MenuCommand.quit, tr("&Quit"), primary("Q")),
            ]),
            navigation,
        ];
    }
}

/// The text of `s` as `platform` shows it next to an item: "⇧⌘S", "Ctrl+Shift+S".
string shortcutText(in Shortcut s, MenuPlatform platform) pure @safe
{
    if (s.isNone)
        return "";
    if (platform == MenuPlatform.mac) // the order of the macOS menus: ⌃⌥⇧⌘
        return (s.alt ? "⌥" : "") ~ (s.shift ? "⇧" : "") ~ (s.primary ? "⌘" : "") ~ s.key;
    return (s.primary ? "Ctrl+" : "") ~ (s.alt ? "Alt+" : "") ~ (s.shift ? "Shift+" : "") ~ s.key;
}

/// The key equivalent of an NSMenuItem: a character key in lower case, F1..F12 as the
/// function key characters of AppKit (NSF1FunctionKey...).
string macKeyEquivalent(const Shortcut s) pure @safe
{
    import std.conv : to;
    import std.uni : toLower;

    if (s.key.length >= 2 && s.key[0] == 'F')
    {
        int n;
        try
            n = s.key[1 .. $].to!int;
        catch (Exception)
            return s.key.toLower;
        if (n >= 1 && n <= 35)
            return [cast(dchar)(0xF704 + n - 1)].to!string;
    }
    return s.key.toLower;
}

/// The key equivalent modifier mask of an NSMenuItem (NSEventModifierFlags).
ulong macModifierMask(in Shortcut s) pure nothrow @nogc @safe
{
    enum ulong shift = 1UL << 17, option = 1UL << 19, cmd = 1UL << 20;
    return (s.primary ? cmd : 0) | (s.shift ? shift : 0) | (s.alt ? option : 0);
}

/// The `KeyboardEvent.code` of the key of a shortcut: "KeyO", "Digit1", "Comma", "F4"; null
/// for a character that is no key of its own ("+": Shift+Equal), such a shortcut can't work.
string domKeyCode(string key) pure @safe
{
    import std.ascii : isAlpha, isDigit, toUpper;

    if (key.length == 1)
    {
        const c = key[0];
        if (c.isAlpha)
            return "Key" ~ c.toUpper;
        if (c.isDigit)
            return "Digit" ~ c;
        switch (c)
        {
        case ',': return "Comma";
        case '.': return "Period";
        case '/': return "Slash";
        case ';': return "Semicolon";
        case '-': return "Minus";
        case '=': return "Equal";
        case '[': return "BracketLeft";
        case ']': return "BracketRight";
        case '\'': return "Quote";
        case '`': return "Backquote";
        case '\\': return "Backslash";
        case ' ': return "Space";
        default: return null;
        }
    }
    import std.utf : count;

    if (key.count == 1)
        return null; // a character with no key of its own on the US layout
    return key; // F4, Delete, ...: named as they are
}

/// The menu for the script to show as its menu bar: what the items are, not how Sciter draws
/// them. `[{"label", "items": [...]}]`, an item `{"command", "label", "shortcut"?}`,
/// `{"separator": true}` or `{"label", "items"}`, a label as shown with `"mnemonic"`: the index of
/// its letter in UTF-16 units, if it has one and `platform` shows them; a shortcut `{"text" (as `platform` shows it),
/// "code" (`KeyboardEvent.code`), "ctrl" (the primary modifier), "shift", "alt", "bySystem"}`.
string menuJson(MenuItem[] bar, MenuPlatform platform) @safe
{
    return menuJsonValue(bar, platform).toString();
}

/// The menu of the window for the script, its labels translated by `tr`: `{"menuBar": whether
/// it draws it as its menu bar, "menus": menuJson}`.
string windowMenuJson(WindowMenu menu, scope Translate tr) @safe
{
    import std.json : JSONValue;

    JSONValue json;
    json["menuBar"] = menu.menuBar;
    json["menus"] = menuJsonValue(appMenu(menu.platform, tr), menu.platform);
    return json.toString();
}

private auto menuJsonValue(MenuItem[] bar, MenuPlatform platform) @safe
{
    import std.json : JSONValue;

    void putLabel(ref JSONValue json, ref MenuItem item)
    {
        json["label"] = item.label;
        if (platform != MenuPlatform.mac && item.mnemonic >= 0)
            json["mnemonic"] = item.mnemonic;
    }

    JSONValue itemJson(ref MenuItem item)
    {
        JSONValue json;
        final switch (item.kind)
        {
        case MenuItemKind.separator:
            json["separator"] = true;
            break;
        case MenuItemKind.submenu:
            putLabel(json, item);
            JSONValue[] items;
            foreach (ref sub; item.items)
                items ~= itemJson(sub);
            json["items"] = JSONValue(items);
            break;
        case MenuItemKind.command:
            json["command"] = item.id;
            putLabel(json, item);
            if (!item.shortcut.isNone)
            {
                JSONValue s;
                s["text"] = shortcutText(item.shortcut, platform);
                s["code"] = domKeyCode(item.shortcut.key);
                s["ctrl"] = item.shortcut.primary;
                s["shift"] = item.shortcut.shift;
                s["alt"] = item.shortcut.alt;
                s["bySystem"] = item.shortcut.bySystem;
                json["shortcut"] = s;
            }
            break;
        }
        return json;
    }

    JSONValue[] entries;
    foreach (ref entry; bar)
        entries ~= itemJson(entry);
    return JSONValue(entries);
}

version (unittest)
{
    private const(MenuItem)* find(return scope const(MenuItem)[] items, string id) pure nothrow @safe
    {
        foreach (ref item; items)
        {
            if (item.id == id)
                return &item;
            if (auto found = find(item.items, id))
                return found;
        }
        return null;
    }
}

@("every platform has the same commands")
unittest
{
    foreach (platform; [MenuPlatform.mac, MenuPlatform.windows, MenuPlatform.linux])
    {
        auto bar = appMenu(platform);
        foreach (id; [MenuCommand.openFile, MenuCommand.settings, MenuCommand.quit, MenuCommand.goToMessage])
            assert(find(bar, id) !is null, "a platform lacks " ~ id);
    }
}

@("Go to Message is in Navigation with Cmd+G / Ctrl+G")
unittest
{
    foreach (platform; [MenuPlatform.mac, MenuPlatform.windows, MenuPlatform.linux])
    {
        auto bar = appMenu(platform);
        const(MenuItem)[] navigation;
        foreach (ref menu; bar)
            if (menu.label == "Navigation")
                navigation = menu.items;
        assert(find(navigation, MenuCommand.goToMessage) !is null, "not in Navigation");
        assert(find(bar, MenuCommand.goToMessage).shortcut == primary("G"));
    }
}

@("macOS: the application menu holds Settings and Quit, Window holds Minimize")
unittest
{
    auto bar = appMenu(MenuPlatform.mac);
    assert(bar[0].role == MenuRole.app);
    assert(find(bar[0].items, MenuCommand.settings) !is null);
    assert(find(bar[0].items, MenuCommand.quit) !is null);
    assert(find(bar, MenuCommand.minimize) !is null);
    assert(find(bar, MenuCommand.quit).shortcut == primary("Q"));
}

@("Windows: File ends with Exit Alt+F4, no Window menu")
unittest
{
    auto bar = appMenu(MenuPlatform.windows);
    assert(bar.length == 2 && bar[0].label == "File" && bar[1].label == "Navigation");
    auto quit = find(bar, MenuCommand.quit);
    assert(quit.label == "Exit");
    assert(shortcutText(quit.shortcut, MenuPlatform.windows) == "Alt+F4");
    assert(bar[0].items[$ - 1].id == MenuCommand.quit);
    assert(find(bar, MenuCommand.minimize) is null);
}

@("Linux: File ends with Quit Ctrl+Q")
unittest
{
    auto bar = appMenu(MenuPlatform.linux);
    auto quit = find(bar, MenuCommand.quit);
    assert(quit.label == "Quit");
    assert(shortcutText(quit.shortcut, MenuPlatform.linux) == "Ctrl+Q");
    assert(bar[0].items[$ - 1].id == MenuCommand.quit);
}

@("shortcut texts by platform")
unittest
{
    assert(shortcutText(primary("O"), MenuPlatform.mac) == "⌘O");
    assert(shortcutText(primary("S", true), MenuPlatform.mac) == "⇧⌘S");
    assert(shortcutText(Shortcut("F", true, true, true), MenuPlatform.mac) == "⌥⇧⌘F");
    assert(shortcutText(primary("O"), MenuPlatform.windows) == "Ctrl+O");
    assert(shortcutText(Shortcut("F", true, true, true), MenuPlatform.linux) == "Ctrl+Alt+Shift+F");
    assert(shortcutText(Shortcut.init, MenuPlatform.windows) == "");
}

@("macOS key equivalent and modifier mask")
unittest
{
    assert(macKeyEquivalent(primary("O")) == "o");
    assert(macKeyEquivalent(primary(",")) == ",");
    assert(macKeyEquivalent(Shortcut.init) == "");
    assert(macKeyEquivalent(Shortcut("F4", false, false, true)) == "\uF707");
    assert(macKeyEquivalent(Shortcut("F", true)) == "f");
    assert(macModifierMask(primary("O")) == 1UL << 20);
    assert(macModifierMask(Shortcut("F", true, true, true)) == (1UL << 20 | 1UL << 17 | 1UL << 19));
}

@("macOS application menu merged into the existing one: no Quit, one separator before the system items")
unittest
{
    auto merged = macAppMenuMerge(appMenu(MenuPlatform.mac)[0].items);
    assert(merged.length == 2);
    assert(merged[0].id == MenuCommand.settings);
    assert(merged[1].kind == MenuItemKind.separator);

    auto items = [separator(), command("a", "A"), separator(), separator(), command("b", "B"),
        separator(), command(MenuCommand.quit, "Quit")];
    import std.algorithm : map;
    import std.array : array;
    assert(macAppMenuMerge(items).map!(i => i.kind).array == [MenuItemKind.command,
        MenuItemKind.separator, MenuItemKind.command, MenuItemKind.separator]);
    assert(macAppMenuMerge([command(MenuCommand.quit, "Quit")]).length == 0);
}

@("the menu of the window: a menu bar but on macOS, any for a try")
unittest
{
    assert(windowMenu(MenuPlatform.mac, "") == WindowMenu(MenuPlatform.mac, false));
    assert(windowMenu(MenuPlatform.mac, "nonsense") == WindowMenu(MenuPlatform.mac, false));
    assert(windowMenu(MenuPlatform.mac, "windows") == WindowMenu(MenuPlatform.windows, true));
    assert(windowMenu(MenuPlatform.mac, "linux") == WindowMenu(MenuPlatform.linux, true));
    assert(windowMenu(MenuPlatform.windows, "") == WindowMenu(MenuPlatform.windows, true));
    assert(windowMenu(MenuPlatform.linux, "windows") == WindowMenu(MenuPlatform.windows, true));
}

@("labels: the & of a mnemonic is not shown, it marks the letter")
unittest
{
    assert(parseLabel("E&xit") == Label("Exit", 1));
    assert(parseLabel("&File") == Label("File", 0));
    assert(parseLabel("Tom && Jerry") == Label("Tom & Jerry", -1));
    assert(parseLabel("Tom && &Jerry") == Label("Tom & Jerry", 6));
    assert(parseLabel("None") == Label("None", -1));
    assert(parseLabel("Trailing&") == Label("Trailing", -1));
    assert(parseLabel("&A &B") == Label("A B", 0)); // the first one
    assert(parseLabel("\U0001D400 &x") == Label("\U0001D400 x", 3)); // a surrogate pair before it
    // Items keep the label as shown
    assert(command("x", "E&xit").label == "Exit" && command("x", "E&xit").mnemonic == 1);
    assert(submenu("&File", []).label == "File" && submenu("&File", []).mnemonic == 0);
}

version (unittest)
{
    /// Every entry and command of `items` has a mnemonic, unique in its menu
    private void checkMnemonics(MenuItem[] items)
    {
        import std.uni : toLower;

        dchar[] used;
        foreach (ref item; items)
        {
            if (item.kind == MenuItemKind.separator)
                continue;
            const i = item.mnemonic;
            assert(i >= 0, item.label);
            import std.algorithm : canFind;
            import std.conv : to;

            const letter = item.label.to!wstring[i].toLower;
            assert(!used.canFind(letter), item.label);
            used ~= letter;
            checkMnemonics(item.items);
        }
    }
}

@("every entry and command of Windows and Linux has a mnemonic, unique in its menu")
unittest
{
    checkMnemonics(appMenu(MenuPlatform.windows));
    checkMnemonics(appMenu(MenuPlatform.linux));
}

@("the menus of every catalog built in have their mnemonics, unique in a menu")
unittest
{
    import ui.app_resources : builtInCatalogs;
    import ui.translations : findTranslations, parseCatalog;

    const translations = findTranslations(builtInCatalogs());
    assert(translations.length > 0, "the catalogs of the project");
    foreach (t; translations)
    {
        const catalog = parseCatalog(t.text);
        checkMnemonics(appMenu(MenuPlatform.windows, &catalog.translate));
        checkMnemonics(appMenu(MenuPlatform.linux, &catalog.translate));
    }
}
@("DOM key codes of shortcut keys")
unittest
{
    assert(domKeyCode("O") == "KeyO");
    assert(domKeyCode("o") == "KeyO");
    assert(domKeyCode("1") == "Digit1");
    assert(domKeyCode(",") == "Comma");
    assert(domKeyCode(".") == "Period");
    assert(domKeyCode("F4") == "F4");
    assert(domKeyCode("[") == "BracketLeft");
    assert(domKeyCode("'") == "Quote");
    assert(domKeyCode(" ") == "Space");
    assert(domKeyCode("+") is null); // Shift+Equal on one layout, NumpadAdd: no single code
    assert(domKeyCode("é") is null);
}

@("every shortcut of the menu has a DOM key code")
unittest
{
    void check(MenuItem[] items)
    {
        foreach (ref item; items)
        {
            check(item.items);
            if (!item.shortcut.isNone)
                assert(domKeyCode(item.shortcut.key) !is null, item.shortcut.key);
        }
    }

    foreach (platform; [MenuPlatform.mac, MenuPlatform.windows, MenuPlatform.linux])
        check(appMenu(platform));
}

@("menu for the script: submenus, commands, separators, shortcuts by platform")
unittest
{
    import std.json : parseJSON;

    auto bar = [
        submenu("File", [
            command("file.open", "Open", primary("O")),
            separator(),
            command("none", "None"),
            submenu("Recent", []),
            command("app.quit", "Exit", Shortcut("F4", false, false, true, true)),
        ]),
    ];
    assert(parseJSON(menuJson(bar, MenuPlatform.windows)) == parseJSON(`[{"label": "File", "items": [
        {"command": "file.open", "label": "Open", "shortcut": {"text": "Ctrl+O", "code": "KeyO",
            "ctrl": true, "shift": false, "alt": false, "bySystem": false}},
        {"separator": true},
        {"command": "none", "label": "None"},
        {"label": "Recent", "items": []},
        {"command": "app.quit", "label": "Exit", "shortcut": {"text": "Alt+F4", "code": "F4",
            "ctrl": false, "shift": false, "alt": true, "bySystem": true}}
    ]}]`));
    auto mac = parseJSON(menuJson([submenu("File", [command("a", "A", primary("S", true))])], MenuPlatform.mac));
    assert(mac[0]["items"][0]["shortcut"]["text"].str == "⇧⌘S");

    // A label is given as shown, with the index of its mnemonic; macOS has none
    auto withMnemonics = [submenu("&File", [command("x", "E&xit")])];
    assert(parseJSON(menuJson(withMnemonics, MenuPlatform.linux)) == parseJSON(`[{"label": "File",
        "mnemonic": 0, "items": [{"command": "x", "label": "Exit", "mnemonic": 1}]}]`));
    assert(parseJSON(menuJson(withMnemonics, MenuPlatform.mac)) == parseJSON(`[{"label": "File",
        "items": [{"command": "x", "label": "Exit"}]}]`));
}

@("appMenu: the labels are translated, the mnemonic is that of the translation")
unittest
{
    string russian(string text) pure @safe
    {
        switch (text)
        {
        case "&File": return "&Файл";
        case "E&xit": return "В&ыход";
        case "&Open File...": return "&Открыть файл...";
        default: return text;
        }
    }

    auto bar = appMenu(MenuPlatform.windows, &russian);
    assert(bar[0].label == "Файл" && bar[0].mnemonic == 0);
    assert(bar[0].items[0].label == "Открыть файл..." && bar[0].items[0].mnemonic == 0);
    assert(bar[0].items[$ - 1].label == "Выход" && bar[0].items[$ - 1].mnemonic == 1);
    assert(bar[0].items[2].label == "Settings...", "a text not translated stays english");
    assert(appMenu(MenuPlatform.mac, &russian)[0].label == "Log Tracy", "the name of the application is no text to translate");
}

@("windowMenuJson: the menu translated")
unittest
{
    import std.json : parseJSON;

    string upper(string text) pure @safe
    {
        import std.uni : toUpper;
        return text.toUpper;
    }

    const json = parseJSON(windowMenuJson(windowMenu(MenuPlatform.windows, ""), &upper));
    assert(json["menus"][0]["label"].str == "FILE");
}
