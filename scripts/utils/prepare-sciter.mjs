// Puts the Sciter library of a build in libs/, ready for dub to copy next to the program: a
// clone leaves its archive as a pointer of Git LFS (.lfsconfig), so the archive of this build is
// fetched and unpacked here. dub runs it before every build, run and test (preGenerateCommands
// of dub.sdl), up to date or not, and tells the architecture in DUB_ARCH; --arch x64|arm64
// names it by hand. Tests: tests/js/prepare-sciter-script.test.mjs.
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { BuildError, checkSciterLibrary } from "../sciter-library.mjs";

const archOfDubArch = { x86_64: "x64", aarch64: "arm64" };

/// The architecture of build.mjs ("x64", "arm64") for what dub tells in DUB_ARCH: the first
/// word, the architecture, then the features of the target ("aarch64 arm_hardfloat"). Null when
/// there is no library for it.
export function archOfDub(dubArch) {
    return archOfDubArch[(dubArch ?? "").split(/\s+/)[0]] ?? null;
}

/// The architecture to prepare for: `--arch` of the command line, else what dub tells in
/// DUB_ARCH, else the machine's (`hostArch`, Node's).
export function pickArch(argv, env, hostArch) {
    const asked = argv.indexOf("--arch");
    if (asked >= 0) return argv[asked + 1];
    return env.DUB_ARCH ? archOfDub(env.DUB_ARCH) : hostArch;
}

function main(argv) {
    process.chdir(fileURLToPath(new URL("../..", import.meta.url))); // the project root
    try {
        checkSciterLibrary(pickArch(argv, process.env, process.arch));
        return 0;
    } catch (error) {
        if (!(error instanceof BuildError)) throw error;
        console.error(error.message);
        return 1;
    }
}

// run, not imported (by the tests); the module's path has its symbolic links resolved, the
// command line's may not
if (process.argv[1] && fileURLToPath(import.meta.url) === realpathSync(process.argv[1]))
    process.exitCode = main(process.argv.slice(2));
