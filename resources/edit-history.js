// Undo and redo for an editor of immutable states (the chip search editor):
// the editor records the state before each change; changes of the same kind in
// a row (typing in one chip) are one step. Pure, so it can be tested with node.
// Tests: tests/js/edit-history.test.mjs. Story: docs/stories/advanced-search.md.

export class EditHistory {
    // @param limit - the most steps kept for undo
    constructor(limit = 100) {
        this.limit = limit;
        this.past = [];
        this.future = [];
        this.lastKind = null; // the kind of the step recorded last, null after a break
    }

    // Records the state before a change.
    // @param kind - changes of the same kind in a row are merged into one step
    record(before, kind = null) {
        this.future = [];
        if (kind !== null && kind === this.lastKind) return; // the step already has its start
        this.lastKind = kind;
        this.past.push(before);
        if (this.past.length > this.limit) this.past.shift();
    }

    // The next change starts a new step, whatever its kind
    breakMerge() {
        this.lastKind = null;
    }

    // @param current - the state now, to be redone
    // @returns the state to go back to, or null if there is nothing to undo
    undo(current) {
        this.lastKind = null;
        if (this.past.length === 0) return null;
        this.future.push(current);
        return this.past.pop();
    }

    // @param current - the state now, to be undone again
    // @returns the state to go forth to, or null if there is nothing to redo
    redo(current) {
        this.lastKind = null;
        if (this.future.length === 0) return null;
        this.past.push(current);
        return this.future.pop();
    }
}
