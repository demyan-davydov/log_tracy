// scripts/test.mjs: the tests under a name that says so, `node scripts/build.mjs test` as it is.
// Run: node --test "tests/js/*.test.mjs"
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const script = fileURLToPath(new URL("../../scripts/test.mjs", import.meta.url));

test("test.mjs --help tells how to run the tests", () => {
    const result = spawnSync(process.execPath, [script, "--help"], { encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /node scripts\/test\.mjs/);
    assert.match(result.stdout, /--module/);
});

test("test.mjs takes the options of the tests only", () => {
    const result = spawnSync(process.execPath, [script, "dist"], { encoding: "utf8" });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /test\.mjs/);
});
