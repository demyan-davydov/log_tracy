// The pure part of scripts/windows-res.mjs: where rc.exe is and how it is called.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { rcFromKits, rcArgs } from "../../scripts/windows-res.mjs";

const kits = "C:\\Program Files (x86)\\Windows Kits\\10\\bin";

test("rc.exe of the newest Windows SDK, for the machine's architecture", () => {
    const versions = ["10.0.19041.0", "10.0.26100.0", "10.0.22621.0", "x64", "arm64"];
    assert.equal(rcFromKits(kits, versions, "x64"), `${kits}\\10.0.26100.0\\x64\\rc.exe`);
    assert.equal(rcFromKits(kits, versions, "arm64"), `${kits}\\10.0.26100.0\\arm64\\rc.exe`);
});

test("versions compared as numbers, not as text", () => {
    assert.equal(rcFromKits(kits, ["10.0.9200.0", "10.0.10240.0"], "x64"), `${kits}\\10.0.10240.0\\x64\\rc.exe`);
});

test("no Windows SDK: no rc.exe", () => {
    assert.equal(rcFromKits(kits, [], "x64"), null);
    assert.equal(rcFromKits(kits, ["x64", "arm64"], "x64"), null);
});

test("rc.exe writes the .res to the given file, quietly", () => {
    assert.deepEqual(rcArgs("C:\\p\\resources\\app.rc", "C:\\p\\build\\windows\\app.res"),
        ["/nologo", "/fo", "C:\\p\\build\\windows\\app.res", "C:\\p\\resources\\app.rc"]);
});
