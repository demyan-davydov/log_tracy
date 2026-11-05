// The caret and the edits of the chip search editor, apart from Sciter so they
// can be tested with node. Tests: tests/js/search-editing.test.mjs.
// Story: docs/stories/advanced-search.md.
//
// A state is {chips, pos}; pos is {gap: g} for the caret between chips (gap g is
// before chip g, gap chips.length after the last one) or {chip: i, offset: o}
// for the caret inside chip i. Functions return a new state, the old one stays.

import { makeChip, typeBar } from "./search-query.js";

const isGap = pos => pos.gap !== undefined;

// Moves the caret to `pos` (given for the chips as they are). The chip the caret
// leaves is removed if it's empty: an empty chip lives only while it's edited.
export function moveTo(state, pos) {
    const from = state.pos;
    const leaving = !isGap(from) && (isGap(pos) || pos.chip !== from.chip);
    if (!leaving || state.chips[from.chip].text !== "")
        return { chips: state.chips, pos };
    const removed = from.chip;
    const chips = state.chips.filter((_, i) => i !== removed);
    if (isGap(pos))
        return { chips, pos: { gap: pos.gap > removed ? pos.gap - 1 : pos.gap } };
    return { chips, pos: { chip: pos.chip > removed ? pos.chip - 1 : pos.chip, offset: pos.offset } };
}

// The caret keys: "left", "right", "wordLeft", "wordRight", "home", "end".
// @param selectionEmpty - no text is selected in the chip the caret is in
// @returns the new state, or null if the key is the text field's own (inside a chip)
export function moveCaret(state, key, selectionEmpty = true) {
    const { chips, pos } = state;
    const back = key === "left" || key === "wordLeft";
    const range = selection(state);
    if (range && key !== "home" && key !== "end")
        return { chips, pos: { gap: back ? range.from : range.to } };
    if (isGap(pos)) {
        const g = pos.gap;
        let target;
        if (key === "home") target = { gap: 0 };
        else if (key === "end") target = { gap: chips.length };
        else if (key === "wordLeft") target = { gap: Math.max(g - 1, 0) };
        else if (key === "wordRight") target = { gap: Math.min(g + 1, chips.length) };
        else if (back) target = g > 0 ? { chip: g - 1, offset: chips[g - 1].text.length } : pos;
        else target = g < chips.length ? { chip: g, offset: 0 } : pos;
        return moveTo(state, target);
    }
    if (!selectionEmpty || key === "home" || key === "end") return null;
    const atStart = pos.offset === 0, atEnd = pos.offset === chips[pos.chip].text.length;
    if (back && atStart) return moveTo(state, { gap: pos.chip });
    if (!back && atEnd) return moveTo(state, { gap: pos.chip + 1 });
    return null;
}

// A character typed with the caret in a gap starts a new chip there, instead of
// the selected chips; '|' does nothing.
export function typeInGap(state, char) {
    if (char === "|") return state;
    state = deleteSelection(state);
    const g = state.pos.gap;
    const chips = [...state.chips.slice(0, g), makeChip(char), ...state.chips.slice(g)];
    return { chips, pos: { chip: g, offset: char.length } };
}

// '|' typed with the caret inside a chip (see typeBar). The caret goes on in the
// next chip; no empty chip is left before it.
export function typeBarInChip(state) {
    const i = state.pos.chip;
    const typed = typeBar(state.chips[i], state.pos.offset);
    const replace = (...chips) => [...state.chips.slice(0, i), ...chips, ...state.chips.slice(i + 1)];
    if (!typed.split)
        return { chips: replace(typed.chip), pos: { chip: i, offset: typed.caret } };
    const [left, split] = typed.split;
    if (left.text === "") return state;
    const { color, ...right } = split; // a new chip: it gets a color of its own
    return { chips: replace(left, right), pos: { chip: i + 1, offset: 0 } };
}

// Backspace ("backspace") or Delete ("delete") with the caret in a gap removes
// the selected chips, or the chip before or after the caret.
export function deleteInGap(state, key) {
    if (selection(state)) return deleteSelection(state);
    const g = state.pos.gap;
    const removed = key === "backspace" ? g - 1 : g;
    if (removed < 0 || removed >= state.chips.length) return state;
    return { chips: state.chips.filter((_, i) => i !== removed), pos: { gap: removed } };
}

// @returns the chips a search is run with: the empty ones are dropped
export function searchChips(chips) {
    return chips.filter(chip => chip.text !== "");
}

// @returns true if the chips make the same query: an empty chip, which lives only
// while it is edited, is no change
export function sameQuery(a, b) {
    const key = chips => JSON.stringify(searchChips(chips).map(c => [c.text, c.isRegex, c.ignoreCase]));
    return key(a) === key(b);
}

// Gives a match color to every chip without one: the first color no
// other chip has, or, with all of them taken, the one used least.
// A chip keeps its color while the query is edited.
// @param size - the number of colors (matchColorCount of match-colors.js)
// @returns the chips, the same array if every chip has a color
export function assignColors(chips, size) {
    if (chips.every(chip => chip.color !== undefined)) return chips;
    const uses = new Array(size).fill(0);
    for (const chip of chips) if (chip.color !== undefined) uses[chip.color % size]++;
    return chips.map(chip => {
        if (chip.color !== undefined) return chip;
        const color = uses.indexOf(Math.min(...uses)); // a free one first: 0 uses
        uses[color]++;
        return { ...chip, color };
    });
}

// ---- selection of whole chips ----
// A state may have an `anchor` gap: with the caret in a gap, the chips between
// the anchor and the caret are selected.

// @returns {from, to} of the selected chips, or null if none is selected
export function selection(state) {
    if (state.anchor === undefined || !isGap(state.pos) || state.anchor === state.pos.gap) return null;
    return { from: Math.min(state.anchor, state.pos.gap), to: Math.max(state.anchor, state.pos.gap) };
}

// @returns the selected chips, in their order
export function selectedChips(state) {
    const range = selection(state);
    return range ? state.chips.slice(range.from, range.to) : [];
}

// A caret key with Shift and the caret in a gap: the selection goes chip by chip
// from the gap it started in (a word is a chip here).
export function extendCaret(state, key) {
    const g = state.pos.gap, n = state.chips.length;
    const anchor = state.anchor ?? g;
    let target;
    if (key === "home") target = 0;
    else if (key === "end") target = n;
    else if (key === "left" || key === "wordLeft") target = Math.max(g - 1, 0);
    else target = Math.min(g + 1, n);
    return { chips: state.chips, pos: { gap: target }, anchor };
}

// A selection started in chip `chip` that left it for gap `target`: it takes the
// whole chip and the chips up to the target. An empty chip is only left.
export function selectChipsFrom(state, chip, target) {
    const right = target > chip;
    if (state.chips[chip].text === "")
        return moveTo(state, { gap: right ? chip + 1 : chip });
    return right
        ? { chips: state.chips, pos: { gap: Math.max(target, chip + 1) }, anchor: chip }
        : { chips: state.chips, pos: { gap: Math.min(target, chip) }, anchor: chip + 1 };
}

// The chips from the `anchor` gap to gap `g` selected (a drag, Shift+click);
// the caret must be in a gap already.
export function selectTo(state, anchor, g) {
    return { chips: state.chips, pos: { gap: g }, anchor };
}

export function selectAll(state) {
    return { chips: state.chips, pos: { gap: state.chips.length }, anchor: 0 };
}

// Removes the selected chips; the caret takes their place
export function deleteSelection(state) {
    const range = selection(state);
    if (!range) return state;
    return {
        chips: [...state.chips.slice(0, range.from), ...state.chips.slice(range.to)],
        pos: { gap: range.from },
    };
}

// Pasted chips: at the caret in a gap (instead of the selection), after the chip
// the caret is in, or instead of it if it's empty. The caret goes after them.
export function insertChips(state, chips) {
    let base = deleteSelection(state), at;
    if (isGap(base.pos)) {
        at = base.pos.gap;
    } else if (base.chips[base.pos.chip].text === "") {
        at = base.pos.chip;
        base = { chips: base.chips.filter((_, i) => i !== at), pos: { gap: at } };
    } else {
        at = base.pos.chip + 1;
    }
    return {
        chips: [...base.chips.slice(0, at), ...chips, ...base.chips.slice(at)],
        pos: { gap: at + chips.length },
    };
}

// ---- the search history ----

// The query an arrow key ("up", "down") goes to in the history list: the first
// arrow down takes the latest one, the arrows stop at the ends.
// @param current - the index of the query marked now, -1 for none
// @returns the index to mark, -1 if the history is empty
export function historyIndex(current, count, key) {
    if (count === 0) return -1;
    return key === "down" ? Math.min(current + 1, count - 1) : Math.max(current - 1, 0);
}
