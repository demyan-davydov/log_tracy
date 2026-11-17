// The checks and the plan of scripts/install-deps.mjs: what a system lacks for a build, and
// the commands that install it. Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { checkComponent, componentsOf, detectSystem, formatReport, installHint, newestCompiler, parseVersion,
    pathHas, planInstall, runSteps, versionAtLeast } from "../../scripts/install-deps.mjs";

const has = (...programs) => (program) => programs.includes(program);
const ids = (components) => components.map((c) => c.id);

test("parseVersion: the first dotted number of the output of a tool", () => {
    assert.deepEqual(parseVersion("v22.1.0"), [22, 1, 0]);
    assert.deepEqual(parseVersion("LDC - the LLVM D compiler (1.43.0):\n  based on DMD v2.113.1"), [1, 43, 0]);
    assert.deepEqual(parseVersion("DUB version 1.38.0, built on Jan 1 2026"), [1, 38, 0]);
    assert.deepEqual(parseVersion("git-lfs/3.5"), [3, 5, 0]);
    assert.equal(parseVersion("no digits"), null);
});

test("versionAtLeast: compares the parts in turn, not as text", () => {
    assert.equal(versionAtLeast([1, 43, 0], [1, 43]), true);
    assert.equal(versionAtLeast([1, 9, 0], [1, 43]), false);
    assert.equal(versionAtLeast([22, 0, 0], [22]), true);
    assert.equal(versionAtLeast([20, 11, 1], [22]), false);
    assert.equal(versionAtLeast([2, 0, 0], [1, 43]), true);
});

test("detectSystem: the package manager of each system, the first one found", () => {
    assert.deepEqual(detectSystem({ platform: "darwin", has: has("brew") }), { os: "macos", manager: "brew" });
    assert.deepEqual(detectSystem({ platform: "darwin", has: has() }), { os: "macos", manager: null });
    assert.deepEqual(detectSystem({ platform: "linux", has: has("dnf", "pacman") }), { os: "linux", manager: "dnf" });
    assert.deepEqual(detectSystem({ platform: "linux", has: has("apt-get") }), { os: "linux", manager: "apt" });
    assert.deepEqual(detectSystem({ platform: "linux", has: has("pacman") }), { os: "linux", manager: "pacman" });
    assert.deepEqual(detectSystem({ platform: "win32", has: has("winget") }), { os: "windows", manager: "winget" });
    assert.throws(() => detectSystem({ platform: "freebsd", has: has() }), /freebsd/);
});

test("componentsOf: what each system needs for a build, and the tools of development only on request", () => {
    const mac = ids(componentsOf({ os: "macos", manager: "brew" }, {}));
    assert.deepEqual(mac, ["node", "git", "git-lfs", "git-lfs-setup", "ldc2", "dub", "toolchain"]);
    const linux = ids(componentsOf({ os: "linux", manager: "apt" }, {}));
    assert.deepEqual(linux, ["node", "git", "git-lfs", "git-lfs-setup", "ldc2", "dub", "toolchain", "curl", "gtk3"]);
    const windows = ids(componentsOf({ os: "windows", manager: "winget" }, {}));
    assert.deepEqual(windows, ["node", "git", "git-lfs", "git-lfs-setup", "ldc2", "dub", "toolchain"]);
    assert.deepEqual(ids(componentsOf({ os: "linux", manager: "apt" }, { dev: true })).slice(-3),
        ["xdotool", "imagemagick", "gdb"]);
    assert.equal(ids(componentsOf({ os: "macos", manager: "brew" }, { dev: true })).length, mac.length);
});

test("checkComponent: found, missing, too old, and a tool that can't be started", () => {
    const ldc = componentsOf({ os: "macos", manager: "brew" }, {}).find((c) => c.id === "ldc2");
    const probe = (status, stdout) => () => ({ status, stdout });
    assert.deepEqual(checkComponent(ldc, probe(0, "LDC - the LLVM D compiler (1.43.0):")),
        { component: ldc, state: "ok", version: "1.43.0" });
    assert.equal(checkComponent(ldc, probe(0, "LDC - the LLVM D compiler (1.30.0):")).state, "old");
    assert.equal(checkComponent(ldc, probe(1, "")).state, "missing");
    assert.equal(checkComponent(ldc, () => ({ status: null, stdout: "", error: new Error("ENOENT") })).state, "missing");
});

test("checkComponent: a check that wants a non-empty answer (vswhere) is missing when it is empty", () => {
    const toolchain = componentsOf({ os: "windows", manager: "winget" }, { env: { "ProgramFiles(x86)": "C:\\PF86" } })
        .find((c) => c.id === "toolchain");
    assert.equal(checkComponent(toolchain, () => ({ status: 0, stdout: "\r\n" })).state, "missing");
    assert.equal(checkComponent(toolchain, () => ({ status: 0, stdout: "C:\\VS\\BuildTools\r\n" })).state, "ok");
});

function missing(system, wanted, options = {}) {
    return componentsOf(system, options).filter((c) => wanted.includes(c.id))
        .map((component) => ({ component, state: "missing", version: null }));
}

test("planInstall: one command of the package manager for all the packages, then the commands, git lfs install last", () => {
    const system = { os: "macos", manager: "brew" };
    const plan = planInstall(missing(system, ["git-lfs", "git-lfs-setup", "ldc2", "dub"]), system);
    assert.deepEqual(plan.steps.map((s) => [s.program, ...s.args]), [
        ["brew", "install", "git-lfs", "ldc", "dub"],
        ["git", "lfs", "install"],
    ]);
    assert.deepEqual(plan.manual, []);
});

test("planInstall: apt through sudo, ldc by the install script of dlang, once curl is there", () => {
    const system = { os: "linux", manager: "apt" };
    const plan = planInstall(missing(system, ["toolchain", "gtk3", "curl", "ldc2", "dub"]), system, { root: false });
    const lines = plan.steps.map((s) => [s.program, ...s.args].join(" "));
    assert.equal(lines[0], "sudo apt-get update", "a fresh machine has no package lists");
    assert.equal(lines[1], "sudo apt-get install -y build-essential curl libgtk-3-dev pkg-config");
    assert.match(lines[2], /^bash -c curl -fsS https:\/\/dlang\.org\/install\.sh \| bash -s ldc$/);
    assert.equal(lines.length, 3, "dub comes with ldc: no second step");
});

test("planInstall: no sudo for root, and the other managers' own packages", () => {
    const apt = { os: "linux", manager: "apt" };
    assert.equal(planInstall(missing(apt, ["curl"]), apt, { root: true }).steps[0].program, "apt-get");
    const dnf = { os: "linux", manager: "dnf" };
    assert.deepEqual(planInstall(missing(dnf, ["gtk3"]), dnf, { root: false }).steps[0].args,
        ["dnf", "install", "-y", "gtk3-devel", "pkgconf-pkg-config"]);
    const pacman = { os: "linux", manager: "pacman" };
    assert.deepEqual(planInstall(missing(pacman, ["toolchain"]), pacman, { root: false }).steps[0].args,
        ["pacman", "-S", "--needed", "--noconfirm", "base-devel"]);
});

test("planInstall: the command line tools of macOS last: their dialog is asynchronous, nothing waits for it", () => {
    const system = { os: "macos", manager: "brew" };
    const plan = planInstall(missing(system, ["ldc2", "toolchain", "git-lfs", "git-lfs-setup"]), system);
    assert.deepEqual(plan.steps.map((s) => s.program), ["brew", "git", "xcode-select"]);
});

test("planInstall: Windows by winget, one command for each, LDC and a too old Node by hand", () => {
    const system = { os: "windows", manager: "winget" };
    const plan = planInstall(missing(system, ["node", "git", "ldc2", "toolchain"], { env: {} }), system);
    assert.deepEqual(plan.steps.map((s) => s.args[2]), ["Git.Git", "Microsoft.VisualStudio.2022.BuildTools"]);
    assert.deepEqual(plan.manual.map((m) => m.id), ["node", "ldc2"]);
    assert.match(plan.manual[1].text, /github\.com\/ldc-developers\/ldc\/releases/);
});

test("planInstall: without a package manager every package is a manual step", () => {
    const system = { os: "macos", manager: null };
    const plan = planInstall(missing(system, ["git-lfs", "ldc2"]), system);
    assert.deepEqual(plan.steps, []);
    assert.deepEqual(plan.manual.map((m) => m.id), ["git-lfs", "ldc2"]);
    assert.match(plan.manual[0].text, /brew\.sh/);
});

test("planInstall: brew upgrades what is installed but too old: install changes nothing", () => {
    const system = { os: "macos", manager: "brew" };
    const old = missing(system, ["ldc2"]).map((r) => ({ ...r, state: "old", version: "1.30.0" }));
    assert.deepEqual(planInstall(old, system).steps.map((s) => s.args), [["upgrade", "ldc"]]);
    const both = [...missing(system, ["dub"]), ...old];
    assert.deepEqual(planInstall(both, system).steps.map((s) => s.args), [["install", "dub"], ["upgrade", "ldc"]]);
});

test("planInstall: nothing is missing, nothing to do", () => {
    const system = { os: "linux", manager: "apt" };
    const ok = componentsOf(system, {}).map((component) => ({ component, state: "ok", version: "1.0.0" }));
    assert.deepEqual(planInstall(ok, system), { steps: [], manual: [] });
});

test("formatReport: every component with its state, and the command to install what is missing", () => {
    const system = { os: "macos", manager: "brew" };
    const results = componentsOf(system, {}).map((component) => ({ component, state: "ok", version: "1.0.0" }));
    results[4] = { ...results[4], state: "missing", version: null };
    const text = formatReport(results, planInstall(results, system), { hint: installHint(["--dev"]) }).join("\n");
    assert.match(text, /ok\s+ldc2|ldc2.*missing/);
    assert.match(text, /brew install ldc/);
    assert.match(text, /node scripts\/install-deps\.mjs --install --dev/);
});

test("formatReport: all found, no command to run", () => {
    const system = { os: "macos", manager: "brew" };
    const results = componentsOf(system, {}).map((component) => ({ component, state: "ok", version: "1.0.0" }));
    const text = formatReport(results, planInstall(results, system), { hint: installHint([]) }).join("\n");
    assert.doesNotMatch(text, /--install/);
    assert.match(text, /node scripts\/build\.mjs/);
});

test("planInstall: no git lfs install while Git LFS itself can't be installed", () => {
    const system = { os: "macos", manager: null };
    const plan = planInstall(missing(system, ["git-lfs", "git-lfs-setup"]), system);
    assert.deepEqual(plan.steps, []);
    assert.deepEqual(plan.manual.map((m) => m.id), ["git-lfs"]);
});

test("planInstall: git lfs install alone when Git LFS is there but not set up", () => {
    const system = { os: "macos", manager: "brew" };
    const lfs = componentsOf(system, {}).find((c) => c.id === "git-lfs");
    const plan = planInstall([{ component: lfs, state: "ok", version: "3.0.0" }, ...missing(system, ["git-lfs-setup"])], system);
    assert.deepEqual(plan.steps.map((s) => [s.program, ...s.args]), [["git", "lfs", "install"]]);
});

test("planInstall: on Windows git lfs install waits for a new terminal, where the new git is on the PATH", () => {
    const system = { os: "windows", manager: "winget" };
    const plan = planInstall(missing(system, ["git", "git-lfs", "git-lfs-setup"]), system);
    assert.deepEqual(plan.steps.map((s) => s.args[2]), ["Git.Git"]);
});

test("newestCompiler: the newest version, not the last by the letters", () => {
    assert.equal(newestCompiler(["ldc-1.9.0", "ldc-1.43.0", "ldc-1.40.1", "dmd-2.1"]), "ldc-1.43.0");
    assert.equal(newestCompiler(["dmd-2.1"]), null);
    assert.equal(newestCompiler([]), null);
});

test("pathHas: a folder is on the PATH as a whole entry, not as a part of one", () => {
    assert.equal(pathHas("/usr/bin:/home/a/dlang/ldc-1.43.0/bin", "/home/a/dlang/ldc-1.43.0/bin", ":"), true);
    assert.equal(pathHas("/usr/bin:/home/a/dlang/ldc-1.43.0/bin2", "/home/a/dlang/ldc-1.43.0/bin", ":"), false);
    assert.equal(pathHas("", "/x", ":"), false);
});

test("runSteps: runs the steps in order and stops at the first that fails, telling it", () => {
    const ran = [];
    const run = (step) => { ran.push(step.id); return step.id !== "b"; };
    const steps = [{ id: "a" }, { id: "b" }, { id: "c" }];
    assert.equal(runSteps(steps, run), steps[1]);
    assert.deepEqual(ran, ["a", "b"]);
    assert.equal(runSteps([{ id: "a" }], () => true), null);
});

test("planInstall: a failure note travels with the step that may fail with it", () => {
    const system = { os: "windows", manager: "winget" };
    const plan = planInstall(missing(system, ["toolchain"], { env: {} }), system);
    assert.match(plan.steps[0].failNote, /Visual Studio Installer/);
});

test("formatReport: all installed but LDC not on the PATH of the shell, it tells to activate it before the build", () => {
    const system = { os: "linux", manager: "apt" };
    const results = componentsOf(system, {}).map((component) => ({ component, state: "ok", version: "1.0.0" }));
    const text = formatReport(results, planInstall(results, system), { hint: installHint([]), activate: "/home/a/dlang/ldc-1.43.0" }).join("\n");
    assert.match(text, /source \/home\/a\/dlang\/ldc-1\.43\.0\/activate/);
    assert.doesNotMatch(text, /Everything is there\. Next/);
});
