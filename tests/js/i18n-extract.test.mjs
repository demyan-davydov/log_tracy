// Finding the texts to translate in the sources, bringing a catalog up to them, checking it.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { extractTexts, mergeCatalog, checkCatalog, scanSources } from "../../scripts/utils/i18n-extract.mjs";

test("the texts of tr, trc and trn calls, keyed as in the catalog", () => {
    const source = `
        title.textContent = tr("Open File...");
        const s = tr('It\\'s {n}', { n });
        label = trc("noun", "Filter");
        status = trn("{n} match", "{n} matches", count);
        hint = tr(\`Plain\`);
    `;
    assert.deepEqual(extractTexts(source).texts, [
        { key: "Open File...", source: "Open File...", plural: false },
        { key: "It's {n}", source: "It's {n}", plural: false },
        { key: "Filter|noun", source: "Filter", plural: false },
        { key: "{n} match", source: "{n} match", plural: true, other: "{n} matches" },
        { key: "Plain", source: "Plain", plural: false },
    ]);
});

const keysOf = (source, language) => extractTexts(source, language).texts.map((t) => t.key);

test("escapes of a literal are decoded, D strings too", () => {
    const source = `auto item = command(MenuCommand.quit, tr("E&xit \\"now\\"\\n"), primary("Q"));`;
    assert.deepEqual(keysOf(source, "d"), ["E&xit \"now\"\n"]);
});

test("hex and unicode escapes are decoded", () => {
    assert.deepEqual(keysOf(String.raw`tr("Press \x22Enter\x22"); tr("\u00e9\u{1F600}");`), ["Press \"Enter\"", "é😀"]);
    assert.deepEqual(keysOf(String.raw`tr("\U0001F600");`, "d"), ["😀"]);
});

test("a line continuation of JS is no character", () => {
    assert.deepEqual(keysOf('tr("one \\\ntwo");'), ["one two"]);
});

test("D: a string may have the postfix of its width", () => {
    assert.deepEqual(keysOf(`tr("Open"w); tr("Close"c); tr("Quit"d);`, "d"), ["Open", "Close", "Quit"]);
});

test("D: a WYSIWYG string is no literal to translate (its escapes are not escapes)", () => {
    const { texts, errors } = extractTexts("tr(`a\\n`); tr(r\"b\");", "d");
    assert.deepEqual(texts, []);
    assert.equal(errors.length, 2);
});

test("a call without a literal is an error, with its line", () => {
    const source = `a = tr("ok");\nb = tr(name);\nc = trn("{n} x", other, n);\nd = tr(\`a \${b}\`);`;
    const { texts, errors } = extractTexts(source);
    assert.deepEqual(texts, [{ key: "ok", source: "ok", plural: false }]);
    assert.deepEqual(errors.map((e) => e.line), [2, 3, 4]);
});

test("names that only end in tr are not calls", () => {
    assert.deepEqual(extractTexts(`attr("x"); str("y"); a.tr("z"); function tr(text) {}`), { texts: [], errors: [] });
});

test("merge: new texts are added untranslated, keys sorted", () => {
    const catalog = { locale: "ru", name: "Русский", messages: { "b": "б" } };
    const texts = [{ key: "c", plural: false }, { key: "a", plural: false }, { key: "b", plural: false }];
    const merged = mergeCatalog(catalog, texts);
    assert.deepEqual(Object.keys(merged.catalog.messages), ["a", "b", "c"]);
    assert.deepEqual(merged.catalog.messages, { a: "", b: "б", c: "" });
    assert.deepEqual(merged.added, ["a", "c"]);
});

test("merge: a text gone from the code goes to obsolete, and comes back from there", () => {
    const catalog = { locale: "ru", name: "Русский", messages: { "old": "старое", "empty": "" }, obsolete: { "back": "назад" } };
    const merged = mergeCatalog(catalog, [{ key: "back", plural: false }]);
    assert.deepEqual(merged.catalog.messages, { back: "назад" });
    assert.deepEqual(merged.catalog.obsolete, { old: "старое" }, "an untranslated one is just dropped");
    assert.deepEqual(merged.obsoleted, ["old"]);
});

test("merge: counts what is left to translate", () => {
    const catalog = { locale: "ru", name: "Русский", messages: { "a": "а", "{n} x": { one: "{n} х" } } };
    const merged = mergeCatalog(catalog, [{ key: "a", plural: false }, { key: "{n} x", plural: true, other: "{n} xs" }, { key: "b", plural: false }]);
    assert.deepEqual(merged.untranslated, ["b", "{n} x"]);
});

test("merge: the fields of the catalog stay in their order", () => {
    const merged = mergeCatalog({ locale: "ru", name: "Русский", messages: {} }, []);
    assert.deepEqual(Object.keys(merged.catalog), ["locale", "name", "messages", "obsolete"]);
});

const ruTexts = [
    { key: "Found {count} in {file}", source: "Found {count} in {file}", plural: false },
    { key: "{n} match", source: "{n} match", plural: true, other: "{n} matches" },
    { key: "Open", source: "Open", plural: false },
];

test("check: a complete and consistent catalog has no problems", () => {
    const catalog = { locale: "ru", name: "Русский", messages: {
        "Found {count} in {file}": "В {file} найдено: {count}",
        "{n} match": { one: "{n} совпадение", few: "{n} совпадения", many: "{n} совпадений" },
        "Open": "",
    } };
    assert.deepEqual(checkCatalog(catalog, ruTexts), []);
});

test("check: texts missing from the catalog or not in the code", () => {
    const catalog = { locale: "ru", name: "Русский", messages: { "Open": "", "Gone": "" } };
    assert.deepEqual(checkCatalog(catalog, ruTexts), [
        "missing: Found {count} in {file}",
        "missing: {n} match",
        "not in the code: Gone",
    ]);
});

test("check: the parameters of a translation are those of the source", () => {
    const catalog = { locale: "ru", name: "Русский", messages: {
        "Found {count} in {file}": "Найдено: {count} в {name}",
        "{n} match": { one: "{n} совпадение", few: "{count} совпадения", many: "{n} совпадений" },
        "Open": "",
    } };
    assert.deepEqual(checkCatalog(catalog, ruTexts), [
        "parameters differ: Found {count} in {file}",
        "parameters differ: {n} match (few)",
    ]);
});

test("check: a plural translation needs every form of its language, a plain one is a string", () => {
    const catalog = { locale: "ru", name: "Русский", messages: {
        "Found {count} in {file}": { one: "x" },
        "{n} match": { one: "{n} совпадение" },
        "Open": "",
    } };
    assert.deepEqual(checkCatalog(catalog, ruTexts), [
        "not a plural: Found {count} in {file}",
        "missing forms few, many: {n} match",
    ]);
});

test("check: a catalog names its locale and its language", () => {
    assert.deepEqual(checkCatalog({ messages: {} }, []), ["no locale", "no name"]);
});

test("calls in comments are not calls: line and block comments, D's nesting ones too", () => {
    const js = `// wrap it in tr(text)\n/* tr(name) */ a = tr("ok"); // tr(x)\nb = "// not a comment"; c = tr("two");`;
    assert.deepEqual(extractTexts(js), {
        texts: [{ key: "ok", source: "ok", plural: false }, { key: "two", source: "two", plural: false }],
        errors: [],
    });
    assert.deepEqual(extractTexts(`/+ tr(x) /+ tr(y) +/ tr(z) +/ tr("d");`, "d").texts.map((t) => t.key), ["d"]);
});

test("a comment ends no string, a quote in a comment starts none", () => {
    assert.deepEqual(keysOf(`a = "/* no */"; // it's\nb = tr("yes");`), ["yes"]);
});

test("the lines of errors count the lines of comments", () => {
    assert.deepEqual(extractTexts(`/*\n\n*/\nx = tr(name);`).errors.map((e) => e.line), [4]);
});

test("htm: the texts of the scripts of a page, at their lines", () => {
    const page = `<html>\n<body>\n<p>It's tr(not) a call</p>\n<script type="module">\nconst a = tr("Columns");\nb = tr(x);\n</script>\n</html>`;
    const { texts, errors } = extractTexts(page, "htm");
    assert.deepEqual(texts.map((t) => t.key), ["Columns"]);
    assert.deepEqual(errors.map((e) => e.line), [6]);
});

test("check: a text with | of its own is no context", () => {
    const texts = extractTexts(`tr("{a} | {b}")`).texts;
    assert.deepEqual(checkCatalog({ locale: "ru", name: "Русский", messages: { "{a} | {b}": "{b} | {a}" } }, texts), []);
});

test("check: one key used as different texts is a conflict", () => {
    const texts = extractTexts(`tr("{n} file"); trn("{n} file", "{n} files", n); trn("{n} x", "{n} xs", n); trn("{n} x", "{n} xs found", n); tr("same"); tr("same");`).texts;
    const catalog = { locale: "ru", name: "Русский", messages: { "{n} file": "", "{n} x": "", "same": "" } };
    assert.deepEqual(checkCatalog(catalog, texts), ["conflicting uses: {n} file", "conflicting uses: {n} x"]);
});

test("check: an entry that is no text and no forms of texts is reported, not a crash", () => {
    const texts = [
        { key: "a", source: "a", plural: false },
        { key: "{n} b", source: "{n} b", plural: true, other: "{n} bs" },
        { key: "{n} c", source: "{n} c", plural: true, other: "{n} cs" },
        { key: "d", source: "d", plural: false },
    ];
    const catalog = { locale: "ru", name: "Русский", messages: { "a": null, "{n} b": null, "{n} c": { one: 1, few: "{n}", many: "{n}" }, "d": ["x"] } };
    assert.deepEqual(checkCatalog(catalog, texts), ["bad entry: a", "bad entry: {n} b", "bad entry: {n} c", "bad entry: d"]);
    assert.doesNotThrow(() => mergeCatalog(catalog, texts));
    assert.doesNotThrow(() => mergeCatalog(catalog, []));
});

test("merge: an untranslated plural (all forms empty) gone from the code is dropped", () => {
    const catalog = { locale: "ru", name: "Русский", messages: { "{n} x": { one: "", few: "", many: "" } } };
    const merged = mergeCatalog(catalog, []);
    assert.deepEqual(merged.catalog.obsolete, {});
    assert.deepEqual(merged.obsoleted, []);
});

test("scan: the scripts of resources (js and the pages) and the D sources, each in its language", () => {
    const root = mkdtempSync(join(tmpdir(), "i18n-scan-"));
    try {
        mkdirSync(join(root, "resources", "i18n"), { recursive: true });
        mkdirSync(join(root, "source", "ui"), { recursive: true });
        writeFileSync(join(root, "resources", "a.js"), `tr("From js");`);
        writeFileSync(join(root, "resources", "page.htm"), `<p>Don't</p>\n<script>tr("From a page");</script>`);
        writeFileSync(join(root, "resources", "i18n", "i18n.js"), `export const tr = (text) => translate(text);`);
        writeFileSync(join(root, "source", "ui", "m.d"), `auto a = tr("From D"w);\nauto b = tr(\`raw\`);`);
        const { texts, errors } = scanSources(root);
        assert.deepEqual(texts.map((t) => t.key), ["From js", "From a page", "From D"]);
        assert.deepEqual(errors.map((e) => `${e.file}:${e.line}`), ["source/ui/m.d:2"]);
    } finally {
        rmSync(root, { recursive: true, force: true });
    }
});

test("check: a translation keeps the mnemonic of its source", () => {
    const texts = extractTexts(`tr("&File"); tr("Tom && Jerry"); tr("Plain"); tr("Search & Filter")`).texts;
    const catalog = { locale: "ru", name: "Русский", messages: { "&File": "Файл", "Tom && Jerry": "Том && Джерри", "Plain": "&Просто", "Search & Filter": "Поиск и фильтр" } };
    assert.deepEqual(checkCatalog(catalog, texts), ["mnemonic lost: &File", "mnemonic added: Plain"]);
    catalog.messages["&File"] = "&Файл";
    catalog.messages["Plain"] = "Просто";
    assert.deepEqual(checkCatalog(catalog, texts), []);
});

test("the texts of marked elements: data-tr, data-tr-title, data-tr-placeholder, in markup and JSX", () => {
    const page = `<html>\n<button data-tr-title="New Tab">+</button>\n<header data-tr="Filters"></header>\n` +
        `<input data-tr-placeholder="Search &amp; find" />\n<script>const a = <span data-tr="In JSX" />;</script>\n</html>`;
    assert.deepEqual(extractTexts(page, "htm").texts.map((t) => t.key), ["In JSX", "New Tab", "Filters", "Search & find"]);
    assert.deepEqual(keysOf(`const h = <header data-tr="Details" />; // <b data-tr="not this" />`), ["Details"]);
});

test("a mark with a context: the key is \"text|context\", as of trc", () => {
    const page = `<p>\n<span data-tr="Search" data-tr-context="noun"></span>\n<b data-tr-context='verb' data-tr="Open"></b></p>`;
    assert.deepEqual(extractTexts(page, "htm").texts.map((t) => t.key), ["Search|noun", "Open|verb"]);
    assert.deepEqual(keysOf(`const t = <span class="name" data-tr="Search" data-tr-context="noun" />;`), ["Search|noun"]);
    assert.deepEqual(keysOf(`const a = <b data-tr="Search" />, b = <i data-tr-context="noun" />;`), ["Search"],
        "the context of another element doesn't count");
});

test("a mark without its text is an error", () => {
    const { errors } = extractTexts(`<p>\n<header data-tr></header>\n<b data-tr={name} /></p>`, "htm");
    assert.deepEqual(errors.map((e) => e.line), [2, 3]);
});

test("the texts of trParts calls, as of tr", () => {
    assert.deepEqual(keysOf(`const hint = trParts("{open} a log with {shortcut}", { open, shortcut });`), ["{open} a log with {shortcut}"]);
});

test("a mark's text in single quotes, or a JSX expression of a literal", () => {
    assert.deepEqual(extractTexts(`<p data-tr='Filters'></p>`, "htm").texts.map((t) => t.key), ["Filters"]);
    assert.deepEqual(keysOf(`const a = <b data-tr={"Details"} data-tr-title={'Hint'} />;`), ["Details", "Hint"]);
});

test("D: the templates of uiText, the texts for the user of the backend", () => {
    const source = `throw new UiTextException(uiText("no column \\"{column}\\" in this log", "column", id));\n` +
        `return uiText("Can't load the filter: {reason}", "reason", uiTextOf(e));\nauto t = uiText(name);`;
    const { texts, errors } = extractTexts(source, "d");
    assert.deepEqual(texts.map((t) => t.key), ['no column "{column}" in this log', "Can't load the filter: {reason}"]);
    assert.deepEqual(errors.map((e) => e.line), [3]);
});

test("D: the texts of the unittests are no texts of the program", () => {
    const source = `auto a = uiText("real");\n@("x")\nunittest\n{\n    auto b = uiText("in a test");\n    if (c) { tr("nested"); }\n    auto s = "}";\n}\n` +
        `version (unittest)\n{\n    auto d = uiText("helper");\n}\nauto e = uiText("after");`;
    assert.deepEqual(keysOf(source, "d"), ["real", "after"]);
});

test("D: a version (unittest) block with attributes before its brace is a test block too", () => {
    const source = `version (unittest) private\n{\n    auto a = uiText("mock");\n}\nversion (unittest) static {\n    tr("b");\n}\nauto c = uiText("kept");`;
    assert.deepEqual(keysOf(source, "d"), ["kept"]);
});
