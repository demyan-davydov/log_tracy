// Runs the JS tests of tests/js and tells the result in a line when all passed, else what
// failed: the output of the spec reporter is a line per test, 500 of them. dub runs it after
// the D unittests (postRunCommands of dub.sdl, with --hook), scripts/build.mjs test runs it
// itself. Arguments: test names to run (each a pattern, taken literally), --verbose for the
// whole output, --hook when dub runs it. Tests: tests/js/test-js-script.test.mjs.
import { spawnSync } from "node:child_process";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { hooksOff } from "./hooks.mjs";

/// The arguments of node that run the JS tests, those whose names match one of `filters` if
/// there are any. The files are named by a pattern: node 22 takes no folder; spec, not node's
/// default: before node 23 that is TAP when the output is no terminal.
export function jsTestArgs(filters) {
    const patterns = filters.map((filter) => `--test-name-pattern=/${filter.replace(/[\\^$.*+?()[\]{}|/]/g, "\\$&")}/`);
    return ["--test", "--test-reporter=spec", ...patterns, "tests/js/*.test.mjs"];
}

/// The result of a run (its exit `status` and spec `output`) as what to tell: `ok` and the
/// `text`. A file of tests shows in the output as a passed test of its own, not counted.
export function summarizeJsRun(status, output, filters = []) {
    const lines = output.split(/\r?\n/);
    const passed = lines.filter((line) => /^✔ .* \([\d.]+m?s\)$/.test(line) && !/\.test\.mjs \([\d.]+m?s\)$/.test(line)).length;
    if (status === 0) {
        return { ok: true, text: passed === 0 && filters.length > 0
            ? `JS tests: no test matches ${filters.join(" ")}` : `JS tests: ${passed} passed` };
    }
    const failing = lines.findIndex((line) => line === "✖ failing tests:");
    const failed = /^ℹ fail (\d+)$/m.exec(output)?.[1];
    const what = failing >= 0 ? lines.slice(failing).join("\n").trimEnd() : output.trimEnd();
    return { ok: false, text: `${what}\nJS tests: ${failed ?? "some"} failed` };
}

function main(argv) {
    const hook = argv.includes("--hook");
    const verbose = argv.includes("--verbose");
    const filters = argv.filter((arg) => !arg.startsWith("--"));
    if (hook && hooksOff(process.env)) return 0;
    process.chdir(fileURLToPath(new URL("../..", import.meta.url))); // the project root
    if (verbose) return spawnSync(process.execPath, jsTestArgs(filters), { stdio: "inherit" }).status ?? 1;
    const result = spawnSync(process.execPath, jsTestArgs(filters), { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
    const { ok, text } = summarizeJsRun(result.status ?? 1, `${result.stdout}${result.stderr}`, filters);
    (ok ? console.log : console.error)(text);
    return ok ? 0 : 1;
}

// run, not imported (by the tests); the module's path has its symbolic links resolved, the
// command line's may not
if (process.argv[1] && fileURLToPath(import.meta.url) === realpathSync(process.argv[1]))
    process.exitCode = main(process.argv.slice(2));
