// Undo and redo of the chip search editor, see resources/edit-history.js.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { EditHistory } from "../../resources/edit-history.js";

test("undo goes back step by step, redo forth again", () => {
    const h = new EditHistory();
    h.record("a");          // "a" -> "b"
    h.record("b");          // "b" -> "c"
    assert.equal(h.undo("c"), "b");
    assert.equal(h.undo("b"), "a");
    assert.equal(h.undo("a"), null, "nothing more to undo");
    assert.equal(h.redo("a"), "b");
    assert.equal(h.redo("b"), "c");
    assert.equal(h.redo("c"), null, "nothing more to redo");
});

test("a new step drops what could be redone", () => {
    const h = new EditHistory();
    h.record("a");
    h.record("b");
    assert.equal(h.undo("c"), "b");
    h.record("b");          // "b" -> "x"
    assert.equal(h.redo("x"), null);
    assert.equal(h.undo("x"), "b");
    assert.equal(h.undo("b"), "a");
});

test("steps of the same kind in a row are one step", () => {
    const h = new EditHistory();
    h.record("", "type 0");     // "" -> "a"
    h.record("a", "type 0");    // "a" -> "ab"
    h.record("ab", "type 0");   // "ab" -> "abc"
    assert.equal(h.undo("abc"), "", "the typing in one chip is undone at once");
});

test("another kind, or a break, starts a new step", () => {
    const h = new EditHistory();
    h.record("", "type 0");
    h.record("a", "type 1");    // typing in another chip
    h.record("ab", "type 1");
    h.breakMerge();             // the caret went elsewhere
    h.record("abc", "type 1");
    assert.equal(h.undo("abcd"), "abc");
    assert.equal(h.undo("abc"), "a");
    assert.equal(h.undo("a"), "");
});

test("undo and redo break the merging too", () => {
    const h = new EditHistory();
    h.record("", "type 0");
    assert.equal(h.undo("a"), "");
    h.record("", "type 0");     // typed again after the undo: a step of its own
    h.record("b", "type 0");
    assert.equal(h.undo("bc"), "");
    assert.equal(h.undo(""), null);
});

test("only the latest steps are kept", () => {
    const h = new EditHistory(2);
    h.record("a");
    h.record("b");
    h.record("c");
    assert.equal(h.undo("d"), "c");
    assert.equal(h.undo("c"), "b");
    assert.equal(h.undo("b"), null);
});
