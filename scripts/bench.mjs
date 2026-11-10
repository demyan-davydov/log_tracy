// The pure part of `node scripts/build.mjs bench`, which measures the working tree against a
// ref (master) with one benchmark of scripts/ (bench_rows.d, bench_index.d): its command line,
// the numbers read from what a benchmark prints, their comparison and its table. The running
// (a worktree of the ref, the builds, the runs): benchAgainst in build.mjs.
// Tests: tests/js/bench-script.test.mjs.

/// What `bench --help` prints.
export const benchUsage = `Measures this working tree against a ref (master) with one benchmark of scripts/:
builds both sides alike, runs them by turns on the same log, prints the numbers of both.

Usage: node scripts/build.mjs bench [log] [benchmark arguments] [options] [-- more arguments]

  log             the log to measure: a file, or a path or a name ending in .dlt, .log,
                  .txt; by default one the generator writes once into build/tools/ (DLT,
                  256 MB, seed 1), and the first word is the benchmark's
  benchmark arguments
                  rows: the words to search (by default: failed value);
                  index: [query] [text|regex] [ic|cs] (by default: error);
                  after -- the benchmark's own options too: -- --rounds=5

Options:
  --against REF   what to measure against (master): a branch, a tag, a commit
  --bench rows|index
                  scripts/bench_rows.d (scrolling, the default) or scripts/bench_index.d
                  (building the indexes); the working tree's file measures both sides
  --runs N        runs of each side (3), by turns: the median and the spread of each
  --json FILE     also writes the numbers of every run to FILE
  -h, --help      this help

A number met several times in one run (the rounds of bench_index) counts by its best. The
sides take turns going first, after the log is read once into the page cache; a difference
within the spreads of both sides is marked "~ noise".
`;

export const benches = ["rows", "index"];

/// The arguments of a benchmark when none are given.
export const defaultBenchArgs = { rows: ["failed", "value"], index: ["error"] };

/// A command line not understood: told without a stack (build.mjs's BuildError is the same).
export class BenchError extends Error {}

/// What `bench` is asked: `{ log, benchArgs, against, bench, runs, json, help }`, `log` null
/// for the generated one. The first word is the log when it is a file (`isFile`) or looks
/// like a path (a folder in it, or the extension of a log): a log missing is told rather than
/// searched for. The other words and everything after `--` are the benchmark's.
export function parseBenchArgs(argv, isFile = () => false) {
    const options = { log: null, benchArgs: [], against: "master", bench: "rows", runs: 3, json: null, help: false };
    const words = [];
    let afterDash = [];
    for (let i = 0; i < argv.length; i++) {
        const arg = argv[i];
        if (arg === "--") {
            afterDash = argv.slice(i + 1);
            break;
        }
        if (arg === "--help" || arg === "-h") {
            options.help = true;
            continue;
        }
        const option = ["--against", "--bench", "--runs", "--json"].find((name) => arg === name || arg.startsWith(`${name}=`));
        if (option === undefined) {
            if (arg.startsWith("-")) throw new BenchError(`unknown option ${arg} (the benchmark's own go after --)`);
            words.push(arg);
            continue;
        }
        const value = arg === option ? argv[++i] : arg.slice(option.length + 1);
        if (value === undefined || value === "") throw new BenchError(`${option} needs a value`);
        if (option === "--against") options.against = value;
        else if (option === "--json") options.json = value;
        else if (option === "--bench") {
            if (!benches.includes(value)) throw new BenchError(`unknown benchmark "${value}", expected one of: ${benches.join(", ")}`);
            options.bench = value;
        } else {
            const runs = Number(value);
            if (!Number.isInteger(runs) || runs < 1) throw new BenchError(`--runs needs a whole number from 1, got "${value}"`);
            options.runs = runs;
        }
    }
    if (words.length > 0 && (isFile(words[0]) || /[\\/]|\.(dlt|log|txt)$/i.test(words[0]))) options.log = words.shift();
    options.benchArgs = [...words, ...afterDash];
    return options;
}

const units = ["ns/row", "ms", "MB"];
const numberPattern = /\d+(?:\.\d+)?/g;

/// The numbers of the output of a benchmark that have a unit (ms, ns/row, MB), in order:
/// `{ name, unit, value }`. A line is its head (up to the first colon) and its parts after it,
/// between commas, semicolons and brackets; a number is named by the head and its part, spaces
/// collapsed, the number as "#" and any other number of the part as "…" (a count). An
/// indented line also takes the header above it (the head of the unindented line), so the
/// same step of two searches has two names.
export function parseMetrics(output) {
    const metrics = [];
    let header = null;
    for (const line of output.split(/\r?\n/)) {
        if (line.trim() === "") continue;
        const indented = /^\s/.test(line);
        const text = line.trim().replace(/\s+/g, " ");
        const colon = text.indexOf(":");
        const head = colon < 0 ? null : text.slice(0, colon);
        // a header without a colon is the whole line, its numbers as "…": the same in every run
        if (!indented) header = head ?? text.replace(numberPattern, "…");
        const prefix = (indented && header !== null ? `${header} › ` : "") + (head === null ? "" : `${head}: `);
        for (const part of (colon < 0 ? text : text.slice(colon + 1)).split(/[,;()]/)) {
            const numbers = [...part.matchAll(numberPattern)];
            numbers.forEach((match, k) => {
                const after = part.slice(match.index + match[0].length).trimStart();
                const unit = units.find((candidate) => after.startsWith(candidate)
                    && !/[A-Za-z]/.test(after.charAt(candidate.length)));
                if (unit === undefined) return;
                let name = "";
                let from = 0;
                numbers.forEach((other, j) => {
                    name += part.slice(from, other.index) + (j === k ? "#" : "…");
                    from = other.index + other[0].length;
                });
                name += part.slice(from);
                metrics.push({ name: prefix + name.trim(), unit, value: Number(match[0]) });
            });
        }
    }
    return metrics;
}

function median(values) {
    const sorted = [...values].sort((a, b) => a - b);
    const middle = Math.floor(sorted.length / 2);
    return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

/// The best of each name in one run (rounds print the same line several times): a Map in
/// the order the names first come.
function bestOfRun(output) {
    const best = new Map();
    for (const { name, unit, value } of parseMetrics(output)) {
        const known = best.get(name);
        if (known === undefined) best.set(name, { unit, value });
        else known.value = Math.min(known.value, value);
    }
    return best;
}

/// The numbers of the runs of both sides (`baseOutputs` the ref's, `changeOutputs` the
/// working tree's), one row a name in the order they first come: the best of each run, the
/// median of each side and the difference of the medians as a share of the ref's (null when
/// a side lacks the number); `noise` when both sides ran more than once and their spreads
/// overlap: the difference is likely chance.
export function compareRuns(baseOutputs, changeOutputs) {
    const rows = new Map();
    const collect = (outputs, side) => {
        for (const output of outputs) {
            for (const [name, { unit, value }] of bestOfRun(output)) {
                if (!rows.has(name)) rows.set(name, { name, unit, base: [], change: [] });
                rows.get(name)[side].push(value);
            }
        }
    };
    collect(baseOutputs, "base");
    collect(changeOutputs, "change");
    return [...rows.values()].map((row) => {
        const baseMedian = row.base.length ? median(row.base) : null;
        const changeMedian = row.change.length ? median(row.change) : null;
        const diff = baseMedian === null || changeMedian === null || baseMedian === 0 ? null
            : (changeMedian - baseMedian) / baseMedian;
        const noise = row.base.length > 1 && row.change.length > 1
            && Math.max(...row.base) >= Math.min(...row.change) && Math.max(...row.change) >= Math.min(...row.base);
        return { ...row, baseMedian, changeMedian, diff, noise };
    });
}

function formatNumber(value) {
    return Number.isInteger(value) ? String(value) : value.toFixed(1);
}

function formatSide(values, middle) {
    if (middle === null) return "—";
    const low = Math.min(...values);
    const high = Math.max(...values);
    return low === high ? formatNumber(middle)
        : `${formatNumber(middle)} (${formatNumber(low)}–${formatNumber(high)})`;
}

/// A share as a signed percent to a tenth; one that rounds to nothing has no sign ("-0.0%"
/// would read as a gain).
function formatPercent(share) {
    const text = (share * 100).toFixed(1);
    if (Number(text) === 0) return "0.0%";
    return `${share > 0 ? "+" : ""}${text}%`;
}

/// The table of a comparison: a row a number, the median (and the spread) of the ref and of
/// the working tree and the difference in percent, less is better for every unit; "~ noise"
/// after a difference within the spreads.
export function formatComparison(rows, against) {
    const header = ["", against, "this tree", "difference"];
    const lines = rows.map((row) => [row.name, formatSide(row.base, row.baseMedian),
        formatSide(row.change, row.changeMedian),
        row.diff === null ? "" : `${formatPercent(row.diff)}${row.noise ? " ~ noise" : ""}`]);
    const widths = header.map((cell, i) => Math.max(cell.length, ...lines.map((line) => line[i].length)));
    const format = (cells) => cells.map((cell, i) => i === 0 ? cell.padEnd(widths[i]) : cell.padStart(widths[i]))
        .join("  ").trimEnd();
    return [format(header), ...lines.map(format)].join("\n") + "\n";
}

/// The arguments of ldc2 for a benchmark (`bench` rows or index) of one side, `dubFlags`
/// the flags and import paths of dub.sdl as dub describes them in that side's tree: optimized
/// as docs/performance.md measures, the program at `program`, its objects in `objects`.
export function benchCompileArgs(dubFlags, bench, program, objects) {
    return ["-O3", "-release", "-enable-inlining", "-i", ...dubFlags, `scripts/bench_${bench}.d`,
        `-of=${program}`, `-od=${objects}`, "-oq"];
}

/// The order of the sides (0 the ref, 1 the working tree) in each run: by turns, so a cold
/// page cache or a machine warming up doesn't always fall on the same side.
export function runOrder(runs) {
    return Array.from({ length: runs }, (_, r) => (r % 2 === 0 ? [0, 1] : [1, 0]));
}
