// Go to Message: what is typed in its window, see resources/go-to-message.js.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { messageIndexOf, rangeText, rememberJump } from "../../resources/go-to-message.js";
import { groupDigits } from "../../resources/file-info.js";

test("a message index typed: a number of the log's messages", () => {
    assert.deepEqual(messageIndexOf("42", 100), { index: 42, outOfRange: false });
    assert.deepEqual(messageIndexOf(" 0 ", 100), { index: 0, outOfRange: false }, "spaces around");
    assert.deepEqual(messageIndexOf("99", 100), { index: 99, outOfRange: false }, "the last one");
    assert.deepEqual(messageIndexOf(groupDigits(1234), 2000), { index: 1234, outOfRange: false }, "grouped as shown");
});

test("nothing to go to: empty, not a number, past the last message", () => {
    assert.deepEqual(messageIndexOf("", 100), { index: null, outOfRange: false }, "empty: no mistake yet");
    assert.deepEqual(messageIndexOf("4x", 100), { index: null, outOfRange: true });
    assert.deepEqual(messageIndexOf("100", 100), { index: null, outOfRange: true });
    assert.deepEqual(messageIndexOf("0", 0), { index: null, outOfRange: true }, "an empty log");
});

test("the range of the indexes, grouped as the File Info page shows numbers", () => {
    assert.equal(rangeText(1234568), `0 – ${groupDigits(1234567)}`);
    assert.equal(rangeText(1), "0 – 0");
    assert.equal(rangeText(0), "");
});

test("the history of jumps: the newest first, no repeats, five at most", () => {
    assert.deepEqual(rememberJump([], 7), [7]);
    assert.deepEqual(rememberJump([7, 3], 12), [12, 7, 3]);
    assert.deepEqual(rememberJump([12, 7, 3], 3), [3, 12, 7], "gone to again: moves to the front");
    assert.deepEqual(rememberJump([5, 4, 3, 2, 1], 6), [6, 5, 4, 3, 2], "the oldest drops out");
    const history = [1];
    rememberJump(history, 2);
    assert.deepEqual(history, [1], "a new list, the old one stays");
});
