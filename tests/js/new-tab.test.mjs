// The New Tab state of the tab strip, see resources/new-tab.js.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import {
    noNewTab, plusAction, openNewTab, activateNewTab, activateDocument,
    closeNewTab, documentAdded, documentsCounted, showsPlaceholder,
    shownDocument, fileFailed, failureReason
} from "../../resources/new-tab.js";

test("+ opens the file dialog while no document is open", () => {
    assert.equal(plusAction(0), "openDialog");
});

test("+ opens the new tab while documents are open", () => {
    assert.equal(plusAction(2), "newTab");
    assert.deepEqual(openNewTab(), { open: true, active: true });
});

test("+ again shows the new tab already open, no second one", () => {
    // openNewTab() doesn't depend on the state: the one New Tab is shown
    assert.deepEqual(openNewTab(), { open: true, active: true });
});

test("a document tab hides the new tab, which stays in the strip", () => {
    const state = activateDocument(openNewTab());
    assert.deepEqual(state, { open: true, active: false });
    assert.equal(showsPlaceholder(state, 1), false);
    assert.deepEqual(activateNewTab(state), { open: true, active: true });
});

test("a closed new tab can't be activated", () => {
    assert.deepEqual(activateNewTab(noNewTab), noNewTab);
});

test("closing the new tab removes it", () => {
    assert.deepEqual(closeNewTab(), noNewTab);
});

test("a file opened from the new tab takes its place", () => {
    assert.deepEqual(documentAdded(openNewTab()), noNewTab);
});

test("a file opened from a document tab leaves the new tab in the strip", () => {
    const state = activateDocument(openNewTab());
    assert.deepEqual(documentAdded(state), state);
});

test("without documents there is no new tab: the start screen is the same", () => {
    const state = activateDocument(openNewTab());
    assert.deepEqual(documentsCounted(state, 0), noNewTab);
    assert.deepEqual(documentsCounted(state, 1), state);
});

test("the placeholder is shown without documents or in the new tab", () => {
    assert.equal(showsPlaceholder(noNewTab, 0), true);
    assert.equal(showsPlaceholder(noNewTab, 1), false);
    assert.equal(showsPlaceholder(openNewTab(), 1), true);
});

test("the document shown is none while the placeholder is", () => {
    assert.equal(shownDocument(noNewTab, 2, 7), 7);
    assert.equal(shownDocument(openNewTab(), 2, 7), null);
    assert.equal(shownDocument(activateDocument(openNewTab()), 2, 7), 7);
    assert.equal(shownDocument(noNewTab, 0, null), null);
});

test("a file failed to open from a document tab opens the new tab to show why", () => {
    assert.deepEqual(fileFailed(noNewTab, 2), { open: true, active: true });
    assert.deepEqual(fileFailed(activateDocument(openNewTab()), 2), { open: true, active: true });
});

test("a file failed to open on the placeholder stays there", () => {
    assert.deepEqual(fileFailed(noNewTab, 0), noNewTab);
    assert.deepEqual(fileFailed(openNewTab(), 2), { open: true, active: true });
});

test("the reason of a failed open is the part in parentheses at the end", () => {
    assert.equal(failureReason("Can't open /logs/a (b).dlt (Permission denied)"), "Permission denied");
    assert.equal(failureReason("Not a DLT file"), "Not a DLT file");
    assert.equal(failureReason(""), "");
});
