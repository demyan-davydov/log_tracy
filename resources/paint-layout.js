//! The layout of rows a table draws itself (prototype, docs/experiments/2026-11-18-painted-rows.md):
// wrapping a text by the advances of its glyphs, the rows on a screen from (first, offset),
// scrolling by pixels, the thumb of the scrollbar. Pure: no Sciter, no DOM; heights and
// advances come in as functions. Tests: tests/js/paint-layout.test.mjs.

// The lines of `text` in a width of `width` px, [[start, end)] in UTF-16 units; `advance(glyph)`
// is the width of a glyph (a code point as a string). A line breaks after a space; the space may
// stick out of the width. A word longer than a line breaks at the width. A hard "\n" breaks too.
// A line has a glyph at least, so a width smaller than a glyph still moves on. An empty text is
// one empty line.
export function wrapLines(text, width, advance) {
    const lines = [];
    let start = 0, lineWidth = 0, breakAt = -1, breakWidth = 0, position = 0;
    while (position < text.length) {
        const code = text.codePointAt(position);
        const glyph = String.fromCodePoint(code);
        const length = glyph.length;
        if (glyph === "\n") {
            lines.push([start, position]);
            start = position + 1;
            lineWidth = 0;
            breakAt = -1;
            position += length;
            continue;
        }
        const step = advance(glyph);
        if (glyph !== " " && position > start && lineWidth + step > width) {
            if (breakAt > start) { // after the last space of the line
                lines.push([start, breakAt]);
                start = breakAt;
                lineWidth -= breakWidth;
            } else { // no space: the word is cut
                lines.push([start, position]);
                start = position;
                lineWidth = 0;
            }
            breakAt = -1;
            // what stayed over may still not leave room for the glyph (a very long word)
            if (position > start && lineWidth + step > width) {
                lines.push([start, position]);
                start = position;
                lineWidth = 0;
            }
        }
        lineWidth += step;
        position += length;
        if (glyph === " ") {
            breakAt = position;
            breakWidth = lineWidth;
        }
    }
    lines.push([start, text.length]);
    return lines;
}

// The height of a row of `lines` lines: `line` px a line, `pad` above and below
export function rowHeight(lines, { line, pad }) {
    return lines * line + 2 * pad;
}

// Settles (first, offset) within the rows: the offset in 0 .. height of the first row, the first
// row not above the log's start, the last row not above the bottom of the screen
function settle(first, offset, viewHeight, total, heightOf) {
    first = Math.max(0, Math.min(total - 1, first));
    const forward = () => {
        while (first < total - 1 && offset >= heightOf(first)) { offset -= heightOf(first); first++; }
    };
    const back = () => {
        while (offset < 0) {
            if (first === 0) { offset = 0; break; }
            first--;
            offset += heightOf(first);
        }
    };
    forward();
    back();
    // the rows end above the bottom of the screen: pull them down, the first rows come in
    let bottom = -offset;
    let index = first;
    while (index < total && bottom < viewHeight) bottom += heightOf(index++);
    if (index === total && bottom < viewHeight) {
        offset -= viewHeight - bottom;
        back();
    }
    return { first, offset };
}

// The rows on the screen of `viewHeight` px for a view of `total` rows whose first row on it is
// `first` shifted up by `offset` px: { rows: [{ index, top, height }], first, offset } with the
// first and the offset settled (see settle). `heightOf(index)` is the height of a row.
export function screenRows({ first, offset, viewHeight, total, heightOf }) {
    if (total <= 0) return { rows: [], first: 0, offset: 0 };
    const state = settle(first, offset, viewHeight, total, heightOf);
    const rows = [];
    let top = -state.offset;
    for (let index = state.first; index < total && top < viewHeight; index++) {
        const height = heightOf(index);
        rows.push({ index, top, height });
        top += height;
    }
    return { rows, first: state.first, offset: state.offset };
}

// (first, offset) scrolled by `pixels` (down is positive). A scroll of more than two screens
// does not pass row after row: it goes by the `mean` height of a row (each row passed is a
// layout), keeping the rest in pixels.
export function scrollBy({ first, offset }, pixels, { viewHeight, total, heightOf, mean }) {
    if (total <= 0) return { first: 0, offset: 0 };
    if (mean > 0 && Math.abs(pixels) > 2 * viewHeight) {
        const rows = Math.trunc(pixels / mean);
        return settle(first + rows, offset + pixels - rows * mean, viewHeight, total, heightOf);
    }
    return settle(first, offset + pixels, viewHeight, total, heightOf);
}

// The thumb of a scrollbar of a `track` px long: { top, size }, null if all the rows are on
// screen (`visible` rows of `total`). By the first row and the part of it scrolled away; at the
// bottom of the track when the last row is the first one to leave the screen. `min`: the least
// size.
export function thumbOf({ first, offset, firstHeight, total, track, visible, min }) {
    if (!(total > visible) || !(track > 0)) return null;
    const size = Math.min(track, Math.max(min, track * visible / total));
    const position = Math.max(0, Math.min(1, (first + offset / Math.max(1, firstHeight)) / (total - visible)));
    return { top: (track - size) * position, size };
}

// The row (a number with a fraction) at the top when the thumb stands at `top`
export function rowAtThumb({ top, track, size, total, visible }) {
    const room = track - size;
    if (!(room > 0)) return 0;
    return Math.max(0, Math.min(1, top / room)) * (total - visible);
}

// ---- the mouse over the rows ----

// The character under the point `dx` px from the start of a text of `length` UTF-16 units:
// the last unit that starts at or before it. `width(k)` is the width of the first k units
// (growing). Left of the text it is 0, right of it `length` (past its end).
export function charAt(dx, length, width) {
    if (length <= 0 || dx < 0) return 0;
    let low = 0, high = length;
    while (low < high) { // the least k whose prefix is wider than dx; the character is k - 1
        const middle = (low + high) >> 1;
        if (width(middle + 1) > dx) high = middle;
        else low = middle + 1;
    }
    return low;
}

// The boxes of the cells whose text can be selected, [{ left, right }]: `widths` are those of
// the anchor, the Index and the columns but the Payload, which takes the rest of `total`
export function cellBoxes(widths, total) {
    const boxes = [];
    let left = widths[0] ?? 0;
    for (let col = 1; col < widths.length; col++) {
        boxes.push({ left, right: left + widths[col] });
        left += widths[col];
    }
    boxes.push({ left, right: Math.max(left, total) });
    return boxes;
}

// The cell of `boxes` at x: left of them the first, right of them the last
export function cellAtX(boxes, x) {
    const col = boxes.findIndex(box => x < box.right);
    return col < 0 ? boxes.length - 1 : col;
}

// The line of a row of `lines` lines at `y` px from its top, clamped to them
export function lineAtY(y, lines, { line, pad }) {
    return Math.max(0, Math.min(lines - 1, Math.floor((y - pad) / line)));
}
