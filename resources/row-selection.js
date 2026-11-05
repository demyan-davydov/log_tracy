// The selected rows of a log table, by their position in the view (view index):
// pure logic, kept apart from the table (virtual-dlt-view.js) so it can be
// tested with node. Tests: tests/js/row-selection.test.mjs.
//
// The selection is a sorted list of disjoint ranges, not a set of rows: a
// Shift+click from the first row to the last of a log of millions of rows takes
// one entry. Checking a row is a binary search: it runs for every row rendered.

export class RowSelection {
    // [[first, last], ...], inclusive, sorted, neither overlapping nor adjacent
    ranges = [];
    // The current row (keyboard focus), null if none. A Shift range starts at
    // `anchor`: the row of the last click without Shift.
    current = null;
    anchor = null;
    // The ranges kept while the mouse drags, see beginDrag()
    dragBase = [];

    // The number of selected rows
    get count() {
        let count = 0;
        for (const [first, last] of this.ranges) count += last - first + 1;
        return count;
    }

    has(index) {
        return this._rangeAt(index) >= 0;
    }

    // A left click on the row `index`. modifiers: shift extends the selection
    // from the anchor; toggle (Cmd on macOS, Ctrl elsewhere) adds or removes
    // the row, and with shift adds the range to the selection.
    click(index, { shift = false, toggle = false } = {}) {
        if (shift) {
            const from = this.anchor ?? index;
            if (!toggle) this.ranges = [];
            this._add(Math.min(from, index), Math.max(from, index));
            this.anchor = from;
        } else if (toggle) {
            if (this.has(index)) this._remove(index);
            else this._add(index, index);
            this.anchor = index;
        } else {
            this._only(index);
        }
        this.current = index;
    }

    // A right click on the row `index`: a row outside the selection becomes
    // the only selected one, a selected row keeps the selection
    contextClick(index) {
        if (!this.has(index)) this._only(index);
        this.current = index;
    }

    // The keyboard moves to the row `index`: only it is selected
    moveTo(index) {
        this._only(index);
        this.current = index;
    }

    // The mouse is pressed on a row (after click()) and may drag: dragTo()
    // selects from the anchor to the row under the mouse. toggle (Cmd/Ctrl)
    // keeps the rows selected before, otherwise only the dragged range is.
    beginDrag({ toggle = false } = {}) {
        this.dragBase = toggle ? this.ranges.map(([first, last]) => [first, last]) : [];
    }

    // The mouse dragged to the row `index`, see beginDrag()
    dragTo(index) {
        const from = this.anchor ?? index;
        this.ranges = (this.dragBase ?? []).map(([first, last]) => [first, last]);
        this._add(Math.min(from, index), Math.max(from, index));
        this.current = index;
    }

    // No row is selected; the current row stays
    clear() {
        this.ranges = [];
    }

    // Nothing selected and no current row: the view shows other rows now
    reset() {
        this.ranges = [];
        this.current = null;
        this.anchor = null;
    }

    copy() {
        const copy = new RowSelection();
        copy.ranges = this.ranges.map(([first, last]) => [first, last]);
        copy.current = this.current;
        copy.anchor = this.anchor;
        return copy;
    }

    _only(index) {
        this.ranges = [[index, index]];
        this.anchor = index;
    }

    // The position in `ranges` of the range with `index`, -1 if none
    _rangeAt(index) {
        let lo = 0, hi = this.ranges.length - 1;
        while (lo <= hi) {
            const mid = (lo + hi) >> 1;
            const [first, last] = this.ranges[mid];
            if (index < first) hi = mid - 1;
            else if (index > last) lo = mid + 1;
            else return mid;
        }
        return -1;
    }

    // Adds the rows first..last, joining the ranges they overlap or touch
    _add(first, last) {
        const ranges = this.ranges;
        let start = 0;
        while (start < ranges.length && ranges[start][1] < first - 1) ++start;
        let end = start;
        while (end < ranges.length && ranges[end][0] <= last + 1) {
            first = Math.min(first, ranges[end][0]);
            last = Math.max(last, ranges[end][1]);
            ++end;
        }
        ranges.splice(start, end - start, [first, last]);
    }

    // Removes a selected row, splitting its range
    _remove(index) {
        const at = this._rangeAt(index);
        if (at < 0) return;
        const [first, last] = this.ranges[at];
        const parts = [];
        if (first < index) parts.push([first, index - 1]);
        if (index < last) parts.push([index + 1, last]);
        this.ranges.splice(at, 1, ...parts);
    }
}

// The text of the selected rows for the clipboard, one row per line, in the
// order of the view. rowText(index) gives the text of a row, null if the view
// doesn't have it (any more): it is skipped. The text stops before the row that
// would make it longer than `limit` characters.
// Returns { text, copied: rows in the text, total: rows selected, truncated:
// true if rows were left out for the limit }.
export function selectedText(selection, rowText, limit) {
    const lines = [];
    let length = 0;
    let full = false;
    for (const [first, last] of selection.ranges) {
        for (let index = first; index <= last && !full; ++index) {
            const line = rowText(index);
            if (line === null || line === undefined) continue;
            const added = (lines.length ? 1 : 0) + line.length; // with the line break
            if (length + added > limit) full = true;
            else {
                lines.push(line);
                length += added;
            }
        }
        if (full) break;
    }
    return { text: lines.join("\n"), copied: lines.length, total: selection.count, truncated: full };
}

// The first row to show so that the row `position` is near the top of a view
// of `visibleRows` rows: up to two rows above it stay visible for context, but
// only as long as the view is high enough to have room for them
export function scrollTarget(position, visibleRows) {
    const above = Math.max(0, Math.min(2, Math.floor((visibleRows - 1) / 3)));
    return Math.max(0, position - above);
}
