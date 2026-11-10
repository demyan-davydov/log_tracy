// The pure part of `node scripts/build.mjs bench` (scripts/bench.mjs): its command line, the
// numbers read from the output of a benchmark, the table of both sides.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { parseBenchArgs, parseMetrics, compareRuns, formatComparison, benchCompileArgs, benchUsage, runOrder }
    from "../../scripts/bench.mjs";

test("bench measures bench_rows against master three times by default, on a generated log", () => {
    assert.deepEqual(parseBenchArgs([]),
        { log: null, benchArgs: [], against: "master", bench: "rows", runs: 3, json: null, help: false });
    assert.deepEqual(parseBenchArgs(["big.dlt", "failed", "value"]),
        { log: "big.dlt", benchArgs: ["failed", "value"], against: "master", bench: "rows", runs: 3, json: null,
            help: false });
});

test("bench takes the ref, the benchmark, the runs and a JSON file; after -- everything is the benchmark's", () => {
    assert.deepEqual(parseBenchArgs(["--against", "v1.2", "--bench=index", "--runs", "5", "--json", "out.json",
        "big.dlt", "error", "--", "--rounds=5", "x"]),
    { log: "big.dlt", benchArgs: ["error", "--rounds=5", "x"], against: "v1.2", bench: "index", runs: 5,
        json: "out.json", help: false });
    assert.equal(parseBenchArgs(["--help"]).help, true);
    assert.throws(() => parseBenchArgs(["--bench", "scroll"]), /scroll/);
    assert.throws(() => parseBenchArgs(["--runs", "0"]), /--runs/);
    assert.throws(() => parseBenchArgs(["--runs", "two"]), /--runs/);
    assert.throws(() => parseBenchArgs(["--against"]), /--against/);
    assert.throws(() => parseBenchArgs(["--fast"]), /--fast/);
    for (const option of ["--against", "--bench", "--runs", "--json", "--help"]) assert.match(benchUsage, new RegExp(option));
});

test("the numbers of a run are those with a unit, named by their part of the line and the header above it", () => {
    const output = [
        "  memory at start:                footprint     1.3 MB (peak     1.3 MB), resident     2.7 MB",
        "records: 2315001, loaded in 577 ms",
        "main view, no search:            183.4 ns/row",
        'search "failed": 106442 results (4.6%), found in 85 ms',
        "  main view, rows only:          184.0 ns/row",
        'search "value": 183462 results (7.9%), found in 81 ms',
        "  main view, rows only:          190.5 ns/row",
    ].join("\n");
    assert.deepEqual(parseMetrics(output), [
        { name: "memory at start: footprint # MB", unit: "MB", value: 1.3 },
        { name: "memory at start: peak # MB", unit: "MB", value: 1.3 },
        { name: "memory at start: resident # MB", unit: "MB", value: 2.7 },
        { name: "records: loaded in # ms", unit: "ms", value: 577 },
        { name: "main view, no search: # ns/row", unit: "ns/row", value: 183.4 },
        { name: 'search "failed": found in # ms', unit: "ms", value: 85 },
        { name: 'search "failed" › main view, rows only: # ns/row', unit: "ns/row", value: 184 },
        { name: 'search "value": found in # ms', unit: "ms", value: 81 },
        { name: 'search "value" › main view, rows only: # ns/row', unit: "ns/row", value: 190.5 },
    ]);
});

test("a number met several times in a run (rounds) counts by its best, the sides by their median", () => {
    const run = (filter, search) => `filter: 10 shown in ${filter[0]} ms\nfilter: 10 shown in ${filter[1]} ms\n`
        + `search: 5 found in ${search} ms\n`;
    const comparison = compareRuns([run([30, 20], 50), run([22, 21], 40), run([25, 40], 60)],
        [run([11, 12], 80), run([10, 13], 90), run([12, 12], 100)]);
    assert.deepEqual(comparison, [
        { name: "filter: … shown in # ms", unit: "ms", base: [20, 21, 25], change: [11, 10, 12],
            baseMedian: 21, changeMedian: 11, diff: (11 - 21) / 21, noise: false },
        { name: "search: … found in # ms", unit: "ms", base: [50, 40, 60], change: [80, 90, 100],
            baseMedian: 50, changeMedian: 90, diff: (90 - 50) / 50, noise: false },
    ]);
});

test("a number one side lacks is in the table without a difference", () => {
    const comparison = compareRuns(["a: 1 ms\n"], ["a: 2 ms\nb: 3 ms\n"]);
    assert.deepEqual(comparison.map((row) => [row.name, row.baseMedian, row.changeMedian, row.diff]),
        [["a: # ms", 1, 2, 1], ["b: # ms", null, 3, null]]);
});

test("a line of several numbers names each by its own part, between commas, semicolons and brackets", () => {
    assert.deepEqual(parseMetrics("search summary: min 10 ms, median 12 ms, max 15 ms; last third / first third: 1.02; "
        + "GC: 3 collections, 40 MB used\n").map((metric) => metric.name), ["search summary: min # ms",
        "search summary: median # ms", "search summary: max # ms", "search summary: # MB used"]);
});

test("the table shows the median and the spread of each side and the difference in percent", () => {
    const table = formatComparison(compareRuns(["a: 100 ms\n", "a: 110 ms\n", "a: 104 ms\n"],
        ["a: 90 ms\n", "a: 91 ms\n", "a: 95 ms\n"]), "master");
    assert.match(table, /master/);
    assert.match(table, /a: # ms/);
    assert.match(table, /104 \(100–110\)/);
    assert.match(table, /91 \(90–95\)/);
    assert.match(table, /-12\.5%/);
});

test("a benchmark is compiled optimized with the flags of dub.sdl, each side in its own folders", () => {
    const args = benchCompileArgs(["-preview=in", "-I/w/source/"], "rows", "/p/build/tools/bench_rows_master",
        "/p/build/tools/obj/bench_rows_master");
    assert.ok(args.includes("-O3") && args.includes("-release") && args.includes("-enable-inlining"));
    assert.ok(args.includes("-i") && args.includes("-preview=in") && args.includes("-I/w/source/"));
    assert.ok(args.includes("scripts/bench_rows.d"));
    assert.ok(args.includes("-of=/p/build/tools/bench_rows_master"));
    assert.ok(args.includes("-od=/p/build/tools/obj/bench_rows_master"));
    assert.ok(benchCompileArgs([], "index", "x", "y").includes("scripts/bench_index.d"));
});

test("the sides take turns going first, so neither always meets a cold cache or a cold machine", () => {
    assert.deepEqual(runOrder(1), [[0, 1]]);
    assert.deepEqual(runOrder(4), [[0, 1], [1, 0], [0, 1], [1, 0]]);
});

test("a difference within the spread of both sides is marked as noise", () => {
    const rows = compareRuns(["a: 100 ms\nb: 100 ms\n", "a: 104 ms\nb: 102 ms\n"],
        ["a: 103 ms\nb: 80 ms\n", "a: 108 ms\nb: 82 ms\n"]);
    assert.deepEqual(rows.map((row) => row.noise), [true, false]);
    assert.equal(compareRuns(["a: 1 ms\n"], ["a: 2 ms\n"])[0].noise, false); // one run: no spread to tell
    const table = formatComparison(rows, "master").split("\n");
    assert.match(table.find((line) => line.startsWith("a:")), /~ noise/);
    assert.doesNotMatch(table.find((line) => line.startsWith("b:")), /noise/);
});

test("the first word is the log only when it is a file or looks like one; else the words are the benchmark's", () => {
    const isFile = (path) => path === "big";
    assert.deepEqual([parseBenchArgs(["timeout", "retry"], isFile).log, parseBenchArgs(["timeout", "retry"], isFile).benchArgs],
        [null, ["timeout", "retry"]]);
    assert.equal(parseBenchArgs(["big", "x"], isFile).log, "big");
    assert.equal(parseBenchArgs(["logs/missing", "x"], isFile).log, "logs/missing"); // told it is missing, not searched
    assert.equal(parseBenchArgs(["missing.dlt"], isFile).log, "missing.dlt");
});

test("a header without a colon names its lines without its numbers, the same in every run", () => {
    const names = (n) => parseMetrics(`round ${n} took ${n * 10} ms\n  rows: 5 ns/row\n`).map((metric) => metric.name);
    assert.deepEqual(names(1), names(2));
    assert.deepEqual(names(1), ["round … took # ms", "round … took … ms › rows: # ns/row"]);
});

test("a difference that rounds to nothing has no sign", () => {
    const table = formatComparison([{ name: "a: # ms", unit: "ms", base: [100], change: [99.99], baseMedian: 100,
        changeMedian: 99.99, diff: -0.0001, noise: false }], "master");
    assert.match(table, / 0\.0%/);
    assert.doesNotMatch(table, /-0\.0%/);
});
