// What the panel does with a row selected in one log table (the table is D's: ui/log_table_behavior.d tells the row chosen): where the
// other table shows it, and when. Pure, so it can be tested with node. Tests: tests/js/row-selection.test.mjs.

// The first row to show so that the row `position` is near the top of a view
// of `visibleRows` rows: up to two rows above it stay visible for context, but
// only as long as the view is high enough to have room for them
export function scrollTarget(position, visibleRows) {
    const above = Math.max(0, Math.min(2, Math.floor((visibleRows - 1) / 3)));
    return Math.max(0, position - above);
}

// ── Following the current row in the other table ──────────────────────────
// A new row selected in one log table is shown in the other one, if that one
// has it (see jumpStep in pane-state.js). See docs/stories/search-highlight.md.

// How long the row must rest, in ms, before a drag or the keys are followed:
// the other table doesn't jump along with every row the mouse passes over
export const followDelay = 500;

// Follows a change of the current row of a table: a click at once, a drag or
// the keys (`delayed`) once the row rests for followDelay. Only the last change
// counts: a newer one, of either table, drops the one waiting.
// follow(list) does it; timers: { set(fn, ms) -> id, clear(id) } (by hand in tests)
export class SelectionFollower {
    constructor(follow, timers = { set: (fn, ms) => setTimeout(fn, ms), clear: id => clearTimeout(id) }) {
        this.follow = follow;
        this.timers = timers;
        this.timer = null;
    }

    changed(list, delayed) {
        this.cancel();
        if (!delayed) {
            this.follow(list);
            return;
        }
        this.timer = this.timers.set(() => {
            this.timer = null;
            this.follow(list);
        }, followDelay);
    }

    cancel() {
        if (this.timer !== null) this.timers.clear(this.timer);
        this.timer = null;
    }
}
