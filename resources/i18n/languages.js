// The languages the interface can be in, as the Settings offer them, and the one a setting
// asks for. The setting is a BCP 47 tag, or "" for the language of the system.
// Sciter-free; tests: tests/js/languages.test.mjs.
import { pseudoLocale, tr } from "./i18n.js";

// The setting of the language of the system.
export const systemSetting = "";

// The options of the language setting, given the languages the backend offers
// ([{locale, name}]): the system's, english (the source), the translations, and last the
// pseudo translation if offered (PSEUDO_LOCALE=1: to look for texts not translated). A
// language is named in itself. The language set now (`current`) is an option even if not
// offered (its catalog gone, set by hand): named by its tag, so that saving the settings
// keeps it.
export function languageOptions(languages, current = systemSetting) {
    const isEnglish = (l) => l.locale.split("-")[0].toLowerCase() === "en";
    const translations = languages.filter((l) => !isEnglish(l) && l.locale !== pseudoLocale);
    const options = [
        { value: systemSetting, label: tr("System") },
        { value: "en", label: "English" },
        ...translations.map((l) => ({ value: l.locale, label: l.name })),
    ];
    const pseudoName = "Pseudo (for testing)";
    const pseudo = languages.find((l) => l.locale === pseudoLocale);
    if (current && !options.some((o) => o.value === current) && !(pseudo && current === pseudoLocale))
        options.push({ value: current, label: current === pseudoLocale ? pseudoName : current });
    if (pseudo)
        options.push({ value: pseudoLocale, label: pseudo.name });
    return options;
}

// The language `setting` asks for; the system's is its `language` and `country` (as Sciter's
// env.language(), env.country() give them; a language with its region already gets no
// country), english if it tells none. The pseudo locale in any case.
export function requestedLocale(setting, language, country) {
    if (setting)
        return setting.toLowerCase() === pseudoLocale ? pseudoLocale : setting;
    if (!language)
        return "en";
    return country && !/[-_]/.test(language) ? `${language}-${country}` : language;
}
