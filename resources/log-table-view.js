//! The log table of a view of a document: an element with the native behavior `log-table` (source/ui/log_table_behavior.d) that draws
//! the rows and handles the input; this script writes on its element what it shows (the attributes `doc`, `search` and `table`, the
//! number the script talks to it by, and `hears`, what its handlers hear of the mouse: D reads them when the behavior attaches), carries what Sciter does not give it (the gestures of the trackpad, the menus, the clipboard,
//! the notices, the tips of the titles) and tells it the look of the application. A view of a panel (view-table.js) holds one `LogTableView`.
import { columns, setAnchor, logTableCall, logTableSetLook, logTableMinWidthNames } from "backend.js";
import { collectLook } from "log-table-look.js";
import { lockAxis, panAxis } from "log-table-gesture.js";
import { anchorClickPlan, isAnchorClick, rowMoved } from "anchor-click.js";
import { anchorRefusalText } from "pane-commands.js";
import { showNotice, showNoticeAt } from "notice.js";
import { popupAtRect } from "rect-popup.js";
import { ColumnTip, hintsOf } from "column-tip.js";
import { PointerHandlers } from "pointer-handlers.js";
import { copyText, isMac, onWindowDeactivated, windowActive } from "platform.js";
import { menuOpensByMouse } from "menu-gate.js";
import { primaryShortcutText } from "menu-shortcuts.js";
import { tr } from "i18n/i18n.js";

// The tables there are, by the number D gave each: what D tells the script (what the mouse did, an item of a menu) names its table
const views = new Map();
let lastTableId = 0; // the number of the last table made: every table has one of its own, from 1

// The size of the header font of the table at 100% (LogFont.header of source/ui/log_table/log_look.d): the tip of a title has it
const headerPoints = 10;

// The font size of the tables in % of the normal one (Settings), as script.js keeps it
const fontPercent = () => globalThis.logTableFontSize ?? 100;

// The names of the CSS variables of the least widths of the columns, asked of D once
let minWidthNames = null;

// Tells D the colors of the theme and the scale of the text, which are the application's: every table has them (the CSS variables are
// read from a table of the log, hidden or not: `style.variable("bg-row")`, no `--`, gives every color as `#rrggbb`, a `morph()` or a named
// one too; what does not read stays as it is in D). Called when the first table starts and by script.js when the theme or the font
// size changes. The font size comes from script.js (`logTableFontSize`).
export function logTableLookChanged(percent = fontPercent()) {
    const view = views.values().next().value;
    if (!view) return;
    const style = view.element.style;
    minWidthNames ??= logTableMinWidthNames(); // the variables of the least widths of the columns, which D names by its formats
    logTableSetLook(JSON.stringify(collectLook(name => style.variable(name), percent, minWidthNames)));
}
globalThis.logTableLookChanged = logTableLookChanged;

export class LogTableView {
    // @param docId - the document whose rows the table shows
    // @param search - false: the main view of the document, true: its search view
    // @param slot - the element the table fills
    constructor(docId, search, slot) {
        this.docId = docId;
        this.search = search;
        this.tableId = ++lastTableId;
        // what the table shows is on its element: the behavior reads it when it attaches (ui/main_window.d, createBehavior)
        this.element = Element.create(<div class="log-table-view" tabindex="0" doc={docId} search={search ? "1" : "0"}
            table={this.tableId} />);
        this.pointerHandlers = new PointerHandlers([clickAnchor]); // what the mouse does to the titles and the cells: `onPointer`
        views.set(this.tableId, this);
        slot.append(this.element); // the behavior of CSS attaches here
        this.bindInput();
        this.tip = this.makeTip();
        logTableLookChanged();
    }

    // The table is gone with its panel
    destroy() {
        this.tip.dismiss();
        views.delete(this.tableId);
        this.element.remove();
    }

    // A call to the table (ui/table_script.d, `dispatch`): logTableCall("stats")
    call(method, ...args) {
        return logTableCall(this.tableId, method, ...args);
    }

    // The message of an anchor was set or cleared, from wherever it came (this table, the other one, the pass of the index that
    // applied it later): the table reads its row again. `rows` as the backend tells it: { message, anchored, main, search }
    anchorApplied(rows) {
        this.call("anchorApplied", rows.message, rowMoved(rows, this.search) ? 1 : 0);
    }

    // ---- what the table gives to the rest of the panel ----

    // Hears what the mouse does to the things of the table: `handler(event, view)`, `event` as D tells it (ui/table_messages.d,
    // `pointerJson`): `type` enter / leave / down / up / click / cancel, `kind` header / cell, `column` (id) and `index`, of a cell
    // `row`; a click on a cell has `id` (its message) and `anchored` (D tells no click on a row that is gone since the press); an enter,
    // a down, an up and a click have `rect` [x, y, w, h] in the element's own coordinates when known. Enters and leaves come only to a
    // view one of whose handlers asked for them, of the kinds asked (`{ over: ["header"] }`, "cell" too): they come at every frame of a
    // scroll under the mouse. They come only
    // when the mouse came to another thing (or the rows moved under it); a leave names the thing as it was entered, its row may be
    // another by now; when the rows are other ones a press is cancelled. While a button is down a handler hears nothing of the things
    // passed: a down, then a leave of the thing, then at the release an up, a click if it is the thing of the press with no drag, and an
    // enter of the thing under the mouse (a cancel instead of the up if the window lost the mouse). A double click is two clicks. What the
    // table does with the mouse itself (selecting, scrolling) is its own and goes on whatever a handler does
    onPointer(handler, { over = [] } = {}) {
        if (!this.pointerHandlers.add(handler, over)) return;
        // the element keeps it for a table that attaches later (or again: ui/log_table/log_tables.d, `hearsOf`); one attached hears it now
        this.element.setAttribute("hears", this.pointerHandlers.hears());
        this.call("hearOver", ...this.pointerHandlers.flags());
    }

    // An event of the mouse from D, to every handler (pointer-handlers.js)
    pointer(event) {
        this.pointerHandlers.hand(event, this);
    }

    // The message index of the current row, the one the other table follows; null if none is picked (taken out of the picked ones, or cleared)
    followedMessage() {
        const row = JSON.parse(this.call("currentRow"));
        return row === null ? null : row.id;
    }

    // Shows the row of a step of `jumpStep` (pane-state.js): the table brings it into view when it is not (with room on the side it came from, or
    // at the top if it does not fit), by a glide; and the row is picked alone, quietly (the other table is not told, the keyboard stays where it is)
    showRow(step) {
        this.call("reveal", step.position, 1);
        this.call("pickRow", step.position);
    }

    // The tip of a short title: the full name of its column (`hint` of the columns of the document, not translated), under the title
    // as its continuation (popup.column-tip in table.css). It hides when the title may move from under it: a wheel or the fingers
    // scroll the columns, a key is pressed, a menu opens, the window loses the focus, the table goes.
    makeTip() {
        let hints = null, close = null;
        const tip = new ColumnTip({
            hintOf: column => {
                hints ??= hintsOf(columns(this.docId)); // null while the document is not open: asked again at the next title
                return hints?.get(column);
            },
            show: (rect, text) => {
                close = popupAtRect(this.element, rect, Element.create(<popup class="column-tip" style={`font-size: ${headerPoints * fontPercent() / 100}pt`}>{text}</popup>),
                    { anchorAt: 1, popupAt: 7, onDismissed: () => tip.dismiss() }); // its top-left on the title's bottom-left
            },
            hide: () => { close?.(); close = null; },
            active: windowActive,
        });
        this.onPointer((event) => tip.pointer(event), { over: ["header"] });
        for (const name of ["^wheel", "^gesturepan", "^contextmenu", "^keydown"])
            this.element.on(name, () => { tip.dismiss(); return false; });
        return tip;
    }

    // ---- the input Sciter leaves to the script ----

    bindInput() {
        const element = this.element;
        // The trackpad: only an element that asks gets its gestures (.ai/knowledge/sciter.md, the wheel and the trackpad);
        // the native event of a gesture has no deltas, so the script carries the finger's move over. The end of the gesture
        // lets the rows coast (the inertia is D's, Sciter gives none to an element scrolled by script).
        // A gesture moves along one axis: the one it goes farther on in its first pixels (`lockAxis`), so a diagonal drift of the
        // fingers does not scroll the columns while the rows are scrolled, and the other way round.
        let axis = null, across = 0, down = 0;
        element.on("gesturestart", () => {
            axis = null;
            across = down = 0;
            element.state.wantsGestures("pan-vertical", "pan-horizontal");
        });
        element.on("gesturepan", evt => {
            if (axis === null) {
                ({ axis, across, down } = lockAxis(across, down, evt.deltaX, evt.deltaY));
            }
            const along = panAxis(axis, evt.deltaX, evt.deltaY);
            this.call("pan", along === "x" ? 0 : -evt.deltaY, along === "y" ? 0 : -evt.deltaX);
            return true;
        });
        element.on("gestureend", () => { this.call("panEnd"); return true; });
        // The context menu is the script's, the table only answers where the click was (`hitTest`, JSON: `kind` header / footer / cell /
        // free, `column` (id) and `index`, of a cell `row`, `picked` and `text` {offset, word} when the point is on characters; `hasText`:
        // some text is selected). A cell of a row that is not picked makes the row the picked one (`contextPick`). Every copy item carries
        // its table and the address it copies from: the kind (0 the text, 1 the rows, 2 a cell), the row, the column's index. Only Copy
        // shows its key: Cmd/Ctrl+C copies the text while there is some, else the rows, so the key of Copy Row would come and go.
        // The event "contextmenu" has no position (x and y are 0): the press that makes it is the last "mousedown", in the element's own dip.
        let pressX = 0, pressY = 0;
        // A press takes the keys: the behavior handles the press itself, and then Sciter does not give the element the focus, so Cmd/Ctrl+C,
        // the arrows and the rest of the keys would go to what had it before
        element.on("mousedown", evt => {
            pressX = evt.x;
            pressY = evt.y;
            if (!element.state.focus) element.state.focus = true;
            return false;
        });
        element.on("contextmenu", evt => {
            if (!menuOpensByMouse()) return true; // the Menu key, Shift+F10: no menu (menu-gate.js), and the press above is not this one's
            const hit = JSON.parse(this.call("hitTest", pressX, pressY));
            if (hit.kind === "header") {
                // Customize Table (script.js opens the Settings on its Table section by this class)
                evt.source = Element.create(<menu class="context">
                    <li class="column-settings">{tr("Customize Table...")}</li>
                </menu>);
                return true;
            }
            if (hit.kind !== "cell") return false; // free space, the footer and the heads of groups have no menu
            if (!hit.picked) this.call("contextPick", hit.row);
            const table = this.tableId;
            evt.source = Element.create(<menu class="context">
                {hit.hasText ? <li class="log-table-copy" table={table} kind="0" row={hit.row} column={hit.index}>
                    {tr("Copy")}<span class="accesskey">{primaryShortcutText("C", isMac())}</span>
                </li> : []}
                <li class="log-table-copy" table={table} kind="2" row={hit.row} column={hit.index}>{tr("Copy Cell")}</li>
                <li class="log-table-copy" table={table} kind="1" row={hit.row} column={hit.index}>{tr("Copy Row")}</li>
            </menu>);
            return true;
        });
    }
}

// A window in the background shows no tip
onWindowDeactivated(() => { for (const view of views.values()) view.tip.dismiss(); });

// A table tells the row the user selected (JSON: table, row, id of the message, delayed); the panel follows it in the other table
globalThis.logTableRowChosen = json => {
    const chosen = JSON.parse(json);
    views.get(chosen.table)?.rowChosen?.(chosen.id, chosen.delayed === true);
};

// The clipboard is the script's: a table hands the text selected over (Cmd/Ctrl+C)
globalThis.logTableCopy = text => copyText(text);

// A copy of rows stopped at the limit of the copy (a million characters, ui/log_table/log_table.d `logCopyFormat`): the user is told
// how many rows went to the clipboard (JSON: table, copied, total)
globalThis.logTableCopyCut = json => {
    const { table, copied, total } = JSON.parse(json);
    const view = views.get(table);
    if (view) showNotice(view.element, tr("Copied {copied} of {total} rows: a copy holds at most a million characters", { copied, total }));
};

// The items of that menu copy from their address (D puts the text on the clipboard)
document.on("click", "menu.context > li.log-table-copy", (evt, item) => {
    const number = name => parseInt(item.getAttribute(name));
    views.get(number("table"))?.call("copy", number("kind"), number("row"), number("column"));
});

// A table tells what the mouse did to a title or a cell (JSON, `LogTableView.onPointer`); its view hands it to whoever listens
globalThis.logTableEvent = json => {
    const event = JSON.parse(json);
    views.get(event.table)?.pointer(event);
};

// A click on a cell of the anchor column sets or clears the anchor of its row: by the backend, `onAnchorApplied` (script.js) tells
// every table of the document. A refusal says why in a notice right of the cell.
function clickAnchor(event, view) {
    if (!isAnchorClick(event)) return;
    const answer = setAnchor(view.docId, event.id, !event.anchored);
    const { rows, notice } = anchorClickPlan(event, answer, anchorRefusalText);
    if (rows) globalThis.onAnchorApplied?.(view.docId, JSON.stringify(rows));
    if (notice) showNoticeAt(view.element, notice.rect, notice.text); // the rect is in the table's coordinates: the element's own
}
