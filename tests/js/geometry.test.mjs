import test from "node:test";
import assert from "node:assert/strict";
import { pointInRect } from "../../resources/geometry.js";

test("a point is in a rectangle by its left and top edges, not by the right and the bottom ones", () => {
    const rect = [10, 20, 30, 16];
    assert.equal(pointInRect(10, 20, rect), true);
    assert.equal(pointInRect(39, 35, rect), true);
    assert.equal(pointInRect(40, 30, rect), false);
    assert.equal(pointInRect(20, 36, rect), false);
    assert.equal(pointInRect(9, 30, rect), false);
    assert.equal(pointInRect(20, 19, rect), false);
});
