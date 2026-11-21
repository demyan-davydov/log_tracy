//! The gestures of the trackpad over the log table, as plain functions (tests/js/log-table-gesture.test.mjs): which axis
//! a gesture moves along. Pure: nothing of Sciter here; log-table-view.js carries the events over.

// How many pixels of movement in all a gesture needs before its axis is known
export const lockPixels = 6;

// The axis of a gesture of the trackpad: after `lockPixels` of movement in all it is the one it went farther on ("x" or "y"),
// before that none yet (null: each move goes along its own larger axis, `panAxis`). `across` and `down` are what has gone so far
// (absolute pixels); the new move `deltaX`, `deltaY` is added. Returns the axis and the sums to pass on.
export function lockAxis(across, down, deltaX, deltaY) {
    across += Math.abs(deltaX);
    down += Math.abs(deltaY);
    const axis = across + down < lockPixels ? null : across > down ? "x" : "y";
    return { axis, across, down };
}

// The axis a move of a gesture goes along: the gesture's once it is locked, before that the larger of this move's (a tie: the rows,
// "y"). The script decides it, D moves along what it is given.
export function panAxis(axis, deltaX, deltaY) {
    return axis ?? (Math.abs(deltaX) > Math.abs(deltaY) ? "x" : "y");
}
