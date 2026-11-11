//! How a virtual list scrolls a row to its top, and how many rows it renders. Kept free of Sciter: tests/js.

// Sciter's vlist.navigateTo(n) puts the row n at the top of the screen when it
// comes from outside the sliding window of rendered rows or from above the
// screen; a row below the screen but inside the window ends up at the bottom
// instead, and a row on screen doesn't move. Such a row is first navigated
// past, out of the window, and then back to.
//
// Returns the row to navigate to before `target`, null if `target` needs no
// such step. `list`: { firstVisible (the first row on screen, null if none),
// lastBuffer (the last rendered row), total (rows), windowSize (rendered rows) }.
export function navigationPast(target, list) {
    if (typeof target !== "number") return null; // "start", "end"
    const { firstVisible, lastBuffer, total, windowSize } = list;
    if (firstVisible !== null && target <= firstVisible) return null; // first on screen or above it
    if (target > lastBuffer) return null; // outside the window
    const past = Math.min(total - 1, target + windowSize);
    return past > target ? past : null;
}

// How a list takes rows added after the ones it has (a view being filled:
// rows are only appended), keeping the rows on screen as they are. `list`:
// { total (rows now), before / rendered / after (the rows it counts before
// the rendered ones, renders, counts after them), windowSize }. Returns
// null if it has as many; { rebuild: true } if it can't be grown in place (no
// row rendered to grow from, or fewer rows than it renders: not a growth);
// else { rebuild: false, append: the rows to render after the last one (the
// window has room and ends at the last row: the list would not ask for them),
// after: the rows to count after the rendered ones }.
export function growStep(list) {
    const { total, before, rendered, after, windowSize } = list;
    if (total === before + rendered + after) return null;
    if (rendered === 0 || total < before + rendered) return { rebuild: true };
    const added = total - before - rendered;
    const append = after === 0 ? Math.min(added, Math.max(0, windowSize - rendered)) : 0;
    return { rebuild: false, append, after: added - append };
}

// Sciter's own sliding window (160 rows) is many times what a log table shows,
// and a jump (the scrollbar, Go to, PageDown) lays all of its rows out anew:
// about 1 ms a row of a log table, the bulk of the time of a jump.
export const minWindowSize = 20;

// What each half of the window has over the rows the list shows: a quarter
// more (windowExtra), at least windowMargin rows. The line measured may be
// higher than the rows (the header, measured before any row: ~10 % higher),
// an error that grows with the list, and Sciter fills a couple of rows less
// than half the window.
export const windowExtra = 0.25;
export const windowMargin = 5;

// How many rows a virtual list renders. Sciter fills a list (a new view, a
// jump) with half its window and asks for no more until it scrolls: half the
// window is the rows the list can show at most, all of them one line high
// (`lineHeight`, px; `height`: of the list), and the margin above. Rows higher
// than a line (a wrapped Payload) only leave more to spare. No fewer than
// minWindowSize. A window of fewer rows than the list shows crashes Sciter
// (vlist_ctl::move_buffer_to). Null while either height is unknown (no layout
// yet).
export function windowSize({ height, lineHeight }) {
    if (!(height > 0) || !(lineHeight > 0)) return null;
    const rows = Math.ceil(height / lineHeight);
    const half = Math.max(Math.ceil(rows * (1 + windowExtra)), rows + windowMargin);
    return Math.max(minWindowSize, 2 * half);
}

// Where a navigation of a virtual list may go: Sciter crashes navigating to a
// row at or past vlist.itemsTotal (`count`) while it has rows rendered
// (vlist_ctl::move_buffer_to). A row is clamped to 0..count - 1. "end" is the
// last row: Sciter navigating to "end" renders a row per pixel of the list's
// height whatever its window (~0.5 s for a tall list), the last row lands at
// the bottom just the same. "start" stays. Null if the list counts no row.
export function safeTarget(target, count) {
    if (!(count > 0)) return null;
    if (target === "end") return count - 1;
    if (typeof target !== "number") return target;
    return Math.max(0, Math.min(count - 1, target));
}
