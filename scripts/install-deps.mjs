// Checks what a build of Log Tracy needs besides Node (the compiler, dub, Git LFS, the C
// toolchain of the system) and installs what is missing when asked with --install. The checks
// and the plan are plain functions over data (tests: tests/js/install-deps-script.test.mjs);
// only `main` touches the system. What the setup is, per system: docs/building.md.
import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { delimiter, join } from "node:path";
import { fileURLToPath } from "node:url";

export const installUsage = `Checks the tools a build of Log Tracy needs, and installs what is missing. More: docs/building.md.

Usage: node scripts/install-deps.mjs [options]

Without options only checks: tells what is found and the command that installs the rest.
The exit code is 1 when something is missing.

Options:
  --install   install what is missing (the package manager of the system, sudo asks for
              its password on Linux), then check again
  --dev       also the tools of development that are not needed to build: screenshots and
              the stacks of a hung app on Linux (xdotool, ImageMagick, gdb)
  --help      this text
`;

// the packages of the distributions are often old: the install script of dlang puts a current
// LDC with its dub in ~/dlang
const dlangCommand = { program: "bash", args: ["-c", "curl -fsS https://dlang.org/install.sh | bash -s ldc"], phase: 2 };
const ldcReleases = "https://github.com/ldc-developers/ldc/releases (ldc2-<version>-windows-multilib.exe, it brings dub too)";

/// The first dotted number of the output of a tool as [major, minor, patch], else null.
export function parseVersion(text) {
    const found = /(\d+)\.(\d+)(?:\.(\d+))?/.exec(text);
    return found ? [Number(found[1]), Number(found[2]), Number(found[3] ?? 0)] : null;
}

/// Whether version `found` is `min` or newer, part by part (a shorter `min` leaves the rest out).
export function versionAtLeast(found, min) {
    for (let i = 0; i < min.length; i++) {
        if ((found[i] ?? 0) !== min[i]) return (found[i] ?? 0) > min[i];
    }
    return true;
}

/// The system and its package manager, the first one found. `has(program)` says whether a
/// program is on the PATH.
export function detectSystem({ platform, has }) {
    if (platform === "darwin") return { os: "macos", manager: has("brew") ? "brew" : null };
    if (platform === "win32") return { os: "windows", manager: has("winget") ? "winget" : null };
    if (platform === "linux") {
        const managers = [["apt-get", "apt"], ["dnf", "dnf"], ["pacman", "pacman"]];
        const found = managers.find(([program]) => has(program));
        return { os: "linux", manager: found ? found[1] : null };
    }
    throw new Error(`no setup for the system "${platform}"`);
}

const wingetFlags = ["-e", "--accept-source-agreements", "--accept-package-agreements"];
const wingetInstall = (id, ...more) => ({ program: "winget", args: ["install", "--id", id, ...wingetFlags, ...more] });

/// What a build needs on `system` ({ os, manager }), in the order it is told. `dev` adds the
/// tools of development; `env` is where the Windows tools are looked up. A component is
///   check:    the program, its arguments and what makes it found: `min` a version, `nonEmpty` an answer
///   packages: its packages by manager (installed with one command of the manager)
///   command:  else what installs it by a command of its own (`phase` 2 after the packages, 3 git lfs install, 4 last)
///   manual:   else the words that tell how to install it, when no command does
export function componentsOf(system, { dev = false, env = process.env } = {}) {
    const { os } = system;
    const manualOf = (name, url) => `${name}: ${url}`;
    const list = [
        { id: "node", label: "Node.js 22 or newer", check: { program: process.execPath, args: ["--version"], min: [22] }, // the one running this script
            manual: manualOf("Node.js 22 or newer", "https://nodejs.org") },
        {
            id: "git", label: "Git", check: { program: "git", args: ["--version"] },
            packages: { brew: ["git"], apt: ["git"], dnf: ["git"], pacman: ["git"] },
            command: os === "windows" ? wingetInstall("Git.Git") : undefined,
            manual: manualOf("Git", "https://git-scm.com"),
        },
        {
            id: "git-lfs", label: "Git LFS", check: { program: "git", args: ["lfs", "version"] },
            packages: { brew: ["git-lfs"], apt: ["git-lfs"], dnf: ["git-lfs"], pacman: ["git-lfs"] },
            command: os === "windows" ? wingetInstall("Git.Git") : undefined, // Git for Windows includes it
            manual: manualOf("Git LFS", "https://git-lfs.com"),
        },
        {
            id: "git-lfs-setup", label: "git lfs install (once per machine)",
            check: { program: "git", args: ["config", "--global", "--get", "filter.lfs.process"], nonEmpty: true },
            command: { program: "git", args: ["lfs", "install"], phase: 3 },
        },
        {
            id: "ldc2", label: "LDC (ldc2)", check: { program: "ldc2", args: ["--version"], min: [1, 43] },
            packages: os === "macos" ? { brew: ["ldc"] } : undefined,
            command: os === "linux" ? dlangCommand : undefined,
            manual: os === "windows" ? manualOf("LDC", ldcReleases) : manualOf("LDC 1.43 or newer", "https://github.com/ldc-developers/ldc/releases"),
        },
        {
            id: "dub", label: "dub", check: { program: "dub", args: ["--version"] },
            packages: os === "macos" ? { brew: ["dub"] } : undefined,
            command: os === "linux" ? dlangCommand : undefined,
            manual: os === "windows" ? manualOf("LDC", ldcReleases) : manualOf("dub", "https://dub.pm"),
        },
    ];
    if (os === "macos") {
        list.push({
            id: "toolchain", label: "Command line tools of Xcode", check: { program: "xcode-select", args: ["-p"] },
            command: { program: "xcode-select", args: ["--install"], phase: 4,
                note: "A dialog opens: run this script again when the installation it starts ends." },
        });
    } else if (os === "linux") {
        list.push(
            {
                id: "toolchain", label: "C toolchain (cc)", check: { program: "cc", args: ["--version"] },
                packages: { apt: ["build-essential"], dnf: ["gcc", "gcc-c++", "make"], pacman: ["base-devel"] },
                manual: manualOf("A C toolchain (gcc or clang, make)", "the package manager of your system"),
            },
            {
                id: "curl", label: "curl (for the install script of dlang)", check: { program: "curl", args: ["--version"] },
                packages: { apt: ["curl"], dnf: ["curl"], pacman: ["curl"] },
                manual: manualOf("curl", "the package manager of your system"),
            },
            {
                id: "gtk3", label: "GTK 3 (development files)", check: { program: "pkg-config", args: ["--exists", "gtk+-3.0"] },
                packages: { apt: ["libgtk-3-dev", "pkg-config"], dnf: ["gtk3-devel", "pkgconf-pkg-config"], pacman: ["gtk3", "pkgconf"] },
                manual: manualOf("GTK 3 with its development files and pkg-config", "the package manager of your system"),
            },
        );
    } else {
        const programFiles = env["ProgramFiles(x86)"] ?? "C:\\Program Files (x86)";
        list.push({
            id: "toolchain", label: "Visual Studio Build Tools (C++)",
            check: {
                program: `${programFiles}\\Microsoft Visual Studio\\Installer\\vswhere.exe`,
                args: ["-products", "*", "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationPath"],
                nonEmpty: true,
            },
            command: {
                ...wingetInstall("Microsoft.VisualStudio.2022.BuildTools", "--override",
                    "--passive --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"),
                // winget doesn't change Build Tools that are installed already, whatever their workloads
                failNote: 'If Visual Studio Build Tools are installed already, open the Visual Studio Installer, Modify, and add "Desktop development with C++".',
            },
            manual: manualOf('Visual Studio Build Tools with "Desktop development with C++"', "https://visualstudio.microsoft.com/downloads/"),
        });
    }
    if (dev && os === "linux") {
        list.push(
            { id: "xdotool", label: "xdotool (screenshots)", check: { program: "xdotool", args: ["--version"] },
                packages: { apt: ["xdotool"], dnf: ["xdotool"], pacman: ["xdotool"] } },
            { id: "imagemagick", label: "ImageMagick (screenshots)", check: { program: "import", args: ["-version"] },
                packages: { apt: ["imagemagick"], dnf: ["ImageMagick"], pacman: ["imagemagick"] } },
            { id: "gdb", label: "gdb (stacks of a hung app)", check: { program: "gdb", args: ["--version"] },
                packages: { apt: ["gdb"], dnf: ["gdb"], pacman: ["gdb"] } },
        );
    }
    return list;
}

/// Checks a component: { component, state: "ok" | "missing" | "old", version }. `probe(program,
/// args)` runs a program and gives { status, stdout, error? }.
export function checkComponent(component, probe) {
    const { program, args, min, nonEmpty } = component.check;
    const result = probe(program, args);
    if (result.error || result.status !== 0) return { component, state: "missing", version: null };
    if (nonEmpty && result.stdout.trim() === "") return { component, state: "missing", version: null };
    const parsed = parseVersion(result.stdout);
    const version = parsed ? parsed.join(".") : null;
    if (min && (parsed === null || !versionAtLeast(parsed, min))) return { component, state: "old", version };
    return { component, state: "ok", version };
}

const installCommands = {
    brew: (packages) => ({ program: "brew", args: ["install", ...packages] }),
    apt: (packages) => ({ program: "apt-get", args: ["install", "-y", ...packages], sudo: true }),
    dnf: (packages) => ({ program: "dnf", args: ["install", "-y", ...packages], sudo: true }),
    pacman: (packages) => ({ program: "pacman", args: ["-S", "--needed", "--noconfirm", ...packages], sudo: true }),
};

const toolsNote = {
    macos: "Install Homebrew (https://brew.sh) and run this script again to have it installed",
    linux: "No package manager known (apt, dnf, pacman)",
    windows: "Install winget (App Installer of Microsoft Store) and run this script again to have it installed",
};

/// The newest compiler of the names of the folders of ~/dlang (ldc-<version>), by the version
/// and not by the letters, else null.
export function newestCompiler(names) {
    const versioned = names.filter((name) => name.startsWith("ldc-")).map((name) => ({ name, version: parseVersion(name) }))
        .filter((c) => c.version !== null);
    versioned.sort((a, b) => (versionAtLeast(a.version, b.version) ? (versionAtLeast(b.version, a.version) ? 0 : 1) : -1));
    return versioned.at(-1)?.name ?? null;
}

/// What installs the components that are not ok: { steps, manual }. A step is { id, label,
/// program, args, note?, failNote? } and they come in this order: the packages of the package
/// manager (one command to install, one to upgrade what is installed but too old), the
/// commands of phase 2 (the install script of dlang), `git lfs install`, and last the commands
/// of phase 4 (the dialog of Xcode's tools, which goes on by itself). What no command installs
/// is `manual`: { id, text }. `root` tells that no sudo is needed.
export function planInstall(results, system, { root = false } = {}) {
    const installs = [];
    const upgrades = [];
    const commands = [];
    const manual = [];
    const addCommand = (id, label, command) => {
        const line = [command.program, ...command.args].join(" ");
        if (!commands.some((c) => c.line === line)) {
            const { program, args, note, failNote } = command;
            commands.push({ line, phase: command.phase ?? 2, step: { id, label, program, args, note, failNote } });
        }
    };
    for (const { component, state } of results.filter((r) => r.state !== "ok")) {
        if (component.id === "git-lfs-setup") continue; // below: it needs Git LFS
        const names = component.packages?.[system.manager];
        if (names) {
            // `brew install` of a package installed already changes nothing: it is upgraded
            const list = state === "old" && system.manager === "brew" ? upgrades : installs;
            for (const name of names) if (!list.includes(name)) list.push(name);
        } else if (component.command && (system.os !== "windows" || system.manager === "winget")) {
            addCommand(component.id, component.label, component.command);
        } else {
            const text = component.manual
                ? (component.command || component.packages ? `${component.manual}. ${toolsNote[system.os]}.` : component.manual)
                : `${component.label}. ${toolsNote[system.os]}.`;
            if (!manual.some((m) => m.text === text)) manual.push({ id: component.id, text });
        }
    }
    // `git lfs install` sets the filters in the git config: it needs Git LFS, found or installed
    // by a package now. Not on Windows, where winget's new git is not on the PATH of this run:
    // the script run again in a new terminal does it
    const lfs = results.find((r) => r.component.id === "git-lfs");
    const setup = results.find((r) => r.component.id === "git-lfs-setup");
    const lfsReady = lfs?.state === "ok" || installs.includes("git-lfs");
    if (lfsReady && (lfs?.state !== "ok" || setup?.state !== "ok"))
        addCommand("git-lfs-setup", "git lfs install (once per machine)", { program: "git", args: ["lfs", "install"], phase: 3 });
    const steps = [];
    if (installs.length > 0) {
        if (system.manager === "apt")
            steps.push({ id: "update", label: "Package lists", program: root ? "apt-get" : "sudo", args: root ? ["update"] : ["apt-get", "update"] });
        const command = installCommands[system.manager](installs);
        const sudo = command.sudo && !root;
        steps.push({
            id: "packages", label: `Packages with ${system.manager}`,
            program: sudo ? "sudo" : command.program, args: sudo ? [command.program, ...command.args] : command.args,
        });
    }
    if (upgrades.length > 0) steps.push({ id: "upgrades", label: "Upgrade with brew", program: "brew", args: ["upgrade", ...upgrades] });
    const phase = (n) => commands.filter((c) => c.phase === n).map((c) => c.step);
    steps.push(...phase(2), ...phase(3), ...phase(4));
    return { steps, manual };
}

/// Runs the steps in order with `run(step)`, which says whether it went well; the first that
/// didn't, else null.
export function runSteps(steps, run) {
    for (const step of steps) if (!run(step)) return step;
    return null;
}

/// Whether `dir` is one of the entries of a PATH written with `separator`.
export function pathHas(path, dir, separator) {
    return path.split(separator).includes(dir);
}

/// The command that installs what a check found missing: the options of this run are kept.
export function installHint(extraArgs) {
    return ["node scripts/install-deps.mjs", "--install", ...extraArgs].join(" ");
}

const commandLine = (step) => [step.program, ...step.args.map((a) => (/\s/.test(a) ? JSON.stringify(a) : a))].join(" ");

/// The lines of the report of a check: every component with its state, what is to be
/// installed and how (`hint` is the command of the script that does it). `activate` is the folder
/// of an LDC that is installed but not on the PATH of this shell: it is told to activate it.
export function formatReport(results, plan, { hint, activate = null }) {
    const lines = ["Tools for a build:"];
    const width = Math.max(...results.map((r) => r.component.label.length));
    for (const { component, state, version } of results) {
        const text = state === "ok" ? `ok${version ? ` (${version})` : ""}`
            : state === "old" ? `too old (${version})` : "missing";
        lines.push(`  ${component.label.padEnd(width)}  ${text}`);
    }
    if (plan.steps.length === 0 && plan.manual.length === 0) {
        lines.push("");
        if (activate === null) lines.push("Everything is there. Next: node scripts/build.mjs");
        else lines.push(`Everything is installed, but LDC is not on the PATH of this shell. Run`, `  source ${activate}/activate`,
            "(or add it to ~/.bashrc), then: node scripts/build.mjs");
        return lines;
    }
    if (plan.steps.length > 0) {
        lines.push("", "To install:");
        for (const step of plan.steps) lines.push(`  ${commandLine(step)}`);
    }
    if (plan.manual.length > 0) {
        lines.push("", "By hand:");
        for (const item of plan.manual) lines.push(`  ${item.text}`);
    }
    if (plan.steps.length > 0) lines.push("", `Run \`${hint}\` to install it${plan.manual.length > 0 ? " (what is by hand stays)" : ""}.`);
    return lines;
}

// The system's side ---------------------------------------------------------------------

function probe(program, args) {
    const shell = process.platform === "win32" && program === "dub"; // dub may be a dub.cmd shim
    const result = spawnSync(program, args, { encoding: "utf8", shell });
    return { status: result.status, stdout: `${result.stdout ?? ""}${result.stderr ?? ""}`, error: result.error };
}

function has(program) {
    return spawnSync(process.platform === "win32" ? "where" : "which", [program], { stdio: "ignore" }).status === 0;
}

/// The newest compiler of the dlang install script in ~/dlang, its folder, else null.
function dlangCompiler() {
    const dir = join(homedir(), "dlang");
    if (!existsSync(dir)) return null;
    const name = newestCompiler(readdirSync(dir));
    return name && join(dir, name);
}

function checkAll(components) {
    return components.map((component) => checkComponent(component, probe));
}

function main(argv) {
    const options = new Set(argv);
    const unknown = argv.filter((a) => !["--install", "--dev", "--help"].includes(a));
    if (unknown.length > 0) {
        console.error(`Unknown option ${unknown[0]}.\n\n${installUsage}`);
        process.exitCode = 2;
        return;
    }
    if (options.has("--help")) return process.stdout.write(installUsage);
    const system = detectSystem({ platform: process.platform, has });
    const components = componentsOf(system, { dev: options.has("--dev") });
    const root = typeof process.getuid === "function" && process.getuid() === 0;
    const hint = installHint(options.has("--dev") ? ["--dev"] : []);
    // An LDC of the install script of dlang that the shell didn't activate (or that an older one
    // on the PATH hides) is used by this run, so it is not installed again; the build in this
    // shell still needs the activation: `activate`
    const ldc = components.find((c) => c.id === "ldc2");
    let activate = null;
    const useDlang = () => {
        const compiler = system.os === "linux" && checkComponent(ldc, probe).state !== "ok" ? dlangCompiler() : null;
        const bin = compiler && join(compiler, "bin");
        if (bin && !pathHas(process.env.PATH, bin, delimiter)) {
            activate = compiler;
            process.env.PATH = `${bin}${delimiter}${process.env.PATH}`;
        }
    };
    useDlang();
    let results;
    let plan;
    const report = () => {
        results = checkAll(components);
        plan = planInstall(results, system, { root });
        return formatReport(results, plan, { hint, activate }).join("\n");
    };
    console.log(report());
    if (options.has("--install") && plan.steps.length > 0) {
        const failed = runSteps(plan.steps, (step) => {
            console.log(`\n> ${commandLine(step)}`);
            const done = spawnSync(step.program, step.args, { stdio: "inherit" });
            if (done.error || done.status !== 0) return false;
            if (step.note) console.log(step.note);
            return true;
        });
        if (failed) {
            console.error(`\nFailed: ${commandLine(failed)}`);
            if (failed.failNote) console.error(failed.failNote);
            process.exitCode = 1;
            return;
        }
        useDlang();
        console.log(`\n${report()}`);
    }
    if (options.has("--install") && system.os === "windows") console.log("\nOpen a new terminal and run this script again: the PATH of this one doesn't have what was installed.");
    process.exitCode = results.every((r) => r.state === "ok") && activate === null ? 0 : 1;
}

// run, not imported (by the tests); the module's path has its symbolic links resolved, the
// command line's may not
if (process.argv[1] && fileURLToPath(import.meta.url) === realpathSync(process.argv[1]))
    main(process.argv.slice(2));
