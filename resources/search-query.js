// The search query: a list of chips joined by OR, each a text or a regex over
// the payload with its own case flag, and its text form for the clipboard.
// Pure, so it can be tested with node. Tests: tests/js/search-query.test.mjs.
// Story: docs/stories/advanced-search.md.

// The start of a query in the clipboard: a text without it is pasted as text
export const queryPrefix = "dlt-explorer-search:";

// @returns a chip; a new one is text and ignores case
export function makeChip(text, { isRegex = false, matchCase = false } = {}) {
    return { text, isRegex, matchCase };
}

// A text in quotes escapes '"' and '\'; a regex between slashes escapes a bare '/'
// and keeps its own escapes as they are.
function formatChip(chip) {
    let body;
    if (chip.isRegex) {
        body = "";
        for (let i = 0; i < chip.text.length; i++) {
            const c = chip.text[i];
            if (c === "\\" && i + 1 < chip.text.length)
                body += c + chip.text[++i];
            else
                body += c === "/" ? "\\/" : c;
        }
        body = `/${body}/`;
    } else {
        body = `"${chip.text.replace(/[\\"]/g, c => "\\" + c)}"`;
    }
    return chip.matchCase ? body : body + "i";
}

// @returns the text form of the chips, starting with queryPrefix
export function formatQuery(chips) {
    return chips.length ? `${queryPrefix} ${chips.map(formatChip).join(" | ")}` : queryPrefix;
}

// Reads the chip at `pos`. @returns {chip, end} or null
function parseChip(text, pos) {
    const open = text[pos];
    if (open !== '"' && open !== "/") return null;
    const isRegex = open === "/";
    let body = "";
    let i = pos + 1;
    for (; ; i++) {
        if (i >= text.length) return null; // not closed
        const c = text[i];
        if (c === open) break;
        if (c !== "\\") { body += c; continue; }
        const next = text[++i];
        if (next === undefined) return null;
        if (isRegex)
            body += next === "/" ? "/" : "\\" + next; // \/ is the same as / for a regex
        else if (next === '"' || next === "\\")
            body += next;
        else
            return null;
    }
    i++;
    const matchCase = text[i] !== "i";
    if (!matchCase) i++;
    return { chip: makeChip(body, { isRegex, matchCase }), end: i };
}

// @returns the chips of a text form, or null if `text` is not a query
export function parseQuery(text) {
    const isSpace = c => c === " " || c === "\t" || c === "\r" || c === "\n";
    const skipSpaces = i => { while (i < text.length && isSpace(text[i])) i++; return i; };

    let pos = skipSpaces(0);
    if (!text.startsWith(queryPrefix, pos)) return null;
    pos = skipSpaces(pos + queryPrefix.length);

    const chips = [];
    while (pos < text.length) {
        if (chips.length) {
            if (text[pos] !== "|") return null;
            pos = skipSpaces(pos + 1);
        }
        const read = parseChip(text, pos);
        if (!read) return null;
        chips.push(read.chip);
        pos = skipSpaces(read.end);
    }
    return chips;
}

// The '|' typed at `caret` in `chip`. In a text chip it closes the chip and starts
// the next one, unless it follows a '\', which it replaces; in a regex it is a '|'.
// @returns {split: [left, right]} if it closes the chip and starts the next one,
//          {chip, caret} if it goes into the chip
export function typeBar(chip, caret) {
    const before = chip.text.slice(0, caret), after = chip.text.slice(caret);
    if (chip.isRegex)
        return { chip: { ...chip, text: before + "|" + after }, caret: caret + 1 };
    if (before.endsWith("\\"))
        return { chip: { ...chip, text: before.slice(0, -1) + "|" + after }, caret };
    // the rest of the text keeps the properties, an empty next chip is a new one
    const right = after ? { ...chip, text: after } : makeChip("");
    return { split: [{ ...chip, text: before }, right] };
}

// The most characters of plain text a paste puts into a chip: pasting a whole
// log is a mistake, the cut text with an ellipsis shows it
export const pasteLimit = 64;

// Plain text pasted into the search editor (not a query): one line, at most
// pasteLimit characters and an ellipsis after them if it was longer. Into a
// regex chip it isn't cut: long patterns are real, and a piece of a log pasted
// into a regex shows itself anyway, as an invalid one mostly.
export function pastedText(text, { isRegex = false } = {}) {
    const line = text.replace(/\r\n|\r|\n/g, " ");
    if (isRegex) return line;
    const chars = [...line]; // by characters: a surrogate pair is never cut in two
    return chars.length > pasteLimit ? chars.slice(0, pasteLimit).join("") + "…" : line;
}
