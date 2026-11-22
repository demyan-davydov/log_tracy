//! The handlers of what the mouse does to the titles and the cells of a log table (`LogTableView.onPointer`): who hears an event, and
//! the kinds of things whose enters and leaves they asked for, which the table is told. Free of Sciter.

// The kinds a handler may ask the enters and leaves of, in the order the table is told them (`hearOver(headers, cells)`)
const kinds = ["header", "cell"];

export class PointerHandlers {
    // `handlers`: the first ones, asking for no enters and leaves; `log(text)`: where a failing handler is told
    constructor(handlers = [], { log = text => console.log(text) } = {}) {
        this.handlers = [...handlers];
        this.heard = new Set();
        this.log = log;
    }

    // Adds `handler(event, view)`, which hears the enters and leaves of `over` too ("header", "cell"); true if the kinds heard changed
    add(handler, over = []) {
        this.handlers.push(handler);
        const before = this.heard.size;
        for (const kind of over)
            this.heard.add(kind);
        return this.heard.size !== before;
    }

    // Hands `event` to every handler in order; one that fails is logged, the ones after it still hear the event
    hand(event, view) {
        for (const handler of this.handlers) {
            try {
                handler(event, view);
            } catch (e) {
                this.log(`a pointer handler of the log table failed: ${e}`);
            }
        }
    }

    // The kinds heard as the attribute `hears` of the table's element writes them: by space, "" for none
    hears() {
        return kinds.filter(kind => this.heard.has(kind)).join(" ");
    }

    // The kinds heard as the table's `hearOver` takes them: 1 or 0 for the headers, the cells
    flags() {
        return kinds.map(kind => this.heard.has(kind) ? 1 : 0);
    }
}
