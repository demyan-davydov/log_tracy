// The pure part of scripts/build.mjs: the command line, the dub calls, the files of a bundle.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { parseCommand, dubArgs, distArch, infoPlist, desktopEntry, sciterLibrary, isLfsPointer,
    compilerArgs, genLogArgs, moduleTestArgs, commands, buildUsage, runUsage } from "../../scripts/build.mjs";

test("build in debug for the machine by default", () => {
    assert.deepEqual(parseCommand([]), { command: "build", release: false, arch: null });
});

test("a command, release and an architecture", () => {
    assert.deepEqual(parseCommand(["build", "--release", "--arch", "x64"]),
        { command: "build", release: true, arch: "x64" });
    assert.deepEqual(parseCommand(["--arch=arm64"]), { command: "build", release: false, arch: "arm64" });
    assert.deepEqual(parseCommand(["test"]), { command: "test", release: false, arch: null });
    assert.deepEqual(parseCommand(["dist"]), { command: "dist", release: true, arch: null });
    assert.deepEqual(parseCommand(["check-windows"]), { command: "check-windows", release: false, arch: null });
});

test("what isn't understood is refused, naming it", () => {
    assert.throws(() => parseCommand(["pack"]), /pack/);
    assert.throws(() => parseCommand(["--fast"]), /--fast/);
    assert.throws(() => parseCommand(["--arch", "x86"]), /x86/);
    assert.throws(() => parseCommand(["--arch"]), /--arch/);
    assert.throws(() => parseCommand(["build", "test"]), /test/);
    assert.throws(() => parseCommand(["run"]), /run/);
});

test("an option the command would ignore is refused", () => {
    assert.throws(() => parseCommand(["test", "--release"]), /--release/);
    assert.throws(() => parseCommand(["check-windows", "--release"]), /--release/);
    assert.throws(() => parseCommand(["check-windows", "--arch", "arm64"]), /--arch/);
});

test("the dub calls: ldc2 always, the build type, the architecture as dub names it", () => {
    assert.deepEqual(dubArgs("build", { release: false, arch: null }),
        ["build", "--compiler=ldc2", "--build=debug"]);
    assert.deepEqual(dubArgs("build", { release: true, arch: "x64" }),
        ["build", "--compiler=ldc2", "--build=release", "--arch=x86_64"]);
    assert.deepEqual(dubArgs("test", { release: false, arch: "arm64" }),
        ["test", "--compiler=ldc2", "--arch=aarch64"]);
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
    const plist = infoPlist({ name: "DltExplorer", version: "1.2.3", languages: ["en", "ru"] });
    assert.match(plist, /<key>CFBundleShortVersionString<\/key>\s*<string>1\.2\.3<\/string>/);
    assert.match(plist, /<key>CFBundleVersion<\/key>\s*<string>1\.2\.3<\/string>/);
    assert.match(plist, /<key>CFBundleExecutable<\/key>\s*<string>DltExplorer<\/string>/);
    assert.match(plist, /<array>\s*<string>en<\/string>\s*<string>ru<\/string>\s*<\/array>/);
});

test("the desktop entry starts the program where it is installed", () => {
    const entry = desktopEntry({ installDir: "/opt/dlt_explorer", program: "dlt_explorer" });
    assert.match(entry, /^\[Desktop Entry\]$/m);
    assert.match(entry, /^Exec=\/opt\/dlt_explorer\/dlt_explorer$/m);
    assert.match(entry, /^Icon=\/opt\/dlt_explorer\/app\.png$/m);
});

test("the Sciter library of a system and an architecture", () => {
    assert.equal(sciterLibrary("darwin", "arm64"), "libs/macosx/libsciter.dylib");
    assert.equal(sciterLibrary("darwin", "x64"), "libs/macosx/libsciter.dylib"); // universal
    assert.equal(sciterLibrary("linux", "x64"), "libs/linux/x64/libsciter.so");
    assert.equal(sciterLibrary("win32", "arm64"), "libs/windows/arm64/sciter.dll");
});

test("a file Git LFS hasn't fetched is a pointer, a library is not", () => {
    const pointer = "version https://git-lfs.github.com/spec/v1\noid sha256:4ae7\nsize 25056928\n";
    assert.equal(isLfsPointer(Buffer.from(pointer)), true);
    assert.equal(isLfsPointer(Buffer.from([0xcf, 0xfa, 0xed, 0xfe, 7, 0, 0, 1])), false); // Mach-O
    assert.equal(isLfsPointer(Buffer.from("MZ\x90\0")), false);
    assert.equal(isLfsPointer(Buffer.alloc(0)), false);
});

test("the compiler arguments dub describes, separated by zeros, without the resource script", () => {
    const described = "-I/p/source/\0-I/d/source/\0\0-J/p/resources/\0\0-preview=in\0-mtriple=x86_64-windows-msvc"
        + "\0\0/p/source/app.d\0/p/resources/app.rc\0/p/source/ui/x.d";
    assert.deepEqual(compilerArgs(described), ["-I/p/source/", "-I/d/source/", "-J/p/resources/",
        "-preview=in", "-mtriple=x86_64-windows-msvc", "/p/source/app.d", "/p/source/ui/x.d"]);
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
    assert.ok(args.includes("scripts/gen_log.d"));
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

test("one module is compiled with its unittests, a main and the flags of dub.sdl, into build/tools", () => {
    const args = moduleTestArgs(["-preview=in", "-I/p/source/"], "source/utils/fsm.d", "darwin");
    assert.ok(args.includes("-unittest") && args.includes("-main") && args.includes("-i"));
    assert.ok(args.includes("-preview=in") && args.includes("-I/p/source/"));
    assert.ok(args.includes("source/utils/fsm.d"));
    assert.ok(args.includes("-of=build/tools/test_fsm"));
    assert.ok(args.includes("-od=build/tools/obj/test_fsm"));
    assert.ok(moduleTestArgs([], "source/utils/fsm.d", "win32").includes("-of=build/tools/test_fsm.exe"));
});

test("bench passes everything after it to scripts/bench.mjs, its --help too", () => {
    assert.deepEqual(parseCommand(["bench", "big.dlt", "--runs", "5"]),
        { command: "bench", release: false, arch: null, toolArgs: ["big.dlt", "--runs", "5"] });
    assert.deepEqual(parseCommand(["bench", "--help"]), { command: "bench", release: false, arch: null, toolArgs: ["--help"] });
    assert.throws(() => parseCommand(["--release", "bench"]), /bench comes first/);
});
