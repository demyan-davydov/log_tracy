// The pure part of scripts/build.mjs: the command line, the dub calls, the files of a bundle.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseCommand, dubArgs, distArch, infoPlist, desktopEntry, sciterLibrary, sciterLibraries, sciterArchive, unpackLibrary,
    packLibrary, packLibs, isLfsPointer, lfsPullArgs, jsTestArgs,
    compilerArgs, genLogArgs, moduleTestArgs, commands, buildUsage, runUsage, testUsage, dmgName, debName, debControl, zipName, zipCommand,
    makeDebRoot, signScript, dmgCommand } from "../../scripts/build.mjs";

test("build in debug for the machine by default", () => {
    assert.deepEqual(parseCommand([]), { command: "build", release: false, arch: null });
});

test("a command, release and an architecture", () => {
    assert.deepEqual(parseCommand(["build", "--release", "--arch", "x64"]),
        { command: "build", release: true, arch: "x64" });
    assert.deepEqual(parseCommand(["--arch=arm64"]), { command: "build", release: false, arch: "arm64" });
    assert.deepEqual(parseCommand(["test"]), { command: "test", release: false, arch: null });
    assert.deepEqual(parseCommand(["dist"]), { command: "dist", release: true, arch: null });
    assert.deepEqual(parseCommand(["pack-libs"]), { command: "pack-libs", release: false, arch: null });
});

test("what isn't understood is refused, naming it", () => {
    assert.throws(() => parseCommand(["pack"]), /pack/);
    assert.throws(() => parseCommand(["--fast"]), /--fast/);
    assert.throws(() => parseCommand(["--arch", "x86"]), /x86/);
    assert.throws(() => parseCommand(["--arch"]), /--arch/);
    assert.throws(() => parseCommand(["build", "test"]), /test/);
    assert.throws(() => parseCommand(["run"]), /run/);
    assert.throws(() => parseCommand(["check-windows"]), /check-windows/); // gone: CI builds on Windows
});

test("an option the command would ignore is refused", () => {
    assert.throws(() => parseCommand(["test", "--release"]), /--release/);
    assert.throws(() => parseCommand(["pack-libs", "--release"]), /--release/);
    assert.throws(() => parseCommand(["pack-libs", "--arch", "x64"]), /--arch/);
});

test("the dub calls: ldc2 always, the build type, the architecture as dub names it", () => {
    assert.deepEqual(dubArgs("build", { release: false, arch: null }),
        ["build", "--compiler=ldc2", "--build=debug"]);
    assert.deepEqual(dubArgs("build", { release: true, arch: "x64" }),
        ["build", "--compiler=ldc2", "--build=release", "--arch=x86_64"]);
    assert.deepEqual(dubArgs("test", { release: false, arch: "arm64" }),
        ["test", "--compiler=ldc2", "--arch=aarch64"]);
});

test("a distribution builds the installed program: dub's build type dist", () => {
    assert.deepEqual(dubArgs("build", { release: true, installed: true, arch: null }),
        ["build", "--compiler=ldc2", "--build=dist"]);
});

test("a distribution is for the architecture asked, else this machine's: no universal macOS one yet", () => {
    assert.equal(distArch(null, "arm64"), "arm64");
    assert.equal(distArch("x64", "arm64"), "x64");
    assert.equal(distArch(null, "x64"), "x64");
});

test("a machine of an architecture not known is told to name one", () => {
    assert.throws(() => distArch(null, "ia32"), /ia32.*--arch/);
    assert.equal(distArch("arm64", "ia32"), "arm64");
});

test("the Info.plist names the version and the languages", () => {
    const plist = infoPlist({ name: "LogTracy", version: "1.2.3", languages: ["en", "ru"] });
    assert.match(plist, /<key>CFBundleShortVersionString<\/key>\s*<string>1\.2\.3<\/string>/);
    assert.match(plist, /<key>CFBundleVersion<\/key>\s*<string>1\.2\.3<\/string>/);
    assert.match(plist, /<key>CFBundleExecutable<\/key>\s*<string>LogTracy<\/string>/);
    assert.match(plist, /<array>\s*<string>en<\/string>\s*<string>ru<\/string>\s*<\/array>/);
});

test("the desktop entry starts the program where it is installed", () => {
    const entry = desktopEntry({ installDir: "/opt/log_tracy", program: "log_tracy" });
    assert.match(entry, /^\[Desktop Entry\]$/m);
    assert.match(entry, /^Exec=\/opt\/log_tracy\/log_tracy$/m);
    assert.match(entry, /^Icon=\/opt\/log_tracy\/app\.png$/m);
});

test("the installers are named by the version and the architecture as each system names it", () => {
    // one shape on every system: LogTracy-<version>-<system>-<arch>, x64 on Linux too
    assert.equal(dmgName({ version: "1.2.3", arch: "arm64" }), "LogTracy-1.2.3-macos-arm64.dmg");
    assert.equal(dmgName({ version: "1.2.3", arch: "x64" }), "LogTracy-1.2.3-macos-x64.dmg");
    assert.equal(debName({ version: "1.2.3", arch: "x64" }), "LogTracy-1.2.3-linux-x64.deb");
    assert.equal(debName({ version: "1.2.3", arch: "arm64" }), "LogTracy-1.2.3-linux-arm64.deb");
    assert.equal(zipName({ version: "1.2.3", arch: "x64" }), "LogTracy-1.2.3-windows-x64.zip");
    assert.equal(zipName({ version: "1.2.3", arch: "arm64" }), "LogTracy-1.2.3-windows-arm64.zip");
});

test("the disk image by diskutil image where macOS has it, else by hdiutil", () => {
    assert.deepEqual(dmgCommand(true, "/t/dmg", "/t/L.dmg"), ["diskutil",
        ["image", "create", "from", "--format", "ULFO", "--volumeName", "Log Tracy", "/t/dmg", "/t/L.dmg"]]);
    assert.deepEqual(dmgCommand(false, "/t/dmg", "/t/L.dmg"), ["hdiutil",
        ["create", "-volname", "Log Tracy", "-srcfolder", "/t/dmg", "-format", "UDZO", "-ov", "/t/L.dmg"]]);
});

test("the control file of the .deb: the package, its version, Debian's architecture, GTK 3", () => {
    const control = debControl({ version: "1.2.3", arch: "x64" });
    assert.match(control, /^Package: log-tracy$/m);
    assert.match(control, /^Version: 1\.2\.3$/m);
    assert.match(control, /^Architecture: amd64$/m);
    assert.match(control, /^Depends: libgtk-3-0$/m);
    assert.match(control, /^Description: .+\n .+/m); // a summary and a long description
    assert.ok(control.endsWith("\n"), "dpkg-deb wants the last line ended");
});

// the modes of the files are Unix's, which Windows doesn't keep; a .deb is made on Linux only
test("the tree of the .deb: the program in /opt, the desktop entry in the system's applications",
    { skip: process.platform === "win32" && "no Unix file modes on Windows" }, () => {
    const dist = mkdtempSync(join(tmpdir(), "deb-dist-"));
    const root = mkdtempSync(join(tmpdir(), "deb-root-"));
    try {
        for (const file of ["log_tracy", "libsciter.so", "app.png"]) writeFileSync(join(dist, file), file);
        makeDebRoot(root, { dist, version: "1.2.3", arch: "arm64" });
        const mode = (path) => statSync(join(root, path)).mode & 0o777;
        assert.equal(mode("opt/log_tracy/log_tracy"), 0o755);
        assert.equal(mode("opt/log_tracy/libsciter.so"), 0o644);
        assert.equal(mode("opt/log_tracy/app.png"), 0o644);
        assert.match(readFileSync(join(root, "usr/share/applications/log_tracy.desktop"), "utf8"),
            /^Exec=\/opt\/log_tracy\/log_tracy$/m);
        assert.match(readFileSync(join(root, "DEBIAN/control"), "utf8"), /^Architecture: arm64$/m);
    } finally {
        rmSync(dist, { recursive: true, force: true });
        rmSync(root, { recursive: true, force: true });
    }
});

test("the zip of Windows is made by PowerShell, the folder in it, quoted for PowerShell", () => {
    assert.deepEqual(zipCommand("C:\\t\\LogTracy", "D:\\dist\\it's.zip"), ["powershell", ["-NoProfile", "-NonInteractive",
        "-Command", "Compress-Archive -Path 'C:\\t\\LogTracy' -DestinationPath 'D:\\dist\\it''s.zip' -Force"]]);
});

test("sign.command signs the bundle next to it, else, from the read-only image, the one in /Applications", () => {
    const script = signScript("LogTracy.app");
    assert.match(script, /\[ -w "LogTracy\.app" \]/);
    assert.match(script, /"\/Applications\/LogTracy\.app"/);
    assert.match(script, /codesign --force --sign - "\$app"/);
});

test("the Sciter library of a system and an architecture", () => {
    assert.equal(sciterLibrary("darwin", "arm64"), "libs/macosx/libsciter.dylib");
    assert.equal(sciterLibrary("darwin", "x64"), "libs/macosx/libsciter.dylib"); // universal
    assert.equal(sciterLibrary("linux", "x64"), "libs/linux/x64/libsciter.so");
    assert.equal(sciterLibrary("win32", "arm64"), "libs/windows/arm64/sciter.dll");
});

test("a Sciter library is kept as its archive of brotli next to it", () => {
    assert.equal(sciterArchive("libs/windows/x64/sciter.dll"), "libs/windows/x64/sciter.dll.br");
});

test("pack-libs packs the libraries dub copies, every one", () => {
    const copied = [...readFileSync(new URL("../../dub.sdl", import.meta.url), "utf8").matchAll(/^copyFiles "([^"]+)"/gm)].map((m) => m[1]);
    assert.deepEqual([...sciterLibraries].sort(), copied.sort());
    for (const library of sciterLibraries) assert.ok(sciterLibraries.includes(sciterLibrary(...platformOf(library))));
});

function platformOf(library) {
    const [, system, arch = "arm64"] = library.split("/");
    return [{ macosx: "darwin", windows: "win32", linux: "linux" }[system], arch];
}

test("a library is unpacked from its archive once, and again when the archive changes", async () => {
    const dir = mkdtempSync(join(tmpdir(), "libs-"));
    try {
        const library = join(dir, "libsciter.so");
        writeFileSync(library, "version 1 ".repeat(1000));
        await packLibrary(library);
        rmSync(library);
        assert.equal(unpackLibrary(library), true);
        assert.equal(readFileSync(library, "utf8"), "version 1 ".repeat(1000));
        assert.equal(unpackLibrary(library), false); // already the one of the archive

        writeFileSync(library, "version 2 ".repeat(1000));
        await packLibrary(library); // a checkout brings another archive
        writeFileSync(library, "stale");
        assert.equal(unpackLibrary(library), true);
        assert.equal(readFileSync(library, "utf8"), "version 2 ".repeat(1000));

        // the library changed, the archive didn't: a new Sciter put by hand, not packed yet
        writeFileSync(library, "new Sciter");
        assert.throws(() => unpackLibrary(library), /pack-libs/);
        assert.equal(readFileSync(library, "utf8"), "new Sciter"); // kept
        rmSync(library); // deleted: unpacked again
        assert.equal(unpackLibrary(library), true);
        assert.equal(readFileSync(library, "utf8"), "version 2 ".repeat(1000));
    } finally {
        rmSync(dir, { recursive: true, force: true });
    }
});

test("pack-libs packs nothing when a library is missing", async () => {
    const dir = mkdtempSync(join(tmpdir(), "libs-"));
    try {
        const present = join(dir, "sciter.dll");
        writeFileSync(present, "library");
        await assert.rejects(packLibs([present, join(dir, "libsciter.so")]), /libsciter\.so/);
        assert.equal(existsSync(sciterArchive(present)), false);
    } finally {
        rmSync(dir, { recursive: true, force: true });
    }
});

test("a file Git LFS hasn't fetched is a pointer, a library is not", () => {
    const pointer = "version https://git-lfs.github.com/spec/v1\noid sha256:4ae7\nsize 25056928\n";
    assert.equal(isLfsPointer(Buffer.from(pointer)), true);
    assert.equal(isLfsPointer(Buffer.from([0xcf, 0xfa, 0xed, 0xfe, 7, 0, 0, 1])), false); // Mach-O
    assert.equal(isLfsPointer(Buffer.from("MZ\x90\0")), false);
    assert.equal(isLfsPointer(Buffer.alloc(0)), false);
});

test("only the Sciter library of the build is pulled, past the exclusion of .lfsconfig", () => {
    // .lfsconfig excludes libs/ from every fetch: an --include alone fetches nothing
    assert.deepEqual(lfsPullArgs("libs/linux/x64/libsciter.so"),
        ["lfs", "pull", "--include=libs/linux/x64/libsciter.so", "--exclude="]);
});

test("the JS tests are named by a pattern: node 22 takes no folder", () => {
    assert.deepEqual(jsTestArgs, ["--test", "--test-reporter=spec", "tests/js/*.test.mjs"]);
});

test("the compiler arguments dub describes, separated by zeros", () => {
    const described = "-preview=in\0-preview=dip1000\0\0-I/p/source/\0-I/d/source/\0\0";
    assert.deepEqual(compilerArgs(described), ["-preview=in", "-preview=dip1000", "-I/p/source/", "-I/d/source/"]);
});

test("--help or -h asks for the help, whatever else is given", () => {
    const help = { command: "help", release: false, arch: null };
    assert.deepEqual(parseCommand(["--help"]), help);
    assert.deepEqual(parseCommand(["-h"]), help);
    assert.deepEqual(parseCommand(["dist", "--arch", "arm64", "--help"]), help);
    assert.deepEqual(parseCommand(["pack", "-h"]), help);
    assert.deepEqual(parseCommand(["--help", "gen-log"]), help); // gen-log not first: the script's own help
});

test("the help names every command and option", () => {
    assert.ok(commands.length >= 4);
    for (const command of commands) assert.match(buildUsage, new RegExp(`\\b${command}\\b`), command);
    for (const usage of [buildUsage, runUsage]) {
        assert.match(usage, /--release/);
        assert.match(usage, /--arch x64\|arm64/);
        assert.match(usage, /--help/);
    }
    assert.match(runUsage, /run\.mjs/);
    assert.doesNotMatch(runUsage, /check-windows/);
});

test("gen-log passes everything after it to the generator, its --help too", () => {
    assert.deepEqual(parseCommand(["gen-log", "big.dlt", "--format", "dlt", "--size", "1G"]),
        { command: "gen-log", release: false, arch: null, toolArgs: ["big.dlt", "--format", "dlt", "--size", "1G"] });
    assert.deepEqual(parseCommand(["gen-log", "--help"]),
        { command: "gen-log", release: false, arch: null, toolArgs: ["--help"] });
    assert.throws(() => parseCommand(["--release", "gen-log", "x.dlt"]), /gen-log/);
});

test("the generator is compiled optimized, with its version and the flags of dub.sdl, into build/tools", () => {
    const args = genLogArgs(["-preview=in", "-I/p/source/"], "darwin");
    assert.ok(args.includes("-O2") && args.includes("-i") && args.includes("-d-version=LogGenerator"));
    assert.ok(args.includes("-preview=in") && args.includes("-I/p/source/"));
    assert.ok(args.includes("scripts/utils/gen_log.d"));
    assert.ok(args.includes("-of=build/tools/gen_log"));
    assert.ok(genLogArgs([], "win32").includes("-of=build/tools/gen_log.exe"));
});

test("test --module tests one D module, its path kept as given", () => {
    assert.deepEqual(parseCommand(["test", "--module", "source/utils/fsm.d"]),
        { command: "test", release: false, arch: null, module: "source/utils/fsm.d" });
    assert.deepEqual(parseCommand(["test", "--module=source/utils/fsm.d"]),
        { command: "test", release: false, arch: null, module: "source/utils/fsm.d" });
    assert.throws(() => parseCommand(["test", "--module"]), /--module/);
    assert.throws(() => parseCommand(["test", "--module", "fsm.txt"]), /\.d/);
    assert.throws(() => parseCommand(["build", "--module", "source/utils/fsm.d"]), /--module/);
    assert.throws(() => parseCommand(["--module", "source/utils/fsm.d"]), /--module/);
    assert.throws(() => parseCommand(["test", "--module", "source/utils/fsm.d", "--arch", "x64"]), /--arch/);
    assert.match(buildUsage, /--module/);
});

test("test --filter runs the D unittests whose names start with the ones given, through unit-threaded's runner", () => {
    assert.deepEqual(parseCommand(["test", "--filter", "utils.fsm", "--filter=formats.dlt"]),
        { command: "test", release: false, arch: null, filters: ["utils.fsm", "formats.dlt"] });
    assert.deepEqual(dubArgs("test", { release: false, arch: null, filters: ["utils.fsm", "formats.dlt"] }),
        ["test", "--compiler=ldc2", "--", "utils.fsm", "formats.dlt"]);
    assert.throws(() => parseCommand(["test", "--filter"]), /--filter/);
    assert.throws(() => parseCommand(["build", "--filter", "utils.fsm"]), /--filter/);
    assert.throws(() => parseCommand(["test", "--filter", "utils.fsm", "--module", "source/utils/fsm.d"]), /--filter/);
    for (const usage of [buildUsage, testUsage]) assert.match(usage, /--filter/);
});

test("one module is compiled with its unittests, a main and the flags of dub.sdl, into build/tools", () => {
    const args = moduleTestArgs(["-preview=in", "-I/p/source/"], "source/utils/fsm.d", "darwin");
    assert.ok(args.includes("-unittest") && args.includes("-main") && args.includes("-i"));
    assert.ok(args.includes("-preview=in") && args.includes("-I/p/source/"));
    assert.ok(args.includes("source/utils/fsm.d"));
    assert.ok(args.includes("-of=build/tools/test_fsm"));
    assert.ok(args.includes("-od=build/tools/obj/test_fsm"));
    assert.ok(moduleTestArgs([], "source/utils/fsm.d", "win32").includes("-of=build/tools/test_fsm.exe"));
});

test("--brief: build, test and dist tell only what failed", () => {
    assert.deepEqual(parseCommand(["test", "--brief"]), { command: "test", release: false, arch: null, brief: true });
    assert.deepEqual(parseCommand(["--brief", "--release"]), { command: "build", release: true, arch: null, brief: true });
    assert.deepEqual(parseCommand(["dist", "--brief"]), { command: "dist", release: true, arch: null, brief: true });
    assert.deepEqual(parseCommand(["test", "--module", "source/utils/fsm.d", "--brief"]),
        { command: "test", release: false, arch: null, module: "source/utils/fsm.d", brief: true });
    // gen-log and bench take their own options: --brief is theirs to refuse
    assert.deepEqual(parseCommand(["gen-log", "x.dlt", "--brief"]).toolArgs, ["x.dlt", "--brief"]);
    for (const usage of [buildUsage, runUsage]) assert.match(usage, /--brief/);
});

test("bench passes everything after it to scripts/utils/bench.mjs, its --help too", () => {
    assert.deepEqual(parseCommand(["bench", "big.dlt", "--runs", "5"]),
        { command: "bench", release: false, arch: null, toolArgs: ["big.dlt", "--runs", "5"] });
    assert.deepEqual(parseCommand(["bench", "--help"]), { command: "bench", release: false, arch: null, toolArgs: ["--help"] });
    assert.throws(() => parseCommand(["--release", "bench"]), /bench comes first/);
});
