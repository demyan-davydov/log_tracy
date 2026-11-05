// Translating the texts of the interface by the catalog of a language.
// Run: node --test tests/js
import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { setCatalog, tr, trc, trn, format, pseudoize, pseudoLocale } from "../../resources/i18n/i18n.js";

const ru = {
    locale: "ru",
    name: "Русский",
    messages: {
        "&Open File...": "&Открыть файл...",
        "Settings": "",
        "Filter|noun": "Фильтр",
        "Found {count} in {file}": "В {file} найдено: {count}",
        "{n} match": { one: "{n} совпадение", few: "{n} совпадения", many: "{n} совпадений" },
        "{n} file": { one: "{n} файл" },
    },
};

beforeEach(() => setCatalog(null));

test("without a catalog the text is the english source", () => {
    assert.equal(tr("&Open File..."), "&Open File...");
    assert.equal(trc("noun", "Filter"), "Filter");
});

test("a translated text comes from the catalog", () => {
    setCatalog(ru);
    assert.equal(tr("&Open File..."), "&Открыть файл...");
});

test("a text not in the catalog, or not translated yet, stays english", () => {
    setCatalog(ru);
    assert.equal(tr("Quit"), "Quit");
    assert.equal(tr("Settings"), "Settings");
});

test("a context tells a text from the same text in another sense", () => {
    setCatalog(ru);
    assert.equal(trc("noun", "Filter"), "Фильтр");
    assert.equal(tr("Filter"), "Filter");
    assert.equal(trc("verb", "Filter"), "Filter");
});

test("parameters are put in by name, in the order of the translation", () => {
    assert.equal(tr("Found {count} in {file}", { count: 3, file: "a.dlt" }), "Found 3 in a.dlt");
    setCatalog(ru);
    assert.equal(tr("Found {count} in {file}", { count: 3, file: "a.dlt" }), "В a.dlt найдено: 3");
});

test("an unknown parameter stays as written", () => {
    assert.equal(format("{a} and {b}", { a: 1 }), "1 and {b}");
    assert.equal(format("no {params}"), "no {params}");
});

test("only the own fields of the arguments are parameters", () => {
    assert.equal(format("{constructor} {toString}", {}), "{constructor} {toString}");
});

test("arguments that are no object put in nothing", () => {
    assert.equal(format("Found {n}", 5), "Found {n}");
    assert.equal(tr("Found {n}", "x"), "Found {n}");
});

test("plural: english one or other, the count goes in as {n}", () => {
    assert.equal(trn("{n} match", "{n} matches", 1), "1 match");
    assert.equal(trn("{n} match", "{n} matches", 7), "7 matches");
    assert.equal(trn("{n} match in {file}", "{n} matches in {file}", 2, { file: "a" }), "2 matches in a");
});

test("plural: the form of the language of the catalog", () => {
    setCatalog(ru);
    assert.equal(trn("{n} match", "{n} matches", 21), "21 совпадение");
    assert.equal(trn("{n} match", "{n} matches", 3), "3 совпадения");
    assert.equal(trn("{n} match", "{n} matches", 11), "11 совпадений");
});

test("plural: a missing form falls back to english", () => {
    setCatalog(ru);
    assert.equal(trn("{n} file", "{n} files", 1), "1 файл");
    assert.equal(trn("{n} file", "{n} files", 5), "5 files");
});

test("pseudo: letters accented, padded by 30% of the visible text, in brackets", () => {
    assert.equal(pseudoize("Open"), "[Ôþéñ ~]");
    assert.equal(pseudoize("Settings"), "[Šéţţîñĝš ~~]");
});

test("pseudo: parameters and the mnemonic letter stay as they are", () => {
    assert.equal(pseudoize("{count} of {total}"), "[{count} ôƒ {total} ~]");
    assert.equal(pseudoize("E&xit"), "[É&xîţ ~]");
});

test("pseudo locale: every text pseudoized, parameters put in after", () => {
    setCatalog({ locale: pseudoLocale, messages: {} });
    assert.equal(tr("Open"), "[Ôþéñ ~]");
    assert.equal(tr("{n} of {m}", { n: 1, m: 2 }), "[1 ôƒ 2 ~]");
    assert.equal(trn("{n} file", "{n} files", 3), "[3 ƒîļéš ~~]");
});
