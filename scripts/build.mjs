// Builds, tests and packs DLT Explorer on macOS, Linux and Windows alike: one script instead of
// one per system. dub does the building: dub.sdl puts every build in
// build/<platform>-<arch>-<build type>/ with the Sciter library of libs/ next to the program.
//   node scripts/build.mjs [build] [--release] [--arch x64|arm64]   debug for this machine by default
//   node scripts/build.mjs test [--arch ...]       the D unittests and the JS tests (tests/js)
//   node scripts/build.mjs dist [--arch ...]       a release distribution in build/dist/<system>/;
//                                                  on macOS universal (x86_64 + arm64) unless --arch
//   node scripts/build.mjs check-windows           compiles the app and its unittests for Windows x64
//                                                  from macOS or Linux, without linking
// Tests: tests/js/build-script.test.mjs.
import { spawnSync } from "node:child_process";
import { chmodSync, copyFileSync, cpSync, mkdirSync, mkdtempSync, readdirSync, readFileSync,
    realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const commands = ["build", "test", "dist", "check-windows"];
const arches = ["x64", "arm64"];
const dubArchOf = { x64: "x86_64", arm64: "aarch64" };

/// A command line not understood, or a step that failed: told without a stack.
class BuildError extends Error {}

/// What the command line asks: `{ command, release, arch }`, `arch` null for this machine's.
/// A distribution is always a release.
export function parseCommand(argv) {
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

/// The architectures a distribution is built for: both on macOS (glued into a universal
/// program, this machine's first: a compile error shows there, not as a missing runtime of
/// the other), else the one asked or this machine's. `hostArch` is Node's (`process.arch`).
export function distArches(platform, arch, hostArch) {
    if (arch) return [arch];
    if (!arches.includes(hostArch))
        throw new BuildError(`no build for this machine's architecture "${hostArch}": `
            + `name one with --arch (${arches.join(", ")})`);
    if (platform !== "darwin") return [hostArch];
    return [hostArch, ...arches.filter((other) => other !== hostArch)];
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

function run(program, args, { capture = false } = {}) {
    if (!capture) console.log(`> ${program} ${args.join(" ")}`);
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

/// Builds and gives the folder of the program.
function build(options) {
    const args = dubArgs("build", options);
    runOrFail("dub", args, "Build failed.");
    return describe("target-path", args)[0];
}

function test(options) {
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

function distMac(version, archList) {
    const name = "DltExplorer";
    const programs = archList.map((arch, i) => {
        try {
            return join(build({ release: true, arch }), "dlt_explorer");
        } catch (e) {
            // the first architecture built, the code compiles: the other failing is most likely
            // ldc2 having no runtime for it
            if (i === 0 || !(e instanceof BuildError)) throw e;
            throw new BuildError(`Building for ${arch} failed after ${archList[0]} was built: see the `
                + "errors above. If it is the linking, ldc2 has no runtime for that architecture: "
                + "the osx-universal package of LDC has both, Homebrew's only its own. "
                + `Or build for this machine only: dist --arch ${archList[0]}.`);
        }
    });
    // The bundle is made and signed outside the project: a folder synced by iCloud (Documents)
    // puts Finder information on a new bundle, and codesign refuses to sign one that has it
    return publish("macos", (staging) => {
        const bundle = `${name}.app`;
        makeMacBundle(join(staging, bundle), name, version, programs);
        const sign = join(staging, "sign.command");
        writeFileSync(sign, signScript(bundle), { mode: 0o755 });
        runOrFail("bash", [sign], "Signing failed.");
    });
}

/// Makes a distribution in a temporary folder by `make(folder)`, and only when it is all made
/// replaces build/dist/<system> with it: a failed step leaves the previous one as it was.
function publish(system, make) {
    const staging = mkdtempSync(join(tmpdir(), "dlt-dist-"));
    try {
        make(staging);
        const dir = freshDir(`build/dist/${system}`);
        // ditto keeps the signature and attributes of a bundle as they are
        if (process.platform === "darwin") runOrFail("ditto", [staging, dir], "Copying the distribution failed.");
        else cpSync(staging, dir, { recursive: true });
        return dir;
    } finally {
        rmSync(staging, { recursive: true, force: true });
    }
}

function makeMacBundle(path, name, version, programs) {
    const contents = join(path, "Contents");
    mkdirSync(join(contents, "MacOS"), { recursive: true });
    mkdirSync(join(contents, "Resources"), { recursive: true });
    const program = join(contents, "MacOS", name);
    if (programs.length > 1) runOrFail("lipo", ["-create", ...programs, "-output", program], "lipo failed.");
    else copyFileSync(programs[0], program);
    chmodSync(program, 0o755);
    copyFileSync("libs/macosx/libsciter.dylib", join(contents, "MacOS", "libsciter.dylib"));
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
    const archList = distArches(process.platform, arch, process.arch);
    const dir = process.platform === "darwin" ? distMac(version, archList)
        : process.platform === "win32" ? distWindows(archList[0])
        : distLinux(archList[0]);
    console.log(`DLT Explorer ${version} (${archList.join(" + ")}): ${dir}`);
}

/// Compiles the app and its unittests for Windows x64 with the flags dub would give, without
/// linking: the libraries of Windows aren't here. A full check needs Windows (`test`).
function checkWindows() {
    const dubBuild = dubArgs("build", { release: false, arch: null });
    const flags = [
        ...describe("import-paths", dubBuild).map((path) => `-I${path}`),
        ...describe("string-import-paths", dubBuild).map((path) => `-J${path}`),
        ...describe("dflags", dubBuild),
    ];
    const sources = describe("source-files", dubBuild).filter((file) => file.endsWith(".d")); // not app.rc
    const out = mkdtempSync(join(tmpdir(), "dlt-check-windows-"));
    let ok = true;
    try {
        for (const mode of ["app", "unittest"]) {
            const args = ["-c", "-mtriple=x86_64-windows-msvc", ...flags,
                ...(mode === "unittest" ? ["-unittest"] : []), "-oq", `-od=${join(out, mode)}`, ...sources];
            const passed = run("ldc2", args, { capture: true });
            if (passed.status !== 0) process.stderr.write(passed.stderr);
            console.log(`Windows compile (${mode}): ${passed.status === 0 ? "OK" : "FAILED"}`);
            ok &&= passed.status === 0;
        }
    } finally {
        rmSync(out, { recursive: true, force: true });
    }
    if (!ok) throw new BuildError("Windows compile failed.");
}

function main(argv) {
    process.chdir(fileURLToPath(new URL("..", import.meta.url))); // the project root
    const { command, release, arch } = parseCommand(argv);
    if (command === "build") console.log(`Built: ${build({ release, arch })}`);
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
