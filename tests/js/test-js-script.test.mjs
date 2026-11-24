// scripts/utils/test-js.mjs: the JS tests of tests/js, told in a line when they pass (dub test
// runs it after the D unittests, scripts/test.mjs after them too).
// Run: node --test "tests/js/*.test.mjs"
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { hooksOff, noHooksVariable } from "../../scripts/utils/hooks.mjs";
import { jsTestArgs, summarizeJsRun } from "../../scripts/utils/test-js.mjs";

const script = fileURLToPath(new URL("../../scripts/utils/test-js.mjs", import.meta.url));

test("every JS test is run by a pattern: node 22 takes no folder", () => {
    assert.deepEqual(jsTestArgs([]), ["--test", "--test-reporter=spec", "tests/js/*.test.mjs"]);
});

test("a filter is a pattern of a test's name, taken literally", () => {
    assert.deepEqual(jsTestArgs(["utils.fsm", "rc.exe"]),
        ["--test", "--test-reporter=spec", "--test-name-pattern=/utils\\.fsm/", "--test-name-pattern=/rc\\.exe/",
            "tests/js/*.test.mjs"]);
    assert.ok(jsTestArgs(["a/b (c)"]).includes("--test-name-pattern=/a\\/b \\(c\\)/"));
});

const green = "✔ one (0.4ms)\n✔ two (0.1ms)\n✔ other.test.mjs (120ms)\nℹ tests 3\nℹ pass 3\nℹ fail 0\n";

test("all passed: a line with the number of tests, the files of tests not counted", () => {
    assert.deepEqual(summarizeJsRun(0, green), { ok: true, text: "JS tests: 2 passed" });
});

test("a filter that names no test is told, not passed in silence", () => {
    const output = "✔ other.test.mjs (120ms)\nℹ tests 1\nℹ pass 1\n";
    assert.deepEqual(summarizeJsRun(0, output, ["zzz"]), { ok: true, text: "JS tests: no test matches zzz" });
});

test("failed: what failed, from the list of failing tests, not the passed ones", () => {
    const output = "✔ good (0.4ms)\n✖ bad (0.6ms)\nℹ tests 2\nℹ fail 1\n\n✖ failing tests:\n\ntest at a.test.mjs:3:1\n✖ bad (0.6ms)\n  AssertionError: 1 !== 2\n";
    const { ok, text } = summarizeJsRun(1, output);
    assert.equal(ok, false);
    assert.match(text, /^✖ failing tests:/);
    assert.match(text, /AssertionError: 1 !== 2/);
    assert.doesNotMatch(text, /good/);
    assert.match(text, /JS tests: 1 failed/);
});

test("a run that failed without a list of failing tests shows its whole output", () => {
    const { ok, text } = summarizeJsRun(1, "SyntaxError: bad\n");
    assert.equal(ok, false);
    assert.match(text, /SyntaxError: bad/);
});

test("NO_DUB_HOOKS says the hooks of dub are off: scripts/test.mjs runs the steps itself", () => {
    assert.equal(noHooksVariable, "NO_DUB_HOOKS");
    assert.equal(hooksOff({ NO_DUB_HOOKS: "1" }), true);
    assert.equal(hooksOff({}), false);
    assert.equal(hooksOff({ NO_DUB_HOOKS: "" }), false);
});

test("as a hook with the hooks off it does nothing", () => {
    const result = spawnSync(process.execPath, [script, "--hook"], {
        encoding: "utf8", env: { ...process.env, NO_DUB_HOOKS: "1" } });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, "");
});
