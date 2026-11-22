//! The tip of a column title: when it shows the full name of a short title (`hint` of the column) and when it hides, from the mouse
//! events of the log table (`LogTableView.onPointer`). Free of Sciter: the view shows and hides the popup (log-table-view.js).

// How long the mouse rests on a title before its tip shows; a trial value
export const tipDelayMs = 500;

// The hints of the columns of a document (`getColumns`: `{ id, hint }`) by the column id, only of the columns that have one; null while
// the columns are not known yet (the document is not open): asked again later
export function hintsOf(columns) {
    if (columns.length === 0) return null;
    return new Map(columns.filter(c => c.hint).map(c => [c.id, c.hint]));
}

export class ColumnTip {
    // `hintOf(column)`: the hint of a column id, nothing if none; `show(rect, text)`: the tip under the title at `rect` [x, y, w, h];
    // `hide()`: hides it; `active()`: whether the window is active (no tip over a window in the background)
    constructor({ hintOf, show, hide, active = () => true,
        timers = { set: (fn, ms) => setTimeout(fn, ms), clear: id => clearTimeout(id) } }) {
        Object.assign(this, { hintOf, show, hide, active, timers });
        this.wait = null; // the timer of a tip to come
        this.shown = false;
        this.pressed = false; // a button is down: the leave and the enter it brings are not the mouse moving
        this.quiet = null; // the title pressed: no tip until the mouse leaves it
    }

    // An event of the table's mouse
    pointer(event) {
        switch (event.type) {
        case "enter":
            if (event.kind === "header" && event.column !== this.quiet) this.schedule(event);
            break;
        case "leave":
            this.dismiss();
            if (!this.pressed) this.quiet = null;
            break;
        case "down":
            this.dismiss();
            this.pressed = true;
            this.quiet = event.kind === "header" ? event.column : null;
            break;
        case "up":
        case "cancel":
            this.pressed = false;
            break;
        }
    }

    // Hides the tip and drops the one to come: the title moved (a scroll), a menu opened, the window or the table went
    dismiss() {
        if (this.wait !== null) this.timers.clear(this.wait);
        this.wait = null;
        if (this.shown) this.hide();
        this.shown = false;
    }

    // A tip of the title of `event` after the delay, if the column has a hint
    schedule(event) {
        const text = this.hintOf(event.column);
        if (!text || !event.rect) return;
        this.dismiss();
        this.wait = this.timers.set(() => {
            this.wait = null;
            if (!this.active()) return;
            this.show(event.rect, text);
            this.shown = true;
        }, tipDelayMs);
    }
}
