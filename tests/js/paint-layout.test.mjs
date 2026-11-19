// The layout of painted rows (resources/paint-layout.js): wrapping by the advances of glyphs,
// the rows on a screen from (first, offset), scrolling, the scrollbar's thumb.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { wrapLines, rowHeight, screenRows, scrollBy, thumbOf, rowAtThumb, charAt, cellBoxes, cellAtX, lineAtY } from "../../resources/paint-layout.js";

const adv = () => 10; // every glyph 10 px wide
const text = (s, lines) => lines.map(([a, b]) => s.slice(a, b));

test("a text that fits is one line", () => {
    assert.deepEqual(wrapLines("hello", 100, adv), [[0, 5]]);
    assert.deepEqual(wrapLines("", 100, adv), [[0, 0]], "an empty text is one empty line");
});

test("a text breaks after a space when the word does not fit", () => {
    const s = "aaa bbb ccc";
    assert.deepEqual(text(s, wrapLines(s, 70, adv)), ["aaa bbb ", "ccc"]);
    assert.deepEqual(text(s, wrapLines(s, 40, adv)), ["aaa ", "bbb ", "ccc"]);
});

test("the space ending a line may stick out of the width", () => {
    const s = "aaaa bb";
    assert.deepEqual(text(s, wrapLines(s, 40, adv)), ["aaaa ", "bb"]);
});

test("a word longer than the line breaks at the width", () => {
    const s = "abcdefghij";
    assert.deepEqual(text(s, wrapLines(s, 40, adv)), ["abcd", "efgh", "ij"]);
    assert.deepEqual(text("x" + s, wrapLines("x" + s, 40, adv)), ["xabc", "defg", "hij"]);
});

test("a long word starts on a line of its own only when it is a word", () => {
    const s = "ab cdefghijkl";
    assert.deepEqual(text(s, wrapLines(s, 50, adv)), ["ab ", "cdefg", "hijkl"]);
});

test("a hard line break is kept", () => {
    const s = "ab\ncd";
    assert.deepEqual(text(s, wrapLines(s, 100, adv)), ["ab", "cd"]);
    assert.deepEqual(text("ab\n", wrapLines("ab\n", 100, adv)), ["ab", ""]);
});

test("a width smaller than a glyph still takes a glyph a line", () => {
    assert.deepEqual(text("abc", wrapLines("abc", 5, adv)), ["a", "b", "c"]);
});

test("surrogate pairs are not cut", () => {
    const s = "a😀b"; // 😀 is two UTF-16 units
    const lines = wrapLines(s, 20, adv);
    assert.deepEqual(text(s, lines), ["a😀", "b"]);
});

test("a row is as high as its lines, with padding", () => {
    assert.equal(rowHeight(1, { line: 17, pad: 1 }), 19);
    assert.equal(rowHeight(3, { line: 17, pad: 1 }), 53);
});

// ---- the screen ----
const heights = index => 10 + (index % 3) * 10; // 10, 20, 30, 10, 20, 30...

test("rows from the first one fill the screen, the first one shifted up by the offset", () => {
    const view = screenRows({ first: 0, offset: 5, viewHeight: 50, total: 100, heightOf: heights });
    assert.deepEqual(view.rows.map(r => [r.index, r.top, r.height]), [[0, -5, 10], [1, 5, 20], [2, 25, 30]]);
    assert.equal(view.first, 0);
    assert.equal(view.offset, 5);
});

test("an offset past the first row moves on to the next", () => {
    const view = screenRows({ first: 0, offset: 12, viewHeight: 50, total: 100, heightOf: heights });
    assert.equal(view.first, 1);
    assert.equal(view.offset, 2);
});

test("a negative offset goes back to the rows above", () => {
    const view = screenRows({ first: 3, offset: -4, viewHeight: 50, total: 100, heightOf: heights });
    assert.equal(view.first, 2);
    assert.equal(view.offset, 26);
});

test("above the first row there is nothing: it stays at its top", () => {
    const view = screenRows({ first: 0, offset: -30, viewHeight: 50, total: 100, heightOf: heights });
    assert.equal(view.first, 0);
    assert.equal(view.offset, 0);
});

test("at the end the last row stands at the bottom", () => {
    const view = screenRows({ first: 99, offset: 0, viewHeight: 50, total: 100, heightOf: heights });
    const last = view.rows[view.rows.length - 1];
    assert.equal(last.index, 99);
    assert.equal(last.top + last.height, 50);
    assert.equal(view.rows[0].top <= 0, true);
});

test("a log shorter than the screen starts at its top", () => {
    const view = screenRows({ first: 1, offset: 3, viewHeight: 500, total: 2, heightOf: heights });
    assert.equal(view.first, 0);
    assert.equal(view.offset, 0);
    assert.equal(view.rows.length, 2);
});

test("no rows, nothing to show", () => {
    const view = screenRows({ first: 0, offset: 0, viewHeight: 50, total: 0, heightOf: heights });
    assert.deepEqual(view, { rows: [], first: 0, offset: 0 });
});

test("scrolling adds pixels to the offset and settles it", () => {
    const state = scrollBy({ first: 0, offset: 0 }, 35, { viewHeight: 50, total: 100, heightOf: heights });
    assert.deepEqual(state, { first: 2, offset: 5 });
    const back = scrollBy(state, -35, { viewHeight: 50, total: 100, heightOf: heights });
    assert.deepEqual(back, { first: 0, offset: 0 });
});

test("a scroll far past the rows known is by the mean height", () => {
    const state = scrollBy({ first: 0, offset: 0 }, 20000, { viewHeight: 50, total: 100000, heightOf: heights, mean: 20 });
    assert.equal(state.first, 1000);
});

// ---- the thumb ----
test("the thumb stands by the first row and the part of it scrolled away", () => {
    const geo = thumbOf({ first: 50, offset: 5, firstHeight: 10, total: 100, track: 200, visible: 5, min: 24 });
    assert.equal(geo.size, 24 > 200 * 5 / 100 ? 24 : 10);
    assert.ok(Math.abs(geo.top - (200 - geo.size) * (50.5 / 95)) < 1e-6);
});

test("the thumb is at the bottom on the last screen, at the top at the start", () => {
    assert.equal(thumbOf({ first: 0, offset: 0, firstHeight: 10, total: 100, track: 200, visible: 5, min: 24 }).top, 0);
    const end = thumbOf({ first: 95, offset: 0, firstHeight: 10, total: 100, track: 200, visible: 5, min: 24 });
    assert.equal(end.top + end.size, 200);
});

test("no thumb when every row is on screen", () => {
    assert.equal(thumbOf({ first: 0, offset: 0, firstHeight: 10, total: 3, track: 200, visible: 3, min: 24 }), null);
});

test("a thumb dragged gives the row under it", () => {
    const row = rowAtThumb({ top: 88, track: 200, size: 24, total: 100, visible: 5 });
    assert.ok(Math.abs(row - 95 * (88 / 176)) < 1e-6);
    assert.equal(rowAtThumb({ top: 0, track: 200, size: 24, total: 100, visible: 5 }), 0);
    assert.equal(rowAtThumb({ top: 176, track: 200, size: 24, total: 100, visible: 5 }), 95);
});

// ---- the character and the cell under the mouse ----
const tenWide = k => k * 10; // the width of the first k units of a text

test("the character under a point is the last one that starts at or before it", () => {
    assert.equal(charAt(0, 5, tenWide), 0);
    assert.equal(charAt(9, 5, tenWide), 0);
    assert.equal(charAt(10, 5, tenWide), 1);
    assert.equal(charAt(34, 5, tenWide), 3);
});

test("left of the text is its first character, right of it is past its end", () => {
    assert.equal(charAt(-5, 5, tenWide), 0);
    assert.equal(charAt(50, 5, tenWide), 5);
    assert.equal(charAt(500, 5, tenWide), 5);
    assert.equal(charAt(3, 0, tenWide), 0, "an empty text");
});

test("uneven widths are searched by the width of the prefix", () => {
    const widths = [0, 3, 14, 20, 21]; // the first k units' widths
    assert.equal(charAt(13, 4, k => widths[k]), 1);
    assert.equal(charAt(14, 4, k => widths[k]), 2);
    assert.equal(charAt(20.5, 4, k => widths[k]), 3);
});

test("the boxes of the text cells follow the anchor, the columns and the Payload", () => {
    // anchor 20, Index 40, Time 100, the Payload takes the rest of 400
    const boxes = cellBoxes([20, 40, 100], 400);
    assert.deepEqual(boxes, [{ left: 20, right: 60 }, { left: 60, right: 160 }, { left: 160, right: 400 }]);
});

test("the cell at x: left of them the first, right of them the last", () => {
    const boxes = cellBoxes([20, 40, 100], 400);
    assert.equal(cellAtX(boxes, 5), 0);
    assert.equal(cellAtX(boxes, 59), 0);
    assert.equal(cellAtX(boxes, 60), 1);
    assert.equal(cellAtX(boxes, 399), 2);
    assert.equal(cellAtX(boxes, 900), 2);
});

test("the line of a row at a height: clamped to its lines", () => {
    assert.equal(lineAtY(0, 3, { line: 17, pad: 1 }), 0);
    assert.equal(lineAtY(18, 3, { line: 17, pad: 1 }), 1);
    assert.equal(lineAtY(36, 3, { line: 17, pad: 1 }), 2);
    assert.equal(lineAtY(500, 3, { line: 17, pad: 1 }), 2);
    assert.equal(lineAtY(-9, 3, { line: 17, pad: 1 }), 0);
});
