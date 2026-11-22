// Builds, tests and packs Log Tracy on macOS, Linux and Windows alike: one script instead of
// one per system. dub does the building: dub.sdl puts every build in
// build/<platform>-<arch>-<build type>/ with the Sciter library of libs/ next to the program.
// The commands and options: `node scripts/build.mjs --help` (buildUsage below), the setup and
// more: docs/building.md.
// Builds and starts the program: scripts/run.mjs. Tests: tests/js/build-script.test.mjs.
import { spawnSync } from "node:child_process";
import { appendFileSync, chmodSync, closeSync, copyFileSync, cpSync, existsSync, mkdirSync, mkdtempSync, openSync, readdirSync,
    readFileSync, readSync, realpathSync, renameSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import { basename, dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { brotliCompress, brotliDecompressSync, constants as zlibConstants } from "node:zlib";

import { BenchError, benchCompileArgs, benchUsage, compareRuns, defaultBenchArgs, formatComparison,
    parseBenchArgs, runOrder } from "./utils/bench.mjs";
import { filterBuildOutput } from "./build-output-filter.mjs";

export const commands = ["build", "test", "dist", "gen-log", "bench", "pack-libs"];

/// Where `--brief` puts the whole output of the steps of the last run, relative to the root.
export const briefLogPath = "build/brief.log";

/// What `--help` prints. Every command and option is in it: tests/js/build-script.test.mjs.
export const buildUsage = `Builds, tests and packs Log Tracy. More: docs/building.md.

Usage: node scripts/build.mjs [command] [options]

Commands:
  build           build the program (the default) into build/<platform>-<arch>-<type>/,
                  the Sciter library next to it
  test            the D unittests, the JS tests (tests/js) and the names of .ai/ the code
                  no longer has (scripts/utils/check-ai-context.mjs)
  test --module <file.d>
                  the unittests of one D module and of the modules it imports, without
                  dub (one that doesn't depend on Sciter): built into build/tools/
  test --filter <name> [--filter <name>...]
                  only the D unittests whose names start with one of these, by
                  unit-threaded's runner: utils.fsm, or a test's own name (dub test -- -l
                  lists them)
  dist            a distribution in build/dist/<macos|linux|windows>/: the release of an
                  installed program (build type dist), settings in the user's folder; with
                  its installer, a .dmg on macOS, a .deb on Linux (where dpkg-deb is), a
                  .zip on Windows
  gen-log <file> [options]
                  generate a test log (scripts/utils/gen_log.d, built into build/tools/):
                  everything after gen-log is its own, see gen-log --help
  bench [log] [options]
                  measure this working tree against master with scripts/utils/bench_rows.d
                  or bench_index.d (scripts/utils/bench.mjs), see bench --help
  pack-libs       pack the Sciter libraries of libs/ into the archives kept in Git LFS
                  (<library>.br), after an update of Sciter

Options:
  --release       a release build instead of debug (build; dist always is one)
  --debug-channel also build the debug channel, in a debug or a release build
                  (scripts/utils/app.mjs drives the app through it)
  --arch x64|arm64
                  another architecture than this machine's (build, test, dist)
  --brief         only what failed: compile errors, failed tests with their places and the
                  summary; the whole output goes to ${briefLogPath} (build, test, dist)
  -h, --help      this help

Build and start the program: node scripts/run.mjs (see its --help).
`;

/// What `--help` of scripts/run.mjs prints.
export const runUsage = `Builds Log Tracy as scripts/build.mjs does and starts it from its build folder,
its output in this terminal.

Usage: node scripts/run.mjs [options]

Options:
  --release       a release build instead of debug
  --arch x64|arm64
                  another architecture than this machine's
  --brief         the build tells only what failed, its whole output in ${briefLogPath};
                  the program's output as always
  -h, --help      this help
`;
/// What `node scripts/test.mjs --help` prints.
export const testUsage = `Runs the tests of Log Tracy: the D unittests, the JS tests (tests/js) and the
names of .ai/ the code no longer has; the same as node scripts/build.mjs test.

Usage: node scripts/test.mjs [options]

Options:
  --module <file.d>
                  the unittests of one D module and of the modules it imports, without
                  dub (one that doesn't depend on Sciter)
  --filter <name>
                  only the D unittests whose names start with it (a module, utils.fsm, or a
                  test's own name), no JS tests; may be repeated
  --arch x64|arm64
                  another architecture than this machine's
  --brief         only what failed, the whole output in ${briefLogPath}
  -h, --help      this help
`;
const arches = ["x64", "arm64"];
const dubArchOf = { x64: "x86_64", arm64: "aarch64" };

/// A command line not understood, or a step that failed: told without a stack.
export class BuildError extends Error {}

/// What the command line asks: `{ command, release, arch }`, `arch` null for this machine's.
/// A distribution is always a release. `gen-log` first gives everything after it to the
/// generator (`toolArgs`), its `--help` too. Otherwise `--help` anywhere asks for the help
/// (command "help") whatever else is there.
export function parseCommand(argv) {
    // the generator takes its own options, --help too
    if (argv[0] === "gen-log" || argv[0] === "bench")
        return { command: argv[0], release: false, arch: null, toolArgs: argv.slice(1) };
    if (argv.includes("--help") || argv.includes("-h")) return { command: "help", release: false, arch: null };
    for (const command of ["gen-log", "bench"])
        if (argv.includes(command)) throw new BuildError(`${command} comes first: node scripts/build.mjs ${command} ...`);
    let command = null;
    let release = false;
    let debugChannel = false;
    let arch = null;
    let module = null;
    const filters = [];
    let brief = false;
    for (let i = 0; i < argv.length; i++) {
        const arg = argv[i];
        if (arg === "--release") release = true;
        else if (arg === "--debug-channel") debugChannel = true;
        else if (arg === "--brief") brief = true;
        else if (arg === "--arch" || arg.startsWith("--arch=")) {
            const value = arg === "--arch" ? argv[++i] : arg.slice("--arch=".length);
            if (value === undefined) throw new BuildError(`--arch needs one of: ${arches.join(", ")}`);
            if (!arches.includes(value))
                throw new BuildError(`unknown architecture "${value}", expected one of: ${arches.join(", ")}`);
            arch = value;
        } else if (arg === "--module" || arg.startsWith("--module=")) {
            const value = arg === "--module" ? argv[++i] : arg.slice("--module=".length);
            if (value === undefined || value.startsWith("-")) throw new BuildError("--module needs a file: --module source/utils/fsm.d");
            if (!value.endsWith(".d")) throw new BuildError(`--module takes a D file (.d), got "${value}"`);
            module = value;
        } else if (arg === "--filter" || arg.startsWith("--filter=")) {
            const value = arg === "--filter" ? argv[++i] : arg.slice("--filter=".length);
            if (!value || value.startsWith("-")) throw new BuildError("--filter needs a name: --filter utils.fsm");
            filters.push(value);
        } else if (arg.startsWith("-")) throw new BuildError(`unknown option ${arg}`);
        else if (command !== null) throw new BuildError(`one command only, got "${command}" and "${arg}"`);
        else if (!commands.includes(arg))
            throw new BuildError(`unknown command "${arg}", expected one of: ${commands.join(", ")}`);
        else command = arg;
    }
    command ??= "build";
    // an option the command doesn't take is refused rather than silently ignored
    if (release && (command === "test" || command === "pack-libs"))
        throw new BuildError(`${command} takes no --release`);
    if (debugChannel && command !== "build") throw new BuildError("--debug-channel is an option of build");
    if (arch && command === "pack-libs") throw new BuildError("pack-libs packs every library, it takes no --arch");
    if (filters.length > 0) {
        if (command !== "test") throw new BuildError("--filter is an option of test: node scripts/build.mjs test --filter <name>");
        if (module !== null) throw new BuildError("--filter is for dub test, --module runs druntime's runner: one of them");
    }
    if (module !== null) {
        if (command !== "test") throw new BuildError("--module is an option of test: node scripts/build.mjs test --module <file.d>");
        if (arch) throw new BuildError("test --module builds for this machine only, it takes no --arch");
        return { command, release: false, arch: null, module, ...(brief && { brief }) };
    }
    return { command, release: release || command === "dist", arch, ...(filters.length > 0 && { filters }),
        ...(brief && { brief }), ...(debugChannel && { debugChannel }) };
}

/// The arguments of dub for `build` or `test` (whose build type is always unittest); `filters`
/// go to unit-threaded's runner of `test`.
export function dubArgs(command, { release, installed, arch, debugChannel, filters = [] }) {
    const args = [command, "--compiler=ldc2"];
    // dist: the release of an installed program, settings in the user's folder (dub.sdl)
    if (command === "build") args.push(`--build=${installed ? "dist" : release ? "release" : "debug"}`);
    // the debug channel (ui/debug_channel) is in a build only when asked, a debug one too
    if (debugChannel && command === "build") args.push("--d-version=DebugChannel");
    if (arch) args.push(`--arch=${dubArchOf[arch]}`);
    if (filters.length > 0) args.push("--", ...filters);
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

/// Every Sciter library of libs/, one per system and architecture: what `pack-libs` packs.
export const sciterLibraries = [sciterLibrary("darwin"),
    ...["linux", "win32"].flatMap((platform) => arches.map((arch) => sciterLibrary(platform, arch)))];

/// The archive a Sciter library is kept as in Git LFS: the library packed by brotli, a quarter
/// of its size, which Node unpacks with no package. The library itself is ignored by git.
export function sciterArchive(library) {
    return `${library}.br`;
}

/// What the library unpacked from an archive was: the hash, size and time of the archive, the
/// size and time of the library. Ignored by git, next to the library.
function unpackedStamp(library) {
    return `${library}.unpacked`;
}

/// Unpacks the archive of a library into the library next to it, unless the library is already
/// the one of this archive: unpacked from it and not changed since. Gives whether it unpacked.
/// Throws, keeping the library, when it changed though the archive didn't: a new Sciter put by
/// hand and not packed yet would be lost.
export function unpackLibrary(library) {
    const archivePath = sciterArchive(library);
    const stampPath = unpackedStamp(library);
    const stamp = existsSync(stampPath) ? readFileSync(stampPath, "utf8").split(" ") : [];
    const [stampHash, ...stampRest] = stamp.length === 5 ? stamp : []; // another one: as if none
    const archiveStats = statSync(archivePath);
    const archiveFile = `${archiveStats.size} ${archiveStats.mtimeMs}`;
    // the archive is read and hashed only when its file changed: a checkout writes it anew
    let archive = null;
    const hash = stampHash !== undefined && stampRest.slice(0, 2).join(" ") === archiveFile ? stampHash
        : createHash("sha256").update(archive = readFileSync(archivePath)).digest("hex");
    if (existsSync(library) && stampHash === hash) {
        const libraryStats = statSync(library);
        if (stampRest.slice(2).join(" ") === `${libraryStats.size} ${libraryStats.mtimeMs}`) {
            if (stampRest.slice(0, 2).join(" ") !== archiveFile) writeStamp(); // touched, same bytes
            return false;
        }
        throw new Error(`${library} isn't the library of ${archivePath}: if it is a new Sciter, `
            + `run "node scripts/build.mjs pack-libs"; else delete it to unpack the archive again`);
    }
    const unpacking = `${library}.${process.pid}.unpacking`; // half written, it's never taken for the library
    writeFileSync(unpacking, brotliDecompressSync(archive ?? readFileSync(archivePath)));
    renameSync(unpacking, library);
    writeStamp();
    return true;

    function writeStamp() {
        const libraryStats = statSync(library);
        writeFileSync(stampPath, `${hash} ${archiveFile} ${libraryStats.size} ${libraryStats.mtimeMs}`);
    }
}

/// Packs a library into its archive (`pack-libs`): the strongest brotli, a window as large as
/// it goes (16 MB), a minute or two for the largest library.
export async function packLibrary(library) {
    const data = readFileSync(library);
    const packed = await promisify(brotliCompress)(data, { params: {
        [zlibConstants.BROTLI_PARAM_QUALITY]: zlibConstants.BROTLI_MAX_QUALITY,
        [zlibConstants.BROTLI_PARAM_LGWIN]: zlibConstants.BROTLI_MAX_WINDOW_BITS,
        [zlibConstants.BROTLI_PARAM_SIZE_HINT]: data.length,
    } });
    writeFileSync(sciterArchive(library), packed);
}

/// Whether these first bytes of a file are a pointer of Git LFS, left in place of a file it
/// hasn't fetched: .lfsconfig excludes libs/ from fetching, or git-lfs wasn't installed.
export function isLfsPointer(head) {
    return head.subarray(0, lfsPointerStart.length).equals(lfsPointerStart);
}

const lfsPointerStart = Buffer.from("version https://git-lfs");

/// The arguments of node that run the JS tests: a pattern, node 22 takes no folder. spec, not
/// node's default: before node 23 that is TAP when the output is no terminal (--brief).
export const jsTestArgs = ["--test", "--test-reporter=spec", "tests/js/*.test.mjs"];

/// The arguments of git that fetch one file of Git LFS and put it in place of its pointer.
/// .lfsconfig excludes libs/ from every fetch (a clone fetches no library) and an --include
/// alone doesn't lift that: the empty --exclude does.
export function lfsPullArgs(file) {
    return ["lfs", "pull", `--include=${file}`, "--exclude="];
}

/// The compiler arguments of `dub describe --data-0` (each argument ends with a zero, a list
/// with one more).
export function compilerArgs(described) {
    return described.split("\0").filter((arg) => arg !== "");
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
    <string>com.demiandavidov.logtracy</string>
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
Name=Log Tracy
Comment=DLT file viewer and analyzer
Exec=${installDir}/${program}
Icon=${installDir}/app.png
Terminal=false
Type=Application
Categories=Development;Utility;
`;
}

/// The disk image of the macOS distribution: LogTracy-<version>-<system>-<arch>, as every installer.
export function dmgName({ version, arch }) {
    return `LogTracy-${version}-macos-${arch}.dmg`;
}

/// The name of the zip of the Windows distribution: the version and the architecture in it.
export function zipName({ version, arch }) {
    return `LogTracy-${version}-windows-${arch}.zip`;
}

/// The command packing `folder` (the folder itself, not only its files) into the zip `path`:
/// PowerShell's Compress-Archive, there on every Windows. Single quotes doubled for PowerShell.
export function zipCommand(folder, path) {
    const quoted = (text) => `'${text.replaceAll("'", "''")}'`;
    return ["powershell", ["-NoProfile", "-NonInteractive", "-Command",
        `Compress-Archive -Path ${quoted(folder)} -DestinationPath ${quoted(path)} -Force`]];
}

/// The command making the disk image `path` of `folder`: `diskutil image create from` where
/// macOS has it (APFS, lzfse: ULFO), else `hdiutil create` (HFS+, zlib: UDZO), which newer macOS
/// calls deprecated but older ones, the CI's runners among them, have alone.
export function dmgCommand(diskutilImage, folder, path) {
    return diskutilImage
        ? ["diskutil", ["image", "create", "from", "--format", "ULFO", "--volumeName", "Log Tracy", folder, path]]
        : ["hdiutil", ["create", "-volname", "Log Tracy", "-srcfolder", folder, "-format", "UDZO", "-ov", path]];
}

/// Whether this macOS has `diskutil image` (macOS 27 and newer, where hdiutil is deprecated)
function hasDiskutilImage() {
    const result = spawnSync("diskutil", ["image", "create", "from", "--help"], { stdio: "ignore" });
    return !result.error && result.status === 0;
}

/// Debian's names of the architectures, for the control file
const debArchOf = { x64: "amd64", arm64: "arm64" };

/// The .deb of the Linux distribution, named as the installers of the other systems
/// (LogTracy-<version>-<system>-<arch>), not as Debian names packages: apt reads the package's
/// name and architecture from its control file, not from the file's name.
export function debName({ version, arch }) {
    return `LogTracy-${version}-linux-${arch}.deb`;
}

/// The control file of the .deb. GTK 3 is what Sciter draws with; libgtk-3-0t64 of newer
/// Ubuntu provides libgtk-3-0. No maintainer's address: the package isn't in any repository.
export function debControl({ version, arch }) {
    return `Package: log-tracy
Version: ${version}
Architecture: ${debArchOf[arch]}
Maintainer: Demian Davidov
Depends: libgtk-3-0
Section: devel
Priority: optional
Description: viewer of DLT and text logs
 Log Tracy opens DLT and text logs of any size, gigabytes too, without loading them into
 memory: search, filters, several views of one log.
`;
}

/// The tree a .deb is packed from (dpkg-deb --build), in `root`: the files of the Linux
/// distribution `dist` (the program, libsciter.so, app.png) in /opt/log_tracy, the desktop
/// entry in /usr/share/applications for every user, DEBIAN/control. The modes are set here:
/// dpkg-deb packs them as they are, the owner is root (--root-owner-group).
export function makeDebRoot(root, { dist, version, arch }) {
    const program = "log_tracy";
    const installDir = `/opt/${program}`;
    const opt = join(root, installDir);
    const applications = join(root, "usr", "share", "applications");
    const debian = join(root, "DEBIAN");
    for (const dir of [opt, applications, debian]) mkdirSync(dir, { recursive: true, mode: 0o755 });
    for (const file of [program, "libsciter.so", "app.png"]) {
        copyFileSync(join(dist, file), join(opt, file));
        chmodSync(join(opt, file), file === program ? 0o755 : 0o644);
    }
    const entry = join(applications, `${program}.desktop`);
    writeFileSync(entry, desktopEntry({ installDir, program }));
    chmodSync(entry, 0o644);
    writeFileSync(join(debian, "control"), debControl({ version, arch }));
    chmodSync(join(debian, "control"), 0o644);
    // mkdirSync's mode is masked by the umask: set the folders once more
    for (const dir of [root, join(root, "opt"), opt, join(root, "usr"), join(root, "usr", "share"), applications, debian])
        chmodSync(dir, 0o755);
}

/// The script next to the macOS bundle: a downloaded program is in quarantine and unsigned,
/// and macOS on arm64 starts no unsigned code. Clears the quarantine and signs (ad-hoc) the
/// Sciter library, then the bundle. A .command opens in Terminal from Finder. The bundle next
/// to it, or, when that can't be written (the script runs from the disk image), the copy
/// already dragged into /Applications.
export function signScript(bundle) {
    return `#!/bin/bash
# Lets macOS start ${bundle}: clears its quarantine and signs it for this machine.
cd "$(dirname "$0")" || exit 1
app="${bundle}"
[ -w "${bundle}" ] || app="/Applications/${bundle}"
if [ ! -w "$app" ]; then
    echo "Drag ${bundle} into Applications first, then open this again."
    exit 1
fi
xattr -cr "$app" &&
codesign --force --sign - "$app/Contents/MacOS/libsciter.dylib" &&
codesign --force --sign - "$app" &&
echo "$app is ready."
`;
}

/// The file the output of every step goes to with --brief (startBrief), null without it.
let briefLog = null;

/// From now on the steps tell only what failed (filterBuildOutput), their whole output appended
/// to `file`, which starts empty. scripts/run.mjs calls it too.
export function startBrief(file = briefLogPath) {
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, "");
    briefLog = file;
}

/// Runs a program, its output shown, or kept with `capture` (up to `maxBuffer`, 1 MB). `echo`
/// tells the command line first; `cwd` is the folder it runs in (the project root). With
/// --brief what is not captured goes to the log, and only its failures are shown.
function run(program, args, { capture = false, echo = !capture, cwd, env } = {}) {
    const brief = briefLog !== null && !capture;
    if (echo && !brief) console.log(`> ${program} ${args.join(" ")}`);
    // dub on Windows may be a dub.cmd (a shim of scoop or chocolatey), which only a shell
    // starts; its arguments here are options without spaces, joined by the shell as they are
    const shell = process.platform === "win32" && program === "dub";
    const options = { encoding: "utf8", shell, cwd, env: env && { ...process.env, ...env }, maxBuffer: 64 * 1024 * 1024 };
    if (!brief) {
        const result = spawnSync(program, args, { ...options, stdio: capture ? ["ignore", "pipe", "pipe"] : "inherit" });
        if (result.error) throw new BuildError(`can't run ${program}: ${result.error.message}`);
        return result;
    }
    // the step's own file, its stdout and stderr in it in the order they were written; then
    // added to the log: another run with --brief may empty the log meanwhile
    const dir = mkdtempSync(join(tmpdir(), "dlt-step-"));
    try {
        const file = join(dir, "output.log");
        const handle = openSync(file, "w");
        let result;
        try {
            result = spawnSync(program, args, { ...options, stdio: ["ignore", handle, handle] });
        } finally {
            closeSync(handle);
        }
        const output = readFileSync(file, "utf8");
        appendFileSync(briefLog, (echo ? `> ${program} ${args.join(" ")}\n` : "") + output);
        if (result.error) throw new BuildError(`can't run ${program}: ${result.error.message}`);
        for (const line of filterBuildOutput(output, { failed: result.status !== 0, root: process.cwd(), log: briefLog }))
            console.log(line);
        return result;
    } finally {
        rmSync(dir, { recursive: true, force: true });
    }
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

/// Makes sure the Sciter library the build will copy is in libs/: unpacked from its archive,
/// which a clone leaves as a pointer of Git LFS (.lfsconfig), so only the archive of this build
/// is fetched, on the first build that needs it. Stops with what to do when it can't be: the
/// program would build and then fail to load it.
function checkSciterLibrary(arch) {
    if (!arches.includes(arch)) return; // no library for it: dub will tell
    const library = sciterLibrary(process.platform, arch);
    const archive = sciterArchive(library);
    if (readArchiveHead(archive) === "pointer") {
        if (briefLog === null) console.log(`Fetching ${archive} from Git LFS`);
        const failed = `${archive} is a pointer of Git LFS, not the library, and fetching it failed: install git `
            + `and git-lfs, run "git lfs install", then "git ${lfsPullArgs(archive).join(" ")}" (docs/building.md).`;
        let pulled;
        try {
            pulled = run("git", lfsPullArgs(archive)).status === 0;
        } catch (error) {
            throw new BuildError(`${error.message}\n${failed}`); // no git on the PATH
        }
        if (!pulled || readArchiveHead(archive) === "pointer") throw new BuildError(failed);
    }
    try {
        if (unpackLibrary(library) && briefLog === null) console.log(`Unpacked ${library}`);
    } catch (error) {
        throw new BuildError(`Can't unpack ${archive} into ${library}: ${error.message}`);
    }
}

/// "pointer" when the archive is a pointer of Git LFS, "archive" otherwise; stops when it is missing.
function readArchiveHead(archive) {
    const head = Buffer.alloc(lfsPointerStart.length);
    let read = 0;
    try {
        const file = openSync(archive, "r");
        try { read = readSync(file, head); } finally { closeSync(file); }
    } catch {
        throw new BuildError(`No Sciter library ${archive}: run "git checkout -- ${archive}" and build again (docs/building.md).`);
    }
    return read === head.length && isLfsPointer(head) ? "pointer" : "archive";
}

/// Packs every Sciter library of libs/ into its archive, side by side (zlib works on threads
/// of its own): after an update of Sciter, before the commit (.ai/workflows/update-sciter.md).
export async function packLibs(libraries = sciterLibraries) {
    // all of them or none: archives of two versions of Sciter would be easy to commit
    const missing = libraries.filter((library) => !existsSync(library));
    if (missing.length > 0)
        throw new BuildError(`No ${missing.join(", ")} to pack: put the libraries of the new Sciter in libs/`);
    await Promise.all(libraries.map(async (library) => {
        await packLibrary(library);
        console.log(`Packed ${sciterArchive(library)}: ${statSync(library).size >> 20} MB into ${statSync(sciterArchive(library)).size >> 20} MB`);
    }));
}

/// Builds (`{ release, arch }`) and gives the folder of the program.
export function build(options) {
    checkSciterLibrary(options.arch ?? process.arch);
    runOrFail("dub", dubArgs("build", options), "Build failed.");
    return targetPath(options);
}

/// The folder a build of `options` ({ release, arch }) goes to, as dub says (nothing is built)
export function targetPath(options) {
    return describe("target-path", dubArgs("build", options))[0];
}

function test(options) {
    checkSciterLibrary(options.arch ?? process.arch);
    const dub = run("dub", dubArgs("test", options)).status === 0;
    // a filter asks for some D tests: the rest would only be in the way
    if (options.filters) {
        console.log(`D unittests: ${dub ? "OK" : "FAILED"}`);
        if (!dub) throw new BuildError("Tests failed.");
        return;
    }
    const js = run(process.execPath, jsTestArgs).status === 0;
    // the names of .ai/, AGENTS.md, CLAUDE.md and .claude/ the code no longer has
    const context = run(process.execPath, ["scripts/utils/check-ai-context.mjs"]).status === 0;
    console.log(`D unittests: ${dub ? "OK" : "FAILED"}, JS tests: ${js ? "OK" : "FAILED"}, `
        + `context of .ai/: ${context ? "OK" : "STALE"}`);
    if (!dub || !js || !context) throw new BuildError("Tests failed.");
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
    const name = "LogTracy";
    const program = join(build({ release: true, installed: true, arch }), "log_tracy");
    return publish("macos", (staging) => {
        const bundle = `${name}.app`;
        makeMacBundle(join(staging, bundle), name, version, program);
        const sign = join(staging, "sign.command");
        writeFileSync(sign, signScript(bundle), { mode: 0o755 });
        runOrFail("bash", [sign], "Signing failed.");
        makeDmg(join(staging, dmgName({ version, arch })), [bundle, "sign.command"].map((f) => join(staging, f)));
    });
}

/// The disk image to install from: the bundle and sign.command next to a link to
/// /Applications, to drag the bundle onto. Compressed, read-only.
function makeDmg(path, files) {
    const folder = mkdtempSync(join(tmpdir(), "dlt-dmg-"));
    try {
        // ditto keeps the signature and attributes of the bundle
        for (const file of files) runOrFail("ditto", [file, join(folder, basename(file))], "Copying into the disk image failed.");
        symlinkSync("/Applications", join(folder, "Applications"));
        runOrFail(...dmgCommand(hasDiskutilImage(), folder, path), "Making the disk image failed.");
    } finally {
        rmSync(folder, { recursive: true, force: true });
    }
}

/// Makes a distribution by `make(folder)` and only when it is all made and copied replaces
/// build/dist/<system> with it: a failed step leaves the previous one as it was. It is made
/// in a temporary folder outside the project (see distMac), copied next to its place and
/// renamed into it.
function publish(system, make) {
    const staging = mkdtempSync(join(tmpdir(), "dlt-dist-"));
    const dir = `build/dist/${system}`;
    // no leading dot: iCloud Drive marks a dot folder hidden and the flag outlives the rename
    const copy = freshDir(`build/dist/${system}-new`);
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
    const target = dirname(builtProgram);
    const contents = join(path, "Contents");
    mkdirSync(join(contents, "MacOS"), { recursive: true });
    mkdirSync(join(contents, "Resources"), { recursive: true });
    const program = join(contents, "MacOS", name);
    copyFileSync(builtProgram, program);
    chmodSync(program, 0o755);
    // the library dub put next to the program: the one it was built and tested with
    copyFileSync(join(target, "libsciter.dylib"), join(contents, "MacOS", "libsciter.dylib"));
    copyFileSync("resources/app-icons/app.icns", join(contents, "Resources", "app.icns"));
    const tags = languages();
    for (const tag of tags) {
        mkdirSync(join(contents, "Resources", `${tag}.lproj`));
        writeFileSync(join(contents, "Resources", `${tag}.lproj`, "InfoPlist.strings"),
            "/* Log Tracy is translated to this language: resources/i18n/translations */\n");
    }
    writeFileSync(join(contents, "Info.plist"), infoPlist({ name, version, languages: tags }));
}

function distLinux(version, arch) {
    const target = build({ release: true, installed: true, arch });
    const program = "log_tracy";
    const installDir = `/opt/${program}`;
    const dir = publish("linux", (staging) => {
        for (const file of [program, "libsciter.so"]) copyFileSync(join(target, file), join(staging, file));
        chmodSync(join(staging, program), 0o755);
        copyFileSync("resources/app-icons/app.png", join(staging, "app.png"));
        writeFileSync(join(staging, `${program}.desktop`), desktopEntry({ installDir, program }));
        makeDeb(join(staging, debName({ version, arch })), { dist: staging, version, arch });
    });
    console.log(`To install: sudo apt install ./${join(dir, debName({ version, arch }))}, `
        + `or copy ${dir} to ${installDir} and link ${program}.desktop.`);
    return dir;
}

/// The .deb of the distribution `dist` (makeDebRoot), by dpkg-deb: there on Debian and Ubuntu
/// (the CI too); on another Linux the distribution is made without it.
function makeDeb(path, { dist, version, arch }) {
    const found = spawnSync("dpkg-deb", ["--version"], { stdio: "ignore" }); // run throws when it is missing
    if (found.error || found.status !== 0) {
        console.log("No dpkg-deb here: the distribution is made without the .deb.");
        return;
    }
    const root = mkdtempSync(join(tmpdir(), "dlt-deb-"));
    try {
        makeDebRoot(root, { dist, version, arch });
        runOrFail("dpkg-deb", ["--root-owner-group", "--build", root, path], "Making the .deb failed.");
    } finally {
        rmSync(root, { recursive: true, force: true });
    }
}

function distWindows(version, arch) {
    const target = build({ release: true, installed: true, arch });
    // the icon is built into the program (resources/app.rc, scripts/windows-res.mjs)
    return publish("windows", (staging) => {
        const files = ["log_tracy.exe", "sciter.dll"];
        for (const file of files) copyFileSync(join(target, file), join(staging, file));
        // the zip to download: a LogTracy folder with the program in it
        const folder = mkdtempSync(join(tmpdir(), "dlt-zip-"));
        try {
            const inZip = join(folder, "LogTracy");
            mkdirSync(inZip);
            for (const file of files) copyFileSync(join(staging, file), join(inZip, file));
            runOrFail(...zipCommand(inZip, join(staging, zipName({ version, arch }))), "Making the zip failed.");
        } finally {
            rmSync(folder, { recursive: true, force: true });
        }
    });
}

function dist(arch) {
    const version = readFileSync("VERSION", "utf8").trim();
    const distArchitecture = distArch(arch, process.arch);
    const dir = process.platform === "darwin" ? distMac(version, distArchitecture)
        : process.platform === "win32" ? distWindows(version, distArchitecture)
        : distLinux(version, distArchitecture);
    console.log(`Log Tracy ${version} (${distArchitecture}): ${dir}`);
}

/// The arguments of ldc2 for the log generator, `dubFlags` the flags and import paths of
/// dub.sdl as dub describes them: optimized (a gigabyte takes a while), the code of the
/// generator in (-d-version=LogGenerator), the program in build/tools/.
export function genLogArgs(dubFlags, platform) {
    const program = `build/tools/gen_log${platform === "win32" ? ".exe" : ""}`;
    return ["-O2", "-i", "-d-version=LogGenerator", ...dubFlags, "scripts/utils/gen_log.d", `-of=${program}`,
        "-od=build/tools/obj", "-oq"];
}

/// The arguments of ldc2 for the unittests of one module (`file`) and of the modules it
/// imports (-i), `dubFlags` the flags and import paths of dub.sdl as dub describes them: a
/// main of druntime's (-main), the program in build/tools/test_<name>.
export function moduleTestArgs(dubFlags, file, platform) {
    const name = `test_${basename(file, ".d")}`;
    return ["-unittest", "-main", "-i", ...dubFlags, file, `-of=build/tools/${name}${platform === "win32" ? ".exe" : ""}`,
        `-od=build/tools/obj/${name}`, "-oq"];
}

/// The flags and import paths of dub.sdl, as dub describes them for a build in `cwd`. dub
/// checks the files of copyFiles even to describe: here the Sciter library is unpacked as for
/// a build; another tree (the base of bench, its LFS files not fetched) gets an empty file in
/// its place, which nothing there loads. `configuration`: the one of dub.sdl to describe, the
/// program's when not given.
function dubCompilerFlags(cwd, configuration) {
    const library = sciterLibrary(process.platform, process.arch);
    if (cwd === undefined || resolve(cwd) === process.cwd()) checkSciterLibrary(process.arch);
    else if (!existsSync(join(cwd, library))) writeFileSync(join(cwd, library), "");
    const described = run("dub", ["describe", "--compiler=ldc2", ...(configuration ? [`--config=${configuration}`] : []),
        "--data=dflags,import-paths", "--data-0"],
        { capture: true, cwd });
    if (described.status !== 0) throw new BuildError(`dub describe failed:\n${described.stderr}`);
    return compilerArgs(described.stdout);
}

/// Builds and runs the unittests of one module, `file` relative to `callerDir` (the folder the
/// script was started from) or to the project root.
function testModule(file, callerDir) {
    const path = [resolve(callerDir, file), resolve(file)].find((candidate) => existsSync(candidate));
    if (!path) throw new BuildError(`no file ${file}`);
    // the configuration of the tests: unit-threaded's import paths, for tests that use its asserts
    const args = moduleTestArgs(dubCompilerFlags(undefined, "unittest"), relative(process.cwd(), path), process.platform);
    runOrFail("ldc2", args, "Building the unittests of the module failed.");
    const program = resolve(args.find((arg) => arg.startsWith("-of=")).slice("-of=".length));
    const status = run(program, [], { echo: false }).status;
    // druntime's runner has no filter and leaves a module at its first failing unittest
    if (status !== 0) throw new BuildError("Tests failed. A module's tests stop at its first failing "
        + "unittest: the ones after it in that module didn't run.");
}

/// Builds the log generator and runs it with `toolArgs` in `callerDir`, the folder the script
/// was started from: a relative path of a log is the user's. Its exit code is the script's.
function genLog(toolArgs, callerDir) {
    const args = genLogArgs(dubCompilerFlags(), process.platform);
    runOrFail("ldc2", args, "Building the log generator failed.");
    const program = resolve(args.find((arg) => arg.startsWith("-of=")).slice("-of=".length));
    const status = run(program, toolArgs, { echo: false, cwd: callerDir }).status;
    if (status !== 0) process.exit(status ?? 1);
}

/// Reads a file through once, so that the first run of a side doesn't read it from the disk
/// while the others find it in the page cache.
function warmPageCache(file) {
    const buffer = Buffer.alloc(8 * 1024 * 1024);
    const handle = openSync(file, "r");
    try {
        while (readSync(handle, buffer, 0, buffer.length, null) > 0);
    } finally {
        closeSync(handle);
    }
}

/// The log `bench` measures when none is given: written once by the generator.
const benchLog = { path: "build/tools/bench-dlt-256M-seed1.dlt", args: ["--format", "dlt", "--size", "256M", "--seed", "1"] };

/// Measures the working tree against a ref (scripts/utils/bench.mjs): a temporary worktree of the
/// ref gets the working tree's benchmark, both sides are built alike and run by turns on one
/// log, then the table of their numbers. The worktree is removed whatever happens.
function benchAgainst(toolArgs, callerDir) {
    const options = parseBenchArgs(toolArgs, (path) => statSync(resolve(callerDir, path), { throwIfNoEntry: false })?.isFile() ?? false);
    if (options.help) {
        process.stdout.write(benchUsage);
        return;
    }
    let log;
    if (options.log !== null) {
        log = resolve(callerDir, options.log);
        if (!existsSync(log)) throw new BuildError(`no log ${log}`);
    } else {
        log = resolve(benchLog.path);
        if (!existsSync(log)) genLog([log, ...benchLog.args], callerDir);
    }
    const benchArgs = options.benchArgs.length ? options.benchArgs : defaultBenchArgs[options.bench];
    const commit = run("git", ["rev-parse", "--verify", "--quiet", `${options.against}^{commit}`], { capture: true });
    if (commit.status !== 0) throw new BuildError(`no commit "${options.against}" in this repository`);
    const ref = commit.stdout.trim();

    const benchFile = `scripts/utils/bench_${options.bench}.d`;
    const sides = [{ name: options.against, tree: mkdtempSync(join(tmpdir(), "dlt-bench-")) },
        { name: "this tree", tree: process.cwd() }];
    const base = sides[0];
    const removeWorktree = () => {
        run("git", ["worktree", "remove", "--force", base.tree], { capture: true });
        rmSync(base.tree, { recursive: true, force: true });
    };
    // Ctrl-C stops the run in progress (the benchmark gets it too), then the worktree goes
    const interrupted = () => {
        removeWorktree();
        process.exit(130);
    };
    process.once("SIGINT", interrupted);
    try {
        // the files of Git LFS (the Sciter libraries) aren't needed: not fetched
        if (run("git", ["worktree", "add", "--detach", "--quiet", base.tree, ref], { env: { GIT_LFS_SKIP_SMUDGE: "1" } }).status !== 0)
            throw new BuildError(`git worktree add ${options.against} failed.`);
        // the same benchmark on both sides: the working tree's (it builds against older code too)
        copyFileSync(benchFile, join(base.tree, benchFile));
        sides.forEach((side, i) => {
            const id = `bench_${options.bench}_${i === 0 ? "base" : "change"}`;
            side.program = resolve("build/tools", `${id}${process.platform === "win32" ? ".exe" : ""}`);
            const args = benchCompileArgs(dubCompilerFlags(side.tree), options.bench, side.program,
                resolve("build/tools/obj", id));
            console.log(`Building ${benchFile} of ${side.name}`);
            if (run("ldc2", args, { echo: false, cwd: side.tree }).status !== 0)
                throw new BuildError(`Building ${benchFile} of ${side.name} failed.`);
            side.outputs = [];
        });
        console.log(`Measuring ${log} ${benchArgs.join(" ")}: ${options.runs} runs a side, by turns`);
        warmPageCache(log);
        for (const [r, order] of runOrder(options.runs).entries()) {
            for (const side of order.map((i) => sides[i])) {
                const started = Date.now();
                const result = run(side.program, [log, ...benchArgs], { capture: true });
                if (result.signal) throw new BuildError(`The benchmark of ${side.name} was stopped (${result.signal}).`);
                if (result.status !== 0)
                    throw new BuildError(`The benchmark of ${side.name} failed:\n${result.stdout}${result.stderr}`);
                side.outputs.push(result.stdout);
                console.log(`  ${side.name}, run ${r + 1}: ${((Date.now() - started) / 1000).toFixed(1)} s`);
            }
        }
    } finally {
        process.off("SIGINT", interrupted);
        removeWorktree();
    }
    const rows = compareRuns(base.outputs, sides[1].outputs);
    console.log(`\n${options.against} (${ref.slice(0, 7)}) against this tree, median (spread) of ${options.runs}; `
        + "less is better:\n");
    process.stdout.write(formatComparison(rows, options.against));
    if (options.json !== null) {
        const file = resolve(callerDir, options.json);
        writeFileSync(file, JSON.stringify({ against: options.against, commit: ref, bench: options.bench, log,
            args: benchArgs, runs: options.runs, rows,
            outputs: { base: base.outputs, change: sides[1].outputs } }, null, 2) + "\n");
        console.log(`\nThe numbers: ${file}`);
    }
}

/// Runs a command line of build.mjs (`argv` without node and the script) the way the command
/// line does: a BuildError or BenchError is told without a stack and exits with 1. test.mjs
/// runs its tests through it.
export function runCommandLine(argv) {
    const fail = (e) => {
        if (!(e instanceof BuildError || e instanceof BenchError)) throw e;
        console.error(e.message);
        if (briefLog !== null) console.error(`The whole output: ${briefLog}`);
        process.exit(1);
    };
    try {
        main(argv)?.catch(fail); // pack-libs is asynchronous
    } catch (e) {
        fail(e);
    }
}

function main(argv) {
    const callerDir = process.cwd();
    process.chdir(fileURLToPath(new URL("..", import.meta.url))); // the project root
    const { command, release, debugChannel, arch, toolArgs, module, filters, brief } = parseCommand(argv);
    if (brief) startBrief();
    if (command === "gen-log") genLog(toolArgs, callerDir);
    else if (command === "bench") benchAgainst(toolArgs, callerDir);
    else if (command === "help") process.stdout.write(buildUsage);
    else if (command === "build") console.log(`Built: ${build({ release, arch, debugChannel })}`);
    else if (command === "test" && module) testModule(module, callerDir);
    else if (command === "test") test({ arch, filters });
    else if (command === "dist") dist(arch);
    else if (command === "pack-libs") return packLibs();
    else throw new Error(`no branch of main for the command "${command}"`);
}

// run, not imported (by the tests); the module's path has its symbolic links resolved, the
// command line's may not
if (process.argv[1] && fileURLToPath(import.meta.url) === realpathSync(process.argv[1]))
    runCommandLine(process.argv.slice(2));
