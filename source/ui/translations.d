//! The translations of the interface the application has: its catalogs
//! (`resources/i18n/translations/<BCP 47 tag>.json`, see `resources/i18n/i18n.js`, built in by
//! `ui/app_resources`), which of them a language asked for takes, and the text of that catalog
//! for the script. Free of Sciter.
module ui.translations;

import std.json;
import std.stdio : writeln;
import utils.ui_text : render, UiText;

/// A file that may be a catalog: its name ("ru.json") and its text.
struct CatalogFile
{
    string name;
    string text;
}

/// A catalog found: its language, the file it is in and its text.
struct Translation
{
    string locale; /// BCP 47 tag: "ru", "pt-BR"
    string name; /// the name of the language in that language: "Русский"
    string file; /// "ru.json"
    string text;
}

/// The catalogs of `files`, by locale; a file that is no catalog (no .json, no JSON, no locale
/// or name) is skipped, so is a second catalog of a locale (a copy): the one named by the
/// locale (ru.json) is taken, else the first by name.
Translation[] findTranslations(const CatalogFile[] files)
{
    import std.algorithm : endsWith, sort;
    import std.path : baseName, stripExtension;

    Translation[] found;
    foreach (file; files)
    {
        if (!file.name.endsWith(".json"))
            continue;
        try
        {
            const j = parseJSON(file.text);
            const locale = "locale" in j, name = "name" in j;
            if (locale && name && locale.type == JSONType.string && name.type == JSONType.string
                && locale.str.length && name.str.length)
                found ~= Translation(locale.str, name.str, file.name, file.text);
            else
                writeln("Not a catalog of translations: ", file.name);
        }
        catch (Exception e)
            writeln("Can't read the catalog ", file.name, ": ", e.msg);
    }

    // The file named by its locale first, then by name: the first of a locale is taken
    const named = (const Translation t) => t.file.baseName.stripExtension == t.locale;
    found.sort!((a, b) => a.locale != b.locale ? a.locale < b.locale
        : named(a) != named(b) ? named(a) : a.file < b.file);
    Translation[] unique;
    foreach (t; found)
        if (unique.length && unique[$ - 1].locale == t.locale)
            writeln("A second catalog of ", t.locale, " is not taken: ", t.file);
        else
            unique ~= t;
    return unique;
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
    // Another tag of the language, but not of another script (zh-Hant is no zh-Hans)
    const script = scriptOf(requested.replace("_", "-").toLower);
    foreach (locale; available)
    {
        const lower = locale.toLower;
        const other = scriptOf(lower);
        if (lower.split("-")[0] == tag && (script.length == 0 || other.length == 0 || other == script))
            return locale;
    }
    return null;
}

// The script subtag of a lowered tag ("hant" of "zh-hant-tw"), "" if none: four letters
private string scriptOf(string tag)
{
    import std.algorithm : all, find;
    import std.ascii : isAlpha;
    import std.array : split;

    auto parts = tag.split("-");
    if (parts.length < 2)
        return "";
    auto found = parts[1 .. $].find!(p => p.length == 4 && p.all!isAlpha);
    return found.length ? found[0] : "";
}

/// The languages of `translations` as JSON for the script: [{"locale", "name"}].
string languagesJson(const Translation[] translations)
{
    JSONValue[] languages;
    foreach (t; translations)
        languages ~= JSONValue(["locale": t.locale, "name": t.name]);
    return JSONValue(languages).toString;
}

/// The text of the catalog `requested` takes (`resolveLocale`), null if none.
string translationJson(const Translation[] translations, string requested)
{
    import std.algorithm : map;
    import std.array : array;

    const locale = resolveLocale(requested, translations.map!(t => t.locale).array);
    foreach (t; translations)
        if (t.locale == locale)
            return t.text;
    return null;
}

/// The translations of the texts of the backend (the menu, the errors): the plain texts of a
/// catalog. The pseudo locale has none: the script pseudoizes its own texts, those of the
/// backend stay english.
struct Catalog
{
    string[string] messages; /// by the english text, translated ones only

    /// `t` in the language of the catalog: its templates translated, its plain parameters
    /// (the texts of the OS, names, paths) as they are
    string translate(const UiText t) const @safe
    {
        return render(t, (string text) => translate(text));
    }

    /// The translation of `text`, `text` itself if none
    string translate(string text) const pure @safe
    {
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

@("resolveLocale: another tag of the language, but not of another script")
unittest
{
    assert(resolveLocale("zh-Hant-TW", ["zh-Hans"]) is null, "traditional is not simplified");
    assert(resolveLocale("sr-Latn", ["sr-Cyrl"]) is null);
    assert(resolveLocale("zh-Hant-TW", ["zh-Hans", "zh-Hant"]) == "zh-Hant");
    assert(resolveLocale("sr-Latn-RS", ["sr"]) == "sr", "a catalog of no script is the language's");
    assert(resolveLocale("pt-PT", ["pt-BR"]) == "pt-BR", "a region is no script");
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

@("findTranslations: the catalogs by locale, the rest skipped")
unittest
{
    const ru = `{"locale": "ru", "name": "Русский", "messages": {}}`;
    const de = `{"locale": "de", "name": "Deutsch", "messages": {}}`;
    const found = findTranslations([CatalogFile("ru.json", ru), CatalogFile("de.json", de),
        CatalogFile("broken.json", `{"locale": `), CatalogFile("nameless.json", `{"locale": "fr"}`),
        CatalogFile("notes.txt", `{"locale": "it", "name": "Italiano"}`)]);
    assert(found.length == 2);
    assert(found[0] == Translation("de", "Deutsch", "de.json", de));
    assert(found[1] == Translation("ru", "Русский", "ru.json", ru));
}

@("findTranslations: a locale twice (a copy of a catalog) is listed once, by the file named so")
unittest
{
    const found = findTranslations([
        CatalogFile("ru-old.json", `{"locale": "ru", "name": "Русский (старый)", "messages": {}}`),
        CatalogFile("ru.json", `{"locale": "ru", "name": "Русский", "messages": {}}`)]);
    assert(found.length == 1);
    assert(found[0].file == "ru.json", "ru.json, not the copy");
}

@("findTranslations: no files, no catalogs")
unittest
{
    assert(findTranslations(null).length == 0);
}

@("languagesJson: the locale and name of each")
unittest
{
    const json = parseJSON(languagesJson([Translation("ru", "Русский", "ru.json", "{}")]));
    assert(json.array.length == 1);
    assert(json[0]["locale"].str == "ru" && json[0]["name"].str == "Русский");
    assert("file" !in json[0] && "text" !in json[0], "no business of the script");
}

@("translationJson: the text of the catalog the language takes")
unittest
{
    const text = `{"locale": "ru", "name": "Русский", "messages": {"Open": "Открыть"}}`;
    const translations = findTranslations([CatalogFile("ru.json", text)]);

    assert(translationJson(translations, "ru-RU") == text);
    assert(translationJson(translations, "en") is null, "english is the source");
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

@("Catalog.translate: a text for the user, its templates translated, plain parameters as they are")
unittest
{
    import utils.ui_text : uiText;

    const catalog = parseCatalog(`{"messages": {
        "Can't load the filter: {reason}": "Не удалось загрузить фильтр: {reason}",
        "no column \"{column}\" in this log": "в этом журнале нет колонки «{column}»"}}`);
    const t = uiText("Can't load the filter: {reason}", "reason",
        uiText("no column \"{column}\" in this log", "column", "ecu"));
    assert(catalog.translate(t) == "Не удалось загрузить фильтр: в этом журнале нет колонки «ecu»");
    assert(catalog.translate(uiText("Can't load the filter: {reason}", "reason", "Permission denied"))
        == "Не удалось загрузить фильтр: Permission denied", "the text of the OS as it is");
    assert(Catalog.init.translate(t) == "Can't load the filter: no column \"ecu\" in this log");
}
