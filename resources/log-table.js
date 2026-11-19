//! PROTOTYPE: puts the log table drawn by a native behavior written in D (source/ui/log_table_behavior.d,
//! docs/experiments/2026-11-19-painted-rows-d.md) over the main table: `showLogTable()` starts it,
//! `showLogTable(false)` stops it. All this script does is to place an element with
//! `behavior: log-table` over the table; the rows are drawn and the input handled by D. The
//! element's methods (el.xcall): jump(row, now), scrollBy(px, now), pan(px), panEnd(), setWrap(0|1), setWheelScale(k),
//! resetStats(), stats(), copyText(whole = 1: whole cells with their dates, as Cmd+C; 0: as shown),
//! demo(on = 1: the demo of rows grouped by two columns in place of the log; 0: the log again).
import { setAnchor, setLogTableTarget, logTableCall as callTable, logTableSetLook, logTableSingleLine as callSingleLine } from "backend.js";
import { collectLook } from "log-table-look.js";
import { lockAxis } from "log-table-gesture.js";
import { anchorClickPlan, rowMoved } from "anchor-click.js";
import { anchorRefusalText } from "pane-commands.js";
import { showNoticeAt } from "notice.js";
import { tr } from "i18n/i18n.js";

let overlay = null;
let watched = null;
let fitWatch = null;
let shown = { docId: 0, search: false }; // the view the table draws: its anchors are set through the backend
let tableId = 0; // the number D gave the table (`setLogTableTarget`): every call to it says it
const logTableCall = (method, ...args) => callTable(tableId, method, ...args);

// The overlay leaves what lies in the container under the table (the progress of a filter or a search and its Cancel,
// ux.md 21a): its bottom edge stands where the table's ends. The table's size changes so when the progress shows or
// goes; while the window is resized what is under the table keeps its height, and the edges follow by CSS alone.
function fit(table) {
    const [, containerTop, , containerHeight] = table.parentElement.state.box("xywh", "border", "window");
    const [, top, , height] = table.state.box("xywh", "border", "window");
    overlay.style.top = `${top - containerTop}px`;
    overlay.style.bottom = `${containerTop + containerHeight - top - height}px`;
}

function stop() {
    if (watched && fitWatch) watched.off?.("sizechange", fitWatch);
    overlay?.remove();
    overlay = watched = fitWatch = null;
}

// Tells the table drawn by D the colors of the theme and the scale of the text (the CSS variables are read from
// the table of the log). Called when the table starts and by the script when the theme or the font size changes.
// `style.variable("bg-row")` (no `--`) gives every color as `#rrggbb`, a `morph()` or a named one too; what does not
// read stays as it is in D. The font size comes from script.js (`logTableFontSize`).
globalThis.logTableLookChanged = (percent = globalThis.logTableFontSize ?? 100) => {
    if (!overlay || !watched) return;
    const style = watched.style;
    logTableSetLook(JSON.stringify(collectLook(name => style.variable(name), percent)));
};

// showLogTable(true, "search") draws the search results instead of the main view; the two share the widths of the columns
globalThis.showLogTable = (on = true, view = "main") => {
    stop();
    if (!on) return false;
    const table = [...document.querySelectorAll(`.log-table.${view}-view`)].find(t => t.getBoundingClientRect().height > 0);
    if (!table) return false;
    shown = { docId: table.$("tbody").docId, search: view === "search" };
    tableId = setLogTableTarget(shown.docId, shown.search);
    // Over the table in its own container, by its edges as the status views (tab-content.css): its size follows the
    // window's while it is resized, not only once the resize ends as a script listening to "sizechange" saw it
    // (.ai/knowledge/sciter.md); its bottom leaves the progress under the table (`fit`)
    overlay = Element.create(<div class="log-table-overlay" tabindex="0"
        style="behavior: log-table; position: absolute; left: 0; top: 0; right: 0; bottom: 0; size: auto; z-index: 50; background: #fff;" />);
    table.parentElement.append(overlay);
    watched = table;
    fit(table);
    fitWatch = () => fit(table);
    table.on("sizechange", fitWatch);
    // The trackpad: only an element that asks gets its gestures (.ai/knowledge/sciter.md, the wheel and the trackpad);
    // the native event of a gesture has no deltas, so the script carries the finger's move over. The end of the gesture
    // lets the rows coast (the inertia is D's, Sciter gives none to an element scrolled by script).
    // A gesture moves along one axis: the one it goes farther on in its first pixels (`lockAxis`), so a diagonal drift of the
    // fingers does not scroll the columns while the rows are scrolled, and the other way round.
    let axis = null, across = 0, down = 0;
    overlay.on("gesturestart", () => {
        axis = null;
        across = down = 0;
        overlay.state.wantsGestures("pan-vertical", "pan-horizontal");
    });
    overlay.on("gesturepan", evt => {
        if (axis === null) {
            ({ axis, across, down } = lockAxis(across, down, evt.deltaX, evt.deltaY));
        }
        logTableCall("pan", axis === "x" ? 0 : -evt.deltaY, axis === "y" ? 0 : -evt.deltaX);
        return true;
    });
    overlay.on("gestureend", () => { logTableCall("panEnd"); return true; });
    // The context menu is the script's, the table only answers where the click was (`hitTest`, JSON: `kind` header / footer / cell /
    // free, `column` (id) and `index`, of a cell `row`, `picked` and `text` {offset, word} when the point is on characters; `hasText`:
    // some text is selected). A cell of a row that is not picked makes the row the picked one (`contextPick`). Every copy item carries
    // the address it copies from: the kind (0 the text, 1 the rows, 2 a cell), the row, the column's index.
    // The event "contextmenu" has no position (x and y are 0): the press that makes it is the last "mousedown", in the element's own dip.
    let pressX = 0, pressY = 0;
    overlay.on("mousedown", evt => { pressX = evt.x; pressY = evt.y; return false; });
    overlay.on("contextmenu", evt => {
        const hit = JSON.parse(logTableCall("hitTest", pressX, pressY));
        if (hit.kind === "header") {
            // as the header of the old table: Customize Table (script.js opens the Settings on its Table section by this class)
            evt.source = Element.create(<menu class="context">
                <li class="column-settings">{tr("Customize Table...")}</li>
            </menu>);
            return true;
        }
        if (hit.kind !== "cell") return false; // free space, the footer and the heads of groups have no menu (as in the old table)
        if (!hit.picked) logTableCall("contextPick", hit.row);
        evt.source = Element.create(<menu class="context">
            {hit.hasText ? <li class="log-table-copy" kind="0" row={hit.row} column={hit.index}>{tr("Copy")}</li> : []}
            <li class="log-table-copy" kind="2" row={hit.row} column={hit.index}>{tr("Copy Cell")}</li>
            <li class="log-table-copy" kind="1" row={hit.row} column={hit.index}>{tr("Copy Row")}</li>
        </menu>);
        return true;
    });
    overlay.state.focus = true;
    globalThis.logTableElement = overlay;
    globalThis.logTableLookChanged();
    return true;
};

// The setting "every row one line" (Settings): the Payload is cut at its cell, or wrapped. script.js tells it when it changes
globalThis.logTableSingleLine = on => callSingleLine(on === true); // D keeps it for every table, those that start later too

// A call to the table drawn by D: logTableCall("stats"), logTableCall("jump", row, true)
globalThis.logTableCall = logTableCall;

// The clipboard is the script's: the table drawn by D hands the text selected over (Cmd/Ctrl+C)
globalThis.logTableCopy = text => Clipboard.writeText(text);

// The items of that menu copy from their address (D puts the text on the clipboard)
document.on("click", "menu.context > li.log-table-copy", (evt, item) => {
    const number = name => parseInt(item.getAttribute(name));
    logTableCall("copy", number("kind"), number("row"), number("column"));
});

// The table drawn by D tells a click on a cell of a clickable column (the anchor column; JSON: item, id of the message, column id,
// whether the row is anchored). The anchor is set or cleared by the backend as in the old table; `onAnchorApplied` (script.js) tells
// every table of the document, and `logTableAnchorRows` below is how this one hears of it. A refusal says why in a notice right of the cell.
globalThis.logTableCellClicked = json => {
    const click = JSON.parse(json);
    if (click.column !== "anchor" || !overlay || click.table !== tableId) return; // a click of another table is that table's
    const answer = setAnchor(shown.docId, click.id, !click.anchored);
    const { rows, notice } = anchorClickPlan(click, answer, anchorRefusalText);
    if (rows) globalThis.onAnchorApplied?.(shown.docId, JSON.stringify(rows));
    if (notice) showNoticeAt(overlay, notice.rect, notice.text); // the rect is in the table's coordinates: the overlay's own
};

// The rows of a document's message that an anchor changed, from wherever the anchor came (this table, the other one, the pass of the
// index that applied it later): the table drawn by D reads that row again. Called by `followAnchorRows` (document-pane.js).
globalThis.logTableAnchorRows = (docId, rows) => {
    if (!overlay || docId !== shown.docId) return;
    logTableCall("anchorApplied", rows.message, rowMoved(rows, shown.search) ? 1 : 0);
};
