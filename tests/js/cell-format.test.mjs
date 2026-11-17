// The values of the log table cells, see resources/cell-format.js.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { formatTime, formatDuration, levelName, cellClass, columnClass, rowText, cellText, cellTexts, itemText, matchPieces, groupDigits, rowLayout } from "../../resources/cell-format.js";
import { readFileSync } from "node:fs";

// TimeKind values of the backend (log_core/log_message)
const Absolute = 1, Local = 2, LocalNoYear = 3, SinceBoot = 4;

// 2026-11-03 14:22:01.5 as if in UTC, in microseconds
const us = Date.UTC(2026, 10, 3, 14, 22, 1) * 1000 + 500000;

test("a record without time shows a dash", () => {
    assert.equal(formatTime(null), "-");
    assert.equal(formatTime([0, Absolute]), "-");
});

test("the time since boot is seconds with microseconds", () => {
    assert.equal(formatTime([3141592, SinceBoot]), "3.141592");
    assert.equal(formatTime([0, SinceBoot]), "0.000000", "the boot itself is a time");
});

test("a local time is shown as written, with or without its year", () => {
    assert.equal(formatTime([us, Local]), "2026/11/03 14:22:01.500000");
    assert.equal(formatTime([us, LocalNoYear]), "11/03 14:22:01.500000");
});

test("a moment is shown in the user's zone", () => {
    const d = new Date(us / 1000);
    const pad = (v, n) => String(v).padStart(n, "0");
    const expected = `${d.getFullYear()}/${pad(d.getMonth() + 1, 2)}/${pad(d.getDate(), 2)} `
        + `${pad(d.getHours(), 2)}:${pad(d.getMinutes(), 2)}:${pad(d.getSeconds(), 2)}.500000`;
    assert.equal(formatTime([us, Absolute]), expected);
});

test("a duration in units of a second", () => {
    assert.equal(formatDuration(1234567, 10000), "123.4567");
    assert.equal(formatDuration(5, 10000), "0.0005");
    assert.equal(formatDuration(0, 10000), "-");
});

test("level names by LogLevel value", () => {
    assert.equal(levelName(1), "Fatal");
    assert.equal(levelName(3), "Warn");
    assert.equal(levelName(0), "", "None");
    assert.equal(levelName(99), "", "unknown");
});

test("a column colored by the level gets the class of the record's level", () => {
    assert.equal(cellClass({ byLevel: true }, 2), "aux level-error");
    assert.equal(cellClass({ byLevel: true }, 3), "aux level-warn");
    assert.equal(cellClass({ byLevel: true }, 0), "aux", "a record without level");
    assert.equal(cellClass({}, 2), "aux", "other columns");
});

test("a copied row is its cells as shown, separated by tabs", () => {
    assert.equal(rowText(["12", "2026-11-03 14:22:01.500000", "ECU1", "hello"]),
        "12\t2026-11-03 14:22:01.500000\tECU1\thello");
});

test("a copied row keeps its empty cells, so the columns stay aligned", () => {
    assert.equal(rowText(["1", "", "text"]), "1\t\ttext");
});

test("a cell is copied as it is shown", () => {
    assert.equal(cellText({ kind: "Time" }, [3141592, SinceBoot]), "3.141592");
    assert.equal(cellText({ kind: "Time" }, null), "-");
    assert.equal(cellText({ kind: "Level" }, 2), "Error");
    assert.equal(cellText({ kind: "Level" }, 0), "", "the record has no level");
    assert.equal(cellText({ kind: "Level" }, 99), "unknown");
    assert.equal(cellText({ kind: "Integer" }, 42), "42");
    assert.equal(cellText({ kind: "Hex" }, "0x1F"), "0x1F");
    assert.equal(cellText({ kind: "Duration", unitsPerSecond: 10000 }, 31415), "3.1415");
    assert.equal(cellText({ kind: "Enum", labels: ["log", "trace"] }, 1), "trace");
    assert.equal(cellText({ kind: "Enum", labels: ["log"] }, 5), "unknown");
    assert.equal(cellText({ kind: "Text" }, "ECU1"), "ECU1");
    assert.equal(cellText({ kind: "Payload" }, "line1\n\tat foo"), "line1\n\tat foo", "copied as is");
    assert.equal(cellText({ kind: "Text" }, null), "", "the record has no such field");
});

test("a row of the backend is copied as Index and its columns, without the fixed cells", () => {
    const columns = [{ kind: "Text" }, { kind: "Payload" }];
    // anchored, rule id, view index, message index, level, found, then the columns
    const item = [true, 3, 7, 1234, 4, true, "ECU1", "hello"];
    assert.equal(itemText(item, columns), "1234\tECU1\thello");
    assert.equal(itemText(null, columns), null, "no such row");
    assert.deepEqual(cellTexts(item, columns), ["1234", "ECU1", "hello"], "the texts of the cells, Index first");
    assert.equal(cellTexts(null, columns), null);
});

// ---- what the search chips found in the payload ----

test("matchPieces: the text cut at the fragments, each with its chip", () => {
    assert.deepEqual(matchPieces("timeout after 30s", [[0, 4, 0], [4, 7, 1], [8, 17, 2]]), [
        { text: "time", chip: 0 }, { text: "out", chip: 1 }, { text: " ", chip: null },
        { text: "after 30s", chip: 2 },
    ]);
    assert.deepEqual(matchPieces("a b", [[2, 3, 0]]), [{ text: "a ", chip: null }, { text: "b", chip: 0 }]);
});

test("matchPieces: no fragments, the text as one piece", () => {
    assert.deepEqual(matchPieces("abc", []), [{ text: "abc", chip: null }]);
    assert.deepEqual(matchPieces("abc", null), [{ text: "abc", chip: null }], "a row the search didn't find has none");
    assert.deepEqual(matchPieces("abc", undefined), [{ text: "abc", chip: null }],
        "no such cell: the columns of the script and the backend differ for a moment");
    assert.deepEqual(matchPieces("", []), []);
});

test("matchPieces: fragments out of the text or out of order are not trusted", () => {
    assert.deepEqual(matchPieces("abc", [[1, 9, 0]]), [{ text: "a", chip: null }, { text: "bc", chip: 0 }]);
    assert.deepEqual(matchPieces("abcd", [[2, 3, 1], [0, 1, 0]]),
        [{ text: "a", chip: 0 }, { text: "b", chip: null }, { text: "c", chip: 1 }, { text: "d", chip: null }]);
    assert.deepEqual(matchPieces("abc", [[0, 2, 0], [1, 3, 1]]), [{ text: "ab", chip: 0 }, { text: "c", chip: 1 }],
        "an overlap is cut off");
});

test("rowLayout: whether the search found the record comes after the level (writeRow in table_rows.d)", () => {
    assert.equal(rowLayout.found, rowLayout.level + 1);
    assert.equal(rowLayout.firstColumn, rowLayout.found + 1);
});

test("rowLayout: the fragments the search found come after the cells", () => {
    assert.equal(rowLayout.matches(3), rowLayout.firstColumn + 3);
});

test("matchPieces: a cell that isn't a list of fragments shows the text as it is", () => {
    // e.g. a Time cell, while the columns of the script and the backend differ
    assert.deepEqual(matchPieces("abc", [1700000000000000, 1]), [{ text: "abc", chip: null }]);
    assert.deepEqual(matchPieces("abc", "abc"), [{ text: "abc", chip: null }]);
});

test("columnClass: a column is styled by its id, and by the ids of its format and of the column", () => {
    assert.equal(columnClass({ format: "dlt", id: "timestamp" }), "col-timestamp col-dlt-timestamp");
    assert.equal(columnClass({ format: "access-log", id: "agent" }), "col-agent col-access-log-agent");
});

test("columnClass: Payload is marked by its kind, whatever its id", () => {
    assert.equal(columnClass({ format: "logcat", id: "message", kind: "Payload" }), "col-message col-logcat-message payload");
    assert.equal(columnClass({ format: "dlt", id: "app", kind: "Text" }), "col-app col-dlt-app");
});

test("a row the search found is a bit darker than its stripe, the selection above it", () => {
    // A found row and a found stripe have their own colors in both themes, set on
    // the row only while it isn't selected; no layer over the row (it would tint the text)
    const resource = name => readFileSync(new URL(`../../resources/${name}`, import.meta.url), "utf8");
    const table = resource("table.css");
    assert.match(table, /tr\[row-found="true"\]\[row-selected="false"\]\s*\{\s*background-color: var\(--bg-row-found\);/);
    assert.match(table, /tr:nth-child\(even\)\[row-found="true"\]\[row-selected="false"\]\s*\{\s*background-color: var\(--bg-row-found-stripe\);/);
    assert.doesNotMatch(table, /-foreground:/);
    for (const theme of ["theme-light.css", "theme-dark.css"]) {
        assert.match(resource(theme), /--bg-row-found:/, theme);
        assert.match(resource(theme), /--bg-row-found-stripe:/, theme);
    }
});

// The pieces of a cell (splitSelected) as text with "|" for each gap, "^" for
// a gap inside the selection
const shown = pieces => pieces.map(p => p.gap ? (p.selected ? "^" : "|") : p.selected ? `[${p.text}]` : p.text).join("");

test("groupDigits: a gap between the thousands of a number, counted from its end", () => {
    assert.equal(shown(groupDigits([{ text: "1234567" }])), "1|234|567");
    assert.equal(shown(groupDigits([{ text: "123456" }])), "123|456");
    assert.equal(shown(groupDigits([{ text: "1000" }])), "1|000");
});

test("groupDigits: a number of 3 digits or fewer, or not a number, stays as it is", () => {
    for (const text of ["999", "0", "", "12a456", "-1234", "1 234"])
        assert.equal(shown(groupDigits([{ text }])), text);
});

test("groupDigits: the gaps fall inside and between the pieces of a selection, the text is kept", () => {
    const pieces = groupDigits([{ text: "12", selected: false }, { text: "345", selected: true }, { text: "67", selected: false }]);
    assert.equal(shown(pieces), "1|2[34]^[5]67");
    assert.equal(pieces.filter(p => !p.gap).map(p => p.text).join(""), "1234567");
});

test("groupDigits: a gap at the border of two pieces goes before the second, selected if both are", () => {
    assert.equal(shown(groupDigits([{ text: "1" }, { text: "234", selected: true }])), "1|[234]");
    assert.equal(shown(groupDigits([{ text: "1", selected: true }, { text: "234", selected: true }])), "[1]^[234]");
});
