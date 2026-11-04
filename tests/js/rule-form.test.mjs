// The conditions of a rule as the rows of the rule editor, see resources/rule-form.js.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { editableColumns, rowsFromRule, conditionsFromRows, describeCondition, errorsOfRows } from "../../resources/rule-form.js";

const columns = [
    { id: "time", title: "Time", kind: "Time" },
    { id: "timestamp", title: "Timestamp", kind: "Duration" },
    { id: "tag", title: "Tag", kind: "Text" },
    { id: "pid", title: "PID", kind: "Integer" },
    { id: "id", title: "ID", kind: "Hex" },
    { id: "type", title: "Type", kind: "Enum", labels: ["LOG", "CTRL"] },
    { id: "level", title: "Level", kind: "Level" },
    { id: "payload", title: "Message", kind: "Payload" },
];

test("a row for every column a condition can be put on: not times, not durations", () => {
    assert.deepEqual(editableColumns(columns).map(c => c.id), ["tag", "pid", "id", "type", "level", "payload"]);
});

test("a rule without conditions: every row off, with its defaults", () => {
    const { rows, kept } = rowsFromRule({ conditions: [] }, columns);
    assert.deepEqual(kept, []);
    assert.deepEqual(rows.tag, { on: false, check: "equals", value: "", ignoreCase: false });
    assert.deepEqual(rows.pid, { on: false, from: "", to: "" });
    assert.deepEqual(rows.type, { on: false, value: "LOG" });
    assert.deepEqual(rows.level, { on: false, from: "fatal", to: "verbose" });
});

test("conditions fill their rows: text checks, numbers (hex in hex), ranges, levels, labels", () => {
    const { rows } = rowsFromRule({
        conditions: [
            { column: "tag", check: "contains", value: "Act", ignoreCase: true },
            { column: "pid", check: "range", min: 100, max: 200 },
            { column: "id", check: "equals", value: "0x1F" },
            { column: "type", check: "equals", value: "CTRL" },
            { column: "level", check: "equals", value: "warn" },
            { column: "payload", check: "regex", value: "^err" },
        ]
    }, columns);
    assert.deepEqual(rows.tag, { on: true, check: "contains", value: "Act", ignoreCase: true });
    assert.deepEqual(rows.pid, { on: true, from: "100", to: "200" });
    assert.deepEqual(rows.id, { on: true, from: "0x1F", to: "" });
    assert.deepEqual(rows.type, { on: true, value: "CTRL" });
    assert.deepEqual(rows.level, { on: true, from: "warn", to: "warn" });
    assert.deepEqual(rows.payload, { on: true, check: "regex", value: "^err", ignoreCase: false });
});

test("the rows give the conditions back as a filter file has them", () => {
    const rule = {
        conditions: [
            { column: "tag", check: "contains", value: "Act", ignoreCase: true },
            { column: "pid", check: "range", min: "100", max: "200" },
            { column: "id", check: "equals", value: "0x1F" },
            { column: "type", check: "equals", value: "CTRL" },
            { column: "level", check: "range", min: "fatal", max: "error" },
        ]
    };
    const { rows, kept } = rowsFromRule(rule, columns);
    assert.deepEqual(conditionsFromRows(rows, columns, kept), rule.conditions);
});

test("a number typed in a hex row is hex, with or without 0x; an empty 'to' is a single value", () => {
    const rows = rowsFromRule({ conditions: [] }, columns).rows;
    rows.id = { on: true, from: "1f", to: "" };
    rows.pid = { on: true, from: "12", to: "" };
    assert.deepEqual(conditionsFromRows(rows, columns, []), [
        { column: "pid", check: "equals", value: "12" },
        { column: "id", check: "equals", value: "0x1f" },
    ]);
    rows.id = { on: true, from: "0x10", to: "20" };
    assert.deepEqual(conditionsFromRows(rows, columns, [])[1], { column: "id", check: "range", min: "0x10", max: "0x20" });
});

test("a number row switched on without a value gives an empty value, for the backend to refuse", () => {
    const rows = rowsFromRule({ conditions: [] }, columns).rows;
    rows.pid = { on: true, from: "", to: "" };
    rows.id = { on: true, from: " ", to: "" };
    assert.deepEqual(conditionsFromRows(rows, columns, []), [
        { column: "pid", check: "equals", value: "" },
        { column: "id", check: "equals", value: "" },
    ]);
});

test("a level the row can't show (none, a number) is kept as it is", () => {
    const none = { column: "level", check: "range", min: "none", max: "warn" };
    const { rows, kept } = rowsFromRule({ conditions: [none] }, columns);
    assert.deepEqual(kept, [none]);
    assert.equal(rows.level.on, false);
    const byName = rowsFromRule({ conditions: [{ column: "level", check: "equals", value: "Error" }] }, columns);
    assert.deepEqual(byName.rows.level, { on: true, from: "error", to: "error" });
});

test("rows switched off give no condition, ignore case only where it is set", () => {
    const { rows } = rowsFromRule({ conditions: [] }, columns);
    rows.tag = { on: true, check: "equals", value: "A", ignoreCase: false };
    assert.deepEqual(conditionsFromRows(rows, columns, []), [{ column: "tag", check: "equals", value: "A" }]);
});

test("conditions the rows can't show are kept as they are: other columns, a second one on a column", () => {
    const header = { column: "header", check: "contains", value: "X" };
    const second = { column: "tag", check: "regex", value: "^B" };
    const { rows, kept } = rowsFromRule({ conditions: [{ column: "tag", check: "equals", value: "A" }, header, second] }, columns);
    assert.deepEqual(kept, [header, second]);
    assert.equal(rows.tag.value, "A");
    assert.deepEqual(conditionsFromRows(rows, columns, kept),
        [{ column: "tag", check: "equals", value: "A" }, header, second]);
});

test("a kept condition is described for the editor", () => {
    assert.equal(describeCondition({ column: "header", check: "contains", value: "X", ignoreCase: true }),
        'header contains "X" (any case)');
    assert.equal(describeCondition({ column: "msgid", check: "range", min: 1, max: 5 }), "msgid from 1 to 5");
    assert.equal(describeCondition({ column: "msgid", check: "equals", value: 3 }), "msgid equals 3");
});

test("the errors of the conditions go to their rows and kept conditions", () => {
    const { rows } = rowsFromRule({ conditions: [] }, columns);
    rows.pid = { on: true, from: "x", to: "" };
    rows.level = { on: true, from: "verbose", to: "error" };
    const kept = [{ column: "header", check: "contains", value: "X" }];
    // The conditions are those of conditionsFromRows: pid, level, then the kept one
    const errors = errorsOfRows(rows, columns, kept, ["not a number", "empty range", "no column"], [false, false, true]);
    assert.deepEqual(errors.rows, { pid: "not a number", level: "empty range" });
    assert.deepEqual(errors.kept, ["no column"]);
    assert.equal(errors.blocking, true);
    assert.deepEqual(errorsOfRows(rows, columns, kept, ["", "", ""], [false, false, true]),
        { rows: {}, kept: [""], blocking: false });
});

test("only a mistake on a column of the log blocks the rule, not a column it doesn't have", () => {
    const { rows } = rowsFromRule({ conditions: [] }, columns);
    const kept = [{ column: "header", check: "contains", value: "X" }];
    assert.equal(errorsOfRows(rows, columns, kept, ["no column"], [true]).blocking, false);
    assert.equal(errorsOfRows(rows, columns, kept, ["bad regex"], [false]).blocking, true,
        "a second condition on a column of the log");
});
