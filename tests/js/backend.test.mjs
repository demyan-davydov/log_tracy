// The calls of the backend, see resources/backend.js: each one is the xcall of
// its name with its arguments, and JSON results come parsed, with the value of
// "nothing" when the backend gives none.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";

const calls = [];
let answer = undefined;
globalThis.Window = { this: { xcall: (...args) => { calls.push(args); return answer; } } };
const backend = await import("../../resources/backend.js");

function callOf(run, result) {
    calls.length = 0;
    answer = result;
    const value = run();
    assert.equal(calls.length, 1, "one xcall");
    return { call: calls[0], value };
}

test("a call is the xcall of its name, the document first", () => {
    assert.deepEqual(callOf(() => backend.setAnchor(3, 42, true), true),
        { call: ["setAnchor", 3, 42, true], value: true });
    assert.deepEqual(callOf(() => backend.mainViewItem(3, 7), null).call, ["getMainViewItem", 3, 7]);
    assert.deepEqual(callOf(() => backend.reorderTab(5, 0)).call, ["reorderTab", 5, 0]);
});

test("JSON results come parsed", () => {
    assert.deepEqual(callOf(() => backend.recentFiles(), `[{"path": "/a.log"}]`).value, [{ path: "/a.log" }]);
    assert.deepEqual(callOf(() => backend.filters(3), `{"sets": []}`).value, { sets: [] });
    assert.deepEqual(callOf(() => backend.searchHistory(3), `[[]]`).value, [[]]);
});

test("no answer gives the value of nothing", () => {
    assert.deepEqual(callOf(() => backend.recentFiles(), "").value, []);
    assert.deepEqual(callOf(() => backend.columns(3), undefined).value, []);
    assert.equal(callOf(() => backend.filters(3), "").value, null);
    assert.equal(callOf(() => backend.settings(), "").value, null);
    assert.equal(callOf(() => backend.workspaceInfo(), undefined).value, null);
});

test("JSON arguments are sent as text", () => {
    assert.deepEqual(callOf(() => backend.startChipSearch(3, [{ text: "x" }]), "").call,
        ["startChipSearch", 3, `[{"text":"x"}]`]);
    assert.deepEqual(callOf(() => backend.setColumnLayouts({ dlt: [] })).call, ["setColumnLayouts", `{"dlt":[]}`]);
    assert.deepEqual(callOf(() => backend.addFilterRule(3, 1, { name: "r" }), "").call,
        ["addFilterRule", 3, 1, `{"name":"r"}`]);
});

test("the columns of the tables come as text, to tell a change", () => {
    assert.equal(callOf(() => backend.tableColumnsJson(3), `[{"id": "time"}]`).value, `[{"id": "time"}]`);
    assert.equal(callOf(() => backend.tableColumnsJson(3), undefined).value, "[]");
});

test("a message of the backend is \"\" when there is none", () => {
    assert.equal(callOf(() => backend.newFilterSet(3), undefined).value, "");
    assert.equal(callOf(() => backend.retryDocument(3), "gone").value, "gone");
});

test("openFile: the id of the document, or why the file can't be opened", () => {
    assert.deepEqual(callOf(() => backend.openFile("/a.log"), 4).value, { docId: 4 });
    assert.deepEqual(callOf(() => backend.openFile("/b.log"), `{"path": "/b.log", "error": "gone"}`).value,
        { failure: { path: "/b.log", error: "gone" } });
    assert.deepEqual(callOf(() => backend.openFile("/c.log"), "not json").value,
        { failure: { path: "/c.log", error: "not json" } }, "a plain message is the error");
});

test("results that are no JSON objects keep their shape", () => {
    assert.equal(callOf(() => backend.mainViewPosition(3, 9), null).value, null);
    assert.equal(callOf(() => backend.mainViewPosition(3, 9), 12).value, 12);
    assert.equal(callOf(() => backend.filterRule(3, 0, 1), "null").value, null, "no such rule");
    assert.equal(callOf(() => backend.checkFilterRuleJson(3, { name: "r" }), `{"error": ""}`).value,
        `{"error": ""}`, "as text: the rule editor window parses it");
});

test("the menu of the window: whether it is a menu bar, its menus", () => {
    const menu = { menuBar: true, menus: [{ label: "File", items: [{ command: "file.open", label: "Open File..." }] }] };
    assert.deepEqual(callOf(() => backend.menu(), JSON.stringify(menu)), { call: ["getMenu"], value: menu });
    assert.deepEqual(callOf(() => backend.menu(), "").value, { menuBar: false, menus: [] });
});

test("the languages of the translations and the catalog a language takes", () => {
    assert.deepEqual(callOf(() => backend.languages(), `[{"locale": "ru", "name": "Русский"}]`),
        { call: ["getLanguages"], value: [{ locale: "ru", name: "Русский" }] });
    assert.deepEqual(callOf(() => backend.languages(), undefined).value, []);
    assert.deepEqual(callOf(() => backend.useLanguage("ru-RU", ""), `{"locale": "ru", "messages": {}}`),
        { call: ["useLanguage", "ru-RU", ""], value: { locale: "ru", messages: {} } });
    assert.equal(callOf(() => backend.useLanguage("de", "de"), undefined).value, null, "none: the english source");
});

test("the language of the system as the backend knows it, \"\" if it doesn't", () => {
    assert.deepEqual(callOf(() => backend.systemLanguage(), "ru-RU"), { call: ["getSystemLanguage"], value: "ru-RU" });
    assert.equal(callOf(() => backend.systemLanguage(), undefined).value, "");
});
