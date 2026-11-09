// The panel of a document: its tables and the panels of the open documents,
// see resources/pane-state.js.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { noTable, tableStep, paneChanges, anchorEdit, rowLookStep, keptRowStep, searchViewKey, jumpStep } from "../../resources/pane-state.js";

const ready = (dataVersion) => ({ status: "ready", dataVersion });

test("the first rows of a table start at the top, nothing selected", () => {
    const step = tableStep(noTable, ready(1));
    assert.equal(step.table, true);
    assert.equal(step.reload, "start");
    assert.equal(step.resetSelection, true);
    assert.deepEqual(step.shown, { loaded: true, dataVersion: 1 });
});

test("the same content again: the table is kept as it is", () => {
    const step = tableStep({ loaded: true, dataVersion: 1 }, ready(1));
    assert.equal(step.table, true);
    assert.equal(step.reload, false);
    assert.equal(step.resetSelection, false);
});

test("other content: other rows at the same scroll, the selection dropped", () => {
    const step = tableStep({ loaded: true, dataVersion: 1 }, ready(2));
    assert.equal(step.reload, "keep");
    assert.equal(step.resetSelection, true);
    assert.deepEqual(step.shown, { loaded: true, dataVersion: 2 });
});

test("a status instead of the table: the table is reloaded when it comes back", () => {
    const filtering = tableStep({ loaded: true, dataVersion: 1 }, { status: "filtering", dataVersion: 1 });
    assert.equal(filtering.table, false);
    assert.equal(filtering.reload, false);
    assert.deepEqual(filtering.shown, { loaded: true, dataVersion: null });
    const back = tableStep(filtering.shown, ready(1));
    assert.equal(back.reload, "keep", "even with the same dataVersion: the view was rebuilt");
    assert.equal(back.resetSelection, true);
});

test("a status before any rows: the first rows still start at the top", () => {
    const loading = tableStep(noTable, { status: "loadingFile" });
    assert.deepEqual(loading.shown, noTable);
    assert.equal(tableStep(loading.shown, ready(1)).reload, "start");
});

test("panels are created for new documents and removed for closed ones", () => {
    assert.deepEqual(paneChanges([1, 2], [2, 3]), { create: [3], remove: [1] });
    assert.deepEqual(paneChanges([], [5]), { create: [5], remove: [] });
    assert.deepEqual(paneChanges([4], []), { create: [], remove: [4] });
    assert.deepEqual(paneChanges([1, 2], [2, 1]), { create: [], remove: [] }, "a new order changes nothing");
});

const edit = (fields) => ({ before: 0, after: 0, insertAt: null, removeAt: null, ...fields });

test("an anchor outside the rendered rows changes the count of rows before or after them", () => {
    const rendered = [10, 20, 30];
    assert.deepEqual(anchorEdit(rendered, 5, true, false), edit({ before: 1 }));
    assert.deepEqual(anchorEdit(rendered, 5, false, false), edit({ before: -1 }));
    assert.deepEqual(anchorEdit(rendered, 40, true, false), edit({ after: 1 }));
    assert.deepEqual(anchorEdit(rendered, 40, false, false), edit({ after: -1 }));
});

test("an anchor among the rendered rows inserts or removes its row in place", () => {
    const rendered = [10, 20, 30];
    assert.deepEqual(anchorEdit(rendered, 15, true, false), edit({ insertAt: 1 }));
    assert.deepEqual(anchorEdit(rendered, 25, true, false), edit({ insertAt: 2 }));
    assert.deepEqual(anchorEdit(rendered, 10, false, false), edit({ removeAt: 0 }));
    assert.deepEqual(anchorEdit(rendered, 30, false, false), edit({ removeAt: 2 }));
});

test("a list that doesn't fill the table shows the row of a new anchor at its end", () => {
    const rendered = [10, 20, 30];
    assert.deepEqual(anchorEdit(rendered, 40, true, true), edit({ insertAt: 3 }));
    assert.deepEqual(anchorEdit(rendered, 5, true, true), edit({ insertAt: 0 }));
    assert.deepEqual(anchorEdit(rendered, 20, false, true), edit({ removeAt: 1 }));
});

test("no rendered rows: nothing to follow", () => {
    assert.equal(anchorEdit([], 5, true, true), null);
});

test("a tab shows the progress of loading its file, nothing otherwise", async () => {
    const { tabProgress } = await import("../../resources/pane-state.js");
    assert.equal(tabProgress({ status: "loadingFile", progress: 0.25 }), 0.25);
    assert.equal(tabProgress({ status: "loadingFile", progress: 1.5 }), 1);
    assert.equal(tabProgress({ status: "loadingFile", progress: -1 }), 0);
    assert.equal(tabProgress({ status: "loadingFile" }), 0);
    assert.equal(tabProgress({ status: "ready" }), null);
    assert.equal(tabProgress({ status: "filtering", progress: 0.5 }), null);
    assert.equal(tabProgress(null), null);
    assert.equal(tabProgress(undefined), null);
});

const look = (fontSize, singleLine) => ({ fontSize, singleLine });

test("the look of the rows: the first one is applied as it is, nothing to keep", () => {
    assert.deepEqual(rowLookStep(null, look(100, false), false), { apply: true, keep: false });
    assert.deepEqual(rowLookStep(null, look(100, true), true), { apply: true, keep: false });
});

test("the look of the rows: the same one again changes nothing", () => {
    assert.deepEqual(rowLookStep(look(100, true), look(100, true), true), { apply: false, keep: false });
});

test("the look of the rows: a shown panel takes another one at once, keeping its first rows", () => {
    assert.deepEqual(rowLookStep(look(100, false), look(100, true), true), { apply: true, keep: true });
    assert.deepEqual(rowLookStep(look(100, false), look(150, false), true), { apply: true, keep: true });
});

test("the look of the rows: a hidden panel takes another one when shown", () => {
    assert.deepEqual(rowLookStep(look(100, false), look(100, true), false), { apply: false, keep: false });
});

test("a kept first row is scrolled to while the table shows rows", () => {
    assert.deepEqual(keptRowStep({ top: 42 }, { loaded: true, dataVersion: 3 }, 100), { wait: false, target: 42 });
});

test("a kept first row of a table with other rows now keeps its place, within the rows", () => {
    // a reload keeps the position (tableStep "keep"): the same row number, not the pixels
    assert.deepEqual(keptRowStep({ top: 42 }, { loaded: true, dataVersion: 4 }, 100), { wait: false, target: 42 });
    assert.deepEqual(keptRowStep({ top: 42 }, { loaded: true, dataVersion: 4 }, 10), { wait: false, target: 9 });
    assert.deepEqual(keptRowStep({ top: 42 }, { loaded: true, dataVersion: 4 }, 0), { wait: false, target: null });
});

test("a kept first row waits while a status view covers the table", () => {
    assert.deepEqual(keptRowStep({ top: 42 }, { loaded: true, dataVersion: null }, 100), { wait: true, target: null });
});

test("no row was on screen: nothing to scroll to", () => {
    assert.deepEqual(keptRowStep({ top: null }, { loaded: true, dataVersion: 3 }, 100), { wait: false, target: null });
});

// ---- the found rows of the main table follow the search view ----

test("searchViewKey: the same search view gives the same key, whatever object it came in", () => {
    const a = { status: "ready", canCancel: false, dataVersion: 3 };
    assert.equal(searchViewKey(a), searchViewKey(JSON.parse(JSON.stringify(a))), "a snapshot of the workspace");
    assert.equal(searchViewKey(null), searchViewKey(null));
});

test("searchViewKey: another status, result or progress gives another key", () => {
    const keys = [
        { status: "ready", dataVersion: 3 },
        { status: "ready", dataVersion: 4 },
        { status: "searching", canCancel: true, progress: 0.25 },
        { status: "searching", canCancel: true, progress: 0.5 },
        { status: "searchCancelled", canCancel: false },
        null,
    ].map(searchViewKey);
    assert.equal(new Set(keys).size, keys.length, keys.join(", "));
});

const at = (position) => () => position;
const screen = { visibleRange: [200, 229], visibleRows: 30 };

test("jumpStep: the row of the message becomes the only one selected, near the top", () => {
    assert.deepEqual(jumpStep(ready(1), at(100), screen), { position: 100, top: 98 });
    assert.deepEqual(jumpStep(ready(1), at(1), screen), { position: 1, top: 0 }, "no rows above the first");
    assert.deepEqual(jumpStep(ready(1), at(0), screen), { position: 0, top: 0 }, "the first row is a position too");
    assert.deepEqual(jumpStep(ready(1), at(5), { visibleRange: null, visibleRows: 30 }), { position: 5, top: 3 }, "no rows on screen");
});

test("jumpStep: a row already on screen is selected where it is", () => {
    assert.deepEqual(jumpStep(ready(1), at(200), screen), { position: 200, top: null }, "the first on screen");
    assert.deepEqual(jumpStep(ready(1), at(229), screen), { position: 229, top: null }, "the last on screen");
    assert.equal(jumpStep(ready(1), at(230), screen).top, 228, "just below");
});

test("jumpStep: nowhere to go when the other table doesn't show the message", () => {
    assert.equal(jumpStep(ready(1), at(null), screen), null, "not in that view");
    assert.equal(jumpStep(ready(1), at(undefined), screen), null, "no answer");
});

test("jumpStep: nowhere to go while the other table shows a status, the backend isn't asked", () => {
    // its positions belong to the content being replaced
    const asked = [];
    const position = () => { asked.push(1); return 5; };
    for (const status of ["searching", "filtering", "loading", "searchCancelled", "sourceLost"])
        assert.equal(jumpStep({ status, dataVersion: 1 }, position, screen), null, status);
    assert.equal(jumpStep(null, position, screen), null, "no view yet");
    assert.equal(asked.length, 0);
});
