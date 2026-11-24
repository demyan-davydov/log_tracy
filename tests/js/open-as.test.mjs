// The choice of "Open as", see resources/open-as.js.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { openAsItems } from "../../resources/open-as.js";

const formats = [
    { id: "dlt", name: "DLT", shortName: "DLT" },
    { id: "logcat", name: "Android logcat", shortName: "ADB" },
];

test("the list starts with detecting the format again, then the formats in the order given", () => {
    assert.deepEqual(openAsItems(formats, "dlt"), [
        { format: "", label: "Detect automatically", current: false, detected: false },
        { format: "dlt", label: "DLT", current: true, detected: false },
        { format: "logcat", label: "Android logcat", current: false, detected: false },
    ]);
});

test("the format detection would pick is told, though the log is open as another", () => {
    const items = openAsItems(formats, "dlt", "logcat");
    assert.deepEqual(items.map(item => [item.format, item.detected]), [["", false], ["dlt", false], ["logcat", true]]);
    assert.ok(openAsItems(formats, "dlt", "").every(item => !item.detected), "none detected: none marked");
    assert.ok(openAsItems(formats, "dlt").every(item => !item.detected), "not told: none marked");
});

test("no format is current for a log opened in none of them, and without formats only detection is left", () => {
    assert.ok(openAsItems(formats, "").every(item => !item.current));
    assert.deepEqual(openAsItems([], "dlt"), [{ format: "", label: "Detect automatically", current: false, detected: false }]);
});
