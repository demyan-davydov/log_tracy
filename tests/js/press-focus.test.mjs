// Where the keyboard goes when a press on a tab shows a panel, see
// resources/press-focus.js.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { PressFocus } from "../../resources/press-focus.js";

// A take() that records it was called
function taker(log, name) {
    return () => log.push(name);
}

test("without a press the focus is given at once", () => {
    const focus = new PressFocus();
    const log = [];
    focus.request(taker(log, "pane"));
    assert.deepEqual(log, ["pane"]);
});

test("during a press the focus waits for its end", () => {
    const focus = new PressFocus();
    const log = [];
    focus.press();
    focus.request(taker(log, "pane"));
    assert.deepEqual(log, [], "not while the mouse button is down");
    focus.release();
    assert.deepEqual(log, ["pane"]);
});

test("only the last panel asked during a press gets the focus", () => {
    const focus = new PressFocus();
    const log = [];
    focus.press();
    focus.request(taker(log, "first"));
    focus.request(taker(log, "second"));
    focus.release();
    assert.deepEqual(log, ["second"]);
});

test("a press that asked nothing gives nothing at its end", () => {
    const focus = new PressFocus();
    const log = [];
    focus.press();
    focus.release();
    assert.deepEqual(log, []);
});

test("the focus is given once: a second release gives nothing", () => {
    const focus = new PressFocus();
    const log = [];
    focus.press();
    focus.request(taker(log, "pane"));
    focus.release();
    focus.release();
    assert.deepEqual(log, ["pane"]);
});

test("after the press the focus is given at once again", () => {
    const focus = new PressFocus();
    const log = [];
    focus.press();
    focus.release();
    focus.request(taker(log, "pane"));
    assert.deepEqual(log, ["pane"]);
});

test("a new press drops what an unfinished one asked", () => {
    const focus = new PressFocus();
    const log = [];
    focus.press();
    focus.request(taker(log, "old"));
    focus.press(); // the release of the first was lost outside the window
    focus.release();
    assert.deepEqual(log, []);
});
