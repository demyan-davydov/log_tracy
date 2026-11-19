//! The gestures of the trackpad over the log table, as plain functions (tests/js/log-table-gesture.test.mjs): which axis
//! a gesture moves along. Pure: nothing of Sciter here; log-table.js carries the events over.

// How many pixels of movement in all a gesture needs before its axis is known
export const lockPixels = 6;

// The axis of a gesture of the trackpad: after `lockPixels` of movement in all it is the one it went farther on ("x" or "y"),
// before that none yet (null: both go to D, which takes the larger of them). `across` and `down` are what has gone so far
// (absolute pixels); the new move `deltaX`, `deltaY` is added. Returns the axis and the sums to pass on.
export function lockAxis(across, down, deltaX, deltaY) {
    across += Math.abs(deltaX);
    down += Math.abs(deltaY);
    const axis = across + down < lockPixels ? null : across > down ? "x" : "y";
    return { axis, across, down };
}
