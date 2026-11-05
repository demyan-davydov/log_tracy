// The chip search editor: a query of chips joined by OR on a Sciter element.
// Every chip is its own single-line edit (behavior: edit), so the caret, the
// selection and the word moves inside a chip are the text field's own; the
// caret between chips is drawn here. What the keys do is decided by the pure
// functions of search-editing.js, this module only binds them to the DOM.
// Story: docs/stories/advanced-search.md.

import * as env from "@env";
import {
    moveCaret, moveTo, typeInGap, typeBarInChip, deleteInGap, searchChips,
    selection, extendCaret, selectChipsFrom, selectTo, selectAll, selectedChips, deleteSelection, insertChips,
} from "search-editing.js";
import { formatQuery, parseQuery, makeChip } from "search-query.js";

const isMac = () => env.PLATFORM === "OSX";

export class SearchEditor {
    // @param root - the editor element (focusable: tabindex="0")
    // @param checkRegex(pattern, ignoreCase) -> error message, "" for a valid regex
    // @param onEdited() - the chips changed
    // @param onCommit() - Enter: run the search
    constructor(root, { checkRegex, onEdited, onCommit }) {
        this.root = root;
        this.checkRegexBy = checkRegex;
        this.onEdited = onEdited;
        this.onCommit = onCommit;
        this.state = { chips: [], pos: { gap: 0 } };
        this.regexErrors = new Map(); // "ignoreCase\0pattern" -> error
        this.entryText = null; // the text of the chip edited, as it was when the caret came in (Esc)
        this.textAnchor = null; // where a Shift selection inside the edited chip started
        this.drag = null; // a mouse selection: {anchor} from a gap, {chip, left} from inside a chip
        this.bind();
        this.render();
    }

    // The chips as edited, empty ones included
    get chips() { return this.state.chips; }

    // Shows other chips (another document), the caret after the last one
    setChips(chips) {
        this.state = { chips: chips.map(c => ({ ...c })), pos: { gap: chips.length } };
        this.entryText = null;
        this.render();
    }

    // The chips the search runs with
    searchChips() { return searchChips(this.state.chips); }

    // @returns the error of the first invalid regex chip, "" if there is none
    firstError() {
        for (const chip of searchChips(this.state.chips)) {
            const error = this.regexError(chip);
            if (error) return error;
        }
        return "";
    }

    // Closes the chip the caret is in, as Enter does before a search
    closeChip() {
        const pos = this.state.pos;
        if (pos.gap === undefined) this.go(moveTo(this.syncedState(), { gap: pos.chip + 1 }));
    }

    focus() { this.placeFocus(); }

    // ---- state and rendering ----

    regexError(chip) {
        if (!chip.isRegex || chip.text === "") return "";
        const key = `${chip.ignoreCase ? 1 : 0}\0${chip.text}`;
        if (!this.regexErrors.has(key)) this.regexErrors.set(key, this.checkRegexBy(chip.text, chip.ignoreCase));
        return this.regexErrors.get(key);
    }

    // The state with the caret offset of the chip edit as it is now
    syncedState() {
        const pos = this.state.pos;
        if (pos.gap !== undefined) return this.state;
        const edit = this.chipEdit(pos.chip);
        return edit ? { ...this.state, pos: { chip: pos.chip, offset: edit.edit.selectionStart } } : this.state;
    }

    chipEdit(i) { return this.root.$(`.chip[data-chip="${i}"] > .chip-text`); }

    // Goes to a new state: renders it if the chips changed, moves the focus
    go(next) {
        if (!next) return;
        const enteredChip = next.pos.gap === undefined
            && (this.state.pos.gap !== undefined || this.state.pos.chip !== next.pos.chip);
        const chipsChanged = next.chips !== this.state.chips;
        if (enteredChip) this.entryText = next.chips[next.pos.chip].text;
        if (next.pos.gap !== undefined) this.entryText = null;
        this.state = next;
        if (chipsChanged) {
            this.render();
            this.onEdited?.();
        } else {
            this.markState();
        }
        this.placeFocus();
    }

    render() {
        const root = this.root;
        root.innerHTML = "";
        const { chips } = this.state;
        for (let i = 0; i <= chips.length; i++) {
            root.append(<span class="gap" data-gap={i}></span>);
            if (i === chips.length) break;
            const chip = chips[i];
            root.append(<span class="chip" data-chip={i}>
                <span class="chip-toggle chip-regex" title="Regular expression">.*</span>
                <span class="chip-toggle chip-case" title="Ignore case">Aa</span>
                <span class="chip-text"></span>
            </span>);
            root.lastElementChild.$(".chip-text").value = chip.text;
        }
        if (chips.length === 0)
            root.append(<span class="placeholder">Search in payload: | starts the next condition (Enter)</span>);
        this.markState();
    }

    // The classes that follow the state: chip properties, errors, the caret
    markState() {
        const { chips, pos } = this.state;
        const focused = this.root.state.focus || this.root.$(":focus") !== null;
        this.root.$$(".chip").forEach((el, i) => {
            const chip = chips[i];
            const edited = pos.gap === undefined && pos.chip === i;
            el.classList.toggle("regex", chip.isRegex);
            el.classList.toggle("nocase", chip.ignoreCase);
            el.classList.toggle("active", edited);
            const error = edited ? "" : this.regexError(chip);
            el.classList.toggle("invalid", !!error);
            el.attributes["title"] = error || null;
            markEdgeSpaces(el.$(".chip-text"), chip.text);
        });
        const range = selection(this.state);
        // whole chips selected: no text stays selected inside a chip
        if (range)
            for (const edit of this.root.$$(".chip-text"))
                if (edit.edit.selectionStart !== edit.edit.selectionEnd) edit.edit.selectRange();
        this.root.$$(".chip").forEach((el, i) =>
            el.classList.toggle("selected", !!range && i >= range.from && i < range.to));
        this.root.$$(".gap").forEach((el, g) =>
            el.classList.toggle("caret", focused && !range && pos.gap === g));
        this.root.classList.toggle("focused", focused);
    }

    placeFocus() {
        const pos = this.state.pos;
        if (pos.gap !== undefined) {
            this.root.state.focus = true;
        } else {
            const edit = this.chipEdit(pos.chip);
            if (!edit) return;
            edit.state.focus = true;
            edit.edit.selectRange(pos.offset, pos.offset);
        }
        this.markState();
    }

    // ---- events ----

    bind() {
        const root = this.root;
        // In the sinking phase: the edit of a chip consumes the arrows itself,
        // even at its edges, so the editor has to see them first
        const sinking = (name, handler) => root.addEventListener(name, evt => {
            if (!handler(evt)) return;
            evt.preventDefault();
            evt.stopPropagation();
        }, { capture: true });
        sinking("keydown", evt => this.onKeyDown(evt));
        sinking("keypress", evt => this.onKeyChar(evt));
        root.on("input", ".chip-text", (evt, edit) => this.onInput(edit));
        // The mouse too: a chip edit would start selecting its text under a drag
        // begun outside it, and would take Shift+click for its own
        sinking("mousedown", evt => this.onMouseDown(evt));
        sinking("mousemove", evt => {
            if (!this.drag) return false;
            this.onMouseMove(evt);
            return this.drag !== null && (this.drag.anchor !== undefined || this.drag.left);
        });
        // outside the editor: the drag goes on there
        document.on("mousemove", evt => {
            if (this.drag && !this.isInside(evt.target)) this.onMouseMove(evt);
        });
        document.on("mouseup", () => this.endDrag());
        root.on("focusin", () => this.markState());
        root.on("focusout", () => {
            // posted: the focus may be moving to another chip of this editor
            setTimeout(() => this.onFocusLeft(), 0);
        });
    }

    // The editor captures the mouse while chips are selected by a drag, as the
    // log tables do: the moves and the release come to it even outside the
    // window. The root element is never recreated, so it is safe to capture.
    captureDrag() {
        if (this.drag && !this.drag.captured) {
            this.drag.captured = true;
            this.root.state.capture(true);
        }
    }

    endDrag() {
        if (this.drag?.captured) this.root.state.capture(false);
        this.drag = null;
    }

    isInside(el) {
        for (; el; el = el.parentElement) if (el === this.root) return true;
        return false;
    }

    chipIndexOf(el) {
        const chip = el?.closest?.(".chip");
        return chip ? parseInt(chip.getAttribute("data-chip")) : -1;
    }

    onInput(edit) {
        const i = this.chipIndexOf(edit);
        if (i < 0) return;
        const chips = [...this.state.chips];
        chips[i] = { ...chips[i], text: edit.value };
        this.state = { chips, pos: { chip: i, offset: edit.edit.selectionStart } };
        markEdgeSpaces(edit, edit.value);
        this.onEdited?.();
    }

    onKeyDown(evt) {
        const inGap = this.state.pos.gap !== undefined;
        const mod = isMac() ? evt.altKey : evt.ctrlKey;
        const line = isMac() && evt.metaKey;
        const command = isMac() ? evt.metaKey : evt.ctrlKey;
        if (command && !evt.altKey) {
            switch (evt.code) {
                case "KeyA": return this.selectAllKey();
                case "KeyC": return this.copy(false);
                case "KeyX": return this.copy(true);
                case "KeyV": return this.paste();
            }
        }
        let key = null;
        switch (evt.code) {
            case "ArrowLeft": key = line ? (inGap ? "home" : "wordLeft") : mod ? "wordLeft" : "left"; break;
            case "ArrowRight": key = line ? (inGap ? "end" : "wordRight") : mod ? "wordRight" : "right"; break;
            case "Home": key = "home"; break;
            case "End": key = "end"; break;
            case "Enter":
                this.closeChip();
                this.onCommit?.();
                return true;
            case "Escape":
                if (inGap) {
                    if (!selection(this.state)) return false;
                    this.go(moveTo(this.state, this.state.pos)); // drops the selection
                    return true;
                }
                if (this.entryText === null) return false;
                return this.cancelChip();
            case "Backspace":
            case "Delete":
                if (!inGap) return false;
                this.go(deleteInGap(this.state, evt.code === "Backspace" ? "backspace" : "delete"));
                return true;
        }
        if (!key) return false;
        if (evt.shiftKey) return this.extendKey(key, line);
        this.textAnchor = null;
        const synced = this.syncedState();
        let selectionEmpty = true;
        if (!inGap) {
            const edit = this.chipEdit(synced.pos.chip);
            selectionEmpty = edit.edit.selectionStart === edit.edit.selectionEnd;
            // Cmd+arrow inside a chip goes to its edge first, then out of it;
            // the edit itself doesn't know Cmd+Right
            if (line) {
                const len = synced.chips[synced.pos.chip].text.length;
                const edge = key === "wordLeft" ? 0 : len;
                if (synced.pos.offset !== edge || !selectionEmpty) {
                    edit.edit.selectRange(edge, edge);
                    this.state = { ...synced, pos: { chip: synced.pos.chip, offset: edge } };
                    return true;
                }
            }
        }
        const next = moveCaret(synced, key, selectionEmpty);
        if (!next) return false; // the edit's own key
        this.go(next);
        return true;
    }

    // A caret key with Shift. In a gap the selection goes by whole chips; inside a
    // chip it is the edit's own until it reaches the edge of the chip, then it takes
    // the whole chip and goes on by chips.
    extendKey(key, line) {
        if (this.state.pos.gap !== undefined) {
            this.go(extendCaret(this.state, key));
            return true;
        }
        if (key === "home" || key === "end") return false;
        const synced = this.syncedState();
        const i = synced.pos.chip;
        const edit = this.chipEdit(i).edit;
        const len = synced.chips[i].text.length;
        const start = edit.selectionStart, end = edit.selectionEnd;
        if (start === end || this.textAnchor === null) this.textAnchor = start;
        const anchor = this.textAnchor;
        const focus = start === anchor ? end : start; // the moving end of the selection
        const back = key === "left" || key === "wordLeft";
        if (back ? focus > 0 : focus < len) {
            if (!line) return false; // the edit's own
            // Cmd+Shift+arrow: to the edge of the chip (the edit doesn't know Cmd+Shift+Right)
            if (back) edit.selectRange(0, anchor); else edit.selectRange(anchor, len);
            return true;
        }
        this.textAnchor = null;
        edit.selectRange();
        this.go(selectChipsFrom(synced, i, back ? i : i + 1));
        return true;
    }

    // Cmd/Ctrl+A: inside a chip its text first, then every chip
    selectAllKey() {
        const synced = this.syncedState();
        if (synced.pos.gap === undefined) {
            const i = synced.pos.chip;
            const edit = this.chipEdit(i).edit;
            const len = synced.chips[i].text.length;
            if (len > 0 && (edit.selectionStart !== 0 || edit.selectionEnd !== len)) {
                edit.selectAll();
                return true;
            }
            edit.selectRange();
        }
        const left = moveTo(synced, { gap: synced.pos.gap ?? synced.pos.chip + 1 });
        this.go(selectAll(left));
        return true;
    }

    // Cmd/Ctrl+C, Cmd/Ctrl+X of the selected chips, in the text form of a query.
    // Inside a chip the edit copies its own text.
    copy(cut) {
        const chips = selectedChips(this.state);
        if (this.state.pos.gap === undefined || chips.length === 0) return this.state.pos.gap !== undefined;
        Clipboard.writeText(formatQuery(chips));
        if (cut) this.go(deleteSelection(this.state));
        return true;
    }

    // Cmd/Ctrl+V: a query (with its prefix) is pasted as chips; any other text into
    // the chip the caret is in, as it is, or as a new chip in a gap
    paste() {
        // Sciter's readText ends the text with a NUL character
        const text = (Clipboard.readText() ?? "").replace(/\0+$/, "");
        if (text === "") return true;
        const synced = this.syncedState();
        const chips = parseQuery(text);
        if (chips) {
            this.go(insertChips(synced, chips));
            return true;
        }
        if (synced.pos.gap === undefined) return false; // the edit's own paste
        const inserted = insertChips(synced, [makeChip(text)]);
        const i = inserted.pos.gap - 1;
        this.go({ chips: inserted.chips, pos: { chip: i, offset: text.length } });
        return true;
    }

    onKeyChar(evt) {
        const char = evt.char ?? (evt.keyCode ? String.fromCharCode(evt.keyCode) : "");
        if (!char || char < " ") return false;
        if (evt.ctrlKey || evt.metaKey) return false;
        const synced = this.syncedState();
        if (synced.pos.gap !== undefined) {
            this.go(typeInGap(synced, char));
            return true;
        }
        if (char !== "|") return false; // typed into the chip by its edit
        const edit = this.chipEdit(synced.pos.chip);
        if (edit.edit.selectionStart !== edit.edit.selectionEnd) edit.edit.removeText();
        this.go(typeBarInChip(this.syncedState()));
        return true;
    }

    cancelChip() {
        const synced = this.syncedState();
        const i = synced.pos.chip;
        const chips = [...synced.chips];
        chips[i] = { ...chips[i], text: this.entryText };
        this.go(moveTo({ chips, pos: synced.pos }, { gap: i + 1 }));
        return true;
    }

    onMouseDown(evt) {
        if (evt.button !== 0 && evt.button !== undefined) return false;
        const target = evt.target;
        const toggle = target.closest?.(".chip-toggle");
        if (toggle) {
            this.toggle(this.chipIndexOf(toggle), toggle.classList.contains("chip-regex") ? "isRegex" : "ignoreCase");
            return true;
        }
        const synced = this.syncedState();
        const g = this.gapAt(evt.clientX, evt.clientY);
        if (evt.shiftKey) {
            // Shift+click selects whole chips up to the pointer
            if (synced.pos.gap === undefined) {
                this.chipEdit(synced.pos.chip)?.edit.selectRange();
                this.go(selectChipsFrom(synced, synced.pos.chip, g));
            } else {
                this.go(selectTo(synced, synced.anchor ?? synced.pos.gap, g));
            }
            return true;
        }
        const chipEl = target.closest?.(".chip");
        if (chipEl) {
            // the edit places the caret itself; the state follows it
            const i = this.chipIndexOf(chipEl);
            const next = moveTo(synced, { chip: i, offset: 0 });
            if (next.chips !== synced.chips) {
                // an empty chip before it was removed: the elements are rebuilt
                this.go(next);
                return true;
            }
            if (synced.pos.gap !== undefined || synced.pos.chip !== i) this.entryText = synced.chips[i].text;
            this.state = next;
            this.textAnchor = null;
            this.endDrag();
            this.drag = { chip: i, left: false };
            this.markState();
            setTimeout(() => {
                const edit = this.chipEdit(i);
                if (edit && this.state.pos.chip === i) {
                    this.state = { ...this.state, pos: { chip: i, offset: edit.edit.selectionStart } };
                    this.markState();
                }
            }, 0);
            return false;
        }
        // a gap or the background: the caret goes to the gap nearest to the pointer,
        // a drag from there selects whole chips
        const next = moveTo(synced, { gap: g });
        this.endDrag();
        this.drag = { anchor: next.pos.gap };
        this.go(next);
        this.captureDrag();
        return true;
    }

    // A drag with the left button pressed down in this editor
    onMouseMove(evt) {
        const drag = this.drag;
        if (!drag) return;
        // A move without the button inside the window: the release was missed.
        // Outside the window the moves of the captured mouse may come without
        // the button state, so only mouseup ends the drag there.
        if (evt.buttons !== undefined && !(evt.buttons & 1) && insideWindow(evt)) return this.endDrag();
        const g = this.gapAt(evt.clientX, evt.clientY);
        if (drag.anchor !== undefined) {
            if (this.state.pos.gap === g && this.state.anchor === drag.anchor) return;
            this.go(selectTo(this.state, drag.anchor, g));
            return;
        }
        // from inside a chip: the edit selects its text until the pointer leaves the chip
        const chipEl = this.root.$(`.chip[data-chip="${drag.chip}"]`);
        if (!chipEl) { this.endDrag(); return; }
        if (!drag.left) {
            const box = chipEl.getBoundingClientRect();
            const inside = evt.clientX >= box.left && evt.clientX <= box.right
                && evt.clientY >= box.top && evt.clientY <= box.bottom;
            if (inside) return;
            drag.left = true;
            this.chipEdit(drag.chip)?.edit.selectRange();
            this.captureDrag();
        }
        const chips = this.state.chips;
        const next = selectChipsFrom({ chips, pos: { chip: drag.chip, offset: 0 } }, drag.chip, g);
        if (next.chips !== chips) { this.endDrag(); this.go(next); return; } // it was empty
        if (this.state.pos.gap === next.pos.gap && this.state.anchor === next.anchor) return;
        this.entryText = null;
        this.go(next);
    }

    // The gap nearest to a point: before the first chip of the pointer's row
    // whose middle is right of it
    gapAt(x, y) {
        const chips = this.root.$$(".chip");
        for (let i = 0; i < chips.length; i++) {
            const box = chips[i].getBoundingClientRect();
            if (y !== undefined && y < box.top) return i;
            if ((y === undefined || y <= box.bottom) && x < box.left + box.width / 2) return i;
        }
        return chips.length;
    }

    toggle(i, property) {
        if (i < 0) return;
        const synced = this.syncedState();
        const chips = [...synced.chips];
        chips[i] = { ...chips[i], [property]: !chips[i][property] };
        // the regex is checked at once: show it as if the chip were closed
        this.go(moveTo({ chips, pos: synced.pos }, synced.pos.gap === undefined && synced.pos.chip === i
            ? { gap: i + 1 } : synced.pos));
    }

    onFocusLeft() {
        if (this.root.state.focus || this.root.$(":focus")) return;
        const pos = this.state.pos;
        if (pos.gap === undefined) {
            const next = moveTo(this.syncedState(), { gap: pos.chip + 1 });
            this.entryText = null;
            if (next.chips !== this.state.chips) {
                this.state = next;
                this.render();
                this.onEdited?.();
                return;
            }
            this.state = next;
        }
        this.markState();
    }
}

// True if the mouse event is over the window's client area
function insideWindow(evt) {
    const box = document.documentElement.getBoundingClientRect();
    return evt.clientX >= box.left && evt.clientX < box.right
        && evt.clientY >= box.top && evt.clientY < box.bottom;
}

// Spaces at the edges of a chip are significant: they are marked so they can be seen
function markEdgeSpaces(edit, text) {
    try {
        edit.clearMarks?.();
        const lead = text.length - text.trimStart().length;
        const trail = text.length - text.trimEnd().length;
        const node = edit.firstChild;
        if (!node || (!lead && !trail)) return;
        const mark = (from, to) => {
            const range = new Range();
            range.setStart(node, from);
            range.setEnd(node, to);
            range.applyMark("edge-space");
        };
        if (lead === text.length) { mark(0, text.length); return; }
        if (lead) mark(0, lead);
        if (trail) mark(text.length - trail, text.length);
    } catch (e) {
        console.log("markEdgeSpaces:", e);
    }
}
