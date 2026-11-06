// The Columns section of Settings, see resources/column-settings.js.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import {
    toggleColumn, moveColumn, resetColumns, isDefaultLayout, layoutsOf, initialFormat, formatLabel
} from "../../resources/column-settings.js";

const dlt = {
    id: "dlt", name: "DLT", payload: "Payload", defaults: ["time", "app", "ctx"],
    columns: [
        { id: "ctx", title: "CtxId", visible: true },
        { id: "time", title: "Time", visible: false },
        { id: "app", title: "AppId", visible: true },
    ]
};
const logcat = {
    id: "logcat", name: "Android logcat", payload: "Message", defaults: ["tag"],
    columns: [{ id: "tag", title: "Tag", visible: true }]
};

test("a column is hidden and shown again", () => {
    const hidden = toggleColumn(dlt, "app");
    assert.equal(hidden.columns[2].visible, false);
    assert.equal(toggleColumn(hidden, "app").columns[2].visible, true);
    assert.equal(dlt.columns[2].visible, true, "the format itself is kept");
});

test("a column is moved to another place", () => {
    assert.deepEqual(moveColumn(dlt, 0, 2).columns.map(c => c.id), ["time", "app", "ctx"]);
    assert.deepEqual(dlt.columns.map(c => c.id), ["ctx", "time", "app"], "the format itself is kept");
});

test("reset puts the columns in the order of the format and keeps them shown or hidden", () => {
    const reset = resetColumns(dlt);
    assert.deepEqual(reset.columns, [
        { id: "time", title: "Time", visible: false },
        { id: "app", title: "AppId", visible: true },
        { id: "ctx", title: "CtxId", visible: true },
    ]);
    assert.equal(reset.payload, "Payload");
});

test("the default layout is the order of the format, whatever columns are hidden", () => {
    assert.equal(isDefaultLayout(dlt), false);
    assert.equal(isDefaultLayout(resetColumns(dlt)), true, "a hidden column stays hidden");
    assert.equal(isDefaultLayout(toggleColumn(resetColumns(dlt), "app")), true);
    assert.equal(isDefaultLayout(moveColumn(resetColumns(dlt), 0, 1)), false);
});

test("the layouts of all the formats go back to the backend", () => {
    assert.deepEqual(layoutsOf([dlt, logcat]), {
        dlt: [{ id: "ctx", visible: true }, { id: "time", visible: false }, { id: "app", visible: true }],
        logcat: [{ id: "tag", visible: true }],
    });
});

test("the format of the active document is shown first, if it is listed", () => {
    assert.equal(initialFormat([dlt, logcat], "logcat"), 1);
    assert.equal(initialFormat([dlt, logcat], "text"), 0, "nothing to arrange in it: the first one");
    assert.equal(initialFormat([dlt, logcat], ""), 0, "no document");
    assert.equal(initialFormat([], "dlt"), -1, "no format to show");
});

test("the format of the active document is marked in the list", () => {
    assert.equal(formatLabel(dlt, "dlt"), "DLT (current file)");
    assert.equal(formatLabel(logcat, "dlt"), "Android logcat");
    assert.equal(formatLabel(dlt, ""), "DLT", "no document");
});
