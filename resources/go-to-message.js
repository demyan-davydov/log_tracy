//! Go to Message: what is typed in its window (go-to-message.htm) as the index of a message
//! of the log, the range of the indexes it shows and the history of the jumps under the
//! field. Sciter-free; tests:
//! tests/js/go-to-message.test.mjs.
import { groupDigits } from "./file-info.js";

// The index typed in `text` among `count` messages: { index } of one of them (spaces, as
// groupDigits puts them, are skipped), else index null; outOfRange: what is typed can't be
// gone to (not a number, past the last message); nothing typed is no mistake yet
export function messageIndexOf(text, count) {
    const digits = String(text).replace(/\s/g, "");
    if (!digits) return { index: null, outOfRange: false };
    const index = /^\d+$/.test(digits) ? Number(digits) : NaN;
    if (!(index < count)) return { index: null, outOfRange: true };
    return { index, outOfRange: false };
}

// "0 – 1 234 567": the indexes of `count` messages, empty if there are none
export function rangeText(count) {
    return count > 0 ? `0 – ${groupDigits(count - 1)}` : "";
}

// How many jumps the history keeps
export const maxJumps = 5;

// `history` (message indexes gone to, the newest first) with a jump to `index`:
// at the front, not twice, maxJumps at most. A new list
export function rememberJump(history, index) {
    return [index, ...history.filter(i => i !== index)].slice(0, maxJumps);
}
