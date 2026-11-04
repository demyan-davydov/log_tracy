// Dragging an item of a list, see resources/drag-order.js.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { clampShift, dragTarget, settleShift, moveItem } from "../../resources/drag-order.js";

// Three items of 10, 20 and 30 px one after another
const spans = [{ start: 0, end: 10 }, { start: 10, end: 30 }, { start: 30, end: 60 }];

test("the dragged item stays within the list", () => {
    assert.equal(clampShift(spans, 1, -50), -10);
    assert.equal(clampShift(spans, 1, 50), 30);
    assert.equal(clampShift(spans, 1, 5), 5);
});

test("an item stays in place until its edge passes the middle of a neighbour", () => {
    assert.deepEqual(dragTarget(spans, 1, 14), { to: 1, shifts: [0, 0, 0] });
    assert.deepEqual(dragTarget(spans, 1, -4), { to: 1, shifts: [0, 0, 0] });
});

test("passing the middle of the next item takes its place, the item slides back", () => {
    // the end of item 1 (30) + 15 reaches the middle of item 2 (45)
    assert.deepEqual(dragTarget(spans, 1, 15), { to: 2, shifts: [0, 0, -20] });
});

test("passing the middle of the previous item takes its place, the item slides on", () => {
    // the start of item 1 (10) - 5 reaches the middle of item 0 (5)
    assert.deepEqual(dragTarget(spans, 1, -5), { to: 0, shifts: [20, 0, 0] });
});

test("an item dragged past several takes the place of the last one passed", () => {
    assert.deepEqual(dragTarget(spans, 0, 50), { to: 2, shifts: [0, -10, -10] });
    assert.deepEqual(dragTarget(spans, 2, -60), { to: 0, shifts: [30, 30, 0] });
});

test("on drop the item slides into the place freed for it", () => {
    assert.equal(settleShift(spans, 1, 1), 0);
    assert.equal(settleShift(spans, 1, 2), 30, "its end on the end of the last one");
    assert.equal(settleShift(spans, 2, 0), -30, "its start on the start of the first one");
});

test("moving an item reorders a copy", () => {
    const items = ["a", "b", "c", "d"];
    assert.deepEqual(moveItem(items, 0, 2), ["b", "c", "a", "d"]);
    assert.deepEqual(moveItem(items, 3, 1), ["a", "d", "b", "c"]);
    assert.deepEqual(moveItem(items, 1, 1), items);
    assert.deepEqual(items, ["a", "b", "c", "d"], "the list itself is kept");
});
