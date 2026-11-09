// The languages the interface can be in, and the one a setting asks for.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { languageOptions, requestedLocale, systemSetting } from "../../resources/i18n/languages.js";
import { pseudoLocale, setCatalog } from "../../resources/i18n/i18n.js";

test("the options: the system's, english, the translations, the pseudo one last if offered", () => {
    setCatalog(null);
    const pseudo = { locale: pseudoLocale, name: "Pseudo (for testing)" };
    assert.deepEqual(languageOptions([pseudo, { locale: "de", name: "Deutsch" }, { locale: "ru", name: "Русский" }]), [
        { value: systemSetting, label: "System" },
        { value: "en", label: "English" },
        { value: "de", label: "Deutsch" },
        { value: "ru", label: "Русский" },
        { value: pseudoLocale, label: "Pseudo (for testing)" },
    ]);
});

test("no pseudo option unless the backend offers it (PSEUDO_LOCALE)", () => {
    assert.deepEqual(languageOptions([{ locale: "ru", name: "Русский" }]).map((o) => o.value), [systemSetting, "en", "ru"]);
});

test("the pseudo locale set while not offered stays an option, named as when offered", () => {
    const options = languageOptions([], pseudoLocale);
    assert.deepEqual(options.map((o) => o.value), [systemSetting, "en", pseudoLocale]);
    assert.equal(options[2].label, "Pseudo (for testing)");
});

test("the option of the system is translated, the names of the languages are their own", () => {
    setCatalog({ locale: "ru", messages: { "System": "Системный", "English": "Английский" } });
    const options = languageOptions([{ locale: "ru", name: "Русский" }]);
    setCatalog(null);
    assert.equal(options[0].label, "Системный");
    assert.equal(options[1].label, "English");
    assert.equal(options[2].label, "Русский");
});

test("a translation of english is not listed twice", () => {
    assert.deepEqual(languageOptions([{ locale: "en", name: "English" }]).map((o) => o.value),
        [systemSetting, "en"]);
});

test("the system setting asks for the language of the system, with its country", () => {
    assert.equal(requestedLocale(systemSetting, "ru", "KZ"), "ru-KZ");
    assert.equal(requestedLocale(systemSetting, "ru", ""), "ru");
    assert.equal(requestedLocale(undefined, "de", "AT"), "de-AT", "no setting yet: the system's");
    assert.equal(requestedLocale(systemSetting, "", ""), "en", "the system tells nothing: english");
});

test("a language chosen is asked for as it is", () => {
    assert.equal(requestedLocale("ru", "de", "DE"), "ru");
    assert.equal(requestedLocale(pseudoLocale, "ru", "RU"), pseudoLocale);
});

test("a language set but not offered (its catalog gone, set by hand) is kept as an option", () => {
    const options = languageOptions([{ locale: "ru", name: "Русский" }], "de");
    assert.deepEqual(options.map((o) => o.value), [systemSetting, "en", "ru", "de"]);
    assert.equal(options[3].label, "de");
    assert.equal(languageOptions([{ locale: "ru", name: "Русский" }], "ru").length, 3, "an offered one is not added");
    assert.equal(languageOptions([], systemSetting).length, 2);
});

test("a language of the system that has its region already gets no country", () => {
    assert.equal(requestedLocale(systemSetting, "ru-RU", "RU"), "ru-RU");
    assert.equal(requestedLocale(systemSetting, "ru_RU", "RU"), "ru_RU");
});

test("the pseudo locale is asked for in any case", () => {
    assert.equal(requestedLocale("X-Pseudo", "ru", "RU"), pseudoLocale);
});
