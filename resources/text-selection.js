// The text selected across the cells and rows of a log table: pure logic,
// kept apart from the table (virtual-dlt-view.js) so it can be tested with
// node. Tests: tests/js/text-selection.test.mjs.
// See docs/stories/selectable-cells.md.
//
// A selection is { anchor, focus }: where the drag began and where the mouse
// is now. A position is { row, col, offset }: the view index of the row, the
// number of the cell among the cells of the row whose text can be selected,
// in their order (which cells those are is the table's to decide), and the
// character under the mouse in the text of that cell (-1 in an empty cell). The characters under both ends are selected:
// that is what Sciter's rangeFromPoint gives, the character under a point.
// The table keeps no text: the cells are read anew by their row (the rows are
// not kept in the script either), so the selection survives scrolling.

// -1, 0 or 1 as `a` is before, at or after `b`
function compare(a, b) {
    return Math.sign(a.row - b.row) || Math.sign(a.col - b.col) || Math.sign(a.offset - b.offset);
}

// { start, end } of `selection` in the order of the text, null if none
export function textRange(selection) {
    if (!selection) return null;
    const { anchor, focus } = selection;
    return compare(anchor, focus) <= 0 ? { start: anchor, end: focus } : { start: focus, end: anchor };
}

// Whether the cell `col` of the row `row` is in `range`: from the cell of the
// start to the cell of the end, both included
function cellInRange(range, row, col) {
    const cell = { row, col, offset: 0 };
    return compare(cell, { ...range.start, offset: 0 }) >= 0 && compare(cell, { ...range.end, offset: 0 }) <= 0;
}

// The selected part of the cell `col` of the row `row`, whose text has
// `length` characters: [from, to) in its text, null if none of it is
export function cellPart(range, row, col, length) {
    if (!range || length === 0 || !cellInRange(range, row, col)) return null;
    const { start, end } = range;
    const from = row === start.row && col === start.col ? Math.max(0, start.offset) : 0;
    const to = row === end.row && col === end.col ? Math.min(length, end.offset + 1) : length;
    return to > from ? [from, to] : null;
}

// The selected text for the clipboard: the cells of a row by tabs, the rows by
// new lines, as whole rows are copied (rowText in cell-format.js); at most
// `limit` characters of whole rows, as selectedText in row-selection.js:
// { text, copied (rows), total (rows), truncated }.
// @param cellTextsOf - row => the texts of its cells in their order, null if the
//   row can't be read: it is left out
// @param rowCount - the rows of the view: the selection may outlast a shorter view
export function rangeText(range, cellTextsOf, limit = Infinity, rowCount = Infinity) {
    if (!range) return { text: "", copied: 0, total: 0, truncated: false };
    const lines = [];
    let length = 0, truncated = false;
    const last = Math.min(range.end.row, rowCount - 1);
    for (let row = range.start.row; row <= last && !truncated; row++) {
        const texts = cellTextsOf(row);
        if (!texts) continue;
        const parts = [];
        texts.forEach((text, col) => {
            if (!cellInRange(range, row, col)) return;
            const part = cellPart(range, row, col, text.length);
            parts.push(part ? text.slice(part[0], part[1]) : ""); // an empty cell keeps its tab
        });
        const line = parts.join("\t");
        const added = (lines.length ? 1 : 0) + line.length; // with the line break
        if (length + added > limit) truncated = true;
        else {
            lines.push(line);
            length += added;
        }
    }
    return { text: lines.join("\n"), copied: lines.length, total: Math.max(0, last - range.start.row + 1), truncated };
}

// The rows to paint again when the selection goes from `before` to `after`
// ({ anchor, focus }, either null): [first, last], null if none. While the
// mouse drags, the anchor stays: only the rows from the old focus to the new
// one change (the row of the anchor is among them if the focus passed it).
export function repaintRows(before, after) {
    const sameAnchor = before && after && before.anchor.row === after.anchor.row
        && before.anchor.col === after.anchor.col && before.anchor.offset === after.anchor.offset;
    const rows = sameAnchor ? [before.focus.row, after.focus.row]
        : [before, after].filter(Boolean).flatMap(s => [s.anchor.row, s.focus.row]);
    return rows.length ? [Math.min(...rows), Math.max(...rows)] : null;
}

// The pieces of a cell's text ([{text, chip}] of matchPieces) cut where its
// selected part `part` ([from, to), null if none) starts and ends, each with
// `selected`
export function splitSelected(pieces, part) {
    const result = [];
    let at = 0;
    for (const piece of pieces) {
        const start = at, end = at + piece.text.length;
        at = end;
        const cuts = part ? [start, Math.min(end, Math.max(start, part[0])), Math.min(end, Math.max(start, part[1])), end]
            : [start, end, end, end];
        for (let i = 0; i < 3; i++) {
            if (cuts[i + 1] > cuts[i])
                result.push({ text: piece.text.slice(cuts[i] - start, cuts[i + 1] - start), chip: piece.chip, selected: i === 1 });
        }
    }
    return result;
}

const wordChar = /^[\p{L}\p{N}_]$/u;

// [start, end) of the character of `text` with the UTF-16 unit `i`: two units
// for one outside the BMP (a surrogate pair), never half of it
function charSpan(text, i) {
    const code = text.charCodeAt(i);
    if (code >= 0xDC00 && code <= 0xDFFF && i > 0) {
        const before = text.charCodeAt(i - 1);
        if (before >= 0xD800 && before <= 0xDBFF) return [i - 1, i + 1];
    }
    if (code >= 0xD800 && code <= 0xDBFF && i + 1 < text.length) {
        const after = text.charCodeAt(i + 1);
        if (after >= 0xDC00 && after <= 0xDFFF) return [i, i + 2];
    }
    return [i, i + 1];
}

// The word of `text` at `offset` a double click selects: [from, to), the
// character alone if it is not part of a word, null for an empty text
export function wordAt(text, offset) {
    if (text.length === 0) return null;
    const isWord = ([start, end]) => wordChar.test(text.slice(start, end));
    const here = charSpan(text, Math.min(Math.max(0, offset), text.length - 1));
    if (!isWord(here)) return here;
    let [from, to] = here;
    for (let before; from > 0 && isWord(before = charSpan(text, from - 1));) from = before[0];
    for (let after; to < text.length && isWord(after = charSpan(text, to));) to = after[1];
    return [from, to];
}

// Whether two selections ({ anchor, focus }, or null) are the same: a mouse
// move that doesn't change it paints nothing again
export function sameSelection(a, b) {
    if (!a || !b) return a === b;
    return compare(a.anchor, b.anchor) === 0 && compare(a.focus, b.focus) === 0;
}

// How far, in dips, the mouse moves from a plain press before the press is a
// drag selecting text rather than a click
const dragThreshold = 3;

// Whether the mouse at `point` ({ x, y }) has moved from `press` far enough
// to drag (dragThreshold)
export function isDrag(press, point) {
    return Math.hypot(point.x - press.x, point.y - press.y) >= dragThreshold;
}

// The offset of a text position right of the text of its cell: past its end
// (finite: positions are compared by subtracting them)
export const pastEnd = Number.MAX_SAFE_INTEGER;

// The cell under the window coordinate x of a row, from the boxes of its text
// cells (Index first): [{ right, innerLeft, innerRight }]. Left of the cells is
// the first one, right of them the end of the last one. { col, offset }: the
// offset is 0 left of the text of the cell (in its padding), pastEnd right of
// it, null over it: the character there is the cell's to tell (rangeFromPoint).
// null if the row has no cells.
export function cellHit(cells, x) {
    if (cells.length === 0) return null;
    const col = cells.findIndex(cell => x < cell.right);
    if (col < 0) return { col: cells.length - 1, offset: pastEnd };
    const { innerLeft, innerRight } = cells[col];
    return { col, offset: x < innerLeft ? 0 : x >= innerRight ? pastEnd : null };
}
