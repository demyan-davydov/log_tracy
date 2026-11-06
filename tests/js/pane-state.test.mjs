// The panel of a document: its tables and the panels of the open documents,
// see resources/pane-state.js.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { noTable, tableStep, paneChanges, anchorEdit } from "../../resources/pane-state.js";

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
    assert.deepEqual(anchorEdit(rendered, 5, true), edit({ before: 1 }));
    assert.deepEqual(anchorEdit(rendered, 5, false), edit({ before: -1 }));
    assert.deepEqual(anchorEdit(rendered, 40, true), edit({ after: 1 }));
    assert.deepEqual(anchorEdit(rendered, 40, false), edit({ after: -1 }));
});

test("an anchor among the rendered rows inserts or removes its row in place", () => {
    const rendered = [10, 20, 30];
    assert.deepEqual(anchorEdit(rendered, 15, true), edit({ insertAt: 1 }));
    assert.deepEqual(anchorEdit(rendered, 25, true), edit({ insertAt: 2 }));
    assert.deepEqual(anchorEdit(rendered, 10, false), edit({ removeAt: 0 }));
    assert.deepEqual(anchorEdit(rendered, 30, false), edit({ removeAt: 2 }));
});

test("no rendered rows: nothing to follow", () => {
    assert.equal(anchorEdit([], 5, true), null);
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
