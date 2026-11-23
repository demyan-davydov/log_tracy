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
    assert.deepEqual(callOf(() => backend.reorderTab(5, 0)).call, ["reorderTab", 5, 0]);
    assert.deepEqual(callOf(() => backend.removeRecentFile("/a.log"), true),
        { call: ["removeRecentFile", "/a.log"], value: true });
    assert.deepEqual(callOf(() => backend.showInFolder("/a.log"), ""), { call: ["showInFolder", "/a.log"], value: "" });
    const query = [{ text: "a", isRegex: false, matchCase: true }];
    assert.deepEqual(callOf(() => backend.removeSearch(3, query), true),
        { call: ["removeSearch", 3, JSON.stringify(query)], value: true });
    assert.equal(callOf(() => backend.removeSearch(3, query), false).value, false);
});

test("the names of the variables of the least widths come parsed, none when the backend gives none", () => {
    assert.deepEqual(callOf(() => backend.logTableMinWidthNames(), `["column-min-width"]`),
        { call: ["logTableMinWidthNames"], value: ["column-min-width"] });
    assert.deepEqual(callOf(() => backend.logTableMinWidthNames()).value, []);
});

test("JSON results come parsed", () => {
    assert.deepEqual(callOf(() => backend.recentFiles(), `[{"path": "/a.log"}]`).value, [{ path: "/a.log" }]);
    assert.deepEqual(callOf(() => backend.filters(3), `{"sets": []}`).value, { sets: [] });
    assert.deepEqual(callOf(() => backend.searchHistory(3), `[[]]`).value, [[]]);
    assert.deepEqual(callOf(() => backend.documentInfo(3), `{"records": 5}`),
        { call: ["getDocumentInfo", 3], value: { records: 5 } });
    assert.deepEqual(callOf(() => backend.attachments(3), `[{"id": 0}]`),
        { call: ["getAttachments", 3], value: [{ id: 0 }] });
});

test("an attachment is saved where the script says, the error for the user comes back", () => {
    assert.deepEqual(callOf(() => backend.saveAttachment(3, 1, "/tmp/a.bin"), ""),
        { call: ["saveAttachment", 3, 1, "/tmp/a.bin"], value: "" });
    assert.equal(callOf(() => backend.saveAttachment(3, 1, "/tmp/a.bin"), "no such attachment").value,
        "no such attachment");
});

test("no answer gives the value of nothing", () => {
    assert.deepEqual(callOf(() => backend.recentFiles(), "").value, []);
    assert.deepEqual(callOf(() => backend.columns(3), undefined).value, []);
    assert.equal(callOf(() => backend.filters(3), "").value, null);
    assert.equal(callOf(() => backend.documentInfo(3), "null").value, null);
    assert.deepEqual(callOf(() => backend.attachments(3), "").value, []);
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
});

test("a message of the backend is \"\" when there is none", () => {
    assert.equal(callOf(() => backend.newFilterSet(3), undefined).value, "");
    assert.equal(callOf(() => backend.retryDocument(3), "gone").value, "gone");
    assert.deepEqual(callOf(() => backend.renameFilterSet(3, 1, "Errors"), undefined),
        { call: ["renameFilterSet", 3, 1, "Errors"], value: "" });
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
    assert.equal(callOf(() => backend.mainViewNearestPosition(3, 9), 12).value, 12);
    assert.equal(callOf(() => backend.mainViewNearestPosition(3, 9), null).value, null, "an empty view");
    assert.equal(callOf(() => backend.filterRule(3, 0, 1), "null").value, null, "no such rule");
    assert.equal(callOf(() => backend.checkFilterRuleJson(3, { name: "r" }), `{"error": ""}`).value,
        `{"error": ""}`, "as text: the rule editor window parses it");
});

test("the menu of the window: whether it is drawn, by which platform, its menus", () => {
    const menu = { drawn: true, platform: "windows",
        menus: [{ label: "File", items: [{ command: "file.open", label: "Open File..." }] }] };
    assert.deepEqual(callOf(() => backend.menu(), JSON.stringify(menu)), { call: ["getMenu"], value: menu });
    assert.deepEqual(callOf(() => backend.menu(), "").value, { drawn: false, platform: "mac", menus: [] });
});

test("the files to open at start", () => {
    assert.deepEqual(callOf(() => backend.startFiles(), `["/logs/a.dlt"]`),
        { call: ["getStartFiles"], value: ["/logs/a.dlt"] });
    assert.deepEqual(callOf(() => backend.startFiles(), undefined).value, []);
});

test("the languages of the translations and the catalog a language takes", () => {
    assert.deepEqual(callOf(() => backend.languages(), `[{"locale": "ru", "name": "Русский"}]`),
        { call: ["getLanguages"], value: [{ locale: "ru", name: "Русский" }] });
    assert.deepEqual(callOf(() => backend.languages(), undefined).value, []);
    assert.deepEqual(callOf(() => backend.useLanguage("ru-RU"), `{"locale": "ru", "messages": {}}`),
        { call: ["useLanguage", "ru-RU"], value: { locale: "ru", messages: {} } });
    assert.equal(callOf(() => backend.useLanguage("de"), undefined).value, null, "none: the english source");
});

test("a FIBEX is loaded and unloaded, the error for the user comes back", () => {
    assert.deepEqual(callOf(() => backend.loadDescriptions(3, "/fibex/ecu.xml"), ""),
        { call: ["loadDescriptions", 3, "/fibex/ecu.xml"], value: "" });
    assert.equal(callOf(() => backend.loadDescriptions(3, "/fibex"), "not open").value, "not open");
    assert.deepEqual(callOf(() => backend.unloadDescriptions(3), ""),
        { call: ["unloadDescriptions", 3], value: "" });
});
