// The conditions of a filter rule as the rows of the rule editor
// (rule-editor.htm), apart from Sciter so they can be tested:
// tests/js/rule-form.test.mjs.
//
// A condition is as a filter file has it (source/log_core/filter_file.d):
// { column, check: "equals" | "contains" | "regex" | "range", value | min, max, ignoreCase }.
// The editor has a row per column a condition can be put on, by its kind:
//   Text, Payload  { on, check, value, ignoreCase }
//   Integer, Hex   { on, from, to }      an empty "to": a single value; hex in a hex column
//   Level          { on, from, to }      level names, fatal..verbose
//   Enum           { on, value }         a label
// The conditions a row can't show (on a column this log doesn't have, a
// second one on a column) are kept as they are.
import { tr } from "./i18n/i18n.js";

const editableKinds = new Set(["Text", "Payload", "Integer", "Hex", "Enum", "Level"]);
export const levelNames = ["fatal", "error", "warn", "info", "debug", "verbose"];

// The columns that get a row: times and durations can't be filtered by hand
export function editableColumns(columns) {
    return columns.filter(c => editableKinds.has(c.kind));
}

function emptyRow(column) {
    switch (column.kind) {
        case "Text":
        case "Payload": return { on: false, check: "equals", value: "", ignoreCase: false };
        case "Integer":
        case "Hex": return { on: false, from: "", to: "" };
        case "Level": return { on: false, from: "fatal", to: "verbose" };
        case "Enum": return { on: false, value: column.labels?.[0] ?? "" };
    }
}

// A number as the row shows it: hex digits in a hex column
function numberText(value, column) {
    if (typeof value === "number")
        return column.kind === "Hex" ? value.toString(16).toUpperCase() : String(value);
    return String(value ?? "");
}

// A level as the row shows it: its name among the options, or null if it
// isn't one of them (none, an unknown number): the condition is kept then
function levelText(value) {
    const name = typeof value === "number" ? levelNames[value - 1] : String(value).toLowerCase();
    return levelNames.includes(name) ? name : null;
}

// The row of a condition, or null if a row can't show it
function rowOf(condition, column) {
    switch (column.kind) {
        case "Text":
        case "Payload":
            if (condition.check === "range") return null;
            return { on: true, check: condition.check, value: String(condition.value ?? ""),
                ignoreCase: !!condition.ignoreCase };
        case "Integer":
        case "Hex":
            if (condition.check === "equals")
                return { on: true, from: numberText(condition.value, column), to: "" };
            if (condition.check === "range")
                return { on: true, from: numberText(condition.min, column), to: numberText(condition.max, column) };
            return null;
        case "Level": {
            const from = levelText(condition.check === "equals" ? condition.value : condition.min);
            const to = levelText(condition.check === "equals" ? condition.value : condition.max);
            if (condition.check !== "equals" && condition.check !== "range") return null;
            return from && to ? { on: true, from, to } : null;
        }
        case "Enum":
            return condition.check === "equals" ? { on: true, value: String(condition.value) } : null;
    }
    return null;
}

// The rows of the conditions of a rule: { rows: {column id: row}, kept: [conditions] }
export function rowsFromRule(rule, columns) {
    const editable = editableColumns(columns);
    const rows = {};
    for (const column of editable) rows[column.id] = emptyRow(column);
    const kept = [];
    const shown = new Set();
    for (const condition of rule.conditions ?? []) {
        const column = editable.find(c => c.id === condition.column);
        const row = column && !shown.has(column.id) ? rowOf(condition, column) : null;
        if (row) {
            rows[column.id] = row;
            shown.add(column.id);
        } else kept.push(condition);
    }
    return { rows, kept };
}

// "1f" in a hex column is hex: written with its 0x; nothing stays nothing,
// for the backend to refuse
function numberValue(text, column) {
    const value = text.trim();
    return column.kind === "Hex" && value !== "" && !/^0x/i.test(value) ? "0x" + value : value;
}

function conditionOf(row, column) {
    const condition = { column: column.id };
    switch (column.kind) {
        case "Text":
        case "Payload":
            condition.check = row.check;
            condition.value = row.value;
            if (row.ignoreCase) condition.ignoreCase = true;
            return condition;
        case "Integer":
        case "Hex":
            if (row.to.trim() === "") {
                condition.check = "equals";
                condition.value = numberValue(row.from, column);
            } else {
                condition.check = "range";
                condition.min = numberValue(row.from, column);
                condition.max = numberValue(row.to, column);
            }
            return condition;
        case "Level":
            condition.check = "range";
            condition.min = row.from;
            condition.max = row.to;
            return condition;
        case "Enum":
            condition.check = "equals";
            condition.value = row.value;
            return condition;
    }
}

// The conditions of the rows switched on, in the order of the columns, then the kept ones
export function conditionsFromRows(rows, columns, kept) {
    const conditions = [];
    for (const column of editableColumns(columns)) {
        const row = rows[column.id];
        if (row && row.on) conditions.push(conditionOf(row, column));
    }
    return conditions.concat(kept);
}

// A kept condition in words of the language of the interface, for the editor; a check this
// editor doesn't know is said as it is
export function describeCondition(c) {
    if (c.check === "range") return tr("{column} from {min} to {max}", { column: c.column, min: c.min, max: c.max });
    // A text in quotes, those of the translation; a number as it is
    const text = typeof c.value === "string";
    const args = { column: c.column, value: String(c.value) };
    const condition = c.check === "equals" ? (text ? tr('{column} equals "{value}"', args) : tr("{column} equals {value}", args))
        : c.check === "contains" ? tr('{column} contains "{value}"', args)
        : c.check === "regex" ? tr('{column} regex "{value}"', args)
        : text ? `${c.column} ${c.check} "${c.value}"` : `${c.column} ${c.check} ${c.value}`;
    return c.ignoreCase ? tr("{condition} (any case)", { condition }) : condition;
}

// The errors of the conditions (as conditionsFromRows gives them, in that
// order) by row: { rows: {column id: message}, kept: [message or "", ...],
// blocking }. missing[i] tells that the column of condition i is one the log
// doesn't have: that only keeps the rule from being applied, it isn't a
// mistake, so it doesn't block a rule switched on (blocking: a mistake on a
// column of the log).
export function errorsOfRows(rows, columns, kept, errors, missing = []) {
    const result = { rows: {}, kept: [], blocking: false };
    let i = 0;
    for (const column of editableColumns(columns)) {
        const row = rows[column.id];
        if (!row || !row.on) continue;
        if (errors[i]) {
            result.rows[column.id] = errors[i];
            result.blocking = true;
        }
        i++;
    }
    result.kept = kept.map((_, k) => errors[i + k] || "");
    if (kept.some((_, k) => errors[i + k] && !missing[i + k])) result.blocking = true;
    return result;
}
