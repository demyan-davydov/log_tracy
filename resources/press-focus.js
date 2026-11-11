// Where the keyboard goes when a panel is shown by a press on a tab: to the
// panel once the press ends, not while the mouse button is down. A focus moved
// inside the press costs Sciter a synchronous layout of the panel and makes it
// lay out and restyle the window again after the handler (~200 ms on large
// logs), and Sciter drops it at the end of the press anyway (the tab strip
// takes the focus of the press). Pure, so it can be tested with node.
// Tests: tests/js/press-focus.test.mjs.

export class PressFocus {
    pressing = false;
    pending = null; // the take() asked during the press

    // A press on a tab begins: a focus asked until it ends waits for it. What
    // an unfinished press asked (its release lost outside the window) is dropped
    press() {
        this.pressing = true;
        this.pending = null;
    }

    // The panel shown asks for the keys: `take()` gives them to it, now, or
    // when the press ends (only the last one asked then)
    request(take) {
        if (this.pressing) this.pending = take;
        else take();
    }

    // The press ended (released, a drag dropped, or lost outside the window):
    // the focus asked meanwhile is given now
    release() {
        const take = this.pending;
        this.pressing = false;
        this.pending = null;
        take?.();
    }
}
