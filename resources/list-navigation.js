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

// A navigation of a virtual list to `target` (a row, "start", "end"), the
// list counting `before` / `rendered` / `after` rows of a view of `total`.
// The list's count lags behind a growing view (it learns of rows from grow()
// and from the rows it asks for): its new rows are counted first (`after`:
// the new count after the rendered rows, null if it stays). It may also still
// count a larger view (a view changed, the list not rendered yet): the target
// stays within the rows of both. Returns { after, target: safeTarget's, null
// if there is nowhere to go }.
export function navigationStep(target, { total, before, rendered, after }) {
    const missing = total - before - rendered - after;
    const counted = missing > 0 ? after + missing : after;
    const rows = Math.min(before + rendered + counted, total);
    return { after: missing > 0 ? counted : null, target: safeTarget(target, rows) };
}

// A list whose window grew (a higher list, a smaller font): Sciter fills a
// list with half its window and asks for no more until it scrolls, so a list
// that got higher shows a gap under its rows. Renders rows up to the window
// (`windowSize`; the list counts `before` / `rendered` / `after` rows) after
// the last one. Rows before the first one only when the list shows its last
// row with room under it (`gap`) and every row after is rendered: they push
// the rows on screen down, so the list goes to its end then (`toEnd`). A list
// whose last row is below the screen keeps its rows where they are. Returns
// { append, after, prepend, before, toEnd }: the rows to render after and
// before, to count after and before them, and whether to go to the last row;
// null if none (the window rendered, every row rendered, or no row rendered:
// Sciter fills an empty list itself).
export function fillStep({ before, rendered, after, windowSize, gap }) {
    if (rendered === 0) return null;
    const room = Math.max(0, windowSize - rendered);
    const append = Math.min(after, room);
    const prepend = gap && append === after ? Math.min(before, room - append) : 0;
    if (append + prepend === 0) return null;
    return { append, after: after - append, prepend, before: before - prepend, toEnd: prepend > 0 };
}

// A jump of a list to a far row ends with a short animated scroll
// (VirtualList.smoothAnimateTo): the eye sees where the rows went. It covers
// this share of the sliding window: half of the half the list renders on each
// side of a row jumped to (see windowSize), a bit more than half a screen of
// rows one line high. Rows on screen don't tell it: one may be higher than
// the list.
export const approachShare = 0.25;

// Where a list starts the animated scroll that brings the row `target` to its
// top. An animated scroll renders no rows: it stops at the last rendered one
// (Sciter 6.0.5.5), so the rows of its way must be rendered when it starts.
// A row nearer than the approach (approachShare of `windowSize`, at least
// one) whose way is rendered (the row and half a window under it: the most
// rows a screen shows) is scrolled to from where the list is: null. Else the
// list first jumps (VirtualList.navigateToTop) to `jumpTo` and shows `startAt`
// at its top at once: a row below is jumped to itself, which renders half a
// window above it, and the scroll starts the approach above it; a row above
// is scrolled to from the approach below it.
// `list`: { firstVisible (the first row on screen, null if none), firstBuffer
// / lastBuffer (the first and the last rendered row), total (rows),
// windowSize (vlist.slidingWindowSize) }.
export function approachStep(target, { firstVisible, firstBuffer, lastBuffer, total, windowSize }) {
    const approach = Math.max(1, Math.floor(windowSize * approachShare));
    if (firstVisible !== null) {
        const near = Math.abs(target - firstVisible) <= approach;
        const rendered = target >= firstBuffer && Math.min(total - 1, target + Math.ceil(windowSize / 2)) <= lastBuffer;
        if (near && rendered) return null;
    }
    if (firstVisible === null || target > firstVisible)
        return { jumpTo: target, startAt: Math.max(0, target - approach) };
    const below = Math.min(total - 1, target + approach);
    return { jumpTo: below, startAt: below };
}
