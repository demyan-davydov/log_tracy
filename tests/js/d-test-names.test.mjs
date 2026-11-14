// The D unittests without a name of their own (scripts/utils/d-test-names.mjs): every one has
// an @("...") before it, the name unit-threaded's runner reports and filters by (.ai/rules/tests.md).
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { unnamedUnittests, scanUnnamedUnittests } from "../../scripts/utils/d-test-names.mjs";

test("a unittest without @(\"...\") before it is unnamed: its line", () => {
    const source = `module a;

@("f: named")
unittest
{
}

unittest
{
}

/// a comment is no name
unittest {}
`;
    assert.deepEqual(unnamedUnittests(source), [8, 13]);
});

test("a name on the same line, other attributes after it and quotes in it are names", () => {
    const source = `@("parseDltItem: verbose bool argument") unittest {}
@("f: \\"+\\" alone") @safe pure unittest {}
@("g: x")
@system
unittest {}
`;
    assert.deepEqual(unnamedUnittests(source), []);
});

test("version (unittest), a unittest in a comment and a word that only contains it are no tests", () => {
    const source = `version (unittest)
{
    import std.conv : to;
}
version(unittest) import std.stdio;
/*@("copyUtf8to: invalid utf8")
unittest
{
}*/
// unittest of the past
enum getUnitTests = 1;
`;
    assert.deepEqual(unnamedUnittests(source), []);
});

test("every D unittest of the project has a name", () => {
    const root = join(fileURLToPath(new URL("../..", import.meta.url)), "source");
    assert.deepEqual(scanUnnamedUnittests(root), [], "name them: @(\"<subject>: <what it checks>\")");
});
