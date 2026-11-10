// Scrolling a row of a virtual list to its top, see resources/list-navigation.js.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { navigationPast, growStep } from "../../resources/list-navigation.js";

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

// Rows 100..179 rendered of 1000
const grown = (fields) => growStep({ before: 100, rendered: 80, after: 820, windowSize: 80, total: 1000, ...fields });

test("a list with as many rows as before has nothing to grow", () => {
    assert.equal(grown({}), null);
});

test("rows added after the rendered ones are only counted: the rows on screen stay", () => {
    assert.deepEqual(grown({ total: 5000 }), { rebuild: false, append: 0, after: 4820 });
    assert.deepEqual(grown({ after: 0, total: 5000 }), { rebuild: false, append: 0, after: 4820 },
        "at the end of a full window too: the list asks for them when scrolled");
});

test("a list with room in its window renders the first rows added", () => {
    const short = { before: 0, rendered: 3, after: 0, windowSize: 80 };
    assert.deepEqual(growStep({ ...short, total: 10 }), { rebuild: false, append: 7, after: 0 });
    assert.deepEqual(growStep({ ...short, total: 500 }), { rebuild: false, append: 77, after: 420 });
});

test("a list without rows, or with fewer rows than it renders, is rebuilt", () => {
    assert.deepEqual(growStep({ before: 0, rendered: 0, after: 0, windowSize: 80, total: 10 }), { rebuild: true });
    assert.deepEqual(grown({ total: 150 }), { rebuild: true });
});
