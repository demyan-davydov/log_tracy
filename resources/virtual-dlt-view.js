console.log("Loading virtual-dlt-view.js...");
import { VirtualList } from "virtual-select.js";
import { VirtualSelect } from "virtual-select.js";
import * as env from "@env";
import { cellClass, cellText, itemText, rowLayout } from "cell-format.js";
import { RowSelection, selectedText, autoScrollSpeed } from "row-selection.js";

// Columns the tables of the active document show, from Window.xcall("getTableColumns"):
// [{ id, title, kind, width, timeKind?, unitsPerSecond?, labels? }]
let columns = [];

// Sets the columns the rows are rendered with; the table header is rebuilt by
// the caller (see renderHeader)
export function setColumns(newColumns) {
    columns = newColumns;
}

// The colors of the filter rules of the active document by rule id (see
// rule-colors.js): a row shows the color of the rule it refers to
let ruleColorById = new Map();

// Sets the colors of the rules; the rows on screen are refreshed by the caller
export function setRuleColors(colors) {
    ruleColorById = colors;
}

// The header row of a log table for the current columns
export function renderHeader() {
    return <tr>
        <th width="20px">⚓</th>
        <th width="80px">Index</th>
        {columns.map(c => <th width={c.width ? `${c.width}px` : "*"}>{c.title}</th>)}
    </tr>;
}


// A cell of `column`; `level` (a LogLevel of the record) colors it if the
// column asks for it (byLevel: an HTTP status shown as it is)
function renderCell(column, value, level) {
    const text = cellText(column, value);
    if (column.kind === "Level") {
        if (!value) return <td class="aux"></td>; // LogLevel.None: the record has no level
        return <td class={`level-${text.toLowerCase()}`}>{text}</td>;
    }
    if (column.kind === "Payload" && value !== null) return <td selectable>{text}</td>;
    return <td class={cellClass(column, level)}>{text}</td>;
}

// Cmd+click toggles a row on macOS, where Ctrl+click opens the context menu
const toggleKey = env.PLATFORM === "OSX" ? "metaKey" : "ctrlKey";

// select with virtual data source
export class VirtualDltTBody extends VirtualSelect {
    // The selected rows by view index (see row-selection.js). Created on first
    // use: field initializers and this() don't run for the tbody bound by CSS
    // `prototype:`.
    get selection() {
        return this._selection ??= new RowSelection();
    }

    // The selection, to be restored by restoreSelection() while the list shows
    // the same content: it refers to positions in the view
    saveSelection() {
        return this.selection.copy();
    }

    // Restores a selection from saveSelection(); null clears the selection.
    // Takes effect on the next render of the rows.
    restoreSelection(selection) {
        this._selection = selection ? selection.copy() : new RowSelection();
    }

    // Nothing is selected or current any more: the view shows other rows now
    resetSelection() {
        this.selection.reset();
        this.updateRowStates();
    }

    renderList(items) // overridable
    {
        return items;
    }

    renderItem(item) {
        // No such row (any more): the backend returns null, e.g. the view just
        // changed. An empty row keeps the rows in place until the next render.
        if (!item) return <tr />;

        const viewIndex = item[rowLayout.viewIndex];
        const selection = this.selection;
        // The color of the rule is set on the row, table.css shows it on the Index cell
        const ruleColor = ruleColorById.get(item[rowLayout.rule]); // undefined: no rule, or no color
        // row-current/row-selected are attributes: a "state-" prefix in JSX
        // sets a runtime state (:current, :checked) instead, see updateRowStates()
        return <tr row-current={selection.current === viewIndex ? "true" : "false"}
            row-selected={selection.has(viewIndex) ? "true" : "false"} view-index={viewIndex}
            rule-color={ruleColor ? "true" : "false"} style={ruleColor ? `--rule-color: ${ruleColor}` : ""}>
            <td class="anchor" has-anchor={item[rowLayout.anchored] ? "true" : "false"} msg-index={item[rowLayout.messageIndex]}></td>
            <td class="aux">{item[rowLayout.messageIndex]}</td>
            {columns.map((column, i) => renderCell(column, item[rowLayout.firstColumn + i], item[rowLayout.level]))}
        </tr>
    }

    // Shows the selection on the rows on screen. render() doesn't update the
    // rows kept on screen (see refreshVisibleRows), and changing only the
    // attributes is cheaper than rendering the rows again.
    updateRowStates() {
        const selection = this.selection;
        for (const row of this.children) {
            const viewIndex = this.viewIndexOf(row);
            if (viewIndex === null) continue; // an empty row
            row.setAttribute("row-current", selection.current === viewIndex ? "true" : "false");
            row.setAttribute("row-selected", selection.has(viewIndex) ? "true" : "false");
        }
    }

    // The view index of the row with `element`, null if it isn't in a row
    viewIndexOf(element) {
        const row = element?.closest("tr");
        if (!row || row.parentElement !== this) return null;
        const viewIndex = Number(row.getAttribute("view-index"));
        return Number.isInteger(viewIndex) ? viewIndex : null;
    }

    // The text of the selected rows for the clipboard, at most `limit`
    // characters: { text, copied, total, truncated }, see selectedText()
    selectedRowsText(limit) {
        return selectedText(this.selection, (index) => itemText(this.itemAt(index), columns), limit);
    }

    // A press of the left button selects (Shift: a range, Cmd/Ctrl: one more
    // row) and starts a drag that selects the rows the mouse passes over, see
    // moveRowDrag(). Dragging inside a Payload cell selects its text instead:
    // the event is not consumed.
    ["on mousedown"](evt) {
        if (evt.buttons & 6) return; // right (2) or middle (4) button
        if (evt.target.closest("td.anchor")) return; // toggles the anchor only
        const viewIndex = this.viewIndexOf(evt.target);
        if (viewIndex === null) return;
        const toggle = evt[toggleKey];
        this.selection.click(viewIndex, { shift: evt.shiftKey, toggle });
        this.updateRowStates();
        if (!evt.target.closest("[selectable]")) beginRowDrag(this, toggle, evt.clientY);
    }

    // The view index of the row at the window coordinate `y`, null if none.
    // By coordinates: while the list captures the mouse, events target the list.
    viewIndexAt(y) {
        const list = this.getBoundingClientRect();
        if (y < list.top || y >= list.bottom) return null; // rows kept off screen are there too
        for (const row of this.children) {
            const box = row.getBoundingClientRect();
            if (y >= box.top && y < box.bottom) return this.viewIndexOf(row);
        }
        return null;
    }

    // The view indexes of the first and the last row on screen, null if none
    visibleRange() {
        const first = this.viewIndexOf(this.vlist?.firstVisibleItem);
        const last = this.viewIndexOf(this.vlist?.lastVisibleItem);
        return first === null || last === null ? null : [first, last];
    }

    // The number of rows the list has room for, by the height of a row on screen
    visibleRowCount() {
        const row = this.vlist?.firstVisibleItem;
        const rowHeight = row ? row.getBoundingClientRect().height : 0;
        if (!(rowHeight > 0)) return 0;
        return Math.floor(this.getBoundingClientRect().height / rowHeight);
    }

    // Moves the current row (and the selection with it) to `index`, scrolling
    // it into view
    moveCurrentTo(index, navigation) {
        const total = this.totalItems();
        if (total === 0) return true;
        index = Math.max(0, Math.min(total - 1, index));
        this.selection.moveTo(index);
        if (navigation) this.vlist.navigateTo(navigation);
        else this.vlist.advanceTo(index);
        this.updateRowStates();
        return true;
    }

    onkeydown(evt) {
        const current = this.selection.current;
        // Without a current row the arrows start from the rows on screen, not
        // from the top of the log
        const range = current === null ? this.visibleRange() : null;
        switch (evt.code) {
            case "ArrowDown": return this.moveCurrentTo(current === null ? (range?.[0] ?? 0) : current + 1);
            case "ArrowUp": return this.moveCurrentTo(current === null ? (range?.[1] ?? 0) : current - 1);
            case "Home": return this.moveCurrentTo(0, "start");
            case "End": return this.moveCurrentTo(this.totalItems() - 1, "end");
            case "Escape":
                if (this.selection.count === 0) return false;
                this.selection.clear();
                this.updateRowStates();
                return true;
            case "KeyC":
                if (!(evt.metaKey || evt.ctrlKey) || this.hasSelectedText()) return false; // copies the text
                this.post(new Event("copyrows", { bubbles: true }));
                return true;
            default: return false;
        }
    }

    // True if text is selected in a cell of a row on screen (a Payload)
    hasSelectedText() {
        for (const cell of this.$$("td[selectable]"))
            if (cell.selection && !cell.selection.isCollapsed) return true;
        return false;
    }

    // Re-renders the rows currently on screen with fresh data from the backend.
    // render() doesn't update existing rows when the number of items is
    // unchanged (Sciter ignores the returned rows), so after any change of the
    // data (a new search or filter result, an anchor) call this after
    // componentUpdate(). When the number of items changes, render() clears the
    // rows itself and there is nothing left to refresh here.
    refreshVisibleRows() {
        const total = this.totalItems();
        for (const row of this.children) {
            const viewIndex = this.viewIndexOf(row);
            if (viewIndex === null || viewIndex >= total) continue; // an empty row, or past the end
            const item = this.itemAt(viewIndex);
            if (item) row.patch(this.renderItem(item));
        }
    }
}

// Selecting rows by dragging: { list, y (clientY of the mouse), timer }, null
// while no drag. The document passes the mouse moves and the release
// (moveRowDrag, endRowDrag); outside the list a timer scrolls it.
let rowDrag = null;

// The list captures the mouse while dragging: the release comes to it even
// outside the window, otherwise the auto-scroll would go on until the mouse
// returned
function beginRowDrag(list, toggle, y) {
    endRowDrag();
    list.selection.beginDrag({ toggle });
    list.state.capture(true);
    rowDrag = { list, y, timer: setInterval(autoScrollRowDrag, 16) };
}

// A mouse move of the document: selects up to the row under the mouse
export function moveRowDrag(evt) {
    if (!rowDrag) return;
    // A move without the button inside the window: the release was missed.
    // Outside the window the moves of the captured mouse may come without the
    // button state, so only mouseup ends the drag there.
    if (!(evt.buttons & 1) && insideWindow(evt)) return endRowDrag();
    rowDrag.y = evt.clientY;
    const { list } = rowDrag;
    const viewIndex = list.viewIndexAt(evt.clientY);
    if (viewIndex === null || viewIndex === list.selection.current) return;
    list.selection.dragTo(viewIndex);
    list.updateRowStates();
}

// True if the mouse event is over the window's client area
function insideWindow(evt) {
    const box = document.documentElement.getBoundingClientRect();
    return evt.clientX >= box.left && evt.clientX < box.right
        && evt.clientY >= box.top && evt.clientY < box.bottom;
}

export function endRowDrag() {
    if (!rowDrag) return;
    clearInterval(rowDrag.timer);
    rowDrag.list.state.capture(false);
    rowDrag = null;
}

// While the mouse is above or below the list, scrolls it towards the mouse by
// pixels, faster the farther it is (autoScrollSpeed), and selects up to the
// row at that edge
function autoScrollRowDrag() {
    const now = Date.now();
    const elapsed = Math.min(100, now - (rowDrag.tickTime ?? now)); // ms; a stalled tick doesn't jump
    rowDrag.tickTime = now;
    const { list, y } = rowDrag;
    const box = list.getBoundingClientRect();
    const up = y < box.top;
    const distance = up ? box.top - y : y > box.bottom ? y - box.bottom : 0;
    if (distance === 0 || !list.vlist) {
        rowDrag.pixels = 0;
        return;
    }
    // Whole pixels only: the fraction is kept for the next tick
    rowDrag.pixels = (rowDrag.pixels ?? 0) + autoScrollSpeed(distance) * elapsed / 1000;
    const pixels = Math.floor(rowDrag.pixels);
    if (pixels === 0) return;
    rowDrag.pixels -= pixels;
    list.vlist.scrollBy(up ? -pixels : pixels);
    const range = list.visibleRange();
    if (!range) return;
    list.selection.dragTo(up ? range[0] : range[1]);
    list.updateRowStates();
}

export class VirtualMainViewTBody extends VirtualDltTBody {
    this(props) {
        super.this(props);
    }

    itemAt(at) {
        return Window.this.xcall("getMainViewItem", at);
    }

    totalItems() {
        const totalLogs = Window.this.xcall("getMainViewCount");
        return totalLogs;
    }
}

export class VirtualSearchViewTBody extends VirtualDltTBody {
    this(props) {
        super.this(props);
    }

    itemAt(at) {
        return Window.this.xcall("getSearchViewItem", at);
    }

    totalItems() {
        const totalLogs = Window.this.xcall("getSearchViewCount");
        return totalLogs;
    }
}