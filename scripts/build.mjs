// Builds, tests and packs DLT Explorer on macOS, Linux and Windows alike: one script instead of
// one per system. dub does the building: dub.sdl puts every build in
// build/<platform>-<arch>-<build type>/ with the Sciter library of libs/ next to the program.
// The commands and options: `node scripts/build.mjs --help` (buildUsage below), the setup and
// more: docs/building.md.
// Builds and starts the program: scripts/run.mjs. Tests: tests/js/build-script.test.mjs.
import { spawnSync } from "node:child_process";
import { chmodSync, closeSync, copyFileSync, cpSync, mkdirSync, mkdtempSync, openSync, readdirSync,
    readFileSync, readSync, realpathSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

export const commands = ["build", "test", "dist", "check-windows"];

/// What `--help` prints. Every command and option is in it: tests/js/build-script.test.mjs.
export const buildUsage = `Builds, tests and packs DLT Explorer. More: docs/building.md.

Usage: node scripts/build.mjs [command] [options]

Commands:
  build           build the program (the default) into build/<platform>-<arch>-<type>/,
                  the Sciter library next to it
  test            the D unittests and the JS tests (tests/js)
  dist            a release distribution in build/dist/<macos|linux|windows>/
  check-windows   compile the program and its unittests for Windows x64 from macOS or
                  Linux, without linking

Options:
  --release       a release build instead of debug (build; dist always is)
  --arch x64|arm64
                  another architecture than this machine's (build, test, dist)
  -h, --help      this help

Build and start the program: node scripts/run.mjs (see its --help).
`;

/// What `--help` of scripts/run.mjs prints.
export const runUsage = `Builds DLT Explorer as scripts/build.mjs does and starts it from its build folder,
its output in this terminal.

Usage: node scripts/run.mjs [options]

Options:
  --release       a release build instead of debug
  --arch x64|arm64
                  another architecture than this machine's
  -h, --help      this help
`;
const arches = ["x64", "arm64"];
const dubArchOf = { x64: "x86_64", arm64: "aarch64" };

/// A command line not understood, or a step that failed: told without a stack.
export class BuildError extends Error {}

/// What the command line asks: `{ command, release, arch }`, `arch` null for this machine's.
/// A distribution is always a release. `--help` anywhere asks for the help (command "help")
/// whatever else is there.
export function parseCommand(argv) {
    if (argv.includes("--help") || argv.includes("-h")) return { command: "help", release: false, arch: null };
    let command = null;
    let release = false;
    let arch = null;
    for (let i = 0; i < argv.length; i++) {
        const arg = argv[i];
        if (arg === "--release") release = true;
        else if (arg === "--arch" || arg.startsWith("--arch=")) {
            const value = arg === "--arch" ? argv[++i] : arg.slice("--arch=".length);
            if (value === undefined) throw new BuildError(`--arch needs one of: ${arches.join(", ")}`);
            if (!arches.includes(value))
                throw new BuildError(`unknown architecture "${value}", expected one of: ${arches.join(", ")}`);
            arch = value;
        } else if (arg.startsWith("-")) throw new BuildError(`unknown option ${arg}`);
        else if (command !== null) throw new BuildError(`one command only, got "${command}" and "${arg}"`);
        else if (!commands.includes(arg))
            throw new BuildError(`unknown command "${arg}", expected one of: ${commands.join(", ")}`);
        else command = arg;
    }
    command ??= "build";
    // an option the command doesn't take is refused rather than silently ignored
    if (release && (command === "test" || command === "check-windows"))
        throw new BuildError(`${command} takes no --release`);
    if (arch && command === "check-windows")
        throw new BuildError("check-windows checks Windows x64 only, it takes no --arch");
    return { command, release: release || command === "dist", arch };
}

/// The arguments of dub for `build` or `test` (whose build type is always unittest).
export function dubArgs(command, { release, arch }) {
    const args = [command, "--compiler=ldc2"];
    if (command === "build") args.push(`--build=${release ? "release" : "debug"}`);
    if (arch) args.push(`--arch=${dubArchOf[arch]}`);
    return args;
}

/// The architecture a distribution is built for: the one asked, else this machine's
/// (`hostArch` is Node's, `process.arch`). No universal macOS program yet: docs/backlog.md.
export function distArch(arch, hostArch) {
    if (arch) return arch;
    if (!arches.includes(hostArch))
        throw new BuildError(`no build for this machine's architecture "${hostArch}": `
            + `name one with --arch (${arches.join(", ")})`);
    return hostArch;
}

/// The Sciter library of libs/ for a system (`process.platform`) and an architecture.
export function sciterLibrary(platform, arch) {
    if (platform === "darwin") return "libs/macosx/libsciter.dylib"; // universal
    if (platform === "win32") return `libs/windows/${arch}/sciter.dll`;
    return `libs/linux/${arch}/libsciter.so`;
}

/// Whether these first bytes of a file are a pointer of Git LFS, left in place of a file it
/// hasn't fetched (no `git lfs pull`, or git-lfs not installed when cloning).
export function isLfsPointer(head) {
    return head.subarray(0, lfsPointerStart.length).equals(lfsPointerStart);
}

const lfsPointerStart = Buffer.from("version https://git-lfs");

/// The compiler arguments of `dub describe --data-0` (each argument ends with a zero, a list
/// with one more), without the resource script of Windows: ldc2 compiles D only.
export function compilerArgs(described) {
    return described.split("\0").filter((arg) => arg !== "" && !arg.endsWith(".rc"));
}

/// The Info.plist of the macOS bundle. macOS draws its own dialogs and items in the language
/// of the app only if the bundle declares it: CFBundleLocalizations (and an <tag>.lproj each).
export function infoPlist({ name, version, languages }) {
    const languageList = languages.map((tag) => `        <string>${tag}</string>\n`).join("");
    return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
${languageList}    </array>
    <key>CFBundleExecutable</key>
    <string>${name}</string>
    <key>CFBundleIconFile</key>
    <string>app.icns</string>
    <key>CFBundleIdentifier</key>
    <string>com.demiandavidov.dltexplorer</string>
    <key>CFBundleName</key>
    <string>${name}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${version}</string>
    <key>CFBundleVersion</key>
    <string>${version}</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
`;
}

/// The desktop entry of Linux: what puts the program with its icon in the menu of applications.
export function desktopEntry({ installDir, program }) {
    return `[Desktop Entry]
Name=DLT Explorer
Comment=DLT file viewer and analyzer
Exec=${installDir}/${program}
Icon=${installDir}/app.png
Terminal=false
Type=Application
Categories=Development;Utility;
`;
}

/// The script next to the macOS bundle: a downloaded program is in quarantine and unsigned,
/// and macOS on arm64 starts no unsigned code. Clears the quarantine and signs (ad-hoc) the
/// Sciter library, then the bundle. A .command opens in Terminal from Finder.
function signScript(bundle) {
    return `#!/bin/bash
# Lets macOS start ${bundle}: clears its quarantine and signs it for this machine.
cd "$(dirname "$0")" || exit 1
xattr -cr "${bundle}" &&
codesign --force --sign - "${bundle}/Contents/MacOS/libsciter.dylib" &&
codesign --force --sign - "${bundle}" &&
echo "${bundle} is ready."
`;
}

/// Runs a program, its output shown, or kept with `capture` (up to `maxBuffer`, 1 MB). `echo`
/// tells the command line first.
function run(program, args, { capture = false, echo = !capture } = {}) {
    if (echo) console.log(`> ${program} ${args.join(" ")}`);
    const result = spawnSync(program, args, { stdio: capture ? ["ignore", "pipe", "pipe"] : "inherit",
        encoding: "utf8" });
    if (result.error) throw new BuildError(`can't run ${program}: ${result.error.message}`);
    return result;
}

function runOrFail(program, args, failure) {
    if (run(program, args).status !== 0) throw new BuildError(failure);
}

/// What dub describes of the build of these arguments, one line per item.
function describe(data, dubBuildArgs) {
    const args = ["describe", ...dubBuildArgs.slice(1), `--data=${data}`, "--data-list"];
    const result = run("dub", args, { capture: true });
    if (result.status !== 0) throw new BuildError(`dub describe failed:\n${result.stderr}`);
    return result.stdout.split(/\r?\n/).filter((line) => line !== "");
}

/// Stops with what to do when the Sciter library the build will copy is missing or is a
/// pointer of Git LFS: the program would build and then fail to load it.
function checkSciterLibrary(arch) {
    if (!arches.includes(arch)) return; // no library for it: dub will tell
    const library = sciterLibrary(process.platform, arch);
    const head = Buffer.alloc(lfsPointerStart.length);
    let read = 0;
    try {
        const file = openSync(library, "r");
        try { read = readSync(file, head); } finally { closeSync(file); }
    } catch {
        throw new BuildError(`No Sciter library ${library}: run "git lfs pull" (docs/building.md).`);
    }
    if (read === head.length && isLfsPointer(head))
        throw new BuildError(`${library} is a pointer of Git LFS, not the library: install git-lfs `
            + `and run "git lfs install" and "git lfs pull" (docs/building.md).`);
}

/// Builds (`{ release, arch }`) and gives the folder of the program.
export function build(options) {
    checkSciterLibrary(options.arch ?? process.arch);
    const args = dubArgs("build", options);
    runOrFail("dub", args, "Build failed.");
    return describe("target-path", args)[0];
}

function test(options) {
    checkSciterLibrary(options.arch ?? process.arch);
    const dub = run("dub", dubArgs("test", options)).status === 0;
    const js = run(process.execPath, ["--test", "tests/js"]).status === 0;
    console.log(`D unittests: ${dub ? "OK" : "FAILED"}, JS tests: ${js ? "OK" : "FAILED"}`);
    if (!dub || !js) throw new BuildError("Tests failed.");
}

function freshDir(dir) {
    rmSync(dir, { recursive: true, force: true });
    mkdirSync(dir, { recursive: true });
    return dir;
}

function languages() {
    const tags = readdirSync("resources/i18n/translations")
        .filter((file) => file.endsWith(".json")).map((file) => file.slice(0, -".json".length));
    return ["en", ...tags.filter((tag) => tag !== "en")]; // english is the source
}

function distMac(version, arch) {
    const name = "DltExplorer";
    const program = join(build({ release: true, arch }), "dlt_explorer");
    return publish("macos", (staging) => {
        const bundle = `${name}.app`;
        makeMacBundle(join(staging, bundle), name, version, program);
        const sign = join(staging, "sign.command");
        writeFileSync(sign, signScript(bundle), { mode: 0o755 });
        runOrFail("bash", [sign], "Signing failed.");
    });
}

/// Makes a distribution by `make(folder)` and only when it is all made and copied replaces
/// build/dist/<system> with it: a failed step leaves the previous one as it was. It is made
/// in a temporary folder outside the project (see distMac), copied next to its place and
/// renamed into it.
function publish(system, make) {
    const staging = mkdtempSync(join(tmpdir(), "dlt-dist-"));
    const dir = `build/dist/${system}`;
    const copy = freshDir(`build/dist/.${system}-new`);
    try {
        make(staging);
        // ditto keeps the signature and attributes of a bundle as they are
        if (process.platform === "darwin") runOrFail("ditto", [staging, copy], "Copying the distribution failed.");
        else cpSync(staging, copy, { recursive: true });
        rmSync(dir, { recursive: true, force: true });
        renameSync(copy, dir);
        return dir;
    } finally {
        rmSync(staging, { recursive: true, force: true });
        rmSync(copy, { recursive: true, force: true });
    }
}

function makeMacBundle(path, name, version, builtProgram) {
    const contents = join(path, "Contents");
    mkdirSync(join(contents, "MacOS"), { recursive: true });
    mkdirSync(join(contents, "Resources"), { recursive: true });
    const program = join(contents, "MacOS", name);
    copyFileSync(builtProgram, program);
    chmodSync(program, 0o755);
    copyFileSync(sciterLibrary("darwin"), join(contents, "MacOS", "libsciter.dylib"));
    copyFileSync("resources/app.icns", join(contents, "Resources", "app.icns"));
    const tags = languages();
    for (const tag of tags) {
        mkdirSync(join(contents, "Resources", `${tag}.lproj`));
        writeFileSync(join(contents, "Resources", `${tag}.lproj`, "InfoPlist.strings"),
            "/* DLT Explorer is translated to this language: resources/i18n/translations */\n");
    }
    writeFileSync(join(contents, "Info.plist"), infoPlist({ name, version, languages: tags }));
}

function distLinux(arch) {
    const target = build({ release: true, arch });
    const program = "dlt_explorer";
    const installDir = `/opt/${program}`;
    const dir = publish("linux", (staging) => {
        for (const file of [program, "libsciter.so"]) copyFileSync(join(target, file), join(staging, file));
        chmodSync(join(staging, program), 0o755);
        copyFileSync("resources/app.png", join(staging, "app.png"));
        writeFileSync(join(staging, `${program}.desktop`), desktopEntry({ installDir, program }));
    });
    console.log(`To install, copy ${dir} to ${installDir} and link ${program}.desktop.`);
    return dir;
}

function distWindows(arch) {
    const target = build({ release: true, arch });
    // the icon is built into the program (resources/app.rc)
    return publish("windows", (staging) => {
        for (const file of ["dlt_explorer.exe", "sciter.dll"]) copyFileSync(join(target, file), join(staging, file));
    });
}

function dist(arch) {
    const version = readFileSync("VERSION", "utf8").trim();
    const distArchitecture = distArch(arch, process.arch);
    const dir = process.platform === "darwin" ? distMac(version, distArchitecture)
        : process.platform === "win32" ? distWindows(distArchitecture)
        : distLinux(distArchitecture);
    console.log(`DLT Explorer ${version} (${distArchitecture}): ${dir}`);
}

/// Compiles the app and its unittests for Windows x64 with the arguments dub would give,
/// without linking: the libraries of Windows aren't here. A full check needs Windows (`test`).
/// dub describes the build for the Windows triple, so what dub.sdl declares for Windows only
/// is in; the arguments carry the triple.
function checkWindows() {
    const described = run("dub", ["describe", "--compiler=ldc2", "--arch=x86_64-windows-msvc",
        "--data=dflags,versions,import-paths,string-import-paths,source-files", "--data-0"], { capture: true });
    if (described.status !== 0) throw new BuildError(`dub describe failed:\n${described.stderr}`);
    const args = compilerArgs(described.stdout);
    const out = mkdtempSync(join(tmpdir(), "dlt-check-windows-"));
    let ok = true;
    try {
        for (const mode of ["app", "unittest"]) {
            // the errors straight to the terminal: there may be more than a captured output holds
            const passed = run("ldc2", ["-c", ...(mode === "unittest" ? ["-unittest"] : []), "-oq",
                `-od=${join(out, mode)}`, ...args], { echo: false }).status === 0;
            console.log(`Windows compile (${mode}): ${passed ? "OK" : "FAILED"}`);
            ok &&= passed;
        }
    } finally {
        rmSync(out, { recursive: true, force: true });
    }
    if (!ok) throw new BuildError("Windows compile failed.");
}

function main(argv) {
    process.chdir(fileURLToPath(new URL("..", import.meta.url))); // the project root
    const { command, release, arch } = parseCommand(argv);
    if (command === "help") process.stdout.write(buildUsage);
    else if (command === "build") console.log(`Built: ${build({ release, arch })}`);
    else if (command === "test") test({ arch });
    else if (command === "dist") dist(arch);
    else checkWindows();
}

// run, not imported (by the tests); the module's path has its symbolic links resolved, the
// command line's may not
if (process.argv[1] && fileURLToPath(import.meta.url) === realpathSync(process.argv[1])) {
    try {
        main(process.argv.slice(2));
    } catch (e) {
        if (!(e instanceof BuildError)) throw e;
        console.error(e.message);
        process.exit(1);
    }
}
