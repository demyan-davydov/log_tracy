//! The translations of the interface the application has: the catalogs of a folder
//! (`resources/i18n/translations/<BCP 47 tag>.json`, see `resources/i18n/i18n.js`), which of
//! them a language asked for takes, and the text of that catalog for the script. Free of
//! Sciter.
module ui.translations;

import std.json;
import std.stdio : writeln;

/// A catalog found: its language and the file it is in.
struct Translation
{
    string locale; /// BCP 47 tag: "ru", "pt-BR"
    string name; /// the name of the language in that language: "Русский"
    string path;
}

/// The catalogs of `dir`, by locale; a file that is no catalog (no JSON, no locale or name)
/// is skipped. None if `dir` doesn't exist.
Translation[] findTranslations(string dir)
{
    import std.algorithm : sort;
    import std.file : dirEntries, exists, isDir, readText, SpanMode;

    Translation[] found;
    if (!exists(dir) || !isDir(dir))
        return found;
    foreach (entry; dirEntries(dir, "*.json", SpanMode.shallow))
    {
        try
        {
            const j = parseJSON(readText(entry.name));
            const locale = "locale" in j, name = "name" in j;
            if (locale && name && locale.type == JSONType.string && name.type == JSONType.string
                && locale.str.length && name.str.length)
                found ~= Translation(locale.str, name.str, entry.name);
            else
                writeln("Not a catalog of translations: ", entry.name);
        }
        catch (Exception e)
            writeln("Can't read the catalog ", entry.name, ": ", e.msg);
    }
    found.sort!((a, b) => a.locale < b.locale);
    return found;
}

/// The locale of `available` that `requested` takes ("ru-KZ" takes "ru"): the tag itself, then
/// the tag with its parts cut from the right, then any tag of the same language; null if
/// none, the english source then. Case doesn't matter; "_" is taken as "-" ("ru_RU"). A
/// private ("x-pseudo") or grandfathered ("i-klingon") tag takes only itself.
string resolveLocale(string requested, const string[] available)
{
    import std.algorithm : findSplitBefore;
    import std.array : replace, split;
    import std.string : toLower, lastIndexOf;

    // "ru_RU.UTF-8": the encoding and the modifier are no part of a tag
    auto tag = requested.findSplitBefore(".")[0].findSplitBefore("@")[0].replace("_", "-").toLower;
    while (tag.length)
    {
        foreach (locale; available)
            if (locale.toLower == tag)
                return locale;
        const cut = tag.lastIndexOf('-');
        if (cut < 0)
            break;
        tag = tag[0 .. cut];
    }
    // "x-..." (private use) and "i-..." (grandfathered) are no language of their own
    if (!tag.length || tag == "x" || tag == "i")
        return null;
    foreach (locale; available)
        if (locale.toLower.split("-")[0] == tag)
            return locale;
    return null;
}

/// The languages of `translations` as JSON for the script: [{"locale", "name"}].
string languagesJson(const Translation[] translations)
{
    JSONValue[] languages;
    foreach (t; translations)
        languages ~= JSONValue(["locale": t.locale, "name": t.name]);
    return JSONValue(languages).toString;
}

/// The text of the catalog `requested` takes (`resolveLocale`), null if none or if it can't
/// be read.
string translationJson(const Translation[] translations, string requested)
{
    import std.algorithm : map;
    import std.array : array;
    import std.file : readText;

    const locale = resolveLocale(requested, translations.map!(t => t.locale).array);
    foreach (t; translations)
        if (t.locale == locale)
        {
            try
                return readText(t.path);
            catch (Exception e)
            {
                writeln("Can't read the catalog ", t.path, ": ", e.msg);
                return null;
            }
        }
    return null;
}

version (unittest)
{
    import std.file : mkdirRecurse, rmdirRecurse, write, exists, tempDir;
    import std.path : buildPath;

    /// An empty folder of the temporary ones for the tests of `name`, made anew
    package string makeTestDir(string name)
    {
        const dir = buildPath(tempDir, "dlt-explorer-translations-" ~ name);
        if (exists(dir))
            rmdirRecurse(dir);
        mkdirRecurse(dir);
        return dir;
    }
}

@("resolveLocale: the tag itself, case aside")
unittest
{
    assert(resolveLocale("ru", ["de", "ru"]) == "ru");
    assert(resolveLocale("pt-br", ["pt-BR"]) == "pt-BR");
}

@("resolveLocale: the parts of the tag are cut from the right")
unittest
{
    assert(resolveLocale("ru-KZ", ["ru"]) == "ru");
    assert(resolveLocale("zh-Hans-CN", ["zh-Hans", "zh-Hant"]) == "zh-Hans");
    assert(resolveLocale("ru_RU.UTF-8", ["ru"]) == "ru", "a POSIX locale");
}

@("resolveLocale: else any tag of the same language")
unittest
{
    assert(resolveLocale("pt-PT", ["de", "pt-BR"]) == "pt-BR");
    assert(resolveLocale("pt", ["pt-BR"]) == "pt-BR");
}

@("resolveLocale: none of the language: null")
unittest
{
    assert(resolveLocale("de", ["ru"]) is null);
    assert(resolveLocale("en-US", ["ru"]) is null);
    assert(resolveLocale("", ["ru"]) is null);
    assert(resolveLocale("ru", []) is null);
}

@("resolveLocale: a private or grandfathered tag (x-, i-) takes no other of its prefix")
unittest
{
    assert(resolveLocale("x-pseudo", ["x-klingon"]) is null);
    assert(resolveLocale("i-klingon", ["i-default"]) is null);
    assert(resolveLocale("X-Pseudo", ["x-pseudo"]) == "x-pseudo", "the tag itself still");
}

@("findTranslations: the catalogs of a folder by locale, the rest skipped")
unittest
{
    const dir = makeTestDir("find");
    scope (exit) rmdirRecurse(dir);
    write(buildPath(dir, "ru.json"), `{"locale": "ru", "name": "Русский", "messages": {}}`);
    write(buildPath(dir, "de.json"), `{"locale": "de", "name": "Deutsch", "messages": {}}`);
    write(buildPath(dir, "broken.json"), `{"locale": `);
    write(buildPath(dir, "nameless.json"), `{"locale": "fr"}`);
    write(buildPath(dir, "notes.txt"), `{"locale": "it", "name": "Italiano"}`);

    const found = findTranslations(dir);
    assert(found.length == 2);
    assert(found[0] == Translation("de", "Deutsch", buildPath(dir, "de.json")));
    assert(found[1] == Translation("ru", "Русский", buildPath(dir, "ru.json")));
}

@("findTranslations: no folder, no catalogs")
unittest
{
    assert(findTranslations(buildPath(tempDir, "dlt-explorer-no-such-folder")).length == 0);
}

@("languagesJson: the locale and name of each")
unittest
{
    const json = parseJSON(languagesJson([Translation("ru", "Русский", "/x/ru.json")]));
    assert(json.array.length == 1);
    assert(json[0]["locale"].str == "ru" && json[0]["name"].str == "Русский");
    assert("path" !in json[0], "where the file is is no business of the script");
}

@("translationJson: the text of the catalog the language takes")
unittest
{
    const dir = makeTestDir("text");
    scope (exit) rmdirRecurse(dir);
    const text = `{"locale": "ru", "name": "Русский", "messages": {"Open": "Открыть"}}`;
    write(buildPath(dir, "ru.json"), text);
    const translations = findTranslations(dir);

    assert(translationJson(translations, "ru-RU") == text);
    assert(translationJson(translations, "en") is null, "english is the source");
    rmdirRecurse(dir);
    mkdirRecurse(dir);
    assert(translationJson(translations, "ru") is null, "a file gone is no catalog");
}
