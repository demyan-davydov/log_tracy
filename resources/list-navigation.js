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
