console.log("Loading virtual-dlt-view.js...");
import { VirtualList, VirtualSelect } from "virtual-select.js";
import * as backend from "backend.js";
import * as platform from "platform.js";
import { cellClass, cellTexts, columnClass, itemText, rowLayout, matchPieces, groupDigits } from "cell-format.js";
import { matchColorClass } from "match-colors.js";
import { RowSelection, selectedText, autoScrollSpeed } from "row-selection.js";
import { textRange, cellPart, rangeText, repaintRows, splitSelected, wordAt, wholeText, sameSelection, isDrag, cellHit }
    from "text-selection.js";
import { anchorEdit } from "pane-state.js";
import { windowSize } from "list-navigation.js";

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
// its part the user selected (`part`, [from, to) of cellPart, null if none).
// `grouped`: the thousands of a number apart (groupDigits), by empty elements
// that add no character to the text.
function cellContent(text, matches, matchColors, part, grouped = false) {
    // the cell after the columns may be no fragments if the columns of the
    // script and the backend differ for a moment: matchPieces checks it
    const found = Array.isArray(matches) && matches.length > 0;
    if (!found && !part && !grouped) return text;
    const pieces = found ? matchPieces(text, matches) : [{ text, chip: null }];
    const parts = splitSelected(pieces, part);
    return (grouped ? groupDigits(parts) : parts).map(piece => {
        if (piece.gap) return <i class={piece.selected ? "digit-gap text-selected" : "digit-gap"} />;
        const color = piece.chip === null ? undefined : matchColors[piece.chip];
        // no color known for the chip: plain text rather than another chip's color
        const classes = [color === undefined ? "" : `match ${matchColorClass(color)}`, piece.selected ? "text-selected" : ""]
            .filter(Boolean).join(" ");
        return classes ? <span class={classes}>{piece.text}</span> : piece.text;
    });
}

// A cell of `column` showing `value` as `text` (cellText); `level` (a LogLevel
// of the record) colors it if the column asks for it (byLevel: an HTTP status
// shown as it is). `matches` are what the search chips found in the payload
// (rows the search found only), `matchColors` the colors of the chips, `part`
// the part of its text the user selected (see cellContent).
function renderCell(column, value, text, level, matches, matchColors, part) {
    if (column.kind === "Level") {
        if (!value) return <td class="aux"></td>; // LogLevel.None: the record has no level
        const content = cellContent(text, null, null, part);
        // Fatal: the color is behind the text only, not the whole cell (table.css)
        return <td class={`level level-${text.toLowerCase()}`}>{text === "Fatal" ? <span class="level-mark">{content}</span> : content}</td>;
    }
    if (column.kind === "Payload" && value !== null)
        return <td>{cellContent(text, matches, matchColors, part)}</td>;
    return <td class={cellClass(column, level)}>{cellContent(text, null, null, part)}</td>;
}

// A row is the anchor cell, then a cell per text of cellTexts (cell-format.js)
// in its order: the cells whose text can be selected, numbered from 0 as
// text-selection.js counts them. renderItem renders them, textCellsOf finds
// them in a row on screen.
const anchorCells = 1;

function textCellsOf(row) {
    return [...row.children].slice(anchorCells);
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

    // Whether the user selected text in the cells (the context menu offers to
    // copy it)
    hasTextSelected() {
        return !!this._textSelection;
    }

    // What Copy and Cmd+C copy: the text selected if any, else the selected
    // rows; at most `limit` characters of whole rows: { text, copied, total,
    // truncated } (rows), see rangeText and selectedRowsText
    copyText(limit) {
        if (!this._textSelection) return this.selectedRowsText(limit);
        return rangeText(textRange(this._textSelection), row => cellTexts(this.itemAt(row), this.columns), limit,
            this.totalItems());
    }

    // The text selected: _textSelection, { anchor, focus } (text-selection.js),
    // unset or null if none. Sets it and paints the rows on screen whose look
    // changes. The methods with "_" are for the drag of this module only.
    // Dropped (null), it is unpainted in place: the elements stay, a press
    // dropping it may still read its event (.ai/knowledge/sciter.md).
    _setTextSelection(selection) {
        const before = this._textSelection ?? null;
        if (sameSelection(before, selection)) return; // a move within a character
        if (!selection) return this._unpaintTextSelection();
        const rows = repaintRows(before, selection);
        this._textSelection = selection;
        if (rows) this.refreshVisibleRows(rows);
    }

    // Drops the text selected keeping the elements of the rows: only the
    // marks of its spans and of the gaps of the Index go
    _unpaintTextSelection() {
        this._textSelection = null;
        for (const piece of this.$$(".text-selected")) piece.classList.remove("text-selected");
    }

    // Nothing is selected or current any more: the view shows other rows now.
    // A drag in progress ends: it began on the rows of before. The text
    // selected is unpainted in place: the rows on screen may be kept as they
    // are (followAnchor), and reading them anew would read the new view.
    resetSelection() {
        abandonDrag(this);
        this.selection.reset();
        if (this._textSelection) this._unpaintTextSelection();
        this.updateRowStates();
    }

    renderList(items) // overridable
    {
        return items;
    }

    // Fits the window first: the render may navigate (a jump, another view).
    // Not filled here: the render renders the rows itself, or clears them.
    render(props) {
        this.watchSize();
        this.fitWindow({ fill: false });
        return super.render(props);
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
        // The cells after the anchor show the texts of cellTexts (see anchorCells)
        // with the part of each the user selected
        const texts = cellTexts(item, columns);
        const range = textRange(this._textSelection);
        const part = cell => range && cellPart(range, viewIndex, cell, texts[cell].length);
        // row-current/row-selected are attributes: a "state-" prefix in JSX
        // sets a runtime state (:current, :checked) instead, see updateRowStates()
        return <tr row-current={selection.current === viewIndex ? "true" : "false"}
            row-selected={selection.has(viewIndex) ? "true" : "false"} view-index={viewIndex}
            row-found={item[rowLayout.found] ? "true" : "false"}
            has-anchor={item[rowLayout.anchored] ? "true" : "false"}
            rule-color={ruleColor ? "true" : "false"} style={ruleColor ? `--rule-color: ${ruleColor}` : ""}>
            <td class="anchor" msg-index={item[rowLayout.messageIndex]}></td>
            <td class="aux">{cellContent(texts[0], null, null, part(0), true)}</td>
            {columns.map((column, i) => renderCell(column, item[rowLayout.firstColumn + i], texts[i + 1],
                item[rowLayout.level], item[rowLayout.matches(columns.length)], matchColors, part(i + 1)))}
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
    // What it needs of `evt` is read before anything changes, the text
    // position too (.ai/knowledge/sciter.md).
    ["on mousedown"](evt) {
        if (evt.buttons & 6) return; // right (2) or middle (4) button
        if (contextClickKey && evt[contextClickKey]) return; // the context menu, see contextmenu
        if (evt.target.closest("td.anchor")) return; // toggles the anchor only
        const viewIndex = this.viewIndexOf(evt.target);
        if (viewIndex === null) return;
        const { clientX: x, clientY: y, shiftKey: shift } = evt;
        const toggle = evt[toggleKey];
        const rows = shift || toggle;
        const at = rows ? null : this._textPositionAt(x, y);
        this._setTextSelection(null);
        if (rows) {
            this._selectByPress(viewIndex, { shift, toggle });
            beginDrag(this, { kind: "rows", toggle, y });
        } else {
            beginDrag(this, { kind: "text", row: viewIndex, at, x, y });
        }
    }

    // A double click selects the word under the mouse (wordAt)
    ["on dblclick"](evt) {
        return this._selectInCell(evt, wordAt);
    }

    // A triple click selects the whole text of the cell under the mouse
    // (wholeText). Its third press came as a mousedown first, as any press.
    ["on tripleclick"](evt) {
        return this._selectInCell(evt, wholeText);
    }

    // Selects a part of the text of the cell under the mouse of `evt`:
    // `partOf(text, offset)` gives it as [from, to), null for none.
    // @return true if it selected: the event is handled
    _selectInCell(evt, partOf) {
        if (evt.target.closest("td.anchor")) return; // toggles the anchor only
        const at = this._textPositionAt(evt.clientX, evt.clientY);
        if (!at) return;
        const text = cellTexts(this.itemAt(at.row), this.columns)?.[at.col] ?? "";
        const part = partOf(text, at.offset);
        if (!part) return;
        this._setTextSelection({ anchor: { ...at, offset: part[0] }, focus: { ...at, offset: part[1] - 1 } });
        return true;
    }

    // Selects by a press on the row `viewIndex` (RowSelection.click) and tells
    // the panel, even if the row was selected already: a click shows it in the
    // other table again, which may have been scrolled away from it
    _selectByPress(viewIndex, modifiers = {}) {
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
    _textPositionAt(x, y) {
        const list = this.getBoundingClientRect();
        let row = this.rowAt(Math.min(Math.max(y, list.top), list.bottom - 1));
        if (!row) {
            const range = this.visibleRange();
            if (!range) return null;
            row = y < list.top ? this.vlist.firstVisibleItem : this.vlist.lastVisibleItem;
        }
        const viewIndex = this.viewIndexOf(row);
        if (viewIndex === null) return null;
        const cells = textCellsOf(row);
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
    // would make them blink. The exception: while the rendered rows fit the table
    // a row to insert is left to the render (see fitsIn).
    // @return false if no row is rendered, the row to show can't be read, or the
    // rows still fit the table: the caller rebuilds the list
    followAnchor(message, added) {
        const vlist = this.vlist;
        const rows = [...this.children];
        const rendered = rows.map(messageOf);
        if (!vlist || rendered.some(m => !Number.isFinite(m))) return false; // an empty row
        // Room: every row of the view is rendered and the window can take one more, so the
        // row is rendered, not counted (sciter.md, "Virtual Lists").
        const room = vlist.itemsBefore === 0 && vlist.itemsAfter === 0 && rows.length < vlist.slidingWindowSize;
        const edit = anchorEdit(rendered, message, added, room);
        if (edit === null) return false;
        // A row inserted by hand that makes the rows overflow the table leaves the list
        // not scrolling by the wheel (only by the scrollbar, until the window is resized):
        // it doesn't learn of the new scroll range. While the rows fit the table any
        // insertion may be that one, so it is left to the render, which does learn (the
        // list is not scrolled yet: nothing is lost). Once they overflow, rows go in by hand.
        if (edit.insertAt !== null && this.fitsIn(rows)) return false;
        // The row of the anchor, before anything changes: without it the list is rebuilt
        let row = null;
        if (edit.insertAt !== null) {
            const item = this.itemAt(vlist.itemsBefore + edit.insertAt);
            if (!item) return false;
            row = Element.create(this.renderItem(item));
        }

        this.settleLater();
        if (edit.removeAt !== null) rows[edit.removeAt].remove();
        if (row && edit.insertAt < rows.length) this.insertBefore(row, rows[edit.insertAt]);
        else if (row) this.append(row); // after the last rendered row
        // The counts are assigned after the rows are in the DOM, as grow() does: the list
        // reads its scroll range then. Assigned first, a row inserted over the height of the
        // table left the range stale: the wheel scrolled nothing until the window was resized.
        vlist.itemsBefore += edit.before;
        vlist.itemsAfter += edit.after;
        const first = vlist.itemsBefore;
        for (const [i, row] of [...this.children].entries())
            row.setAttribute("view-index", first + i);
        if (!this._settledNow) { // the first edit of the frame, now: before it is painted, no blink
            this._settledNow = true;
            this.settle(false);
        }
        return true;
    }

    // After the rows were edited by hand (followAnchor) a list scrolled somewhere may
    // show a gap under its last row (rows removed, the ones before the first still
    // not rendered), or have its rows pushed off their place (a row inserted above the
    // first on screen). The first row on screen and where it is are noted before the
    // first edit of a frame (note); settle() puts the list right: at once after the
    // first edit, so the frame painted has no blink, and in the next frame, after all
    // the edits of this one (a file opened with its anchors brings hundreds: one layout
    // for them, not one each). Nothing is noted for a list at its top with all rows
    // rendered: nothing to keep, nothing before the first row to render.
    settleLater() {
        if (this._settle) return;
        const vlist = this.vlist;
        const scrolled = vlist.itemsBefore > 0 || this.scrollTop > 0;
        this._settle = this.note(scrolled);
        this._settledNow = false;
        requestAnimationFrame(() => this.settle());
    }

    // The first row on screen (its message) and its top in the list; `scrolled`: the
    // list was scrolled somewhere, else nothing is kept
    note(scrolled) {
        const row = scrolled ? this.vlist.firstVisibleItem : null;
        const message = row ? messageOf(row) : NaN;
        return {
            message: Number.isFinite(message) ? message : null,
            offset: row ? row.getBoundingClientRect().top - this.getBoundingClientRect().top : 0,
            scrolled,
        };
    }

    // Puts the list right after an edit by hand: the gap under the last row is
    // filled from the rows before (VirtualList.fill goes to the end of the list
    // then); a scroll left past the end (it stays in pixels when the rows got fewer,
    // sciter.md) is put back to the end; else the first row noted is put back where
    // it was. `final`: the frame's own pass, the last one. Nothing is done for a
    // hidden list (it keeps its scroll, nothing can be measured); a drag in this
    // list goes on as it is and the pass is tried again in the next frame.
    settle(final = true) {
        const noted = this._settle;
        const vlist = this.vlist;
        if (!noted || !noted.scrolled || !vlist || !this.parentElement) {
            if (final) this._settle = null;
            return;
        }
        if (drag?.list === this) {
            if (final) requestAnimationFrame(() => this.settle());
            return;
        }
        if (final) this._settle = null;
        const box = this.getBoundingClientRect();
        if (!(box.height > 0)) return; // hidden
        const last = this.lastElementChild;
        if (vlist.itemsBefore > 0 && last && last.getBoundingClientRect().bottom < box.bottom) {
            this.fill();
            return;
        }
        const end = this.scrollEnd();
        if (this.scrollTop > end + 1) {
            this.scrollTo({ top: end, behavior: "instant" });
            return;
        }
        if (noted.message === null) return;
        const row = [...this.children].find(r => messageOf(r) === noted.message);
        if (!row) { // the row noted was removed: the next edits keep the first row now on screen
            if (!final) this._settle = this.note(true);
            return;
        }
        const delta = row.getBoundingClientRect().top - box.top - noted.offset;
        if (Math.abs(delta) < 1) return;
        this.scrollTo({ top: Math.max(0, Math.min(this.scrollTop + delta, end)), behavior: "instant" });
    }

    // True if the rendered `rows` don't overflow the list yet: a row added to them
    // may be higher than any of them, so any one may be the one that overflows
    fitsIn(rows) {
        if (rows.length === 0) return true;
        const used = rows[rows.length - 1].getBoundingClientRect().bottom - rows[0].getBoundingClientRect().top;
        return used <= this.getBoundingClientRect().height;
    }

    // Sizes the sliding window of the list by its height (windowSize): when it
    // renders, is resized, or its rows change height (see watchSize). A window
    // of fewer rows than the list shows would crash Sciter. A window that grew
    // is filled (`fill`, VirtualList.fill): Sciter doesn't fill a list that got
    // higher. Only a log table sizes its window: the line is measured by its
    // header. `changed`: only if the height of the list or of its header row
    // changed since the last fit (a sizechange of a width only reads no row).
    fitWindow({ fill = true, changed = false } = {}) {
        const vlist = this.vlist;
        if (!vlist) return;
        const height = this.getBoundingClientRect().height;
        const header = this.parentElement?.$("thead>tr")?.getBoundingClientRect().height ?? 0;
        const key = `${height}/${header}`;
        if (changed && key === this._fitKey) return;
        this._fitKey = key;
        const size = windowSize({ height, lineHeight: this.lineHeight() });
        if (size === null || size === vlist.slidingWindowSize) return;
        const grew = size > vlist.slidingWindowSize;
        vlist.slidingWindowSize = size;
        if (grew && fill) this.fill();
    }

    // Fits the window when the list is resized (a window, the splitter, a page
    // shown) and when its rows change height (the font size: the header row's
    // height follows it). Subscribed once, at the first render: neither this()
    // nor an "on sizechange" method of the class runs for the tbody bound by
    // CSS `prototype:`. On the thead: a change of columns replaces its row.
    watchSize() {
        if (this._sizeWatched) return;
        this._sizeWatched = true;
        const fit = () => this.fitWindow({ changed: true });
        this.on("sizechange", fit);
        this.parentElement?.$("thead")?.on("sizechange", fit);
    }

    // The height of a row one line high, px: the lowest of the header row and
    // the rows rendered (the header has the font of the rows); 0 if none
    lineHeight() {
        const heights = [];
        const header = this.parentElement?.$("thead>tr");
        if (header) heights.push(header.getBoundingClientRect().height);
        for (const row of this.children)
            if (this.viewIndexOf(row) !== null) heights.push(row.getBoundingClientRect().height); // not an empty row
        const positive = heights.filter(h => h > 0);
        return positive.length ? Math.min(...positive) : 0;
    }

    // The number of rows the list has room for, by the height of a row on screen
    visibleRowCount() {
        const row = this.vlist?.firstVisibleItem;
        const rowHeight = row ? row.getBoundingClientRect().height : 0;
        if (!(rowHeight > 0)) return 0;
        return Math.floor(this.getBoundingClientRect().height / rowHeight);
    }

    // A key moves the current row (and the selection with it) to `index`,
    // scrolling it into view; with Shift (`extend`) the rows from the anchor to
    // it are selected. The panel is told unless nothing changed (a key at the
    // edge of the log)
    moveCurrentTo(index, navigation, extend = false) {
        const total = this.totalItems();
        if (total === 0) return true;
        index = Math.max(0, Math.min(total - 1, index));
        const changed = extend ? this.selection.extendTo(index) : this.selection.moveTo(index);
        if (changed) this._setTextSelection(null); // Cmd+C copies the rows chosen now
        this.cancelSmoothJump();
        if (navigation) this.navigateTo(navigation);
        else this.vlist.advanceTo(index);
        this.updateRowStates();
        if (changed) this.rowChosen(true);
        return true;
    }

    // What followEndStep (pane-state.js) decides by, before the list grows: { total: the
    // rows it has, lastWhole: the last row wholly on screen, current, selected: the rows
    // selected }; null if it can't tell, its rows not laid out (a hidden tab or page)
    endState() {
        const vlist = this.vlist;
        if (!vlist || !(this.getBoundingClientRect().height > 0)) return null;
        return {
            total: vlist.itemsBefore + this.children.length + vlist.itemsAfter,
            lastWhole: this.wholeRowsRange()?.[1] ?? null,
            current: this.selection.current,
            selected: this.selection.count,
        };
    }

    // Shows the last row, as the table follows the end of a file being written; with
    // `moveCurrent` it is made the current row and the only one selected too. The script
    // moves it, not the user: the other table doesn't follow it (rowChosen isn't told)
    followEnd(moveCurrent) {
        const last = this.totalItems() - 1;
        if (last < 0) return;
        this.cancelSmoothJump();
        if (moveCurrent) this.selection.moveTo(last);
        this.navigateTo("end");
        this.updateRowStates();
    }

    // Makes the row `position` current and the only one selected with `top` the
    // first row shown (by the render componentUpdate() posts, the end of the
    // way animated: smoothAnimateTo; null: the scroll stays), a step of
    // jumpStep (pane-state.js). The keyboard stays where it is.
    showRow({ position, top }) {
        this.selection.moveTo(position);
        if (top !== null) {
            this.navigateTarget = top;
            this.navigateSmoothly = true;
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
        const extend = evt.shiftKey; // Shift extends the selection from the anchor
        switch (evt.code) {
            case "ArrowDown": return this.moveCurrentTo(current === null ? (range?.[0] ?? 0) : current + 1, undefined, extend);
            case "ArrowUp": return this.moveCurrentTo(current === null ? (range?.[1] ?? 0) : current - 1, undefined, extend);
            case "Home": return this.moveCurrentTo(0, "start", extend);
            case "End": return this.moveCurrentTo(this.totalItems() - 1, "end", extend);
            case "Escape": // the text selected first, then the rows
                if (this._textSelection) this._setTextSelection(null);
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

// The message index of the log row `row`, NaN for an empty row
function messageOf(row) {
    return Number(row.$("td.anchor")?.getAttribute("msg-index"));
}

// A drag in a log table, started by a press (beginDrag), null while none:
// { list, kind, y (clientY of the mouse), timer, ... }. kind "rows" selects the
// rows the mouse passes over (a press with Shift or Cmd/Ctrl); kind "text" is a
// plain press: once the mouse moves away from the press (isDrag) it selects
// text from the press to the mouse (list._setTextSelection); released with no
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
    finishDrag(false); // one left from a release that was missed
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
    if (!(evt.buttons & 1) && insideWindow(evt)) return finishDrag(false);
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
        const focus = list._textPositionAt(x, y);
        if (!focus) return;
        // back on the character pressed: nothing selected, the release is a click
        const pressed = sameSelection({ anchor: drag.at, focus }, { anchor: drag.at, focus: drag.at });
        list._setTextSelection(pressed ? null : { anchor: drag.at, focus });
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

// The release of the mouse anywhere (the document passes it): ends the drag;
// a plain press that selected no text is a click on its row
export function endTableDrag() {
    finishDrag(true);
}

// The rows of `list` are other messages now: its drag, if any, ends and
// selects nothing (see resetSelection)
function abandonDrag(list) {
    if (drag?.list === list) finishDrag(false);
}

// Ends the drag; `released`: by the release of the mouse, else given up (the
// release was missed, the view changed) and selecting nothing
function finishDrag(released) {
    if (!drag) return;
    const { list, kind, row, timer } = drag;
    if (timer) clearInterval(timer);
    list.state.capture(false);
    drag = null;
    if (released && kind === "text" && !list.hasTextSelected() && row < list.totalItems()) list._selectByPress(row);
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