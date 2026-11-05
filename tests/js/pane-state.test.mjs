// The panel of a document: its tables and the panels of the open documents,
// see resources/pane-state.js.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { noTable, tableStep, paneChanges } from "../../resources/pane-state.js";

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
