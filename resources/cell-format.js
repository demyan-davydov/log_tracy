// How the cells of the log table show their values: pure functions, kept
// apart from the table (virtual-dlt-view.js) so they can be tested with node.
// Tests: tests/js/cell-format.test.mjs.

const pad = (value, digits) => String(value).padStart(digits, "0");

// TimeKind of the backend (log_core/log_message), by value
const timeKinds = ["None", "Absolute", "Local", "LocalNoYear", "SinceBoot"];

// Time cell: [microseconds since the epoch (or since boot), TimeKind] of the
// record, null if it has no time
export function formatTime(cell) {
    if (!cell) return "-";
    const us = cell[0];
    const timeKind = timeKinds[cell[1]];
    const seconds = Math.floor(us / 1e6);
    const fraction = pad(us - seconds * 1e6, 6);
    if (timeKind === "SinceBoot") return `${seconds}.${fraction}`;
    if (us === 0) return "-"; // no time recorded
    const date = new Date(seconds * 1000);
    // Absolute is a moment, shown in the user's zone; Local* is the wall-clock
    // time of the source stored as if it were UTC, shown as is
    const local = timeKind !== "Absolute";
    const [year, month, dayOfMonth, hours, minutes, secs] = local
        ? [date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate(), date.getUTCHours(), date.getUTCMinutes(), date.getUTCSeconds()]
        : [date.getFullYear(), date.getMonth(), date.getDate(), date.getHours(), date.getMinutes(), date.getSeconds()];
    const day = `${pad(month + 1, 2)}/${pad(dayOfMonth, 2)}`;
    const time = `${pad(hours, 2)}:${pad(minutes, 2)}:${pad(secs, 2)}`;
    if (timeKind === "LocalNoYear") return `${day} ${time}.${fraction}`;
    return `${year}/${day} ${time}.${fraction}`;
}

// Duration cell: a number in 1/unitsPerSecond of a second
export function formatDuration(units, unitsPerSecond) {
    units = Number(units);
    if (units === 0) return "-";
    const digits = Math.round(Math.log10(unitsPerSecond));
    return `${Math.floor(units / unitsPerSecond)}.${pad(units % unitsPerSecond, digits)}`;
}

const levelNames = ["", "Fatal", "Error", "Warn", "Info", "Debug", "Verbose"];

// The name of a LogLevel value, "" for None and unknown values
export function levelName(level) {
    return levelNames[level] ?? "";
}

// The class of a cell: "aux", and the class of the record's level if the
// column is colored by it (ColumnInfo.byLevel: an HTTP status shown as it is)
export function cellClass(column, level) {
    const name = column.byLevel ? levelName(level) : "";
    return name ? `aux level-${name.toLowerCase()}` : "aux";
}

// The text of a row copied to the clipboard: the cells as they are shown
export function rowText(cellTexts) {
    return cellTexts.join("\t");
}

// The cells of a row of the backend (asSciterRow in main_window.d): the fixed
// cells by their position, then a cell per column from firstColumn on, then
// what the chips of the search found in its payload (matches, null if none)
export const rowLayout = {
    anchored: 0, rule: 1, viewIndex: 2, messageIndex: 3, level: 4, found: 5, firstColumn: 6,
    matches(columnCount) { return this.firstColumn + columnCount; },
};

// The text a cell of `column` shows for `value` (a cell of the backend row)
export function cellText(column, value) {
    if (value === null && column.kind !== "Time") return ""; // the record has no such field
    switch (column.kind) {
        case "Time": return formatTime(value);
        case "Level": return value ? (levelName(value) || "unknown") : ""; // None: no level
        case "Duration": return formatDuration(value, column.unitsPerSecond);
        case "Enum": return column.labels?.[value] ?? "unknown";
        default: return String(value); // Payload, Text, Integer, Hex (formatted by the backend)
    }
}

// The texts of the cells of a row of the backend as the table shows them:
// Index, then the cells of `columns` (the cells after the anchor, whose text
// can be selected); null if there is no row
export function cellTexts(item, columns) {
    if (!item) return null;
    return [String(item[rowLayout.messageIndex]),
        ...columns.map((column, i) => cellText(column, item[rowLayout.firstColumn + i]))];
}

// The text of a row of the backend as the table shows it (cellTexts); null if
// there is no row
export function itemText(item, columns) {
    const texts = cellTexts(item, columns);
    return texts && rowText(texts);
}

// The payload cut at the fragments the search chips found in it, for the
// table to show them in the colors of their chips.
// @param fragments - [[start, end, chip]] of the backend (UTF-16 positions, by
//   start, not overlapping); null for a row the search didn't find
// @returns [{text, chip}], chip null for the text between the fragments
export function matchPieces(text, fragments) {
    // not a list of fragments (e.g. a Time cell, while the columns of the script
    // and the backend differ for a moment): the text as it is
    if (!Array.isArray(fragments) || !fragments.every(Array.isArray)) fragments = [];
    const pieces = [];
    const push = (from, to, chip) => { if (to > from) pieces.push({ text: text.slice(from, to), chip }); };
    let at = 0;
    const sorted = [...(fragments ?? [])].sort((a, b) => a[0] - b[0]);
    for (const [start, end, chip] of sorted) {
        const from = Math.max(start, at), to = Math.min(end, text.length);
        if (to <= from) continue; // out of the text, or covered by the one before
        push(at, from, null);
        push(from, to, chip);
        at = to;
    }
    push(at, text.length, null);
    return pieces;
}

// The classes of the header of `column` ({ format, id, kind } of
// backend.tableColumnsJson): table.css gives a column its look (width) by them,
// the same for the column of every format (col-time) or for that of one format
// (col-dlt-timestamp); the Payload column, whatever its id, is also "payload"
export function columnClass(column) {
    const classes = `col-${column.id} col-${column.format}-${column.id}`;
    return column.kind === "Payload" ? `${classes} payload` : classes;
}
