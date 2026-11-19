//! The log table of a view of a document: an element with the native behavior `log-table` (source/ui/log_table_behavior.d) that draws
//! the rows and handles the input; this script gives it the target (`setLogTableTarget`: which document and which view it shows, and
//! the number the script talks to it by), carries what Sciter does not give it (the gestures of the trackpad, the menus, the clipboard,
//! the notices) and tells it the look of the application. A view of a panel (view-table.js) holds one `LogTableView`.
import { setAnchor, setLogTableTarget, logTableCall, logTableSetLook } from "backend.js";
import { collectLook } from "log-table-look.js";
import { lockAxis } from "log-table-gesture.js";
import { anchorClickPlan, rowMoved } from "anchor-click.js";
import { anchorRefusalText } from "pane-commands.js";
import { showNoticeAt } from "notice.js";
import { tr } from "i18n/i18n.js";
import { wholeRows } from "pane-state.js";

// The tables there are, by the number D gave each: what D tells the script (a click on an anchor, an item of a menu) names its table
const views = new Map();

// Tells D the colors of the theme and the scale of the text, which are the application's: every table has them (the CSS variables are
// read from a table of the log, hidden or not: `style.variable("bg-row")`, no `--`, gives every color as `#rrggbb`, a `morph()` or a named
// one too; what does not read stays as it is in D). Called when the first table starts and by script.js when the theme or the font
// size changes. The font size comes from script.js (`logTableFontSize`).
export function logTableLookChanged(percent = globalThis.logTableFontSize ?? 100) {
    const view = views.values().next().value;
    if (!view) return;
    const style = view.element.style;
    logTableSetLook(JSON.stringify(collectLook(name => style.variable(name), percent)));
}
globalThis.logTableLookChanged = logTableLookChanged;

export class LogTableView {
    // @param docId - the document whose rows the table shows
    // @param search - false: the main view of the document, true: its search view
    // @param slot - the element the table fills (a table is put in it: the target is set just before, so the table that
    //   attaches then is this one)
    constructor(docId, search, slot) {
        this.docId = docId;
        this.search = search;
        this.tableId = setLogTableTarget(docId, search);
        this.element = Element.create(<div class="log-table-view" tabindex="0" />);
        views.set(this.tableId, this);
        slot.append(this.element); // the behavior of CSS attaches here
        this.bindInput();
        logTableLookChanged();
    }

    // The table is gone with its panel
    destroy() {
        views.delete(this.tableId);
        this.element.remove();
    }

    // A call to the table (ui/table_script.d, `dispatch`): logTableCall("stats")
    call(method, ...args) {
        return logTableCall(this.tableId, method, ...args);
    }

    // The rows on screen are drawn again (the rules or the search changed what colors them)
    refreshRows() {
        this.call("render");
    }

    // The message of an anchor was set or cleared, from wherever it came (this table, the other one, the pass of the index that
    // applied it later): the table reads its row again. `rows` as the backend tells it: { message, anchored, main, search }
    anchorApplied(rows) {
        this.call("anchorApplied", rows.message, rowMoved(rows, this.search) ? 1 : 0);
    }

    // ---- what the table gives to the rest of the panel ----

    // The message index of the current row, the one the other table follows; null if none is picked (taken out of the picked ones, or cleared)
    followedMessage() {
        const row = JSON.parse(this.call("currentRow"));
        return row === null ? null : row.id;
    }

    // The rows wholly in view and how many it has room for, as `jumpStep` takes them (see wholeRows, pane-state.js)
    visibleRows() {
        return wholeRows(JSON.parse(this.call("view")), row => Number(this.call("rowHeight", row)));
    }

    // Shows the row of a step of `jumpStep` (pane-state.js): the row picked alone, quietly (the other table is not told, the keyboard stays where it
    // is), and scrolled to when it is not in view: the row `step.top` first, the columns where they are, by a glide (D jumps over the far part)
    showRow(step) {
        if (step.top !== null) {
            const { first } = JSON.parse(this.call("view"));
            this.call("scrollTo", step.top, first.column, 0, first.dx, 1);
        }
        this.call("pickRow", step.position);
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
            this.call("pan", axis === "x" ? 0 : -evt.deltaY, axis === "y" ? 0 : -evt.deltaX);
            return true;
        });
        element.on("gestureend", () => { this.call("panEnd"); return true; });
        // The context menu is the script's, the table only answers where the click was (`hitTest`, JSON: `kind` header / footer / cell /
        // free, `column` (id) and `index`, of a cell `row`, `picked` and `text` {offset, word} when the point is on characters; `hasText`:
        // some text is selected). A cell of a row that is not picked makes the row the picked one (`contextPick`). Every copy item carries
        // its table and the address it copies from: the kind (0 the text, 1 the rows, 2 a cell), the row, the column's index.
        // The event "contextmenu" has no position (x and y are 0): the press that makes it is the last "mousedown", in the element's own dip.
        let pressX = 0, pressY = 0;
        element.on("mousedown", evt => { pressX = evt.x; pressY = evt.y; return false; });
        element.on("contextmenu", evt => {
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
                {hit.hasText ? <li class="log-table-copy" table={table} kind="0" row={hit.row} column={hit.index}>{tr("Copy")}</li> : []}
                <li class="log-table-copy" table={table} kind="2" row={hit.row} column={hit.index}>{tr("Copy Cell")}</li>
                <li class="log-table-copy" table={table} kind="1" row={hit.row} column={hit.index}>{tr("Copy Row")}</li>
            </menu>);
            return true;
        });
    }
}

// A table tells the row the user selected (JSON: table, row, id of the message, delayed); the panel follows it in the other table
globalThis.logTableRowChosen = json => {
    const chosen = JSON.parse(json);
    views.get(chosen.table)?.rowChosen?.(chosen.id, chosen.delayed === true);
};

// The clipboard is the script's: a table hands the text selected over (Cmd/Ctrl+C)
globalThis.logTableCopy = text => Clipboard.writeText(text);

// The items of that menu copy from their address (D puts the text on the clipboard)
document.on("click", "menu.context > li.log-table-copy", (evt, item) => {
    const number = name => parseInt(item.getAttribute(name));
    views.get(number("table"))?.call("copy", number("kind"), number("row"), number("column"));
});

// A table tells a click on a cell of a clickable column (the anchor column; JSON: table, item, id of the message, column id, whether the
// row is anchored). The anchor is set or cleared by the backend; `onAnchorApplied` (script.js) tells every table of the document. A
// refusal says why in a notice right of the cell.
globalThis.logTableCellClicked = json => {
    const click = JSON.parse(json);
    const view = views.get(click.table);
    if (click.column !== "anchor" || !view) return;
    const answer = setAnchor(view.docId, click.id, !click.anchored);
    const { rows, notice } = anchorClickPlan(click, answer, anchorRefusalText);
    if (rows) globalThis.onAnchorApplied?.(view.docId, JSON.stringify(rows));
    if (notice) showNoticeAt(view.element, notice.rect, notice.text); // the rect is in the table's coordinates: the element's own
};
