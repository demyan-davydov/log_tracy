// The state of the window, see resources/window-state.js: the open documents
// as the backend reports them, the New Tab, the file that failed to open, and
// what is on screen.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import {
    initialWindow, workspaceChanged, newTabRequested, newTabPressed, newTabClosed, documentPressed,
    documentOpened, openFailed, documentClosed, recentFileRemoved, shown, activeDocId
} from "../../resources/window-state.js";

const docs = (active, ...ids) => ids.map(id => ({ id, name: `${id}.log`, active: id === active }));

test("without documents the start screen is shown", () => {
    assert.deepEqual(shown(initialWindow), { placeholder: "start" });
    assert.equal(activeDocId(initialWindow), null);
});

test("the active document of the backend is shown", () => {
    const state = workspaceChanged(initialWindow, docs(2, 1, 2));
    assert.deepEqual(shown(state), { docId: 2 });
    assert.equal(activeDocId(state), 2);
});

test("the New Tab is shown over the documents and gives way to a file opened from it", () => {
    let state = newTabRequested(workspaceChanged(initialWindow, docs(1, 1)));
    assert.deepEqual(shown(state), { placeholder: "newTab" });
    state = documentPressed(state);
    assert.deepEqual(shown(state), { docId: 1 }, "a document tab pressed: the New Tab stays, hidden");
    assert.equal(state.newTab.open, true);
    state = newTabPressed(state);
    assert.deepEqual(shown(state), { placeholder: "newTab" });
    state = documentOpened(state);
    assert.equal(state.newTab.open, false, "the file takes the place of the New Tab");
});

test("closing the New Tab shows the active document again", () => {
    const state = newTabClosed(newTabRequested(workspaceChanged(initialWindow, docs(1, 1))));
    assert.deepEqual(shown(state), { docId: 1 });
});

test("the New Tab goes with the last document", () => {
    const state = workspaceChanged(newTabRequested(workspaceChanged(initialWindow, docs(1, 1))), []);
    assert.equal(state.newTab.open, false);
    assert.deepEqual(shown(state), { placeholder: "start" });
});

test("a file that failed to open is shown in the placeholder, brought up if needed", () => {
    const failure = { path: "/gone.log", error: "no such file" };
    let state = openFailed(workspaceChanged(initialWindow, docs(1, 1)), failure);
    assert.deepEqual(shown(state), { placeholder: "newTab" });
    assert.deepEqual(state.failure, failure);
    state = documentOpened(state);
    assert.equal(state.failure, null, "a file opened clears it");
    state = openFailed(state, failure);
    assert.equal(newTabRequested(state).failure, null, "a fresh New Tab clears it too");
});

test("the placeholder is rendered again when what it shows changes", () => {
    const start = initialWindow.placeholderVersion;
    assert.ok(newTabRequested(initialWindow).placeholderVersion > start, "a fresh New Tab");
    assert.ok(openFailed(initialWindow, { path: "/a", error: "e" }).placeholderVersion > start, "a failure");
    assert.ok(documentClosed(initialWindow).placeholderVersion > start, "a closed file is used now");
    const failed = openFailed(initialWindow, { path: "/a", error: "e" });
    assert.ok(documentOpened(failed).placeholderVersion > failed.placeholderVersion,
        "a file opened clears the failure: the note under it goes");
    assert.equal(documentOpened(initialWindow).placeholderVersion, start, "nothing to clear");
    assert.equal(workspaceChanged(initialWindow, docs(1, 1)).placeholderVersion, start,
        "not on every change of the documents: it would rebuild the list under the mouse");
});

test("a file removed from the recent files is rendered away, its failure with it", () => {
    const failed = openFailed(initialWindow, { path: "/a", error: "e" });
    const removed = recentFileRemoved(failed, "/a");
    assert.ok(removed.placeholderVersion > failed.placeholderVersion);
    assert.equal(removed.failure, null, "the failure of the file removed");
    assert.deepEqual(recentFileRemoved(failed, "/b").failure, failed.failure, "the failure of another file stays");
});

test("the states are not changed in place", () => {
    const before = workspaceChanged(initialWindow, docs(1, 1));
    const frozen = JSON.stringify(before);
    newTabRequested(before);
    documentPressed(before);
    openFailed(before, { path: "/a", error: "e" });
    assert.equal(JSON.stringify(before), frozen);
});
