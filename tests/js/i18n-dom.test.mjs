// Translating the marked elements of a tree: their text and attributes, again in another language.
// Run: node --test tests/js
import { test, afterEach } from "node:test";
import assert from "node:assert/strict";
import { translateTree } from "../../resources/i18n/dom.js";
import { setCatalog } from "../../resources/i18n/i18n.js";

// An element as much as translateTree uses it
function element(attributes, text = "") {
    return {
        attributes: { ...attributes },
        textContent: text,
        getAttribute(name) { return name in this.attributes ? this.attributes[name] : null; },
        setAttribute(name, value) { this.attributes[name] = String(value); },
    };
}

// A tree of `elements` that finds them by an attribute selector ("[data-tr]", or a list of them)
function tree(elements) {
    return {
        querySelectorAll(selector) {
            const names = selector.split(",").map((s) => s.trim().slice(1, -1));
            return elements.filter((e) => names.some((n) => n in e.attributes));
        },
    };
}

const ru = { locale: "ru", messages: { "Filters": "Фильтры", "New Tab": "Новая вкладка", "Search…": "Поиск…" } };
afterEach(() => setCatalog(null));

test("an element marked with its text gets the translation as its text", () => {
    const header = element({ "data-tr": "Filters" });
    setCatalog(ru);
    translateTree(tree([header]));
    assert.equal(header.textContent, "Фильтры");
});

test("again in another language: the source is kept in the mark", () => {
    const header = element({ "data-tr": "Filters" });
    setCatalog(ru);
    translateTree(tree([header]));
    setCatalog(null);
    translateTree(tree([header]));
    assert.equal(header.textContent, "Filters");
});

test("attributes: the title and the placeholder from their marks", () => {
    const button = element({ "data-tr-title": "New Tab" });
    const input = element({ "data-tr-placeholder": "Search…" });
    setCatalog(ru);
    translateTree(tree([button, input]));
    assert.equal(button.getAttribute("title"), "Новая вкладка");
    assert.equal(input.getAttribute("placeholder"), "Поиск…");
    assert.equal(button.textContent, "", "the text of an element marked for its title stays");
});

test("an element with a context gets the translation of its text in that context, as of trc", () => {
    const tab = element({ "data-tr": "Search", "data-tr-context": "noun" });
    const button = element({ "data-tr": "Search" });
    setCatalog({ locale: "ru", messages: { "Search": "Найти", "Search|noun": "Поиск" } });
    translateTree(tree([tab, button]));
    assert.equal(tab.textContent, "Поиск");
    assert.equal(button.textContent, "Найти");
});

test("a text not translated is the source", () => {
    const header = element({ "data-tr": "Decoding" });
    setCatalog(ru);
    translateTree(tree([header]));
    assert.equal(header.textContent, "Decoding");
});
