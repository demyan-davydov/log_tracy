//! The files of the interface (resources/: HTML, CSS, JS, the catalogs of translations), built
//! into the executable by string imports and served to Sciter at `this://app/<path>`. Free of
//! Sciter.
module ui.app_resources;

import ui.translations : CatalogFile;

/// The address of the files of the interface: `this://app/main.htm`
enum appResourceUrl = "this://app/";

/// The files of resources/ built in, by their paths in it. Every file of resources/ is either
/// here or in `notBuiltIn`: a unittest checks it.
private enum string[] builtIn = [
    "backend.js",
    "column-settings.js",
    "document-pane.js",
    "drag-order.js",
    "drag-strip.js",
    "edit-history.js",
    "file-info.js",
    "file-types.js",
    "filter-panel.js",
    "go-to-message.htm",
    "go-to-message.js",
    "i18n/dom.js",
    "i18n/i18n.js",
    "i18n/languages.js",
    "i18n/plural.js",
    "i18n/translations/ru.json",
    "main.htm",
    "match-colors.css",
    "match-colors.js",
    "menu-bar.css",
    "menu-bar.js",
    "menu-shortcuts.js",
    "new-tab.js",
    "notice.js",
    "osx-frame.css",
    "pane-commands.js",
    "pane-state.js",
    "panel-sizes.js",
    "platform.js",
    "pointer-handlers.js",
    "press-focus.js",
    "recent-file-menu.js",
    "recent-time.js",
    "rect-popup.js",
    "row-selection.js",
    "rule-colors.js",
    "rule-editor.htm",
    "rule-form.js",
    "script.js",
    "search-bar.js",
    "search-editing.js",
    "search-editor.css",
    "search-editor.js",
    "search-query.js",
    "settings-sections.js",
    "settings.htm",
    "status-view.js",
    "style.css",
    "tab-content.css",
    "log-table-look.js",
    "anchor-click.js",
    "column-tip.js",
    "geometry.js",
    "log-table-gesture.js",
    "log-table-view.js",
    "menu-gate.js",
    "table.css",
    "tabs.js",
    "theme-dark.css",
    "theme-light.css",
    "theme.js",
    "view-table.js",
    "win-frame.css",
    "window-frame.js",
    "window-state.js",
];

/// The files of resources/ the interface doesn't use: the Windows resource script and every file
/// of icons/ (the logo and the icons made of it by scripts/utils/make-icons.mjs), taken by dist
// debug-eval.js: evaluated by the debug channel (ui/debug_protocol), never served to the window
private enum string[] notBuiltIn = ["app.rc", "debug-eval.js"];
private enum notBuiltInFolder = "icons/";

/// The file at `path` of resources/ ("main.htm", "i18n/i18n.js"), null if none is built in.
immutable(ubyte)[] appResource(string path)
{
    switch (path)
    {
        static foreach (file; builtIn)
        {
    case file:
            return cast(immutable(ubyte)[]) import(file);
        }
    default:
        return null;
    }
}

/// The file at `url` (`this://app/<path>`, %-escapes decoded, a fragment or query after it
/// aside), null if the url is no such address or none is built in there.
immutable(ubyte)[] appResourceOfUrl(string url)
{
    import std.algorithm : findSplitBefore, skipOver;
    import std.uri : decodeComponent, URIException;

    if (!url.skipOver(appResourceUrl))
        return null;
    try
        return appResource(decodeComponent(url.findSplitBefore("#")[0].findSplitBefore("?")[0]));
    catch (URIException)
        return null; // a bad escape
}

/// The catalogs of translations built in (resources/i18n/translations/*.json).
CatalogFile[] builtInCatalogs()
{
    import std.algorithm : startsWith;

    enum folder = "i18n/translations/";
    CatalogFile[] catalogs;
    static foreach (file; builtIn)
        static if (file.startsWith(folder))
            catalogs ~= CatalogFile(file[folder.length .. $], import(file));
    return catalogs;
}

@("every file of resources/ is built in, but the icons")
unittest
{
    import std.algorithm : canFind, filter, map, setSymmetricDifference, sort, startsWith;
    import std.array : array, join, replace;
    import std.file : dirEntries, SpanMode;
    import std.path : baseName;

    // dub test runs at the root; .DS_Store and the like are no files of the project
    auto onDisk = dirEntries("resources", SpanMode.depth)
        .filter!(e => e.isFile && !e.name.baseName.startsWith("."))
        .map!(e => e.name.replace("\\", "/")["resources/".length .. $])
        .filter!(p => !notBuiltIn.canFind(p) && !p.startsWith(notBuiltInFolder))
        .array.sort.array;
    const listed = builtIn.dup.sort.array;
    assert(onDisk == listed, "add to builtIn in ui/app_resources (or to notBuiltIn), or remove: "
        ~ setSymmetricDifference(onDisk, listed).join(", "));
}

@("appResource: the contents of a file of resources/, in a folder too; null if none")
unittest
{
    import std.file : read;

    assert(appResource("main.htm") == cast(immutable(ubyte)[]) read("resources/main.htm"));
    assert(appResource("i18n/plural.js").length > 0);
    assert(appResource("no-such.js") is null);
    assert(appResource("icons/app.icns") is null, "the icons are not built in");
}

@("appResourceOfUrl: a file at this://app/, nothing at another address")
unittest
{
    assert(appResourceOfUrl("this://app/main.htm") == appResource("main.htm"));
    assert(appResourceOfUrl("this://app/i18n/i18n.js") == appResource("i18n/i18n.js"));
    assert(appResourceOfUrl("this://app/no-such.js") is null);
    assert(appResourceOfUrl("this://app/table.css#log-table") == appResource("table.css"), "a fragment names a part of the file");
    assert(appResourceOfUrl("this://app/main.htm?x=1") == appResource("main.htm"));
    assert(appResourceOfUrl("this://app/i18n%2Fi18n.js") == appResource("i18n/i18n.js"), "an escaped address");
    assert(appResourceOfUrl("this://app/main%2.htm") is null, "a bad escape names no file");
    assert(appResourceOfUrl("file:///main.htm") is null);
    assert(appResourceOfUrl("main.htm") is null);
}

@("builtInCatalogs: the catalogs of resources/i18n/translations by their file names")
unittest
{
    import std.algorithm : canFind;

    const catalogs = builtInCatalogs();
    assert(catalogs.canFind!(c => c.name == "ru.json" && c.text.length > 0));
    foreach (c; catalogs)
        assert(c.name.length > 5 && c.name[$ - 5 .. $] == ".json");
}
