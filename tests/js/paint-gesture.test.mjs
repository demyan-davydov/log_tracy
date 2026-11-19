// The axis of a gesture of the trackpad, see resources/paint-gesture.js.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { lockAxis, lockPixels } from "../../resources/paint-gesture.js";

test("a gesture has no axis until it has gone a few pixels", () => {
    let state = { axis: null, across: 0, down: 0 };
    state = lockAxis(state.across, state.down, 1, 2);
    assert.equal(state.axis, null);
    assert.ok(state.across + state.down < lockPixels);
});

test("the axis is the one the first pixels went farther on", () => {
    let state = lockAxis(0, 0, 1, 1);
    state = lockAxis(state.across, state.down, 1, 9);
    assert.equal(state.axis, "y", "down 10, across 2");
    state = lockAxis(0, 0, 8, 1);
    assert.equal(state.axis, "x");
});

test("the sums are of absolute pixels: moving up and down both count", () => {
    let state = lockAxis(0, 0, 0, -4);
    state = lockAxis(state.across, state.down, 0, 4);
    assert.equal(state.axis, "y");
    assert.equal(state.down, 8);
});
