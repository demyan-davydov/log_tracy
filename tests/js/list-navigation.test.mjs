// Scrolling a row of a virtual list to its top, see resources/list-navigation.js.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { navigationPast } from "../../resources/list-navigation.js";

// Rows 100..179 rendered, 100..129 on screen, 1000 rows in all
const list = { firstVisible: 100, lastBuffer: 179, total: 1000, windowSize: 80 };

test("a row below the screen inside the window is first navigated past, out of the window", () => {
    assert.equal(navigationPast(140, list), 220);
    assert.equal(navigationPast(179, list), 259, "the last rendered row");
});

test("a row on screen, but not the first, is navigated past too", () => {
    assert.equal(navigationPast(101, list), 181);
    assert.equal(navigationPast(129, list), 209);
});

test("rows the list puts at the top by itself need no step", () => {
    assert.equal(navigationPast(100, list), null, "already the first on screen");
    assert.equal(navigationPast(99, list), null, "above the screen");
    assert.equal(navigationPast(180, list), null, "past the window");
    assert.equal(navigationPast("start", list), null);
    assert.equal(navigationPast("end", list), null);
});

test("near the end of the list the step goes to the last row", () => {
    const end = { firstVisible: 900, lastBuffer: 979, total: 960, windowSize: 80 };
    assert.equal(navigationPast(940, end), 959);
    assert.equal(navigationPast(959, end), null, "the last row itself: nothing past it");
});

test("with no row on screen the step is taken: the place of the row is unknown", () => {
    assert.equal(navigationPast(140, { ...list, firstVisible: null }), 220);
});
