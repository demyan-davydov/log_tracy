// The text selected across the cells and rows of a log table, see
// resources/text-selection.js. Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { textRange, cellPart, rangeText, repaintRows, splitSelected, wordAt, wholeText, sameSelection, isDrag, cellHit, pastEnd }
    from "../../resources/text-selection.js";

const at = (row, col, offset) => ({ row, col, offset });

test("textRange: the start and the end of a selection, whichever way it was dragged", () => {
    const forward = textRange({ anchor: at(3, 1, 2), focus: at(5, 0, 4) });
    assert.deepEqual(forward, { start: at(3, 1, 2), end: at(5, 0, 4) });
    assert.deepEqual(textRange({ anchor: at(5, 0, 4), focus: at(3, 1, 2) }), forward, "dragged up");
    assert.deepEqual(textRange({ anchor: at(3, 2, 9), focus: at(3, 1, 0) }), { start: at(3, 1, 0), end: at(3, 2, 9) },
        "dragged left in a row");
    assert.deepEqual(textRange({ anchor: at(3, 1, 7), focus: at(3, 1, 2) }), { start: at(3, 1, 2), end: at(3, 1, 7) },
        "dragged left in a cell");
    assert.equal(textRange(null), null, "no selection");
});

test("cellPart: the characters under the start and the end are selected too", () => {
    const one = textRange({ anchor: at(3, 1, 2), focus: at(3, 1, 4) });
    assert.deepEqual(cellPart(one, 3, 1, 10), [2, 5], "inside one cell");
    assert.deepEqual(cellPart(textRange({ anchor: at(3, 1, 4), focus: at(3, 1, 4) }), 3, 1, 10), [4, 5], "one character");

    const many = textRange({ anchor: at(3, 1, 2), focus: at(5, 2, 4) });
    assert.deepEqual(cellPart(many, 3, 1, 10), [2, 10], "the start cell to its end");
    assert.deepEqual(cellPart(many, 3, 2, 6), [0, 6], "after the start in its row");
    assert.equal(cellPart(many, 3, 0, 6), null, "before the start in its row");
    assert.deepEqual(cellPart(many, 4, 0, 6), [0, 6], "a row between: every cell");
    assert.deepEqual(cellPart(many, 5, 1, 6), [0, 6], "before the end in its row");
    assert.deepEqual(cellPart(many, 5, 2, 10), [0, 5], "the end cell from its start");
    assert.equal(cellPart(many, 5, 3, 6), null, "after the end in its row");
    assert.equal(cellPart(many, 2, 1, 6), null, "a row before");
    assert.equal(cellPart(many, 6, 1, 6), null, "a row after");
});

test("cellPart: empty cells and offsets past the text", () => {
    const range = textRange({ anchor: at(3, 1, 2), focus: at(3, 1, 40) });
    assert.deepEqual(cellPart(range, 3, 1, 10), [2, 10], "the end past the text: to its end");
    assert.equal(cellPart(range, 3, 1, 0), null, "an empty cell has nothing to select");
    const fromEmpty = textRange({ anchor: at(3, 1, -1), focus: at(3, 2, 1) });
    assert.deepEqual(cellPart(fromEmpty, 3, 2, 5), [0, 2], "started in an empty cell (offset -1)");
    assert.equal(cellPart(null, 3, 1, 10), null, "no selection");
});

test("rangeText: cells by tabs, rows by new lines, as the rows are copied", () => {
    const cells = {
        3: ["0", "10:00", "first message"],
        4: ["1", "10:01", "second"],
        5: ["2", "10:02", "third message"],
    };
    const textOf = row => cells[row];
    const text = (selection) => rangeText(textRange(selection), textOf).text;
    assert.equal(text({ anchor: at(3, 2, 6), focus: at(3, 2, 12) }), "message");
    assert.equal(text({ anchor: at(3, 1, 3), focus: at(5, 2, 4) }), "00\tfirst message\n1\t10:01\tsecond\n2\t10:02\tthird");
    assert.equal(text({ anchor: at(5, 0, 0), focus: at(3, 2, 0) }), "first message\n1\t10:01\tsecond\n2", "dragged up");
    assert.equal(text({ anchor: at(4, 2, 0), focus: at(4, 2, 99) }), "second", "past the end of the text");
    assert.deepEqual(rangeText(textRange({ anchor: at(3, 0, 0), focus: at(5, 2, 99) }), textOf),
        { text: "0\t10:00\tfirst message\n1\t10:01\tsecond\n2\t10:02\tthird message", copied: 3, total: 3, truncated: false });
    assert.deepEqual(rangeText(null, textOf), { text: "", copied: 0, total: 0, truncated: false }, "no selection");
});

test("rangeText: an empty cell keeps its tab, a row that can't be read is left out", () => {
    const textOf = row => (row === 4 ? null : ["a", "", "b"]);
    assert.equal(rangeText(textRange({ anchor: at(3, 0, 0), focus: at(5, 2, 0) }), textOf).text, "a\t\tb\na\t\tb");
});

test("rangeText: at most `limit` characters of whole rows, and rows past the view are not read", () => {
    const read = [];
    const textOf = row => { read.push(row); return ["r" + row]; };
    const range = textRange({ anchor: at(0, 0, 0), focus: at(9, 0, 5) });
    assert.deepEqual(rangeText(range, textOf, 8), { text: "r0\nr1\nr2", copied: 3, total: 10, truncated: true });
    read.length = 0;
    assert.deepEqual(rangeText(range, textOf, Infinity, 2), { text: "r0\nr1", copied: 2, total: 2, truncated: false });
    assert.deepEqual(read, [0, 1]);
});

test("repaintRows: the rows whose look changes when the selection changes", () => {
    const before = { anchor: at(3, 1, 2), focus: at(5, 0, 1) };
    assert.deepEqual(repaintRows(before, { anchor: at(3, 1, 2), focus: at(8, 0, 1) }), [5, 8],
        "a drag: only the rows from the old end to the new one");
    assert.deepEqual(repaintRows(before, { anchor: at(3, 1, 2), focus: at(1, 0, 1) }), [1, 5],
        "dragged back past the start: its row is among them");
    assert.deepEqual(repaintRows(before, { anchor: at(9, 0, 0), focus: at(10, 0, 1) }), [3, 10], "a new start");
    assert.deepEqual(repaintRows(null, before), [3, 5], "a new selection");
    assert.deepEqual(repaintRows(before, null), [3, 5], "cleared");
    assert.equal(repaintRows(null, null), null, "nothing to repaint");
});

test("splitSelected: the pieces of a cell cut where its selected part starts and ends", () => {
    const pieces = [{ text: "an ", chip: null }, { text: "error", chip: 0 }, { text: " here", chip: null }];
    assert.deepEqual(splitSelected(pieces, [1, 5]), [
        { text: "a", chip: null, selected: false },
        { text: "n ", chip: null, selected: true },
        { text: "er", chip: 0, selected: true },
        { text: "ror", chip: 0, selected: false },
        { text: " here", chip: null, selected: false },
    ]);
    assert.deepEqual(splitSelected(pieces, null), pieces.map(p => ({ ...p, selected: false })), "nothing selected");
    assert.deepEqual(splitSelected([{ text: "abc", chip: null }], [0, 3]), [{ text: "abc", chip: null, selected: true }],
        "the whole text");
});

test("wordAt: the word a double click selects", () => {
    assert.deepEqual(wordAt("disk error, net ok", 7), [5, 10], "inside a word");
    assert.deepEqual(wordAt("disk error, net ok", 5), [5, 10], "at its start");
    assert.deepEqual(wordAt("disk error, net ok", 10), [10, 11], "a comma alone");
    assert.deepEqual(wordAt("get_software_version req", 3), [0, 20], "underscores and letters");
    assert.deepEqual(wordAt("щит 0x1F", 1), [0, 3], "letters of any script");
    assert.deepEqual(wordAt("0672656D 6FE", 2), [0, 8], "digits");
    assert.deepEqual(wordAt("abc", 9), [0, 3], "past the end: the word at the end");
    assert.deepEqual(wordAt("ab, ", 9), [3, 4], "past the end: the last character");
    assert.equal(wordAt("", 0), null, "an empty text");
});

test("wholeText: the whole text of a cell a triple click selects", () => {
    assert.deepEqual(wholeText("disk error, net ok"), [0, 18], "every character, spaces too");
    assert.deepEqual(wholeText("a😀"), [0, 3], "in UTF-16 units, as the offsets of a position");
    assert.equal(wholeText(""), null, "an empty text");
    // as a selection it is the whole cell and nothing of its neighbours
    const [from, to] = wholeText("error");
    const range = textRange({ anchor: { row: 2, col: 1, offset: from }, focus: { row: 2, col: 1, offset: to - 1 } });
    assert.deepEqual(cellPart(range, 2, 1, 5), [0, 5]);
    assert.equal(cellPart(range, 2, 0, 5), null);
    assert.equal(cellPart(range, 2, 2, 5), null);
});

test("wordAt: characters outside the BMP are never cut in half", () => {
    // "a😀b": the emoji is two UTF-16 units (1, 2)
    assert.deepEqual(wordAt("a😀b", 1), [1, 3], "an emoji alone, from its first half");
    assert.deepEqual(wordAt("a😀b", 2), [1, 3], "from its second half");
    // 𝐀𝐁 (mathematical bold letters, two units each) are letters: one word with x
    assert.deepEqual(wordAt("x𝐀𝐁 y", 3), [0, 5], "letters outside the BMP");
});

test("sameSelection: a move that changes nothing", () => {
    const one = { anchor: at(3, 1, 2), focus: at(5, 0, 4) };
    assert.equal(sameSelection(one, { anchor: at(3, 1, 2), focus: at(5, 0, 4) }), true);
    assert.equal(sameSelection(one, { anchor: at(3, 1, 2), focus: at(5, 0, 5) }), false, "another character");
    assert.equal(sameSelection(one, { anchor: at(3, 2, 2), focus: at(5, 0, 4) }), false, "another start");
    assert.equal(sameSelection(null, null), true);
    assert.equal(sameSelection(one, null), false);
});

test("isDrag: a press becomes a drag once the mouse moves away from it", () => {
    const press = { x: 100, y: 50 };
    assert.equal(isDrag(press, { x: 100, y: 50 }), false, "not moved");
    assert.equal(isDrag(press, { x: 101, y: 51 }), false, "a tremble of the hand");
    assert.equal(isDrag(press, { x: 100, y: 60 }), true, "moved");
});

test("cellHit: the cell under x and whether its text decides the character", () => {
    // Index at 10..40 (text 12..38), a column at 40..90 (text 42..88)
    const cells = [{ right: 40, innerLeft: 12, innerRight: 38 }, { right: 90, innerLeft: 42, innerRight: 88 }];
    assert.deepEqual(cellHit(cells, 20), { col: 0, offset: null }, "over the text: ask the cell");
    assert.deepEqual(cellHit(cells, 5), { col: 0, offset: 0 }, "left of the cells: the first character");
    assert.deepEqual(cellHit(cells, 41), { col: 1, offset: 0 }, "in the padding before the text");
    assert.deepEqual(cellHit(cells, 89), { col: 1, offset: pastEnd }, "in the padding after the text");
    assert.deepEqual(cellHit(cells, 200), { col: 1, offset: pastEnd }, "right of the cells: past the end");
    assert.equal(cellHit([], 20), null, "no cells");
});
