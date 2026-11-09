// What the File Info page of a document shows, see resources/file-info.js.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { fileInfoRows, groupDigits, sizeText } from "../../resources/file-info.js";

const info = { name: "a.dlt", path: "/logs/a.dlt", format: "DLT", bytes: 257_215_283, records: 1234567 };

test("the rows: the full path, the size with the number of records, the format last", () => {
    assert.deepEqual(fileInfoRows(info, "ready"), [
        { label: "Path", value: "/logs/a.dlt" },
        { label: "Size", value: "245.3 MB · 1 234 567 records" },
        { label: "Format", value: "DLT" },
    ]);
});

test("one record is a record", () => {
    assert.equal(fileInfoRows({ ...info, records: 1 }, "ready")[1].value, "245.3 MB · 1 record");
});

test("while the file loads the number of records is the count so far", () => {
    assert.equal(fileInfoRows(info, "loadingFile")[1].value, "245.3 MB · 1 234 567 records, loading...");
});

test("after a failed load the number of records is only of the part loaded", () => {
    assert.equal(fileInfoRows(info, "loadFailed")[1].value,
        "245.3 MB · 1\u00a0234\u00a0567 records, not loaded completely");
});

test("a document that isn't open has no rows", () => {
    assert.deepEqual(fileInfoRows(null, "ready"), []);
});

test("digits are grouped by three with a no-break space", () => {
    assert.equal(groupDigits(0), "0");
    assert.equal(groupDigits(999), "999");
    assert.equal(groupDigits(1000), "1 000");
    assert.equal(groupDigits(4294967296), "4 294 967 296");
});

test("a size is in bytes below a kilobyte, then in the largest unit of 1024 with a decimal", () => {
    assert.equal(sizeText(0), "0 bytes");
    assert.equal(sizeText(1), "1 byte");
    assert.equal(sizeText(1023), "1 023 bytes");
    assert.equal(sizeText(1024), "1.0 KB");
    assert.equal(sizeText(1536), "1.5 KB");
    assert.equal(sizeText(5 * 1024 * 1024), "5.0 MB");
    assert.equal(sizeText(1.25 * 1024 ** 3), "1.3 GB");
    assert.equal(sizeText(2 * 1024 ** 4), "2.0 TB");
});

test("a size that rounds up to 1024 of a unit is shown in the next one", () => {
    assert.equal(sizeText(1024 * 1024 - 1), "1.0 MB");
    assert.equal(sizeText(1024 ** 3 - 1), "1.0 GB");
});
