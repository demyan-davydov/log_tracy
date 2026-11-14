// The D unittests without a name of their own: every unittest has an @("<subject>: <what it
// checks>") before it, the name unit-threaded's runner reports and filters by
// (.ai/rules/tests.md). Comments are left out: a unittest in one is no test. Run by the JS tests:
// tests/js/d-test-names.test.mjs.
import { readFileSync, readdirSync } from "node:fs";
import { join, relative } from "node:path";
import { withoutComments } from "./i18n-extract.mjs";

// what may stand between a test's name and the word unittest: other attributes
const attribute = String.raw`(?:@\w+(?:\([^)]*\))?|pure|nothrow|static|private|public|package|protected)`;
// a name, then attributes, up to the end of the text before the word
const namedBefore = new RegExp(String.raw`@\(\s*"(?:[^"\\]|\\.)*"\s*\)(?:\s*${attribute})*\s*$`);

/// The lines of the unittests of D `source` that have no name.
export function unnamedUnittests(source) {
    const code = withoutComments(source, "d");
    const lines = [];
    for (const m of code.matchAll(/\bunittest\b/g)) {
        const before = code.slice(0, m.index);
        if (/\b(?:version|debug)\s*\(\s*$/.test(before)) continue; // version (unittest): no test
        if (!namedBefore.test(before)) lines.push(before.split("\n").length);
    }
    return lines;
}

/// The unnamed unittests of the D files under `root`: "<file>:<line>", the file relative to `root`.
export function scanUnnamedUnittests(root) {
    return readdirSync(root, { recursive: true, withFileTypes: true })
        .filter((e) => e.isFile() && e.name.endsWith(".d"))
        .map((e) => join(e.parentPath ?? e.path, e.name))
        .sort()
        .flatMap((file) => unnamedUnittests(readFileSync(file, "utf8"))
            .map((line) => `${relative(root, file)}:${line}`));
}
