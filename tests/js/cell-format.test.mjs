// The values of the log table cells, see resources/cell-format.js.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { formatTime, formatDuration, levelName, cellClass } from "../../resources/cell-format.js";

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
