// The panel of a document: its tables and the panels of the open documents,
// see resources/pane-state.js.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { noTable, tableStep, paneChanges, searchViewKey, jumpStep, showsRowsOf } from "../../resources/pane-state.js";

const ready = (dataVersion) => ({ status: "ready", dataVersion });

const table = (dataVersion) => ({ loaded: true, dataVersion });

test("the first rows of a table start at the top", () => {
    const step = tableStep(noTable, ready(1));
    assert.equal(step.table, true);
    assert.equal(step.reload, "start");
    assert.deepEqual(step.shown, table(1));
});

test("the same content again: nothing is reloaded (the table counts the new rows itself)", () => {
    const step = tableStep(table(1), ready(1));
    assert.equal(step.table, true);
    assert.equal(step.reload, false);
});

test("other content, complete: other rows at the same scroll", () => {
    const step = tableStep(table(1), ready(2));
    assert.equal(step.reload, "keep");
    assert.deepEqual(step.shown, table(2));
});

test("a failure instead of the table: the table is reloaded when it comes back", () => {
    const failed = tableStep(table(1), { status: "filterFailed" });
    assert.equal(failed.table, false);
    assert.equal(failed.reload, false);
    assert.equal(failed.running, false);
    assert.deepEqual(failed.shown, { loaded: true, dataVersion: null });
    const back = tableStep(failed.shown, ready(1));
    assert.equal(back.reload, "keep", "even with the same dataVersion: the view was rebuilt");
});

test("a file being loaded shows the records found so far, from the top, and grows", () => {
    const loading = { status: "loadingFile", canCancel: false, progress: 0, dataVersion: 1 };
    const first = tableStep(noTable, loading);
    assert.equal(first.table, true, "even before the first record");
    assert.equal(first.reload, "start");
    assert.equal(first.running, false, "no progress at the table: the tab shows it, closing it stops the load");
    const more = tableStep(first.shown, { ...loading, progress: 0.5 });
    assert.deepEqual([more.table, more.reload], [true, false]);
    const done = tableStep(more.shown, ready(1));
    assert.deepEqual([done.table, done.reload], [true, false],
        "the same content, complete: the last records are counted, nothing is reloaded");
});

test("a filter or a search running shows what it found so far, with its progress under the table", () => {
    for (const status of ["filtering", "searching"]) {
        const vm = { status, canCancel: true, progress: 0.1, dataVersion: 2 };
        const empty = tableStep(table(1), vm);
        assert.deepEqual([empty.table, empty.reload], [true, "start"],
            `${status}: the table, empty, before the first row is found: new content starts at the top`);
        assert.equal(empty.running, true, `${status}: the progress and Cancel under the table, never over it`);
        const more = tableStep(empty.shown, { ...vm, progress: 0.6 });
        assert.deepEqual([more.table, more.reload, more.running],
            [true, false, true], status);
        const done = tableStep(more.shown, ready(2));
        assert.deepEqual([done.table, done.reload, done.running],
            [true, false, false], status);
    }
});

test("an operation that found nothing ends in an empty table", () => {
    const empty = tableStep(table(1), { status: "searching", canCancel: true, progress: 0.9, dataVersion: 2 });
    const done = tableStep(empty.shown, ready(2));
    assert.deepEqual([done.table, done.reload], [true, false]);
});

test("a view shows its table when it has content, its progress under it when it can be cancelled, whatever its status", () => {
    const filling = tableStep(table(1), { status: "someOperation", canCancel: true, progress: 0.3, dataVersion: 2 });
    assert.deepEqual([filling.table, filling.running], [true, true], "content being filled: the table, the progress under it");
    const growing = tableStep(table(1), { status: "someLoad", canCancel: false, progress: 0.3, dataVersion: 2 });
    assert.deepEqual([growing.table, growing.running], [true, false], "content that can't be cancelled: no progress by the table");
    const none = tableStep(table(1), { status: "someFailure", canCancel: false });
    assert.deepEqual([none.table, none.running], [false, false], "no content: its status over the table");
});

test("panels are created for new documents and removed for closed ones", () => {
    assert.deepEqual(paneChanges([1, 2], [2, 3]), { create: [3], remove: [1] });
    assert.deepEqual(paneChanges([], [5]), { create: [5], remove: [] });
    assert.deepEqual(paneChanges([4], []), { create: [], remove: [4] });
    assert.deepEqual(paneChanges([1, 2], [2, 1]), { create: [], remove: [] }, "a new order changes nothing");
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

test("jumpStep: the row of the message becomes the only one selected", () => {
    assert.deepEqual(jumpStep(table(1), ready(1), at(100)), { position: 100 });
    assert.deepEqual(jumpStep(table(1), ready(1), at(0)), { position: 0 }, "the first row is a position too");
});

test("jumpStep: nowhere to go when the other table doesn't show the message", () => {
    assert.equal(jumpStep(table(1), ready(1), at(null)), null, "not in that view");
    assert.equal(jumpStep(table(1), ready(1), at(undefined)), null, "no answer");
});

test("jumpStep: nowhere to go while the other table shows a status, the backend isn't asked", () => {
    // its positions belong to the content being replaced
    const asked = [];
    const position = () => { asked.push(1); return 5; };
    const covered = { loaded: true, dataVersion: null };
    for (const status of ["searching", "filtering", "loadingFile", "searchCancelled", "sourceLost"])
        assert.equal(jumpStep(covered, { status, dataVersion: 1 }, position), null, status);
    assert.equal(jumpStep(table(1), null, position), null, "no view yet");
    assert.equal(jumpStep(noTable, ready(1), position), null, "no rows shown yet");
    assert.equal(asked.length, 0);
});

test("jumpStep: while a load, a filter or a search fills the other table, it goes to the rows found so far", () => {
    // the content of one dataVersion only grows: a position found now stays right
    for (const status of ["loadingFile", "filtering", "searching"])
        assert.deepEqual(jumpStep(table(1), { status, dataVersion: 1 }, at(100)), { position: 100 }, status);
});

test("jumpStep: nowhere to go while the other table still shows the content being replaced", () => {
    const asked = [];
    const position = () => { asked.push(1); return 5; };
    assert.equal(jumpStep(table(1), { status: "filtering", dataVersion: 2 }, position), null, "a new filter");
    assert.equal(jumpStep(table(1), ready(2), position), null, "rebuilt, not reloaded yet");
    assert.equal(asked.length, 0);
});

test("showsRowsOf: the rows on screen are of the content of the view", () => {
    assert.equal(showsRowsOf(table(1), ready(1)), true);
    assert.equal(showsRowsOf(table(0), { status: "loadingFile", dataVersion: 0 }), true, "the first content");
    assert.equal(showsRowsOf(table(1), { status: "searching", dataVersion: 1 }), true);
    assert.equal(showsRowsOf(table(1), { status: "searching", dataVersion: 2 }), false, "a new search");
    assert.equal(showsRowsOf({ loaded: true, dataVersion: null }, { status: "filterFailed" }), false, "a status shown");
    assert.equal(showsRowsOf(noTable, ready(1)), false, "nothing shown yet");
    assert.equal(showsRowsOf(table(1), null), false, "no view");
});
