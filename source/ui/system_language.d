//! The language of the app and that of the OS: tells the OS the language the user chose, for
//! the dialogs it draws itself (macOS: the AppleLanguages of the app, which its file dialogs
//! and the items AppKit adds follow from the next start, see ui/translations.appleLanguagesFor;
//! elsewhere nothing, the dialogs are in the language of the system), and tells the language of
//! the system as the OS keeps it: on macOS the app's own AppleLanguages override what the app
//! is told otherwise (Sciter's env.language() among it).
module ui.system_language;

/// The dialogs of the OS are to be in `languages` (BCP 47 tags, the first preferred); null:
/// in the language of the system. Written only when it changes, and only for the app as a
/// bundle (with an identifier): copies run from the build folder share no setting.
void setSystemLanguages(const string[] languages)
{
    version (OSX)
        setAppleLanguages(languages);
}

/// The language of the user in the system, as a BCP 47 tag ("ru-RU"); "" if it isn't known here.
string systemLanguageTag()
{
    version (OSX)
        return globalAppleLanguage();
    else
        return "";
}

version (OSX):

import std.string : toStringz;

extern (C) void* objc_getClass(const char* name);
extern (C) void* sel_registerName(const char* name);
extern (C) void* objc_msgSend(void* self, void* op, ...);

/// Calls objc_msgSend through an exact prototype derived from the argument types.
private R msg(R = void*, Args...)(void* obj, const(char)* sel, Args args)
{
    alias Fn = extern (C) R function(void*, void*, Args) @trusted;
    return (cast(Fn)&objc_msgSend)(obj, sel_registerName(sel), args);
}

// An NSString of `text`, autoreleased: the defaults keep their own copy
private void* nsString(string text)
{
    return msg(objc_getClass("NSString"), "stringWithUTF8String:", text.toStringz);
}

// The strings of an NSArray of NSString (null: none)
private string[] stringsOf(void* array)
{
    import std.string : fromStringz;

    string[] strings;
    if (array is null)
        return strings;
    const count = msg!ulong(array, "count");
    foreach (i; 0 .. count)
        if (auto text = msg!(const(char)*)(msg(array, "objectAtIndex:", i), "UTF8String"))
            strings ~= text.fromStringz.idup;
    return strings;
}

// The AppleLanguages of the domain `name` as it is kept, not as merged with the others
private string[] appleLanguagesOf(void* defaults, void* name)
{
    auto domain = msg(defaults, "persistentDomainForName:", name);
    return domain is null ? null : stringsOf(msg(domain, "objectForKey:", nsString("AppleLanguages")));
}

private string globalAppleLanguage()
{
    auto defaults = msg(objc_getClass("NSUserDefaults"), "standardUserDefaults");
    const languages = appleLanguagesOf(defaults, nsString("NSGlobalDomain"));
    return languages.length ? languages[0] : "";
}

private void setAppleLanguages(const string[] languages)
{
    auto bundle = msg(msg(objc_getClass("NSBundle"), "mainBundle"), "bundleIdentifier");
    if (bundle is null)
        return; // not a bundle: run from the build folder
    auto defaults = msg(objc_getClass("NSUserDefaults"), "standardUserDefaults");
    if (appleLanguagesOf(defaults, bundle) == languages)
        return;
    auto key = nsString("AppleLanguages");
    if (languages.length == 0)
    {
        msg!void(defaults, "removeObjectForKey:", key);
        return;
    }
    auto array = msg(objc_getClass("NSMutableArray"), "array");
    foreach (language; languages)
        msg!void(array, "addObject:", nsString(language));
    msg!void(defaults, "setObject:forKey:", array, key);
}
