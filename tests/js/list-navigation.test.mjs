// Scrolling a row of a virtual list to its top, see resources/list-navigation.js.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { navigationPast, growStep, windowSize, minWindowSize, windowMargin, safeTarget, navigationStep, fillStep } from "../../resources/list-navigation.js";

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

test("half the window is the rows the list can show, one line high each, and a quarter more", () => {
    assert.equal(windowSize({ height: 2000, lineHeight: 20 }), 2 * 125);
    assert.equal(windowSize({ height: 1990, lineHeight: 20 }), 2 * 125, "a row cut by the bottom edge counts");
});

test("a list of few rows gets at least windowMargin rows more in each half", () => {
    assert.equal(windowSize({ height: 300, lineHeight: 20 }), 2 * (15 + windowMargin));
});

test("rows lower than the line measured still fill the list with half the window, however high it is", () => {
    // The header (21) measured before any row: the rows are 19 high. Sciter
    // fills a couple of rows less than half the window.
    for (const height of [483, 702, 1000, 1500, 2500]) {
        const half = windowSize({ height, lineHeight: 21 }) / 2;
        assert.ok(half - 2 >= Math.ceil(height / 19), `height ${height}: half the window ${half}`);
    }
});

test("a low list renders a window of the minimum size", () => {
    assert.equal(windowSize({ height: 60, lineHeight: 20 }), minWindowSize);
});

test("the window size is unknown while the list or its rows have no height", () => {
    assert.equal(windowSize({ height: 0, lineHeight: 20 }), null);
    assert.equal(windowSize({ height: 480, lineHeight: 0 }), null);
    assert.equal(windowSize({ height: 480, lineHeight: NaN }), null);
});

test("a navigation goes no further than the last row the list counts", () => {
    assert.equal(safeTarget(500, 1000), 500);
    assert.equal(safeTarget(999, 1000), 999);
    assert.equal(safeTarget(1000, 1000), 999, "one past the end");
    assert.equal(safeTarget(5000, 1000), 999);
});

test("a list without rows has nowhere to navigate", () => {
    assert.equal(safeTarget(0, 0), null);
    assert.equal(safeTarget("end", 0), null);
});

test("the end is the last row: Sciter renders a row per pixel of the list for \"end\"", () => {
    assert.equal(safeTarget("end", 1000), 999);
    assert.equal(safeTarget("end", 1), 0);
});

test("the start and rows before the first stay as Sciter takes them", () => {
    assert.equal(safeTarget("start", 1000), "start");
    assert.equal(safeTarget(-5, 1000), 0);
});

// Rows 100..149 rendered, 850 counted after them: 1000 rows in all
const counted = { before: 100, rendered: 50, after: 850 };

test("a navigation in a view that grew counts its new rows first, then goes within them", () => {
    assert.deepEqual(navigationStep(1500, { ...counted, total: 2000 }), { after: 1850, target: 1500 });
    assert.deepEqual(navigationStep("end", { ...counted, total: 2000 }), { after: 1850, target: 1999 });
});

test("a navigation in a view as the list counts it changes no count", () => {
    assert.deepEqual(navigationStep(500, { ...counted, total: 1000 }), { after: null, target: 500 });
    assert.deepEqual(navigationStep(1000, { ...counted, total: 1000 }), { after: null, target: 999 });
});

test("a navigation in a view smaller than the list counts goes no further than the view", () => {
    // The rows of a larger view still counted: a view changed, the list not rendered yet
    assert.deepEqual(navigationStep("end", { ...counted, total: 300 }), { after: null, target: 299 });
    assert.deepEqual(navigationStep(700, { before: 0, rendered: 0, after: 1000, total: 300 }), { after: null, target: 299 });
});

test("a navigation in an empty view goes nowhere", () => {
    assert.deepEqual(navigationStep("end", { ...counted, total: 0 }), { after: null, target: null });
    assert.deepEqual(navigationStep("start", { before: 0, rendered: 0, after: 0, total: 0 }), { after: null, target: null });
});

test("a list whose window grew renders rows after its last one, up to its window", () => {
    assert.deepEqual(fillStep({ before: 100, rendered: 20, after: 500, windowSize: 100 }),
        { append: 80, after: 420, prepend: 0, before: 100 });
});

test("a list at the end of its rows renders rows before its first one: the last row stays at the bottom", () => {
    assert.deepEqual(fillStep({ before: 100, rendered: 20, after: 10, windowSize: 100 }),
        { append: 10, after: 0, prepend: 70, before: 30 }, "the rows after it first");
    assert.deepEqual(fillStep({ before: 30, rendered: 20, after: 0, windowSize: 100 }),
        { append: 0, after: 0, prepend: 30, before: 0 }, "as many as there are");
});

test("a list with its window rendered, all its rows, or no row has nothing to fill", () => {
    assert.equal(fillStep({ before: 100, rendered: 100, after: 500, windowSize: 100 }), null);
    assert.equal(fillStep({ before: 100, rendered: 120, after: 500, windowSize: 100 }), null);
    assert.equal(fillStep({ before: 0, rendered: 20, after: 0, windowSize: 100 }), null);
    assert.equal(fillStep({ before: 100, rendered: 0, after: 500, windowSize: 100 }), null, "Sciter fills an empty list");
});
