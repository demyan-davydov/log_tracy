//! PROTOTYPE: a log table that draws its rows itself in one element (paintContent, Graphics)
// instead of keeping row elements in the DOM (docs/experiments/2026-11-18-painted-rows.md).
// It covers a log table of the window and shows the rows of that table's view (itemAt,
// totalItems, columns). Started from the debug channel: `paintProto()` / `paintProto(false)`.
// Text is selected by a drag, a double click (a word) and a triple click (a cell), copied by Cmd/Ctrl+C.
// Not done: anchors by click, the colors of the theme (the light ones are
// constants here), search matches, the rows of the search table, single-line rows, growth of a
// log being read. The layout (wrap, the rows on a screen, the thumb) is paint-layout.js, tested.
import { cellTexts, rowLayout } from "cell-format.js";
import { wrapLines, rowHeight, screenRows, scrollBy, thumbOf, rowAtThumb, charAt, cellBoxes, cellAtX, lineAtY } from "paint-layout.js";
import { textRange, cellPart, rangeText, wordAt, wholeText, sameSelection, isDrag, pastEnd } from "text-selection.js";

// The families of the table's fonts (table.css); the sizes are read from its cells (readFonts)
// (a name of several words in quotes: unquoted, a Text takes another, heavier face)
const auxFamily = "'Courier New', Courier, monospace";
const payloadFamily = "system-ui, 'Segoe UI', sans-serif";
const pad = 1; // above and below a row
const cellPad = 3; // left and right of a cell
const headerHeight = 19;
const barWidth = 10;

// The sizes of the fonts the table's cells have now (the font size setting, the 80 % of the
// auxiliary cells): read from a row of the table, "10pt" as Sciter tells them
function readFonts(source) {
    const row = source.firstElementChild, size = el => String(getComputedStyle(el).fontSize);
    if (!row || row.children.length < 3) return { aux: "8pt", payload: "10pt", header: "10pt" };
    const head = source.parentElement.$("th");
    return { aux: size(row.children[2]), payload: size(row.lastElementChild), header: head ? size(head) : "8pt" };
}

// The light theme (theme-light.css), until the palette is read from the CSS
const colors = {
    row: "#ffffff", stripe: "#f4f4f4", selected: "#b0d2f8", found: "#eee6d4", foundStripe: "#e7dfcd",
    text: "#333333", selectedText: "#000000", header: "#ffe4c4", border: "#d0d0d0",
    error: "#f00", warn: "#ff8c00", info: "#008000", debug: "#888", fatalText: "#fff", fatalBg: "#c2123a",
    textSelected: "#7fdc94", thumb: "rgba(60,60,60,0.45)", thumbHover: "rgba(60,60,60,0.7)",
};

// LogLevel values of the backend (cell-format.js levelName): the color of a level's text
const levelColor = { Fatal: colors.fatalText, Error: colors.error, Warn: colors.warn, Info: colors.info, Debug: colors.debug, Verbose: colors.debug };

// The style of a Graphics.Text for a font written as "[bold ]size family". The shorthand `font:`
// of a Text ignores the size (6.0.5.5: "10pt system-ui" and "13px system-ui" both come out at the
// default size), so the properties are set one by one
function textStyle(font) {
    const bold = font.startsWith("bold ");
    if (bold) font = font.slice(5);
    const at = font.indexOf(" ");
    return `white-space: nowrap; font-size: ${font.slice(0, at)}; font-family: ${font.slice(at + 1)}${bold ? "; font-weight: bold" : ""}`;
}

export class PaintedTable {
    // `source`: the tbody of a log table (itemAt, totalItems, columns); `table`: its table
    constructor(source, table, portion = 1) {
        this.portion = portion; // the part of the table's height covered (< 1: the native rows show below, for a comparison)
        this.source = source;
        this.table = table;
        this.state = { first: 0, offset: 0 };
        this.selected = -1;
        this.textSel = null; // the text selected: { anchor, focus } of text-selection.js
        this.press = null; // a press on the rows: { x, y, at } (a click, or the start of a drag)
        this.textDrag = false;
        this.mouse = { x: 0, y: 0 };
        this.meters = new Map(); // font -> a Text to measure prefixes by
        this.rows = []; // the rows of the last paint: { index, top, height }
        this.texts = new Map(); // font and text -> Graphics.Text, drawn by drawText
        this.useText = true;
        this.cache = new Map(); // row -> { texts, item, lines, height }
        this.cacheWidth = 0; // the payload width the cached lines are for
        this.widths = []; // the width of each column but the payload, grows only
        this.widthsVersion = 0; // counts the growths of widths: a layout made before one is made again
        this.advances = new Map();
        this.setFonts(readFonts(source));
        this.pending = 0; // wheel pixels not yet scrolled
        this.frame = false;
        this.drag = null;
        this.hover = false;
        this.element = Element.create(<div class="painted-proto" tabindex="0"
            style="position: absolute; z-index: 50; background: #fff; cursor: text;" />);
        document.body.append(this.element);
        this.place();
        this.element.paintContent = gfx => this.paint(gfx);
        const el = this.element;
        el.on("wheel", evt => this.onWheel(evt));
        el.on("mousedown", evt => this.onDown(evt));
        el.on("mousemove", evt => this.onMove(evt));
        el.on("mouseenter", () => { this.hover = true; el.requestPaint(); });
        el.on("mouseleave", () => { this.hover = false; el.requestPaint(); });
        el.on("keydown", evt => this.onKey(evt));
        el.on("dblclick", evt => this.selectWithin(evt, wordAt));
        el.on("tripleclick", evt => this.selectWithin(evt, (text) => wholeText(text)));
        this.mouseup = () => this.onUp();
        document.addEventListener("mouseup", this.mouseup);
        this.moveListener = evt => this.onDrag(evt);
        document.addEventListener("mousemove", this.moveListener);
        this.sizeWatch = () => this.place();
        table.on("sizechange", this.sizeWatch);
        el.state.focus = true;
    }

    // The fonts of the cells, and what follows from them: the advances, the height of a line, the
    // baseline (the same for every cell of a row, as in the table)
    setFonts(sizes) {
        this.auxFont = `${sizes.aux} ${auxFamily}`;
        this.payloadFont = `${sizes.payload} ${payloadFamily}`;
        this.headerFont = `${sizes.header} ${auxFamily}`;
        this.meter = new Graphics.Text("0");
        this.meter.style = textStyle(this.payloadFont);
        this.auxMeter = new Graphics.Text("0");
        this.auxMeter.style = textStyle(this.auxFont);
        this.auxAdvance = this.auxMeter.width()[1];
        const headerMeter = new Graphics.Text("0");
        headerMeter.style = textStyle(this.headerFont);
        this.headerAdvance = headerMeter.width()[1];
        this.advances = new Map();
        const [, height, baseline] = this.meter.lineMetrics(0);
        this.lineHeight = Math.ceil(this.meter.height()[1]);
        this.baseline = Math.round(baseline);
        this.cache?.clear();
    }

    // Puts the element over the table
    place() {
        const [x, y, w, h] = this.table.state.box("xywh", "border", "window");
        const style = this.element.style;
        style.left = `${x}px`;
        style.top = `${y}px`;
        style.width = `${w}px`;
        const covered = Math.round(h * this.portion);
        style.height = `${covered}px`;
        this.width = w;
        this.height = covered;
        this.cache.clear();
        this.element.requestPaint();
    }

    dispose() {
        document.removeEventListener("mouseup", this.mouseup);
        document.removeEventListener("mousemove", this.moveListener);
        this.table.off?.("sizechange", this.sizeWatch);
        this.element.remove();
    }

    // The rows of the source changed: read again
    refresh() {
        this.cache.clear();
        this.element.requestPaint();
    }

    get columns() {
        return this.source.columns;
    }

    get total() {
        return this.source.totalItems();
    }

    // ---- the rows ----

    // The width of a glyph of the Payload's font
    advance = glyph => {
        let width = this.advances.get(glyph);
        if (width === undefined) {
            this.meter.chars = glyph;
            width = this.meter.width()[1];
            this.advances.set(glyph, width);
        }
        return width;
    };

    // The room for the Payload: what the other columns leave
    get payloadWidth() {
        const others = this.widths.reduce((sum, w) => sum + w, 0);
        return Math.max(200, this.width - others - barWidth);
    }

    // The widths of the columns but the Payload grow to the longest text seen (a minimum, as in the
    // table: ux.md rule 26); the first one is the anchor
    growWidths(texts, advance = this.auxAdvance) {
        // the anchor, then the texts of the cells but the Payload (the Index first)
        for (let col = 0; col <= texts.length; col++) {
            const width = col === 0 ? 24 : Math.ceil(texts[col - 1].length * advance) + 2 * cellPad + 1;
            if (!(width <= (this.widths[col] ?? 0))) {
                this.widths[col] = width;
                this.widthsVersion++;
            }
        }
    }

    // The headers' titles are a minimum of the widths too
    growHeaderWidths() {
        const titles = ["Index", ...this.columns.map(c => c.title)];
        this.growWidths(titles.slice(0, -1), this.headerAdvance);
    }

    // The cached form of the row `index`
    entry(index) {
        const width = this.payloadWidth;
        if (width !== this.cacheWidth) {
            this.cache.clear();
            this.cacheWidth = width;
        }
        let entry = this.cache.get(index);
        if (!entry) {
            if (this.cache.size > 4000) this.cache.clear();
            const item = this.source.itemAt(index);
            const texts = item ? cellTexts(item, this.columns) : null;
            const payload = texts ? texts[texts.length - 1] : "";
            const lines = wrapLines(payload, width - 2 * cellPad, this.advance);
            if (texts) this.growWidths(texts.slice(0, -1));
            entry = { item, texts, payload, lines, height: rowHeight(lines.length, { line: this.lineHeight, pad }) };
            this.cache.set(index, entry);
        }
        return entry;
    }

    heightOf = index => this.entry(index).height;

    get bodyHeight() {
        return this.height - headerHeight;
    }

    get meanHeight() {
        const rows = this.rows.length;
        return rows ? this.rows.reduce((sum, r) => sum + r.height, 0) / rows : this.lineHeight + 2 * pad;
    }

    // The rows on screen for the state, which they settle
    layout() {
        this.growHeaderWidths();
        let view;
        // a row seen may widen a column and narrow the Payload: the rows are laid out again
        for (let round = 0; round < 4; round++) {
            const version = this.widthsVersion;
            view = screenRows({ ...this.state, viewHeight: this.bodyHeight, total: this.total, heightOf: this.heightOf });
            if (version === this.widthsVersion) break;
        }
        this.state = { first: view.first, offset: view.offset };
        this.rows = view.rows;
        return view;
    }

    // ---- painting ----

    paint(gfx) {
        const view = this.layout();
        const W = this.width, H = this.height, texts = this.columns;
        this.ink = gfx.fillStyle = colors.row;
        gfx.fillRect(0, 0, W, H);
        gfx.pushLayer(0, headerHeight, W, H - headerHeight);
        for (const row of view.rows) this.paintRow(gfx, row);
        gfx.popLayer();
        this.paintHeader(gfx, W);
        this.paintBar(gfx, view);
    }

    // Draws a text at (x, y) on its baseline in the font and the color last set on `gfx`: by
    // fillText of the canvas, or (useText) as a Graphics.Text, which the text engine of the DOM
    // draws in the same way (the canvas' text came out heavier)
    drawText(gfx, text, x, y) {
        if (!this.useText) return gfx.fillText(text, x, y);
        const item = this.textItem(this.font, text);
        // the baseline of this text's own font: a row's cells of different fonts share a baseline
        item.base ??= Math.round(item.lineMetrics(0)[2]);
        gfx.draw(item, { x, y: y - item.base, fill: this.ink });
    }

    // The Graphics.Text of `text` in `font` (kept: laying one out is the cost)
    textItem(font, text) {
        const key = font + "|" + text;
        let item = this.texts.get(key);
        if (!item) {
            if (this.texts.size > 6000) this.texts.clear();
            item = new Graphics.Text(text);
            item.style = textStyle(font);
            this.texts.set(key, item);
        }
        return item;
    }

    paintHeader(gfx, W) {
        this.ink = gfx.fillStyle = colors.header;
        gfx.fillRect(0, 0, W, headerHeight);
        this.ink = gfx.fillStyle = colors.text;
        this.font = gfx.font = this.headerFont;
        const titles = ["⚓", "Index", ...this.columns.map(c => c.title)];
        let x = 0;
        for (let col = 0; col < titles.length - 1; col++) {
            this.drawText(gfx, titles[col], x + cellPad, 14);
            x += this.widths[col] ?? 40;
            this.ink = gfx.fillStyle = colors.border;
            gfx.fillRect(x - 1, 0, 1, headerHeight);
            this.ink = gfx.fillStyle = colors.text;
        }
        this.font = gfx.font = this.headerFont;
        this.drawText(gfx, titles[titles.length - 1], x + cellPad, 14);
    }

    // The boxes of the text cells of the rows (Index, the columns, the Payload) and the place of
    // their texts: { left, right, x (of the text), font } per cell of `entry`
    cellsOf(entry) {
        const boxes = cellBoxes(this.widths, this.width);
        const columns = this.columns, last = boxes.length - 1;
        return boxes.map((box, col) => {
            const text = entry.texts[col], width = box.right - box.left;
            if (col === last) return { ...box, x: Math.round(box.left + cellPad), font: this.payloadFont, kind: "Payload" };
            const kind = col === 0 ? "Index" : columns[col - 1].kind;
            if (kind === "Level") { // the font of the Payload, bold for the loud levels, centered
                const loud = text === "Fatal" || text === "Error" || text === "Warn";
                const font = (loud ? "bold " : "") + this.payloadFont;
                const wide = Math.round(this.textItem(font, text).width()[1]);
                return { ...box, x: Math.round(box.left + (width - wide) / 2), font, kind, wide };
            }
            return { ...box, x: Math.round(box.right - cellPad - text.length * this.auxAdvance), font: this.auxFont, kind };
        });
    }

    // The text of the cell `col` of `entry`
    textOf(entry, col) {
        return col === entry.texts.length - 1 ? entry.payload : entry.texts[col];
    }

    // The width of the units [from, to) of the text `col` of `entry` (cellsOf `cell`), measured
    // as its own text (the engine's kerning, not a sum of advances)
    sliceWidth(entry, col, cell, from, to) {
        if (to <= from) return 0;
        if (cell.font === this.auxFont) return (to - from) * this.auxAdvance; // monospace
        let meter = this.meters.get(cell.font);
        if (!meter) {
            meter = new Graphics.Text("0");
            meter.style = textStyle(cell.font);
            this.meters.set(cell.font, meter);
        }
        meter.chars = this.textOf(entry, col).slice(from, to);
        return meter.width()[1];
    }

    // The rectangles [x1, x2, y] of the part [from, to) of the text of a cell that is selected,
    // one for each line of the Payload it covers
    selectedSpans(entry, col, cell, from, to, top) {
        if (col < entry.texts.length - 1) {
            return [[cell.x + this.sliceWidth(entry, col, cell, 0, from), cell.x + this.sliceWidth(entry, col, cell, 0, to), top + pad]];
        }
        const spans = [];
        entry.lines.forEach(([a, b], j) => {
            const start = Math.max(a, from), end = Math.min(b, to);
            if (end <= start) return;
            spans.push([cell.x + this.sliceWidth(entry, col, cell, a, start), cell.x + this.sliceWidth(entry, col, cell, a, end),
                top + pad + j * this.lineHeight]);
        });
        return spans;
    }

    // The text position (text-selection.js) under the window point: { row, col, offset }, null
    // with no rows. Above or below the rows it is the first or the last row.
    positionAt(clientX, clientY) {
        if (!this.rows.length) return null;
        const [left, top] = this.element.state.box("xywh", "border", "window");
        const x = clientX - left, y = clientY - top - headerHeight;
        const row = y < this.rows[0].top ? this.rows[0] : (this.rows.find(r => y >= r.top && y < r.top + r.height) ?? this.rows[this.rows.length - 1]);
        const entry = this.entry(row.index);
        if (!entry.texts) return null;
        const cells = this.cellsOf(entry);
        const col = cellAtX(cells, x), cell = cells[col], text = this.textOf(entry, col);
        if (!text.length) return { row: row.index, col, offset: -1 };
        let from = 0, to = text.length;
        if (cell.kind === "Payload") {
            const line = lineAtY(y - row.top, entry.lines.length, { line: this.lineHeight, pad });
            [from, to] = entry.lines[line];
        }
        const k = charAt(x - cell.x, to - from, n => this.sliceWidth(entry, col, cell, from, from + n));
        const last = cell.kind === "Payload" && to !== text.length; // not the end of the text: a line's end is the character before it
        const offset = k >= to - from ? (last ? to - 1 : pastEnd) : from + k;
        return { row: row.index, col, offset };
    }

    paintRow(gfx, row) {
        const entry = this.entry(row.index);
        const top = Math.round(headerHeight + row.top);
        const found = entry.item && entry.item[rowLayout.found];
        const selected = row.index === this.selected;
        this.ink = gfx.fillStyle = selected ? colors.selected : found ? (row.index & 1 ? colors.foundStripe : colors.found)
            : (row.index & 1 ? colors.stripe : colors.row);
        gfx.fillRect(0, top, this.width, row.height);
        if (!entry.texts) return;
        const base = top + pad + this.baseline; // the baseline of a line
        const cells = this.cellsOf(entry);
        const range = textRange(this.textSel);
        // the text selected, under the texts
        if (range) {
            this.ink = gfx.fillStyle = colors.textSelected;
            cells.forEach((cell, col) => {
                const part = cellPart(range, row.index, col, entry.texts[col].length);
                if (!part) return;
                for (const [x1, x2, y] of this.selectedSpans(entry, col, cell, part[0], part[1], top))
                    gfx.fillRect(Math.round(x1), y, Math.max(1, Math.round(x2 - x1)), this.lineHeight);
            });
        }
        // the anchor
        this.font = gfx.font = this.auxFont;
        this.ink = gfx.fillStyle = colors.text;
        if (entry.item[rowLayout.anchored]) this.drawText(gfx, "⚓", 6, base);
        cells.forEach((cell, col) => {
            const text = entry.texts[col];
            this.font = gfx.font = cell.font;
            if (cell.kind === "Payload") {
                this.ink = gfx.fillStyle = selected ? colors.selectedText : colors.text;
                entry.lines.forEach(([from, to], j) => {
                    this.drawText(gfx, entry.payload.slice(from, to).trimEnd(), cell.x, base + j * this.lineHeight);
                });
                return;
            }
            if (cell.kind === "Level") {
                if (text === "Fatal") {
                    this.ink = gfx.fillStyle = colors.fatalBg;
                    gfx.fillRect(cell.x - 4, top + pad + 1, cell.wide + 8, this.lineHeight - 2);
                }
                this.ink = gfx.fillStyle = selected ? colors.selectedText : (levelColor[text] ?? colors.text);
            } else this.ink = gfx.fillStyle = selected ? colors.selectedText : colors.text;
            this.drawText(gfx, text, cell.x, base);
            this.ink = gfx.fillStyle = colors.border;
            gfx.fillRect(cell.right - 1, top, 1, row.height);
        });
    }

    paintBar(gfx, view) {
        const bar = this.bar(view);
        if (!bar) return;
        this.ink = gfx.fillStyle = this.hover || this.drag ? colors.thumbHover : colors.thumb;
        gfx.fillRect(this.width - barWidth + 2, headerHeight + bar.top, barWidth - 4, bar.size);
    }

    bar(view = { rows: this.rows }) {
        const first = this.rows[0];
        return thumbOf({ first: this.state.first, offset: this.state.offset, firstHeight: first ? first.height : 19,
            total: this.total, track: this.bodyHeight, visible: Math.max(1, view.rows.length - 1), min: 24 });
    }

    // ---- input ----

    scroll(pixels) {
        this.state = scrollBy(this.state, pixels, { viewHeight: this.bodyHeight, total: this.total, heightOf: this.heightOf, mean: this.meanHeight });
        this.element.requestPaint();
    }

    // Wheel pixels pile up and are scrolled once a frame
    onWheel(evt) {
        const limit = this.bodyHeight;
        this.pending = Math.max(-limit, Math.min(limit, this.pending + evt.deltaY * 1.3));
        if (!this.frame) {
            this.frame = true;
            requestAnimationFrame(() => {
                this.frame = false;
                const move = this.pending;
                this.pending = 0;
                if (move) this.scroll(move);
            });
        }
        evt.preventDefault();
        return true;
    }

    onDown(evt) {
        this.element.state.focus = true;
        const [left, top] = this.element.state.box("xywh", "border", "window");
        const localX = evt.clientX - left, localY = evt.clientY - top;
        if (localX >= this.width - barWidth) {
            const bar = this.bar();
            if (!bar) return true;
            const at = localY - headerHeight;
            this.drag = { grab: at < bar.top || at > bar.top + bar.size ? bar.size / 2 : at - bar.top, top };
            this.dragTo(evt.clientY);
            return true;
        }
        if (localY < headerHeight) return true;
        // a press waits: dragged away it selects text, let go where it was it is a click on the row
        this.setTextSelection(null);
        this.press = { x: evt.clientX, y: evt.clientY, at: this.positionAt(evt.clientX, evt.clientY) };
        this.mouse = { x: evt.clientX, y: evt.clientY };
        return true;
    }

    // The mouse moves anywhere in the window: the thumb dragged, or the text selected
    onDrag(evt) {
        if (this.drag) return this.dragTo(evt.clientY);
        if (!this.press) return;
        this.mouse = { x: evt.clientX, y: evt.clientY };
        if (!this.textDrag && isDrag(this.press, this.mouse)) {
            this.textDrag = true;
            this.dragFrame();
        }
        if (this.textDrag) this.updateTextDrag();
    }

    // The focus of the text selection goes to the mouse
    updateTextDrag() {
        const at = this.positionAt(this.mouse.x, this.mouse.y);
        if (at && this.press.at) this.setTextSelection({ anchor: this.press.at, focus: at });
    }

    // While the text is dragged and the mouse is above or below the rows, they scroll
    dragFrame() {
        if (!this.textDrag) return;
        const [, top] = this.element.state.box("xywh", "border", "window");
        const y = this.mouse.y - top - headerHeight;
        const out = y < 0 ? y : y > this.bodyHeight ? y - this.bodyHeight : 0;
        if (out) {
            this.scroll(Math.sign(out) * Math.min(40, 2 + Math.abs(out) * 0.4));
            this.updateTextDrag();
        }
        requestAnimationFrame(() => this.dragFrame());
    }

    onUp() {
        this.drag = null;
        const press = this.press;
        this.press = null;
        if (!this.textDrag && press && press.at) this.select(press.at.row); // a click
        this.textDrag = false;
    }

    setTextSelection(selection) {
        if (sameSelection(this.textSel, selection)) return;
        this.textSel = selection;
        this.element.requestPaint();
    }

    // A double or triple click selects a part of the text of the cell under the mouse
    selectWithin(evt, partOf) {
        const at = this.positionAt(evt.clientX, evt.clientY);
        if (!at) return;
        const entry = this.entry(at.row);
        const part = partOf(this.textOf(entry, at.col), at.offset === pastEnd ? Infinity : at.offset);
        if (!part) return;
        this.setTextSelection({ anchor: { ...at, offset: part[0] }, focus: { ...at, offset: part[1] - 1 } });
        return true;
    }

    // The text for the clipboard: the text selected, else the row selected
    copyText() {
        if (this.textSel) {
            return rangeText(textRange(this.textSel), row => { const item = this.source.itemAt(row); return item ? cellTexts(item, this.columns) : null; }, 1e6, this.total).text;
        }
        if (this.selected < 0) return "";
        const item = this.source.itemAt(this.selected);
        return item ? cellTexts(item, this.columns).join("\t") : "";
    }

    // The cursor is an arrow over the thumb's strip, a text cursor over the rows
    onMove(evt) {
        const [left] = this.element.state.box("xywh", "border", "window");
        const cursor = evt.clientX - left >= this.width - barWidth ? "default" : "text";
        if (cursor !== this.cursor) this.element.style.cursor = this.cursor = cursor;
    }

    // The thumb dragged to the window y
    dragTo(clientY) {
        const bar = this.bar();
        if (!bar || !this.drag) return;
        const top = clientY - this.drag.top - headerHeight - this.drag.grab;
        const row = rowAtThumb({ top: Math.max(0, Math.min(this.bodyHeight - bar.size, top)), track: this.bodyHeight, size: bar.size,
            total: this.total, visible: Math.max(1, this.rows.length - 1) });
        this.state = { first: Math.floor(row), offset: 0 };
        this.element.requestPaint();
    }

    select(index) {
        this.selected = Math.max(0, Math.min(this.total - 1, index));
        this.reveal(this.selected);
        this.element.requestPaint();
    }

    // Scrolls the row `index` into view, the least way
    reveal(index) {
        const view = this.layout();
        const row = view.rows.find(r => r.index === index);
        if (row && row.top >= 0 && row.top + row.height <= this.bodyHeight) return;
        if (row && row.top < 0) return this.scroll(row.top);
        if (row) return this.scroll(row.top + row.height - this.bodyHeight);
        if (index < this.state.first) this.state = { first: index, offset: 0 };
        else {
            this.state = { first: index, offset: 0 };
            this.state = scrollBy(this.state, this.heightOf(index) - this.bodyHeight, { viewHeight: this.bodyHeight, total: this.total, heightOf: this.heightOf });
        }
    }

    onKey(evt) {
        const key = evt.code;
        if ((evt.metaKey || evt.ctrlKey) && key === "KeyC") {
            const text = this.copyText();
            if (text) Clipboard.writeText(text);
            evt.preventDefault();
            return true;
        }
        if (key === "Escape") { // the text first, then the row
            if (this.textSel) this.setTextSelection(null);
            else { this.selected = -1; this.element.requestPaint(); }
            return true;
        }
        if (key.startsWith("Arrow") || key.startsWith("Page") || key === "Home" || key === "End") this.setTextSelection(null);
        const page = Math.max(1, this.rows.length - 1);
        const at = this.selected < 0 ? this.state.first : this.selected;
        switch (key) {
            case "ArrowDown": this.select(at + 1); break;
            case "ArrowUp": this.select(at - 1); break;
            case "PageDown": this.select(at + page); break;
            case "PageUp": this.select(at - page); break;
            case "Home": this.select(0); break;
            case "End": this.select(this.total - 1); break;
            default: return false;
        }
        evt.preventDefault();
        return true;
    }
}

let current = null;

// The prototype over the log table shown: paintProto() starts it, paintProto(false) stops it
globalThis.paintProto = (on = true, portion = 1) => {
    current?.dispose();
    current = null;
    if (!on) return false;
    const table = [...document.$$(".log-table.main-view")].find(t => t.getBoundingClientRect().height > 0);
    if (!table) return false;
    current = new PaintedTable(table.$("tbody"), table, portion);
    globalThis.paintedTable = current;
    return true;
};
