// The flows of the commands of a panel, see resources/pane-commands.js: the
// search committed by Enter or the Search button, and the editor of a rule
// opened again while the backend refuses the rule.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { noSearch, runSearch, searchPending, editRule, anchorRefusalText } from "../../resources/pane-commands.js";
import { setCatalog } from "../../resources/i18n/i18n.js";

const chips = [{ text: "error", isRegex: false, matchCase: false }];

test("a search the backend starts is committed with its colors", () => {
    const run = runSearch(noSearch, chips, () => ["c0"], () => "", query => { assert.deepEqual(query, chips); return ""; });
    assert.equal(run.message, "");
    assert.equal(run.started, true);
    assert.deepEqual(run.search.colors, ["c0"]);
    assert.equal(searchPending(run.search, chips), false, "the results are those of the query");
    assert.equal(searchPending(run.search, []), true, "an edited query is pending");
});

test("an invalid regex is refused before the backend is asked", () => {
    let asked = false;
    let colored = false;
    const run = runSearch(noSearch, chips, () => { colored = true; return ["c0"]; }, () => "bad regex",
        () => { asked = true; return ""; });
    assert.equal(colored, false, "the colors are not worked out for a refused search");
    assert.equal(asked, false);
    assert.equal(run.message, "Search error: bad regex");
    assert.equal(run.started, false);
    assert.equal(run.search, noSearch, "the committed search stays");
});

test("an error of the backend keeps the search committed before", () => {
    const before = runSearch(noSearch, chips, () => ["c0"], () => "", () => "").search;
    const run = runSearch(before, [], () => [], () => "", () => "the document is not open");
    assert.equal(run.message, "Search error: the document is not open");
    assert.equal(run.search, before);
});

test("no chips clear the search: nothing is pending then", () => {
    assert.equal(searchPending(noSearch, []), false);
});

test("a rule the backend takes is applied once", () => {
    const opened = [];
    const applied = editRule({ name: "r" }, (values, error) => { opened.push([values, error]); return { name: "x" }; },
        result => { assert.deepEqual(result, { name: "x" }); return ""; });
    assert.equal(applied, true);
    assert.deepEqual(opened, [[{ name: "r" }, ""]]);
});

test("a refused rule opens the editor again with what was typed and the error", () => {
    const opened = [];
    const answers = ["invalid regex", ""];
    const applied = editRule({ name: "r" }, (values, error) => { opened.push([values, error]); return { name: `try${opened.length}` }; },
        () => answers.shift());
    assert.equal(applied, true);
    assert.deepEqual(opened, [[{ name: "r" }, ""], [{ name: "try1" }, "invalid regex"]]);
});

test("a cancelled editor applies nothing", () => {
    let applied = false;
    assert.equal(editRule({ name: "r" }, () => null, () => { applied = true; return ""; }), false);
    assert.equal(applied, false);
});

test("an anchor refused at the limit says the limit, in the plural form of its number", () => {
    assert.equal(anchorRefusalText({ refused: null, max: 16 }), "", "not refused");
    assert.equal(anchorRefusalText({ refused: "limit", max: 16 }), "16 anchors at most");
    assert.equal(anchorRefusalText({ refused: "limit", max: 1 }), "1 anchor at most");
    setCatalog({ locale: "ru", messages: { "{n} anchor at most": { one: "Максимум {n} якорь", few: "Максимум {n} якоря", many: "Максимум {n} якорей" } } });
    try {
        assert.equal(anchorRefusalText({ refused: "limit", max: 16 }), "Максимум 16 якорей");
        assert.equal(anchorRefusalText({ refused: "limit", max: 21 }), "Максимум 21 якорь");
        assert.equal(anchorRefusalText({ refused: "limit", max: 3 }), "Максимум 3 якоря");
    } finally {
        setCatalog(null);
    }
});

test("an anchor refused while an operation runs says so", () => {
    assert.equal(anchorRefusalText({ refused: "busy", max: 16 }), "Not while searching or filtering");
});
