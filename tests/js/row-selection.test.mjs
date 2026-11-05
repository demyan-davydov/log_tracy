// The selected rows of a log table, see resources/row-selection.js.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { RowSelection, selectedText, scrollTarget, autoScrollSpeed, autoScroll } from "../../resources/row-selection.js";

const click = (selection, index, modifiers = {}) => selection.click(index, modifiers);

test("nothing is selected at first", () => {
    const selection = new RowSelection();
    assert.equal(selection.count, 0);
    assert.equal(selection.has(0), false);
    assert.equal(selection.current, null);
});

test("a click selects only its row and makes it current", () => {
    const selection = new RowSelection();
    click(selection, 5);
    click(selection, 7);
    assert.deepEqual(selection.ranges, [[7, 7]]);
    assert.equal(selection.current, 7);
});

test("Shift+click selects the rows from the last clicked one, in either direction", () => {
    const selection = new RowSelection();
    click(selection, 10);
    click(selection, 14, { shift: true });
    assert.deepEqual(selection.ranges, [[10, 14]]);
    assert.equal(selection.current, 14);
    click(selection, 8, { shift: true });
    assert.deepEqual(selection.ranges, [[8, 10]], "the range starts from the same row again");
});

test("Shift+click without a clicked row selects only that row", () => {
    const selection = new RowSelection();
    click(selection, 3, { shift: true });
    assert.deepEqual(selection.ranges, [[3, 3]]);
});

test("Cmd+click adds a row or removes it, and starts the next Shift range", () => {
    const selection = new RowSelection();
    click(selection, 2);
    click(selection, 6, { toggle: true });
    assert.deepEqual(selection.ranges, [[2, 2], [6, 6]]);
    click(selection, 3, { toggle: true });
    assert.deepEqual(selection.ranges, [[2, 3], [6, 6]], "adjacent rows join one range");
    click(selection, 2, { toggle: true });
    assert.deepEqual(selection.ranges, [[3, 3], [6, 6]]);
    click(selection, 5, { shift: true });
    assert.deepEqual(selection.ranges, [[2, 5]], "from the row of the last Cmd+click");
});

test("Cmd+Shift+click adds the range to the selection", () => {
    const selection = new RowSelection();
    click(selection, 1);
    click(selection, 10, { toggle: true });
    click(selection, 12, { toggle: true, shift: true });
    assert.deepEqual(selection.ranges, [[1, 1], [10, 12]]);
});

test("removing a row from the middle of a range splits it", () => {
    const selection = new RowSelection();
    click(selection, 0);
    click(selection, 9, { shift: true });
    click(selection, 4, { toggle: true });
    assert.deepEqual(selection.ranges, [[0, 3], [5, 9]]);
    assert.equal(selection.count, 9);
    assert.equal(selection.has(4), false);
    assert.equal(selection.has(5), true);
});

test("a huge range takes one entry", () => {
    const selection = new RowSelection();
    click(selection, 0);
    click(selection, 4_000_000_000, { shift: true });
    assert.equal(selection.ranges.length, 1);
    assert.equal(selection.count, 4_000_000_001);
    assert.equal(selection.has(3_999_999_999), true);
});

test("a right click on a row outside the selection selects only that row", () => {
    const selection = new RowSelection();
    click(selection, 1);
    click(selection, 3, { shift: true });
    selection.contextClick(2);
    assert.deepEqual(selection.ranges, [[1, 3]], "inside: the selection is kept");
    selection.contextClick(8);
    assert.deepEqual(selection.ranges, [[8, 8]]);
    assert.equal(selection.current, 8);
});

test("moving to a row selects only it", () => {
    const selection = new RowSelection();
    click(selection, 1);
    click(selection, 3, { shift: true });
    selection.moveTo(4);
    assert.deepEqual(selection.ranges, [[4, 4]]);
    assert.equal(selection.current, 4);
});

test("clear keeps the current row", () => {
    const selection = new RowSelection();
    click(selection, 5);
    selection.clear();
    assert.equal(selection.count, 0);
    assert.equal(selection.current, 5);
    selection.reset();
    assert.equal(selection.current, null);
});

test("a copy doesn't change with the original", () => {
    const selection = new RowSelection();
    click(selection, 5);
    const copy = selection.copy();
    click(selection, 6, { toggle: true });
    assert.deepEqual(copy.ranges, [[5, 5]]);
    assert.equal(copy.current, 5);
});

test("the selected rows are copied in the order they are shown, one per line", () => {
    const selection = new RowSelection();
    click(selection, 7);
    click(selection, 2, { toggle: true });
    click(selection, 3, { toggle: true });
    const result = selectedText(selection, (i) => `row ${i}`, 1000);
    assert.deepEqual(result, { text: "row 2\nrow 3\nrow 7", copied: 3, total: 3, truncated: false });
});

test("rows the view doesn't have any more are skipped", () => {
    const selection = new RowSelection();
    click(selection, 0);
    click(selection, 2, { shift: true });
    const result = selectedText(selection, (i) => (i === 1 ? null : `r${i}`), 1000);
    assert.deepEqual(result, { text: "r0\nr2", copied: 2, total: 3, truncated: false },
        "missing rows are not a reason to report the limit");
});

test("the copied text stops before the row that would pass the limit", () => {
    const selection = new RowSelection();
    click(selection, 0);
    click(selection, 1_000_000_000, { shift: true });
    let read = 0;
    const result = selectedText(selection, (i) => { ++read; return "abcd"; }, 12);
    // "abcd\nabcd" is 9, a third row would make 14
    assert.deepEqual(result, { text: "abcd\nabcd", copied: 2, total: 1_000_000_001, truncated: true });
    assert.equal(read, 3, "no row is read past the limit");
});

test("dragging from a clicked row selects the rows up to the one under the mouse", () => {
    const selection = new RowSelection();
    click(selection, 10);
    selection.beginDrag();
    selection.dragTo(13);
    assert.deepEqual(selection.ranges, [[10, 13]]);
    assert.equal(selection.current, 13);
    selection.dragTo(7);
    assert.deepEqual(selection.ranges, [[7, 10]], "back past the clicked row: the range turns");
    selection.dragTo(10);
    assert.deepEqual(selection.ranges, [[10, 10]]);
});

test("dragging with Cmd adds the range to the rows selected before", () => {
    const selection = new RowSelection();
    click(selection, 1);
    click(selection, 5, { toggle: true });
    selection.beginDrag({ toggle: true });
    selection.dragTo(8);
    assert.deepEqual(selection.ranges, [[1, 1], [5, 8]]);
    selection.dragTo(6);
    assert.deepEqual(selection.ranges, [[1, 1], [5, 6]], "the rows dragged over before are released");
});

test("dragging after Shift+click keeps the range from the anchor", () => {
    const selection = new RowSelection();
    click(selection, 4);
    click(selection, 6, { shift: true });
    selection.beginDrag();
    selection.dragTo(9);
    assert.deepEqual(selection.ranges, [[4, 9]]);
});

test("a row shown from a search result keeps rows above it only if the view has room", () => {
    assert.equal(scrollTarget(100, 30), 98, "two rows above it");
    assert.equal(scrollTarget(1, 30), 0, "not above the first row");
    assert.equal(scrollTarget(100, 5), 99, "a low view: one row");
    assert.equal(scrollTarget(100, 3), 100, "a very low view: the row itself at the top");
    assert.equal(scrollTarget(100, 0), 100);
});

test("a first row longer than the limit copies nothing, and says so", () => {
    const selection = new RowSelection();
    click(selection, 0);
    const result = selectedText(selection, () => "abcdef", 3);
    assert.deepEqual(result, { text: "", copied: 0, total: 1, truncated: true });
});

test("dragging past the edge scrolls at a steady speed near it, then faster up to a limit", () => {
    const { nearDistance, minSpeed, maxSpeed, acceleration } = autoScroll;
    assert.equal(autoScrollSpeed(0), 0, "on the edge: no scroll");
    assert.equal(autoScrollSpeed(1), minSpeed);
    assert.equal(autoScrollSpeed(nearDistance), minSpeed, "the same speed up to the threshold");
    assert.equal(autoScrollSpeed(nearDistance + 10), minSpeed + 10 * acceleration, "then grows linearly");
    assert.equal(autoScrollSpeed(100000), maxSpeed, "and stops at the limit");
    assert.ok(autoScrollSpeed(nearDistance + 1) > minSpeed && autoScrollSpeed(nearDistance + 1) < minSpeed + 2 * acceleration,
        "no jump at the threshold");
});

test("rows past the end of the view are neither read nor counted", () => {
    const selection = new RowSelection();
    click(selection, 2);
    click(selection, 1_000_000_000, { shift: true });
    let read = 0;
    const result = selectedText(selection, (i) => { ++read; return `r${i}`; }, 1000, 5);
    assert.deepEqual(result, { text: "r2\nr3\nr4", copied: 3, total: 3, truncated: false });
    assert.equal(read, 3);
});
