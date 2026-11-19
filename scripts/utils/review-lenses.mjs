// Which lenses of the review (.ai/workflows/review.md) a change needs, by the files it touches:
// the rules always, architecture for a change across packages (or of the composition root),
// performance and threads for the indexing, the formats, the filters and the hot rows of the log
// table, UX for what the user sees. `node scripts/utils/review-lenses.mjs [base]`
// prints { base, paths, lenses } as JSON for the change of the current branch against `base`
// (default master) plus the uncommitted and untracked files; on `base` itself, the uncommitted
// ones only.
import { spawnSync } from "node:child_process";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

/// Every lens, in the order they are reported
export const lenses = ["rules", "architecture", "performance", "ux"];

/// The lenses a change of `paths` (from the project root) needs, in the order of `lenses`
export function lensesFor(paths) {
    if (paths.length === 0) return [];
    const needed = new Set(["rules"]);
    const layers = new Set(paths.map(layerOf).filter(layer => layer !== null));
    if (layers.size > 1 || paths.some(path => compositionPaths.some(pattern => pattern.test(path))))
        needed.add("architecture");
    for (const path of paths) {
        if (performancePaths.some(pattern => pattern.test(path))) needed.add("performance");
        if (uxPaths.some(pattern => pattern.test(path)) && !notUxPaths.some(pattern => pattern.test(path)))
            needed.add("ux");
    }
    return lenses.filter(lens => needed.has(lens));
}

// The layer of the code a file belongs to: a package of source/ or the script of the window;
// null for tests, docs, scripts and the rest, which don't make a change cross a boundary
function layerOf(path) {
    const pkg = /^source\/([^/]+)\//.exec(path);
    if (pkg) return pkg[1];
    if (/^resources\/.*\.(js|htm)$/.test(path)) return "script";
    return null;
}

// What puts the packages together: main() and the build
const compositionPaths = [/^source\/app\.d$/, /^dub\.sdl$/];

// The indexing and its threads, the formats and the filters (called from several threads, for
// every record), the rows of the log tables (rendered for every row on screen while scrolling)
const performancePaths = [
    /^source\/(domain|formats|log_core|utils)\//,
    /^source\/ui\/(main_window|app_session)\.d$/,
    /^resources\/(log-table-view|log-table-look|log-table-gesture|row-selection|rule-colors)\.js$/,
    /^resources\/table\.css$/,
    /^scripts\/utils\/bench_/
];

// What the user sees and does: the pages, styles and scripts of the window, their texts, the menu
const uxPaths = [
    /^resources\/.*\.(htm|css|js|json)$/,
    /^source\/ui\/app_menu\.d$/
];
// Bridges with no look of their own
const notUxPaths = [/^resources\/(backend|platform)\.js$/];

// The files of the change: the branch against `base`, the uncommitted and the untracked ones
function changedPaths(base) {
    const git = args => {
        const result = spawnSync("git", args, { encoding: "utf8" });
        if (result.status !== 0) throw new Error(`git ${args.join(" ")}: ${result.stderr.trim()}`);
        return result.stdout.split("\n").filter(line => line !== "");
    };
    const branch = git(["rev-parse", "--abbrev-ref", "HEAD"])[0];
    const committed = branch === base ? [] : git(["diff", "--name-only", `${base}...HEAD`]);
    const paths = [...committed, ...git(["diff", "--name-only", "HEAD"]),
        ...git(["ls-files", "--others", "--exclude-standard"])];
    return [...new Set(paths)].sort();
}

// run, not imported (by the tests)
if (process.argv[1] && fileURLToPath(import.meta.url) === realpathSync(process.argv[1])) {
    process.chdir(fileURLToPath(new URL("../..", import.meta.url))); // the project root
    const base = process.argv[2] ?? "master";
    const paths = changedPaths(base);
    console.log(JSON.stringify({ base, paths, lenses: lensesFor(paths) }, null, 2));
}
