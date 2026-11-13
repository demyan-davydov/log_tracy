// Compiles the resource script of Windows (resources/app.rc: the icon of the program) into
// build/windows/app.res, which ldc2 links in: ldc2 takes a .res, not a .rc. dub runs it before
// every build on Windows (preBuildCommands of dub.sdl), so a plain `dub build` gets it too.
// rc.exe is the one on the PATH, else the one of the newest Windows SDK.
// Tests: tests/js/windows-res-script.test.mjs.
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, realpathSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const defaultKits = "C:\\Program Files (x86)\\Windows Kits\\10\\bin";

/// rc.exe of the newest SDK among the folders of `kits` (`entries`, "10.0.26100.0" and the
/// like; others are skipped) for the machine's architecture, null when there is none.
export function rcFromKits(kits, entries, arch) {
    const versions = entries.filter((entry) => /^\d+(\.\d+)+$/.test(entry));
    if (versions.length === 0) return null;
    const newest = versions.reduce((a, b) => (compareVersions(a, b) >= 0 ? a : b));
    return `${kits}\\${newest}\\${arch}\\rc.exe`;
}

function compareVersions(a, b) {
    const x = a.split(".").map(Number), y = b.split(".").map(Number);
    for (let i = 0; i < Math.max(x.length, y.length); i++)
        if ((x[i] ?? 0) !== (y[i] ?? 0)) return (x[i] ?? 0) - (y[i] ?? 0);
    return 0;
}

/// The arguments of rc.exe that compile `input` (.rc) into `output` (.res).
export function rcArgs(input, output) {
    return ["/nologo", "/fo", output, input];
}

/// rc.exe: the one on the PATH, else the newest of the Windows SDK; null when there is none.
function findRc() {
    if (spawnSync("where", ["rc.exe"], { stdio: "ignore" }).status === 0) return "rc.exe";
    const kits = process.env.WindowsSdkBinPath ?? defaultKits;
    if (!existsSync(kits)) return null;
    const rc = rcFromKits(kits, readdirSync(kits), process.arch === "arm64" ? "arm64" : "x64");
    return rc !== null && existsSync(rc) ? rc : null;
}

function main() {
    const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
    const input = join(root, "resources", "app.rc");
    const output = join(root, "build", "windows", "app.res");
    const rc = findRc();
    if (rc === null) {
        console.error("No rc.exe, the resource compiler of the Windows SDK: install the Windows SDK "
            + "(Visual Studio's \"Desktop development with C++\") (docs/building.md).");
        process.exit(1);
    }
    mkdirSync(dirname(output), { recursive: true });
    // in the folder of the .rc: the files it names (icons/app.ico) are found from there
    const result = spawnSync(rc, rcArgs(input, output), { cwd: dirname(input), stdio: "inherit" });
    if (result.error) {
        console.error(`can't run ${rc}: ${result.error.message}`);
        process.exit(1);
    }
    process.exit(result.status ?? 1);
}

// run, not imported (by the tests)
if (process.argv[1] && fileURLToPath(import.meta.url) === realpathSync(process.argv[1])) main();
