//! The main menu of the window, described once for every platform: its entries by the
//! conventions of each platform (`appMenu`), the texts of their shortcuts, and the menu bar
//! markup Sciter shows on Windows and Linux. Free of Sciter: the native macOS menu is built
//! from it by `ui/main_menu_loader`.
module ui.app_menu;

/// The platform whose conventions a menu follows.
enum MenuPlatform
{
    mac,
    windows,
    linux,
}

/// The commands of the menu, given to the script's `onMenuCommand(id)` on every platform.
enum MenuCommand : string
{
    settings = "app.settings",
    quit = "app.quit",
    openFile = "file.open",
    minimize = "window.minimize",
}

/// A key combination, independent of the platform.
struct Shortcut
{
    string key; /// "O", ",", "F4"; empty: no shortcut
    bool primary; /// Cmd on macOS, Ctrl elsewhere
    bool shift;
    bool alt; /// Option on macOS

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
    string label;
    Shortcut shortcut;
    MenuItem[] items; /// of a submenu
    MenuRole role;
}

MenuItem command(string id, string label, Shortcut shortcut = Shortcut.init) pure nothrow @safe
{
    return MenuItem(MenuItemKind.command, id, label, shortcut);
}

MenuItem separator() pure nothrow @safe
{
    return MenuItem(MenuItemKind.separator);
}

MenuItem submenu(string label, MenuItem[] items, MenuRole role = MenuRole.none) pure nothrow @safe
{
    MenuItem item;
    item.kind = MenuItemKind.submenu;
    item.label = label;
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

/// The menu bar of the window on `platform`.
MenuItem[] appMenu(MenuPlatform platform) pure nothrow @safe
{
    auto openFile = command(MenuCommand.openFile, "Open File...", primary("O"));
    auto settings = command(MenuCommand.settings, "Settings...", primary(","));
    final switch (platform)
    {
    case MenuPlatform.mac:
        return [
            submenu("DLT Explorer", [
                settings, separator(), command(MenuCommand.quit, "Quit", primary("Q")),
            ], MenuRole.app),
            submenu("File", [openFile]),
            submenu("Window", [command(MenuCommand.minimize, "Minimize", primary("M"))]),
        ];
    case MenuPlatform.windows:
        return [
            submenu("File", [
                openFile, separator(), settings, separator(),
                command(MenuCommand.quit, "Exit", Shortcut("F4", false, false, true)),
            ]),
        ];
    case MenuPlatform.linux:
        return [
            submenu("File", [
                openFile, separator(), settings, separator(),
                command(MenuCommand.quit, "Quit", primary("Q")),
            ]),
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

/// The markup of the Sciter menu bar (`behavior: menu-bar`) for `bar`: an item carries its
/// command in the `command` attribute.
string menuBarHtml(in MenuItem[] bar, MenuPlatform platform) pure @safe
{
    import std.array : appender;

    auto html = appender!string;

    void putEscaped(string text)
    {
        foreach (c; text)
        {
            switch (c)
            {
            case '&': html.put("&amp;"); break;
            case '<': html.put("&lt;"); break;
            case '>': html.put("&gt;"); break;
            case '"': html.put("&quot;"); break;
            default: html.put(c);
            }
        }
    }

    void putMenu(in MenuItem[] items)
    {
        html.put("<menu>");
        foreach (ref item; items)
        {
            if (item.kind == MenuItemKind.separator)
            {
                html.put("<hr/>");
                continue;
            }
            if (item.kind == MenuItemKind.submenu)
                html.put("<li>");
            else
            {
                html.put(`<li command="`);
                putEscaped(item.id);
                html.put(`">`);
            }
            putEscaped(item.label);
            if (item.kind == MenuItemKind.submenu)
                putMenu(item.items);
            else if (!item.shortcut.isNone)
            {
                html.put(`<span class="accesskey">`);
                putEscaped(shortcutText(item.shortcut, platform));
                html.put("</span>");
            }
            html.put("</li>");
        }
        html.put("</menu>");
    }

    html.put(`<ul id="menu-bar">`);
    foreach (ref entry; bar)
    {
        html.put("<li><caption>");
        putEscaped(entry.label);
        html.put("</caption>");
        putMenu(entry.items);
        html.put("</li>");
    }
    html.put("</ul>");
    return html[];
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
        foreach (id; [MenuCommand.openFile, MenuCommand.settings, MenuCommand.quit])
            assert(find(bar, id) !is null, "a platform lacks " ~ id);
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
    assert(bar.length == 1 && bar[0].label == "File");
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

@("menu bar markup: captions, commands, shortcuts, separators, escaping")
unittest
{
    auto bar = [
        submenu("File", [
            command("file.open", "Open <File>...", primary("O")),
            separator(),
            command("a&b", "Tom & \"Jerry\""),
            submenu("More", [command("x", "X")]),
        ]),
    ];
    assert(menuBarHtml(bar, MenuPlatform.windows) ==
        `<ul id="menu-bar"><li><caption>File</caption><menu>`
        ~ `<li command="file.open">Open &lt;File&gt;...<span class="accesskey">Ctrl+O</span></li>`
        ~ `<hr/>`
        ~ `<li command="a&amp;b">Tom &amp; &quot;Jerry&quot;</li>`
        ~ `<li>More<menu><li command="x">X</li></menu></li>`
        ~ `</menu></li></ul>`);
}

@("an empty submenu stays a submenu, not a command")
unittest
{
    auto bar = [submenu("File", [submenu("Recent", [])])];
    assert(menuBarHtml(bar, MenuPlatform.windows) ==
        `<ul id="menu-bar"><li><caption>File</caption><menu>`
        ~ `<li>Recent<menu></menu></li>`
        ~ `</menu></li></ul>`);
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
