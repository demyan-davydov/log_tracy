console.log("Loading virtual-dlt-view.js...");
import { VirtualList, VirtualSelect } from "virtual-select.js";
import * as backend from "backend.js";
import * as platform from "platform.js";
import { cellClass, cellText, cellTexts, columnClass, itemText, rowLayout, matchPieces } from "cell-format.js";
import { matchColorClass } from "match-colors.js";
import { RowSelection, selectedText, autoScrollSpeed } from "row-selection.js";
import { textRange, cellPart, rangeText, repaintRows, splitSelected, wordAt, sameSelection, isDrag, cellHit }
    from "text-selection.js";
import { anchorEdit } from "pane-state.js";

// The header row of a log table for `columns`: table.css gives the columns
// their look by the classes (see columnClass)
function renderHeader(columns) {
    return <tr>
        <th class="col-anchor">⚓</th>
        <th class="col-index">Index</th>
        {columns.map(c => <th class={columnClass(c)}>{c.title}</th>)}
    </tr>;
}


// The content of a cell showing `text`: what the search chips found in it
// (`matches`, [[start, end, chip]], a Payload of a row the search found) in
// the colors of the chips (`matchColors`, by their place in the query), and
// its part the user selected (`part`, [from, to) of cellPart, null if none)
function cellContent(text, matches, matchColors, part) {
    // the cell after the columns may be no fragments if the columns of the
    // script and the backend differ for a moment: matchPieces checks it
    const found = Array.isArray(matches) && matches.length > 0;
    if (!found && !part) return text;
    const pieces = found ? matchPieces(text, matches) : [{ text, chip: null }];
    return splitSelected(pieces, part).map(piece => {
        const color = piece.chip === null ? undefined : matchColors[piece.chip];
        // no color known for the chip: plain text rather than another chip's color
        const classes = [color === undefined ? "" : `match ${matchColorClass(color)}`, piece.selected ? "text-selected" : ""]
            .filter(Boolean).join(" ");
        return classes ? <span class={classes}>{piece.text}</span> : piece.text;
    });
}

// A cell of `column`; `level` (a LogLevel of the record) colors it if the
// column asks for it (byLevel: an HTTP status shown as it is). `matches` are
// what the search chips found in the payload (rows the search found only),
// `matchColors` the colors of the chips. partOf(length) gives the part of its
// text the user selected (see cellContent).
function renderCell(column, value, level, matches, matchColors, partOf) {
    const text = cellText(column, value);
    if (column.kind === "Level") {
        if (!value) return <td class="aux"></td>; // LogLevel.None: the record has no level
        return <td class={`level level-${text.toLowerCase()}`}>{cellContent(text, null, null, partOf(text.length))}</td>;
    }
    if (column.kind === "Payload" && value !== null)
        return <td>{cellContent(text, matches, matchColors, partOf(text.length))}</td>;
    return <td class={cellClass(column, level)}>{cellContent(text, null, null, partOf(text.length))}</td>;
}

// The offset of the position (`node`, `offset`) of a range in the text of
// `cell`, null if the node is not in it. In a text node `offset` counts
// characters, in an element (the cell, a match span) its children before it.
function textOffsetIn(cell, node, offset) {
    let total = 0;
    const textLength = n => n.nodeType === 3 ? n.length : [...n.childNodes].reduce((sum, c) => sum + textLength(c), 0);
    const walk = (n) => {
        if (n === node) {
            if (n.nodeType === 3) total += offset;
            else for (const child of [...n.childNodes].slice(0, offset)) total += textLength(child);
            return true;
        }
        if (n.nodeType === 3) { total += n.length; return false; }
        for (const child of n.childNodes) if (walk(child)) return true;
        return false;
    };
    return walk(cell) ? total : null;
}

// No part of a cell is selected (renderItem, while no text is)
const noPart = () => null;

// Cmd+click toggles a row on macOS, where Ctrl+click opens the context menu:
// it comes as a left press with Ctrl, which must not select like a click
const toggleKey = platform.isMac() ? "metaKey" : "ctrlKey";
const contextClickKey = platform.isMac() ? "ctrlKey" : null;

// select with virtual data source
// The rows show the document `docId` (set by the script) with what the script
// gives each table: its columns, the colors of the rules of the document and
// the match colors of the chips of the search.
export class VirtualDltTBody extends VirtualSelect {
    // The columns the rows show, from backend.tableColumnsJson:
    // [{ id, title, kind, width, timeKind?, unitsPerSecond?, labels? }].
    // Getters with defaults: field initializers don't run for the tbody bound
    // by CSS `prototype:`.
    get columns() {
        return this._columns ?? [];
    }

    // Sets the columns and rebuilds the header of the table; the rows on
    // screen are refreshed by the caller
    setColumns(columns) {
        this._columns = columns;
        this.parentElement?.$("thead")?.content(renderHeader(columns));
    }

    // The colors of the filter rules of the document by rule id (see
    // rule-colors.js): a row shows the color of the rule it refers to
    get ruleColors() {
        return this._ruleColors ?? new Map();
    }

    // Sets them; the rows on screen are refreshed by the caller
    set ruleColors(colors) {
        this._ruleColors = colors;
    }

    // The match colors of the chips of the search the rows were found by, by
    // the place of the chip in that query: a fragment of a chip is shown in its
    // color (see matchPieces). Rows the search didn't find have no fragments.
    get matchColors() {
        return this._matchColors ?? [];
    }

    set matchColors(colors) {
        this._matchColors = colors;
    }

    // The selected rows by view index (see row-selection.js). Created on first
    // use: field initializers and this() don't run for the tbody bound by CSS
    // `prototype:`.
    get selection() {
        return this._selection ??= new RowSelection();
    }

    // Tells the panel that the user chose a row (a "rowchosen" event, bubbling;
    // a click on the row already selected too): a click at once, a drag or a
    // key `delayed`, followed once the row rests. Not when the script moves the
    // selection (showRow, resetSelection).
    rowChosen(delayed) {
        this.post(new Event("rowchosen", { bubbles: true, data: { delayed } }));
    }

    // The text the user selected across the cells and rows ({ anchor, focus },
    // see text-selection.js), null if none
    get textSelection() {
        return this._textSelection ?? null;
    }

    // Sets it and paints the rows on screen whose look changes
    setTextSelection(selection) {
        if (sameSelection(this.textSelection, selection)) return; // a move within a character
        const rows = repaintRows(this.textSelection, selection);
        this._textSelection = selection;
        if (rows) this.refreshVisibleRows(rows);
    }

    // Nothing is selected or current any more: the view shows other rows now.
    // A drag in progress ends: it began on the rows of before. The text
    // selected is unpainted in place: the rows on screen may be kept as they
    // are (followAnchor), and reading them anew would read the new view.
    resetSelection() {
        if (drag?.list === this) endTableDrag(false);
        this.selection.reset();
        if (this.textSelection) {
            this._textSelection = null;
            for (const span of this.$$("span.text-selected")) span.classList.remove("text-selected");
        }
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
        const ruleColor = this.ruleColors.get(item[rowLayout.rule]); // undefined: no rule, or no color
        const columns = this.columns;
        const matchColors = this.matchColors;
        // The selected part of the text of a cell: Index is cell 0, the columns follow
        const range = textRange(this.textSelection);
        const partOf = range ? col => length => cellPart(range, viewIndex, col, length) : () => noPart;
        const index = String(item[rowLayout.messageIndex]);
        // row-current/row-selected are attributes: a "state-" prefix in JSX
        // sets a runtime state (:current, :checked) instead, see updateRowStates()
        return <tr row-current={selection.current === viewIndex ? "true" : "false"}
            row-selected={selection.has(viewIndex) ? "true" : "false"} view-index={viewIndex}
            row-found={item[rowLayout.found] ? "true" : "false"}
            rule-color={ruleColor ? "true" : "false"} style={ruleColor ? `--rule-color: ${ruleColor}` : ""}>
            <td class="anchor" has-anchor={item[rowLayout.anchored] ? "true" : "false"} msg-index={item[rowLayout.messageIndex]}></td>
            <td class="aux">{cellContent(index, null, null, partOf(0)(index.length))}</td>
            {columns.map((column, i) => renderCell(column, item[rowLayout.firstColumn + i], item[rowLayout.level],
                item[rowLayout.matches(columns.length)], matchColors, partOf(i + 1)))}
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
        return selectedText(this.selection, (index) => itemText(this.itemAt(index), this.columns), limit,
            this.totalItems());
    }

    // A press of the left button. With Shift (a range) or Cmd/Ctrl (one more
    // row) it selects rows at once and starts a drag that selects the rows the
    // mouse passes over. A plain press waits: dragged away it selects text
    // across the cells and rows (text-selection.js), released where it was it
    // is a click, selecting its row (see the drag below, beginDrag). Any press
    // drops the text selected before.
    ["on mousedown"](evt) {
        if (evt.buttons & 6) return; // right (2) or middle (4) button
        if (contextClickKey && evt[contextClickKey]) return; // the context menu, see contextmenu
        if (evt.target.closest("td.anchor")) return; // toggles the anchor only
        const viewIndex = this.viewIndexOf(evt.target);
        if (viewIndex === null) return;
        this.setTextSelection(null);
        const toggle = evt[toggleKey];
        if (evt.shiftKey || toggle) {
            this.selectByPress(viewIndex, { shift: evt.shiftKey, toggle });
            beginDrag(this, { kind: "rows", toggle, y: evt.clientY });
        } else {
            const at = this.textPositionAt(evt.clientX, evt.clientY);
            beginDrag(this, { kind: "text", row: viewIndex, at, x: evt.clientX, y: evt.clientY });
        }
    }

    // A double click selects the word under the mouse (wordAt)
    ["on dblclick"](evt) {
        if (evt.target.closest("td.anchor")) return; // toggles the anchor only
        const at = this.textPositionAt(evt.clientX, evt.clientY);
        if (!at) return;
        const text = cellTexts(this.itemAt(at.row), this.columns)?.[at.col] ?? "";
        const word = wordAt(text, at.offset);
        if (!word) return;
        this.setTextSelection({ anchor: { ...at, offset: word[0] }, focus: { ...at, offset: word[1] - 1 } });
        return true;
    }

    // Selects by a press on the row `viewIndex` (RowSelection.click) and tells
    // the panel, even if the row was selected already: a click shows it in the
    // other table again, which may have been scrolled away from it
    selectByPress(viewIndex, modifiers = {}) {
        this.selection.click(viewIndex, modifiers);
        this.updateRowStates();
        this.rowChosen(false);
    }

    // The view index of the row at the window coordinate `y`, null if none.
    // By coordinates: while the list captures the mouse, events target the list.
    viewIndexAt(y) {
        return this.viewIndexOf(this.rowAt(y));
    }

    // The row element at the window coordinate `y` on screen, null if none
    rowAt(y) {
        const list = this.getBoundingClientRect();
        if (y < list.top || y >= list.bottom) return null; // rows kept off screen are there too
        for (const row of this.children) {
            const box = row.getBoundingClientRect();
            if (y >= box.top && y < box.bottom) return row;
        }
        return null;
    }

    // The text position (see text-selection.js) under the window point x, y:
    // the row, the cell and the character there. A point above or below the
    // rows on screen goes to the first or the last of them, one left or right
    // of the cells to the first or the last cell; null if no row is on screen.
    // Sciter's rangeFromPoint gives the character under the point, the last
    // one even right of the text; right of the cell is past its end.
    textPositionAt(x, y) {
        const list = this.getBoundingClientRect();
        let row = this.rowAt(Math.min(Math.max(y, list.top), list.bottom - 1));
        if (!row) {
            const range = this.visibleRange();
            if (!range) return null;
            row = y < list.top ? this.vlist.firstVisibleItem : this.vlist.lastVisibleItem;
        }
        const viewIndex = this.viewIndexOf(row);
        if (viewIndex === null) return null;
        const cells = [...row.children].slice(1); // after the anchor: Index, the columns
        const boxes = cells.map(cell => {
            const [left, , width] = cell.state.box("xywh", "inner", "window");
            return { right: cell.getBoundingClientRect().right, innerLeft: left, innerRight: left + width };
        });
        const hit = cellHit(boxes, x);
        if (!hit) return null;
        if (hit.offset !== null) return { row: viewIndex, ...hit };
        const cell = cells[hit.col];
        const [left, top, , height] = cell.state.box("xywh", "inner", "window");
        const range = cell.rangeFromPoint(x - left, Math.min(Math.max(y - top, 0), height - 1));
        const offset = range ? textOffsetIn(cell, range.startContainer, range.startOffset) : null;
        return { row: viewIndex, col: hit.col, offset: offset ?? 0 };
    }

    // The view index of the first row on screen, null if none. The list keeps
    // it while hidden too
    firstVisibleIndex() {
        return this.viewIndexOf(this.vlist?.firstVisibleItem);
    }

    // The view indexes of the first and the last row on screen, null if none
    visibleRange() {
        const first = this.viewIndexOf(this.vlist?.firstVisibleItem);
        const last = this.viewIndexOf(this.vlist?.lastVisibleItem);
        return first === null || last === null ? null : [first, last];
    }

    // Follows an anchor that added (`added`) or removed the row of message
    // `message` from the view, keeping the rows on screen where they are: the
    // row is inserted or removed among the rendered ones, or counted before or
    // after them (see anchorEdit), and the rendered rows are numbered anew.
    // Their content stays: they show the same messages. Rebuilding the list
    // instead (componentUpdate) would scroll it, rendering the rows again
    // would make them blink.
    // @return false if no row is rendered, or the row to show can't be read: the
    // caller rebuilds the list
    followAnchor(message, added) {
        const vlist = this.vlist;
        const rows = [...this.children];
        const rendered = rows.map(row => Number(row.$("td.anchor")?.getAttribute("msg-index")));
        if (!vlist || rendered.some(m => !Number.isFinite(m))) return false; // an empty row
        const room = vlist.itemsBefore === 0 && vlist.itemsAfter === 0 && rows.length < this.visibleRowCount();
        const edit = anchorEdit(rendered, message, added, room);
        if (edit === null) return false;
        // The row of the anchor, before anything changes: without it the list is rebuilt
        let row = null;
        if (edit.insertAt !== null) {
            const item = this.itemAt(vlist.itemsBefore + edit.insertAt);
            if (!item) return false;
            row = Element.create(this.renderItem(item));
        }

        vlist.itemsBefore += edit.before;
        vlist.itemsAfter += edit.after;
        if (edit.removeAt !== null) rows[edit.removeAt].remove();
        if (row && edit.insertAt < rows.length) this.insertBefore(row, rows[edit.insertAt]);
        else if (row) this.append(row); // after the last rendered row
        const first = vlist.itemsBefore;
        for (const [i, row] of [...this.children].entries())
            row.setAttribute("view-index", first + i);
        return true;
    }

    // The number of rows the list has room for, by the height of a row on screen
    visibleRowCount() {
        const row = this.vlist?.firstVisibleItem;
        const rowHeight = row ? row.getBoundingClientRect().height : 0;
        if (!(rowHeight > 0)) return 0;
        return Math.floor(this.getBoundingClientRect().height / rowHeight);
    }

    // A key moves the current row (and the selection with it) to `index`,
    // scrolling it into view; the panel is told unless nothing changed (a key
    // at the edge of the log)
    moveCurrentTo(index, navigation) {
        const total = this.totalItems();
        if (total === 0) return true;
        index = Math.max(0, Math.min(total - 1, index));
        const changed = this.selection.moveTo(index);
        if (changed) this.setTextSelection(null); // Cmd+C copies the rows chosen now
        if (navigation) this.vlist.navigateTo(navigation);
        else this.vlist.advanceTo(index);
        this.updateRowStates();
        if (changed) this.rowChosen(true);
        return true;
    }

    // Makes the row `position` current and the only one selected with `top` the
    // first row shown (by the render componentUpdate() posts; null: the scroll
    // stays), a step of jumpStep (pane-state.js). The keyboard stays where it is.
    showRow({ position, top }) {
        this.selection.moveTo(position);
        if (top !== null) {
            this.navigateTarget = top;
            this.componentUpdate();
        }
        this.updateRowStates();
    }

    // [first, last] rows wholly on screen, null if none: a row cut by an edge
    // of the list is not counted (visibleRange counts it)
    wholeRowsRange() {
        const range = this.visibleRange();
        if (!range) return null;
        const list = this.getBoundingClientRect();
        const whole = row => {
            const box = row.getBoundingClientRect();
            return box.top >= list.top && box.bottom <= list.bottom;
        };
        const first = range[0] + (whole(this.vlist.firstVisibleItem) ? 0 : 1);
        const last = range[1] - (whole(this.vlist.lastVisibleItem) ? 0 : 1);
        return first <= last ? [first, last] : null;
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
            case "Escape": // the text selected first, then the rows
                if (this.textSelection) this.setTextSelection(null);
                else if (this.selection.count > 0) {
                    this.selection.clear();
                    this.updateRowStates();
                } else return false;
                return true;
            case "KeyC":
                if (!(evt.metaKey || evt.ctrlKey)) return false;
                this.post(new Event("copyrows", { bubbles: true }));
                return true;
            default: return false;
        }
    }

    // What Cmd+C copies: the text selected if any, else the selected rows; at
    // most `limit` characters of whole rows: { text, copied, total, truncated }
    // (rows), see rangeText and selectedRowsText
    clipboardText(limit) {
        if (!this.textSelection) return this.selectedRowsText(limit);
        return rangeText(textRange(this.textSelection), row => cellTexts(this.itemAt(row), this.columns), limit,
            this.totalItems());
    }

    // Re-renders the rows currently on screen with fresh data from the backend.
    // render() doesn't update existing rows when the number of items is
    // unchanged (Sciter ignores the returned rows), so after any change of the
    // data (a new search or filter result, an anchor) call this after
    // componentUpdate(). When the number of items changes, render() clears the
    // rows itself and there is nothing left to refresh here.
    // only: [first, last] view indexes of the rows to refresh, all if omitted.
    refreshVisibleRows(only = null) {
        const total = this.totalItems();
        for (const row of this.children) {
            const viewIndex = this.viewIndexOf(row);
            if (viewIndex === null || viewIndex >= total) continue; // an empty row, or past the end
            if (only && (viewIndex < only[0] || viewIndex > only[1])) continue;
            const item = this.itemAt(viewIndex);
            if (item) row.patch(this.renderItem(item));
        }
    }
}

// A drag in a log table, started by a press (beginDrag), null while none:
// { list, kind, y (clientY of the mouse), timer, ... }. kind "rows" selects the
// rows the mouse passes over (a press with Shift or Cmd/Ctrl); kind "text" is a
// plain press: once the mouse moves away from the press (isDrag) it selects
// text from the press to the mouse (list.setTextSelection); released with no
// text selected (not moved, or back on the character pressed) it is a click
// selecting the row pressed (`row`). The document passes the mouse moves and
// the release (moveTableDrag, endTableDrag); while the mouse is above or below
// the list a timer scrolls it (timer is null otherwise) and the drag goes on
// to the row at that edge.
let drag = null;

// The list captures the mouse while dragging: the release comes to it even
// outside the window, otherwise the auto-scroll would go on until the mouse
// returned
function beginDrag(list, { kind, toggle = false, y, ...press }) {
    endTableDrag(false); // one left from a release that was missed
    if (kind === "rows") list.selection.beginDrag({ toggle });
    list.state.capture(true);
    drag = { list, kind, y, timer: null, ...press, selecting: false };
}

// Runs the auto-scroll timer while the mouse is above or below the list
function updateAutoScroll() {
    const box = drag.list.getBoundingClientRect();
    const outside = drag.y < box.top || drag.y >= box.bottom;
    if (outside && !drag.timer) {
        drag.tickTime = Date.now();
        drag.pixels = 0;
        drag.timer = setInterval(autoScrollDrag, 16);
    } else if (!outside && drag.timer) {
        clearInterval(drag.timer);
        drag.timer = null;
    }
}

// A mouse move of the document: drags on to the mouse
export function moveTableDrag(evt) {
    if (!drag) return;
    // A move without the button inside the window: the release was missed.
    // Outside the window the moves of the captured mouse may come without the
    // button state, so only mouseup ends the drag there.
    if (!(evt.buttons & 1) && insideWindow(evt)) return endTableDrag(false);
    if (drag.kind === "text" && !drag.selecting) {
        if (!isDrag(drag, { x: evt.clientX, y: evt.clientY })) return; // drag.x, y: the press yet
        drag.selecting = drag.at !== null; // no text position: nothing to select
    }
    drag.x = evt.clientX;
    drag.y = evt.clientY;
    updateAutoScroll();
    dragTo(drag.list, evt.clientX, evt.clientY);
}

// Drags to the window point x, y: the rows up to the row there, or the text
// up to the character there
function dragTo(list, x, y) {
    if (drag.kind === "text") {
        if (!drag.selecting) return;
        const focus = list.textPositionAt(x, y);
        if (!focus) return;
        // back on the character pressed: nothing selected, the release is a click
        const pressed = sameSelection({ anchor: drag.at, focus }, { anchor: drag.at, focus: drag.at });
        list.setTextSelection(pressed ? null : { anchor: drag.at, focus });
        return;
    }
    const viewIndex = list.viewIndexAt(y);
    if (viewIndex === null || viewIndex === list.selection.current) return;
    list.selection.dragTo(viewIndex);
    list.updateRowStates();
    list.rowChosen(true);
}

// True if the mouse event is over the window's client area
function insideWindow(evt) {
    const box = document.documentElement.getBoundingClientRect();
    return evt.clientX >= box.left && evt.clientX < box.right
        && evt.clientY >= box.top && evt.clientY < box.bottom;
}

// Ends the drag. On the release of the mouse (`released`) a plain press that
// selected no text is a click on its row; a drag given up (the release was
// missed, the view changed) selects nothing.
export function endTableDrag(released = true) {
    if (!drag) return;
    const { list, kind, row, timer } = drag;
    if (timer) clearInterval(timer);
    list.state.capture(false);
    drag = null;
    if (released && kind === "text" && !list.textSelection && row < list.totalItems()) list.selectByPress(row);
}

// While the mouse is above or below the list, scrolls it towards the mouse by
// pixels, faster the farther it is (autoScrollSpeed), and drags on to the row
// at that edge
function autoScrollDrag() {
    const now = Date.now();
    const elapsed = Math.min(100, now - drag.tickTime); // ms; a stalled tick doesn't jump
    drag.tickTime = now;
    const { list, x, y } = drag;
    const box = list.getBoundingClientRect();
    const up = y < box.top;
    const distance = up ? box.top - y : y > box.bottom ? y - box.bottom : 0;
    if (distance === 0 || !list.vlist) return; // the next move stops the timer
    // Whole pixels only: the fraction is kept for the next tick
    drag.pixels += autoScrollSpeed(distance) * elapsed / 1000;
    const pixels = Math.floor(drag.pixels);
    if (pixels === 0) return;
    drag.pixels -= pixels;
    list.vlist.scrollBy(up ? -pixels : pixels);
    // the row at that edge: the point just inside the list
    dragTo(list, x, up ? box.top : box.bottom - 1);
}

// The rows of the main view of the document `docId` (set by the script; null:
// no document, no rows)
export class VirtualMainViewTBody extends VirtualDltTBody {
    this(props) {
        super.this(props);
    }

    itemAt(at) {
        return this.docId == null ? null : backend.mainViewItem(this.docId, at);
    }

    totalItems() {
        return this.docId == null ? 0 : backend.mainViewCount(this.docId);
    }
}

// The rows of the search view of the document `docId`, as above
export class VirtualSearchViewTBody extends VirtualDltTBody {
    this(props) {
        super.this(props);
    }

    itemAt(at) {
        return this.docId == null ? null : backend.searchViewItem(this.docId, at);
    }

    totalItems() {
        return this.docId == null ? 0 : backend.searchViewCount(this.docId);
    }
}