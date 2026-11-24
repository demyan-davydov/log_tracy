import test from "node:test";
import assert from "node:assert/strict";
import { anchorClickPlan, isAnchorClick, rowMoved } from "../../resources/anchor-click.js";

const click = { id: 7, anchored: false };

test("a refusal and a pending anchor tell the tables nothing", () => {
    assert.equal(anchorClickPlan(click, { refused: "limit", rows: null }).rows, null);
    assert.equal(anchorClickPlan(click, { refused: null, pending: true, rows: null }).rows, null);
});

test("a refusal has a notice by the cell, if the cell is known and the refusal has a text; nothing else has one", () => {
    const withRect = { id: 7, anchored: false, rect: [1, 2, 24, 16] };
    const limit = { refused: "limit", max: 16, rows: null };
    assert.deepEqual(anchorClickPlan(withRect, limit, answer => `${answer.max} at most`).notice, { rect: [1, 2, 24, 16], text: "16 at most" });
    assert.equal(anchorClickPlan(click, limit, () => "16 at most").notice, null, "no cell: nowhere to show it");
    assert.equal(anchorClickPlan(withRect, limit).notice, null, "no text");
    assert.equal(anchorClickPlan(withRect, { refused: null, rows: null }, () => "x").notice, null, "done: nothing to say");
    assert.equal(anchorClickPlan(withRect, { refused: null, pending: true }, () => "x").notice, null);
});

test("the rows the backend names are what the tables are told", () => {
    const rows = { message: 7, anchored: true, main: false, search: true };
    assert.deepEqual(anchorClickPlan(click, { refused: null, pending: false, rows }).rows, rows);
});

test("a row that stayed in both views is told as a row that only changed", () => {
    assert.deepEqual(anchorClickPlan(click, { refused: null, pending: false, rows: null }).rows,
        { message: 7, anchored: true, main: false, search: false });
    assert.deepEqual(anchorClickPlan({ id: 7, anchored: true }, { refused: null, rows: null }).rows,
        { message: 7, anchored: false, main: false, search: false });
});

test("the table of the view tells whether its row moved", () => {
    const rows = { message: 7, anchored: true, main: false, search: true };
    assert.equal(rowMoved(rows, true), true);
    assert.equal(rowMoved(rows, false), false);
});

test("only a click on a cell of the anchor column with its message is an anchor click", () => {
    const click = { type: "click", kind: "cell", column: "anchor", row: 3, id: 7, anchored: false };
    assert.equal(isAnchorClick(click), true);
    assert.equal(isAnchorClick({ ...click, type: "enter" }), false, "an enter");
    assert.equal(isAnchorClick({ ...click, kind: "header" }), false, "the title of the column");
    assert.equal(isAnchorClick({ ...click, column: "payload" }), false, "another column");
    const { id, ...gone } = click;
    assert.equal(isAnchorClick(gone), false, "no message: not taken");
});
