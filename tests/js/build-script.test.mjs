// The pure part of scripts/build.mjs: the command line, the dub calls, the files of a bundle.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { parseCommand, dubArgs, distArch, infoPlist, desktopEntry, sciterLibrary, isLfsPointer,
    compilerArgs } from "../../scripts/build.mjs";

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
