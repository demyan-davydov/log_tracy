//! The values of a slider (resources/slider.js), without Sciter (tests/js): the
// value at a point of its track, the place of a value, the value a key moves it
// to. A range is { min, max, step }; its values are min + k * step.

const clamp = (x, lo, hi) => Math.min(hi, Math.max(lo, x));

// The value at `fraction` of the track (0: its left end, 1: its right one; a
// point beyond it gives the end), the nearest of the step
export function valueAt(fraction, { min, max, step }) {
    const value = min + Math.round(clamp(fraction, 0, 1) * (max - min) / step) * step;
    return clamp(value, min, max);
}

// The place of `value` on the track, 0..1; a value beyond the range stands at its end
export function fractionOf(value, { min, max }) {
    return max > min ? clamp((value - min) / (max - min), 0, 1) : 0;
}

// The value a key moves `value` to: the arrows to the step beside it (from a
// value off the step: the nearest one on that side; from one beyond the range
// never further from it), Home and End to the ends; null for a key that isn't
// the slider's
export function keyedValue(value, code, { min, max, step }) {
    const k = (value - min) / step; // the steps from min, fractional off the step
    switch (code) {
        case "ArrowRight":
        case "ArrowUp":
            return value >= max ? value : clamp(min + (Math.floor(k + 1e-9) + 1) * step, min, max);
        case "ArrowLeft":
        case "ArrowDown":
            return value <= min ? value : clamp(min + (Math.ceil(k - 1e-9) - 1) * step, min, max);
        case "Home": return min;
        case "End": return max;
        default: return null;
    }
}

// A range slider has two knobs, [low, high], low <= high.

// The knob a press at `value` takes: 0 (low) or 1 (high), the nearer one (as
// far from both: the right one). On knobs at one place a press on them takes
// none yet (null): the way the mouse moves first decides
export function nearestKnob(value, [low, high]) {
    if (low === high) return value < low ? 0 : value > high ? 1 : null;
    return value - low < high - value ? 0 : 1;
}

// The range with knob `knob` moved to `value`: up to the other knob, never past it
export function movedRange([low, high], knob, value) {
    return knob === 0 ? [Math.min(value, high), high] : [low, Math.max(value, low)];
}
