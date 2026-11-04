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
