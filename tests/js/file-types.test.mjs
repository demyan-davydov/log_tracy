// The filter of a file dialog from the types of files it offers.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { fileFilter, allFiles } from "../../resources/file-types.js";
import { setCatalog } from "../../resources/i18n/i18n.js";

test("a type is its name with its patterns, then its patterns, as Sciter takes them", () => {
    assert.equal(fileFilter([["XML Files", "*.xml"], ["Logs", "*.dlt;*.log"]]),
        "XML Files (*.xml)|*.xml|Logs (*.dlt;*.log)|*.dlt;*.log");
});

test("all files: the type that ends a filter, named in the language of the interface", () => {
    assert.deepEqual(allFiles(), ["All Files", "*.*"]);
    setCatalog({ locale: "ru", messages: { "All Files": "Все файлы" } });
    try {
        assert.equal(fileFilter([allFiles()]), "Все файлы (*.*)|*.*");
    } finally {
        setCatalog(null);
    }
});

test("a | in a name (a translation) would shift the pairs: it is no |", () => {
    assert.equal(fileFilter([["Logs | traces", "*.log"]]), "Logs / traces (*.log)|*.log");
});
