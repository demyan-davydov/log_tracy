// The following of a selected row by the other table, see resources/row-selection.js.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { scrollTarget, followDelay, SelectionFollower } from "../../resources/row-selection.js";

test("a row shown from a search result keeps rows above it only if the view has room", () => {
    assert.equal(scrollTarget(100, 30), 98, "two rows above it");
    assert.equal(scrollTarget(1, 30), 0, "not above the first row");
    assert.equal(scrollTarget(100, 5), 99, "a low view: one row");
    assert.equal(scrollTarget(100, 3), 100, "a very low view: the row itself at the top");
    assert.equal(scrollTarget(100, 0), 100);
});

function fakeTimers() {
    const timers = new Map();
    let next = 1;
    return {
        set(fn, ms) { timers.set(next, { fn, ms }); return next++; },
        clear(id) { timers.delete(id); },
        pending() { return [...timers.values()]; },
        fire() { const all = [...timers.values()]; timers.clear(); for (const t of all) t.fn(); },
    };
}

test("SelectionFollower: a click is followed at once", () => {
    const timers = fakeTimers();
    const followed = [];
    const follower = new SelectionFollower(list => followed.push(list), timers);
    follower.changed("main", false);
    assert.deepEqual(followed, ["main"]);
    assert.equal(timers.pending().length, 0);
});

test("SelectionFollower: a drag or the keys are followed once the row rests", () => {
    const timers = fakeTimers();
    const followed = [];
    const follower = new SelectionFollower(list => followed.push(list), timers);
    follower.changed("main", true);
    follower.changed("main", true);
    follower.changed("main", true);
    assert.deepEqual(followed, [], "not while it moves");
    assert.equal(timers.pending().length, 1, "one timer, started anew by every change");
    assert.equal(timers.pending()[0].ms, followDelay);
    timers.fire();
    assert.deepEqual(followed, ["main"]);
});

test("SelectionFollower: the last change wins, a click drops the waiting one, cancel drops it too", () => {
    const timers = fakeTimers();
    const followed = [];
    const follower = new SelectionFollower(list => followed.push(list), timers);
    follower.changed("main", true);
    follower.changed("search", false);
    timers.fire();
    assert.deepEqual(followed, ["search"], "the drag of the other table is not followed after");
    follower.changed("main", true);
    follower.cancel();
    timers.fire();
    assert.deepEqual(followed, ["search"]);
});
