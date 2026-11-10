//! How a virtual list scrolls a row to its top. Kept free of Sciter: tests/js.

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
