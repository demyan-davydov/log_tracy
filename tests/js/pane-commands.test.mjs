// The flows of the commands of a panel, see resources/pane-commands.js: the
// search committed by Enter or the Search button, and the editor of a rule
// opened again while the backend refuses the rule.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { noSearch, runSearch, searchPending, editRule } from "../../resources/pane-commands.js";

const chips = [{ text: "error", isRegex: false, ignoreCase: true }];

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
