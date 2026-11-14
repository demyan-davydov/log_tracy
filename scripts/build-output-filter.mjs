// The filter of the output of scripts/build.mjs (and run.mjs) with `--brief`: of what a step
// prints (dub, ldc2, a test program, node --test) it keeps the errors and failed tests with
// their places, nothing of what went well. build.mjs writes the whole output to
// build/brief.log. Tests: tests/js/build-output-filter.test.mjs.

/// The most lines a step tells; the rest are counted.
export const filterLimit = 60;

/// How many last lines a failed step tells when none of its lines tells the cause.
const tailLines = 15;

// what the tests of the project print must not match: "Error opening file ..." does not.
// The lines that tell the cause of a failure:
const compileError = /^.+\.di?\(\d+(,\d+)?\): (Error|Warning|Deprecation): /;
// what goes with a compile error, indented after the place: "instantiated from here: ..."
const compileContext = /^.+\.di?\(\d+(,\d+)?\):\s{2,}\S/;
const linkCause = /^Undefined symbols|(^|\/)ld(64)?(\.lld)?: |error LNK\d+/;
// The lines that only say a step failed: the last lines of its output go with them.
const summary = [
    /^Error (Program exited with code|\S+ failed with exit code)/, // dub
    /linker command failed|^collect2: error|^Error: .* failed with status/,
    /^ℹ (fail|cancelled) [1-9]/, // node --test
    // unit-threaded's runner (dub test): a line per failed test, then its summary
    /^Test '.*' failed\.$/,
    /^\d+ test\(s\) run, [1-9]\d* failed\.$/,
];
// the summary of druntime's runner (test --module): glued to a line of a test's own output at times
const failedModules = /\d+\/\d+ modules FAILED unittests/;
// the report of a failure, at the start of a line (unit-threaded indents all but the first by
// four spaces): core.exception.AssertError@source/a.d(12): message
const exception = /^(?: {4})?([\w.]*?)(\w*(?:Error|Exception|Throwable))@(.+?)\((\d+)\): (.*)$/;
const stackSeparator = "----------------";
const maxMessageLines = 5;
const maxFrames = 4;

/// The lines of `text` (a step's whole output) worth telling. `failed`: the step exited with
/// an error. `root`: the project's folder, cut off the paths. `log`: where the whole output
/// is, named when lines are left out.
export function filterBuildOutput(text, { failed = false, root = "", log = "build/brief.log" } = {}) {
    const lines = text.split(/\r?\n/);
    const { isOurs, cut } = projectPaths(root);
    const kept = [];
    let causeTold = false; // a line that tells why, not only that the step failed
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        if (line === "✖ failing tests:") {
            kept.push(...nodeFailures(lines.slice(i + 1), isOurs, cut));
            causeTold = true;
            break; // node's report ends its output
        }
        // a test that passed may print an exception it expects: only a failed step has failures
        const thrown = failed ? exception.exec(line) : null;
        if (compileError.test(line) || compileContext.test(line) || linkCause.test(line)) {
            kept.push(cut(line));
            causeTold = true;
        } else if (summary.some((pattern) => pattern.test(line))) kept.push(cut(line));
        else if (failedModules.test(line)) kept.push(failedModules.exec(line)[0]);
        else if (thrown) {
            const [, , name, file, lineNumber, message] = thrown;
            kept.push(`${cut(file)}(${lineNumber}): ${name}: ${message}`);
            i = druntimeTrace(lines, i + 1, kept, isOurs, cut) - 1;
            causeTold = true;
        }
    }
    if (failed && !causeTold) {
        const told = new Set(kept);
        kept.push(...lines.filter((line) => line.trim() !== "").slice(-tailLines).map(cut)
            .filter((line) => !told.has(line)));
    }
    if (kept.length > filterLimit)
        return [...kept.slice(0, filterLimit), `… ${kept.length - filterLimit} more lines: ${log}`];
    return kept;
}

/// Whether a line names a file of the project (`root`), as a path or as the file URL of node's
/// frames, and the line with those prefixes cut off. A path that climbs out of the project
/// (dub's packages: /p/dlt/../../.dub/...) is not the project's.
function projectPaths(root) {
    if (root === "") return { isOurs: () => false, cut: (line) => line };
    // file:///p/dlt/ on macOS and Linux, file:///C:/p/dlt/ on Windows, spaces as %20
    const url = encodeURI(`file://${root.startsWith("/") ? "" : "/"}${root.replaceAll("\\", "/")}/`);
    const prefixes = [url, `${root}/`, `${root}\\`];
    return {
        isOurs: (line) => prefixes.some((prefix) => {
            const at = line.indexOf(prefix);
            return at >= 0 && !line.startsWith("..", at + prefix.length);
        }),
        cut: (line) => prefixes.reduce((cutLine, prefix) => cutLine.replaceAll(prefix, ""), line),
    };
}

/// After the first line of a D exception: the rest of its message, then the frames of its
/// stack in the project's code. Gives the index of the first line after them.
function druntimeTrace(lines, start, kept, isOurs, cut) {
    // the rest of the message runs to the stack: without one, the lines after are not its
    const separator = lines.slice(start, start + maxMessageLines + 1).indexOf(stackSeparator);
    if (separator < 0) return start;
    for (let n = 0; n < separator; n++) kept.push(`  ${lines[start + n]}`);
    let i = start + separator;
    let frames = 0;
    // a frame: "<file>[:<line>] <function> [0x<address>]", "??:?" for code without debug info
    for (i++; i < lines.length && /\[0x[0-9a-fA-F]+\]$/.test(lines[i]); i++) {
        const frame = /^(\S+:\d+) (.*?) \[0x[0-9a-fA-F]+\]$/.exec(lines[i]);
        if (frame && isOurs(frame[1]) && frames++ < maxFrames) kept.push(`    at ${cut(frame[1])} ${frame[2]}`);
    }
    return i;
}

/// The report of node --test after "✖ failing tests:": every line but the empty ones, node's
/// own frames and the fields of an error node prints after its stack ("{ code: ... }").
function nodeFailures(lines, isOurs, cut) {
    const kept = [];
    let fieldsEnd = null; // the line that closes the fields being skipped
    for (const line of lines) {
        if (fieldsEnd !== null) {
            if (line.startsWith("test at ")) fieldsEnd = null; // the next failure: kept below
            else {
                if (line === fieldsEnd) fieldsEnd = null;
                continue;
            }
        }
        if (line.trim() === "") continue;
        const frame = /^(\s+)at .*?( \{)?$/.exec(line);
        if (frame) {
            // the fields are indented two less than the message, which is two less than the frames
            if (frame[2]) fieldsEnd = `${" ".repeat(Math.max(0, frame[1].length - 4))}}`;
            if (isOurs(line)) kept.push(cut(frame[2] ? line.slice(0, -2) : line));
            continue;
        }
        kept.push(cut(line));
    }
    return kept;
}
