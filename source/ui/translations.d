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

/// The translations of the texts of the backend (the menu): the plain texts of a catalog.
struct Catalog
{
    string[string] messages; /// by the english text, translated ones only
    bool pseudo; /// every text pseudoized: the pseudo locale

    /// The translation of `text`, `text` itself if none
    string translate(string text) const pure @safe
    {
        if (pseudo)
            return pseudoize(text);
        if (const translated = text in messages)
            return *translated;
        return text;
    }
}

/// The locale of the pseudo translation, as in resources/i18n/i18n.js
enum pseudoLocale = "x-pseudo";

/// The catalog of the text of a catalog file; empty if it is no catalog.
Catalog parseCatalog(string json)
{
    Catalog catalog;
    if (!json.length)
        return catalog;
    try
    {
        const j = parseJSON(json);
        const messages = "messages" in j;
        if (!messages || messages.type != JSONType.object)
            return catalog;
        foreach (key, value; messages.object)
            if (value.type == JSONType.string && value.str.length)
                catalog.messages[key] = value.str;
    }
    catch (Exception e)
        writeln("Can't read the catalog: ", e.msg);
    return catalog;
}

/// The catalog of `locale`: pseudo for the pseudo locale, else that of `json`.
Catalog catalogOf(string locale, string json)
{
    import std.uni : sicmp;

    if (sicmp(locale, pseudoLocale) == 0)
        return Catalog(null, true);
    return parseCatalog(json);
}

/// The pseudo translation of `text`, as pseudoize of resources/i18n/i18n.js (lengths in UTF-16
/// units, as of a script string).
string pseudoize(string text) pure @safe
{
    import std.algorithm : max;
    import std.array : appender, replicate;
    import std.ascii : isAlphaNum;
    import std.math : round;
    import std.utf : codeLength, decode;

    static immutable upper = "ÅƁÇÐÉƑĜĤÎĴĶĻṀÑÔÞǪŔŠŢÛṼŴẊÝŽ"d;
    static immutable lower = "áƀçðéƒĝĥîĵķļṁñôþǫŕšţûṽŵẋýž"d;

    auto body = appender!string;
    size_t visible;
    size_t i;
    while (i < text.length)
    {
        if (text[i] == '{') // a parameter stays as it is
        {
            size_t j = i + 1;
            while (j < text.length && (isAlphaNum(text[j]) || text[j] == '_'))
                j++;
            if (j > i + 1 && j < text.length && text[j] == '}')
            {
                body.put(text[i .. j + 1]);
                i = j + 1;
                continue;
            }
        }
        const start = i;
        const c = decode(text, i);
        if (c == '&' && i < text.length) // the mnemonic letter stays as it is
        {
            visible += codeLength!wchar(decode(text, i));
            body.put(text[start .. i]);
            continue;
        }
        else if (c >= 'A' && c <= 'Z')
            body.put(upper[c - 'A']);
        else if (c >= 'a' && c <= 'z')
            body.put(lower[c - 'a']);
        else
            body.put(text[start .. i]);
        visible += codeLength!wchar(c); // as the length of a script string
    }
    const padding = max(1, cast(size_t) round(visible * 0.3));
    return "[" ~ body[] ~ " " ~ "~".replicate(padding) ~ "]";
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

@("parseCatalog: the translated texts of a catalog; plural ones and untranslated are not")
unittest
{
    const catalog = parseCatalog(`{"locale": "ru", "name": "Русский", "messages": {
        "&File": "&Файл", "Quit": "", "{n} file": {"one": "{n} файл"}}}`);
    assert(catalog.translate("&File") == "&Файл");
    assert(catalog.translate("Quit") == "Quit", "not translated yet: english");
    assert(catalog.translate("Gone") == "Gone");
    assert(catalog.messages.length == 1);
}

@("parseCatalog: no catalog, no translations")
unittest
{
    assert(parseCatalog(null).translate("A") == "A");
    assert(parseCatalog(`{"messages": `).translate("A") == "A");
    assert(parseCatalog(`{"messages": 5}`).translate("A") == "A");
}

@("pseudoize: as resources/i18n/i18n.js does it")
unittest
{
    assert(pseudoize("Open") == "[Ôþéñ ~]");
    assert(pseudoize("Settings") == "[Šéţţîñĝš ~~]");
    assert(pseudoize("{count} of {total}") == "[{count} ôƒ {total} ~]");
    assert(pseudoize("E&xit") == "[É&xîţ ~]");
    assert(pseudoize("😀😀😀😀😀") == "[😀😀😀😀😀 ~~~]", "lengths in UTF-16 units, as of a script string");
    assert(pseudoize("&😀😀😀😀😀") == "[&😀😀😀😀😀 ~~~]");
}

@("catalogOf: the pseudo locale pseudoizes every text, in any case")
unittest
{
    assert(catalogOf("x-pseudo", null).translate("Open") == "[Ôþéñ ~]");
    assert(catalogOf("X-Pseudo", null).translate("Open") == "[Ôþéñ ~]");
    assert(catalogOf("ru", `{"messages": {"Open": "Открыть"}}`).translate("Open") == "Открыть");
}
