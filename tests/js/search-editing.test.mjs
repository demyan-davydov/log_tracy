// The caret and the edits of the chip search editor, see resources/search-editing.js.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { makeChip } from "../../resources/search-query.js";
import {
    moveCaret, moveTo, typeInGap, typeBarInChip, deleteInGap, searchChips,
    sameQuery, assignColors, historyIndex, selection, extendCaret, selectChipsFrom, selectTo, selectAll, selectedChips, insertChips,
} from "../../resources/search-editing.js";

const text = (t, ignoreCase = true) => makeChip(t, { ignoreCase });
const regex = (t) => makeChip(t, { isRegex: true });
const gap = (g) => ({ gap: g });
const at = (chip, offset) => ({ chip, offset });

const ab = [text("ab"), text("cd")];

test("moveCaret: an arrow from a gap goes into the next chip, at its near edge", () => {
    assert.deepEqual(moveCaret({ chips: ab, pos: gap(1) }, "left"), { chips: ab, pos: at(0, 2) });
    assert.deepEqual(moveCaret({ chips: ab, pos: gap(1) }, "right"), { chips: ab, pos: at(1, 0) });
});

test("moveCaret: an arrow stays at the ends of the query", () => {
    assert.deepEqual(moveCaret({ chips: ab, pos: gap(0) }, "left"), { chips: ab, pos: gap(0) });
    assert.deepEqual(moveCaret({ chips: ab, pos: gap(2) }, "right"), { chips: ab, pos: gap(2) });
    assert.deepEqual(moveCaret({ chips: [], pos: gap(0) }, "right"), { chips: [], pos: gap(0) });
});

test("moveCaret: a word arrow in a gap jumps over a whole chip", () => {
    assert.deepEqual(moveCaret({ chips: ab, pos: gap(2) }, "wordLeft"), { chips: ab, pos: gap(1) });
    assert.deepEqual(moveCaret({ chips: ab, pos: gap(0) }, "wordRight"), { chips: ab, pos: gap(1) });
});

test("moveCaret: Home and End in a gap go to the ends of the query", () => {
    assert.deepEqual(moveCaret({ chips: ab, pos: gap(1) }, "home"), { chips: ab, pos: gap(0) });
    assert.deepEqual(moveCaret({ chips: ab, pos: gap(1) }, "end"), { chips: ab, pos: gap(2) });
});

test("moveCaret: an arrow at the edge of a chip leaves it for the gap next to it", () => {
    assert.deepEqual(moveCaret({ chips: ab, pos: at(1, 0) }, "left"), { chips: ab, pos: gap(1) });
    assert.deepEqual(moveCaret({ chips: ab, pos: at(0, 2) }, "right"), { chips: ab, pos: gap(1) });
    assert.deepEqual(moveCaret({ chips: ab, pos: at(1, 0) }, "wordLeft"), { chips: ab, pos: gap(1) },
        "a word arrow that reached the edge leaves too");
    assert.deepEqual(moveCaret({ chips: ab, pos: at(1, 2) }, "wordRight"), { chips: ab, pos: gap(2) });
});

test("moveCaret: inside a chip the keys are the text field's own", () => {
    assert.equal(moveCaret({ chips: ab, pos: at(0, 1) }, "left"), null);
    assert.equal(moveCaret({ chips: ab, pos: at(0, 1) }, "right"), null);
    assert.equal(moveCaret({ chips: ab, pos: at(0, 2) }, "left"), null);
    assert.equal(moveCaret({ chips: ab, pos: at(0, 0) }, "home"), null);
    assert.equal(moveCaret({ chips: ab, pos: at(0, 2) }, "end"), null);
    assert.equal(moveCaret({ chips: ab, pos: at(0, 0) }, "left", false), null,
        "with a selection the arrow only collapses it");
});

test("moveTo: leaving an empty chip removes it", () => {
    const chips = [text("ab"), text(""), text("cd")];
    assert.deepEqual(moveTo({ chips, pos: at(1, 0) }, gap(2)), { chips: ab, pos: gap(1) });
    assert.deepEqual(moveTo({ chips, pos: at(1, 0) }, gap(1)), { chips: ab, pos: gap(1) });
    assert.deepEqual(moveTo({ chips, pos: at(1, 0) }, at(2, 1)), { chips: ab, pos: at(1, 1) });
    assert.deepEqual(moveTo({ chips, pos: at(1, 0) }, at(0, 1)), { chips: ab, pos: at(0, 1) });
    assert.deepEqual(moveTo({ chips, pos: at(1, 0) }, gap(3)), { chips: ab, pos: gap(2) });
});

test("moveTo: a chip of spaces is kept, and so is the empty chip the caret stays in", () => {
    const spaced = [text(" ")];
    assert.deepEqual(moveTo({ chips: spaced, pos: at(0, 1) }, gap(1)), { chips: spaced, pos: gap(1) });
    const empty = [text("")];
    assert.deepEqual(moveTo({ chips: empty, pos: at(0, 0) }, at(0, 0)), { chips: empty, pos: at(0, 0) });
});

test("moveCaret: leaving an empty chip by an arrow removes it", () => {
    const chips = [text("ab"), text(""), text("cd")];
    assert.deepEqual(moveCaret({ chips, pos: at(1, 0) }, "right"), { chips: ab, pos: gap(1) });
    assert.deepEqual(moveCaret({ chips, pos: at(1, 0) }, "left"), { chips: ab, pos: gap(1) });
});

test("typeInGap: a character typed in a gap starts a new chip there", () => {
    assert.deepEqual(typeInGap({ chips: ab, pos: gap(1) }, "x"),
        { chips: [text("ab"), text("x"), text("cd")], pos: at(1, 1) });
    assert.deepEqual(typeInGap({ chips: [], pos: gap(0) }, " "), { chips: [text(" ")], pos: at(0, 1) });
});

test("typeInGap: '|' in a gap does nothing", () => {
    assert.deepEqual(typeInGap({ chips: ab, pos: gap(1) }, "|"), { chips: ab, pos: gap(1) });
});

test("typeBarInChip: '|' closes a text chip and goes on in the next one", () => {
    assert.deepEqual(typeBarInChip({ chips: ab, pos: at(0, 2) }),
        { chips: [text("ab"), text(""), text("cd")], pos: at(1, 0) }, "at the end: a new chip");
    assert.deepEqual(typeBarInChip({ chips: [text("abcd", true)], pos: at(0, 2) }),
        { chips: [text("ab", true), text("cd", true)], pos: at(1, 0) }, "in the middle: the chip is split");
});

test("typeBarInChip: no empty chip is left before the caret", () => {
    assert.deepEqual(typeBarInChip({ chips: ab, pos: at(1, 0) }), { chips: ab, pos: at(1, 0) },
        "at the start of a chip nothing changes");
    assert.deepEqual(typeBarInChip({ chips: [text("")], pos: at(0, 0) }), { chips: [text("")], pos: at(0, 0) });
});

test("typeBarInChip: '|' after '\\' and in a regex goes into the chip", () => {
    assert.deepEqual(typeBarInChip({ chips: [text("a\\")], pos: at(0, 2) }), { chips: [text("a|")], pos: at(0, 2) });
    assert.deepEqual(typeBarInChip({ chips: [regex("ab")], pos: at(0, 1) }), { chips: [regex("a|b")], pos: at(0, 2) });
});

test("deleteInGap: Backspace removes the chip before the caret, Delete the one after it", () => {
    assert.deepEqual(deleteInGap({ chips: ab, pos: gap(1) }, "backspace"), { chips: [text("cd")], pos: gap(0) });
    assert.deepEqual(deleteInGap({ chips: ab, pos: gap(1) }, "delete"), { chips: [text("ab")], pos: gap(1) });
    assert.deepEqual(deleteInGap({ chips: ab, pos: gap(0) }, "backspace"), { chips: ab, pos: gap(0) });
    assert.deepEqual(deleteInGap({ chips: ab, pos: gap(2) }, "delete"), { chips: ab, pos: gap(2) });
});

test("searchChips: the chips a search is run with, without the empty ones", () => {
    assert.deepEqual(searchChips([text(""), text("a"), text(" "), regex("")]), [text("a"), text(" ")]);
});

// ---- selection of whole chips ----

const abc = [text("a"), text("b"), text("c")];
const sel = (anchor, g) => ({ chips: abc, pos: gap(g), anchor });

test("selection: the chips between the anchor and the caret, in either direction", () => {
    assert.deepEqual(selection(sel(1, 3)), { from: 1, to: 3 });
    assert.deepEqual(selection(sel(3, 1)), { from: 1, to: 3 });
    assert.equal(selection(sel(2, 2)), null, "an empty one is none");
    assert.equal(selection({ chips: abc, pos: gap(1) }), null);
    assert.deepEqual(selectedChips(sel(3, 1)), [text("b"), text("c")]);
});

test("extendCaret: Shift+arrows in a gap select chip by chip from where they started", () => {
    assert.deepEqual(extendCaret({ chips: abc, pos: gap(1) }, "right"), sel(1, 2));
    assert.deepEqual(extendCaret(sel(1, 2), "right"), sel(1, 3));
    assert.deepEqual(extendCaret(sel(1, 3), "right"), sel(1, 3), "stays at the end");
    assert.deepEqual(extendCaret(sel(1, 2), "left"), sel(1, 1), "back to nothing selected");
    assert.deepEqual(extendCaret(sel(1, 1), "wordLeft"), sel(1, 0), "a word is a chip here");
    assert.deepEqual(extendCaret(sel(2, 2), "home"), sel(2, 0));
    assert.deepEqual(extendCaret(sel(0, 1), "end"), sel(0, 3));
});

test("selectChipsFrom: a selection leaving a chip takes the whole chip", () => {
    const inB = { chips: abc, pos: at(1, 0) };
    assert.deepEqual(selectChipsFrom(inB, 1, 1), sel(2, 1), "to the left: from after the chip");
    assert.deepEqual(selectChipsFrom(inB, 1, 2), sel(1, 2), "to the right: from before it");
    assert.deepEqual(selectChipsFrom(inB, 1, 0), sel(2, 0), "on to the chips under the mouse");
    assert.deepEqual(selectChipsFrom(inB, 1, 3), sel(1, 3));
});

test("selectChipsFrom: leaving an empty chip only removes it", () => {
    const chips = [text("a"), text(""), text("c")];
    assert.deepEqual(selectChipsFrom({ chips, pos: at(1, 0) }, 1, 2), { chips: [text("a"), text("c")], pos: gap(1) });
});

test("selectTo: a drag or Shift+click from an anchor gap", () => {
    assert.deepEqual(selectTo({ chips: abc, pos: gap(0) }, 0, 2), sel(0, 2));
    assert.deepEqual(selectTo(sel(0, 2), 0, 1), sel(0, 1));
});

test("selectAll: every chip", () => {
    assert.deepEqual(selectAll({ chips: abc, pos: gap(1) }), sel(0, 3));
});

test("moveCaret: an arrow without Shift drops the selection at its side", () => {
    assert.deepEqual(moveCaret(sel(1, 3), "left"), { chips: abc, pos: gap(1) });
    assert.deepEqual(moveCaret(sel(3, 1), "right"), { chips: abc, pos: gap(3) });
    assert.deepEqual(moveCaret(sel(1, 3), "home"), { chips: abc, pos: gap(0) });
});

test("deleteInGap: Backspace and Delete remove the selected chips", () => {
    assert.deepEqual(deleteInGap(sel(3, 1), "backspace"), { chips: [text("a")], pos: gap(1) });
    assert.deepEqual(deleteInGap(sel(0, 2), "delete"), { chips: [text("c")], pos: gap(0) });
});

test("typeInGap: a character replaces the selected chips", () => {
    assert.deepEqual(typeInGap(sel(1, 3), "x"), { chips: [text("a"), text("x")], pos: at(1, 1) });
    assert.deepEqual(typeInGap(sel(1, 3), "|"), sel(1, 3), "'|' does nothing");
});

test("insertChips: pasted chips go to the caret, after them the caret", () => {
    const pasted = [regex("x"), text("y")];
    assert.deepEqual(insertChips({ chips: abc, pos: gap(1) }, pasted),
        { chips: [text("a"), regex("x"), text("y"), text("b"), text("c")], pos: gap(3) });
    assert.deepEqual(insertChips(sel(1, 3), pasted),
        { chips: [text("a"), regex("x"), text("y")], pos: gap(3) }, "instead of the selection");
});

test("insertChips: in a chip they go after it, an empty chip they replace", () => {
    const pasted = [regex("x")];
    assert.deepEqual(insertChips({ chips: abc, pos: at(0, 1) }, pasted),
        { chips: [text("a"), regex("x"), text("b"), text("c")], pos: gap(2) });
    assert.deepEqual(insertChips({ chips: [text("a"), text("")], pos: at(1, 0) }, pasted),
        { chips: [text("a"), regex("x")], pos: gap(2) });
});

test("sameQuery: queries differ by their chips, not by the empty ones being edited", () => {
    assert.equal(sameQuery([text("a"), text("")], [text("a")]), true);
    assert.equal(sameQuery([text("a"), text("b")], [text("b"), text("a")]), false, "the order matters");
    assert.equal(sameQuery([text("a")], [text("a", false)]), false, "the case matters");
    assert.equal(sameQuery([text("a")], [regex("a")]), false, "the type matters");
});

// ---- colors ----

const colored = (t, color) => ({ ...makeChip(t), color });

test("assignColors: a chip without a color takes the first one no other chip has", () => {
    assert.deepEqual(assignColors([colored("a", 0), text("b"), colored("c", 1)], 16),
        [colored("a", 0), colored("b", 2), colored("c", 1)]);
    assert.deepEqual(assignColors([text("a"), text("b")], 16), [colored("a", 0), colored("b", 1)]);
});

test("assignColors: the chips keep their colors, the array too if nothing changes", () => {
    const chips = [colored("a", 5), colored("b", 3)];
    assert.equal(assignColors(chips, 16), chips);
});

test("assignColors: with every color taken, the one used least, the first of them", () => {
    const chips = [colored("a", 0), colored("b", 1), colored("c", 0), text("d")];
    assert.deepEqual(assignColors(chips, 2)[3], colored("d", 1));
    assert.deepEqual(assignColors([colored("a", 0), colored("b", 1), text("c")], 2)[2], colored("c", 0));
});

test("typeBarInChip: the chip split off is a new chip, without the color", () => {
    const next = typeBarInChip({ chips: [colored("abcd", 4)], pos: at(0, 2) });
    assert.equal(next.chips[0].color, 4);
    assert.equal(next.chips[1].color, undefined);
});

test("sameQuery: the colors are no part of the query", () => {
    assert.equal(sameQuery([colored("a", 1)], [colored("a", 2)]), true);
});

// ---- the search history ----

test("historyIndex: the arrows go through the queries and stop at the ends", () => {
    assert.equal(historyIndex(-1, 3, "down"), 0, "the first arrow down takes the latest query");
    assert.equal(historyIndex(0, 3, "down"), 1);
    assert.equal(historyIndex(2, 3, "down"), 2);
    assert.equal(historyIndex(2, 3, "up"), 1);
    assert.equal(historyIndex(0, 3, "up"), 0);
    assert.equal(historyIndex(-1, 0, "down"), -1, "an empty history");
});
