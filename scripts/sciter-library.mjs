// The Sciter libraries of libs/: which one a system and an architecture use, how each is kept
// (packed by brotli, in Git LFS) and how it is put in place for a build. Used by scripts/build.mjs
// (pack-libs, dist) and by scripts/utils/prepare-sciter.mjs, which dub runs before every build,
// run and test. Tests: tests/js/build-script.test.mjs, tests/js/prepare-sciter-script.test.mjs.
import { spawnSync } from "node:child_process";
import { closeSync, existsSync, openSync, readFileSync, readSync, renameSync, statSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { promisify } from "node:util";
import { brotliCompress, brotliDecompressSync, constants as zlibConstants } from "node:zlib";

export const arches = ["x64", "arm64"];

/// A command line not understood, or a step that failed: told without a stack.
export class BuildError extends Error {}

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

/// The arguments of git that fetch one file of Git LFS and put it in place of its pointer.
/// .lfsconfig excludes libs/ from every fetch (a clone fetches no library) and an --include
/// alone doesn't lift that: the empty --exclude does.
export function lfsPullArgs(file) {
    return ["lfs", "pull", `--include=${file}`, "--exclude="];
}

/// Makes sure the Sciter library the build will copy is in libs/: unpacked from its archive,
/// which a clone leaves as a pointer of Git LFS (.lfsconfig), so only the archive of this build
/// is fetched, on the first build that needs it. Stops with what to do when it can't be: the
/// program would build and then fail to load it. `git(args)` runs git and tells whether it
/// succeeded (throws when there is no git), `log(line)` tells what is being done.
export function checkSciterLibrary(arch, { git = pullWithGit, log = console.log } = {}) {
    if (!arches.includes(arch)) return; // no library for it: dub will tell
    const library = sciterLibrary(process.platform, arch);
    const archive = sciterArchive(library);
    if (readArchiveHead(archive) === "pointer") {
        log(`Fetching ${archive} from Git LFS`);
        const failed = `${archive} is a pointer of Git LFS, not the library, and fetching it failed: install git `
            + `and git-lfs, run "git lfs install", then "git ${lfsPullArgs(archive).join(" ")}" (docs/building.md).`;
        let pulled;
        try {
            pulled = git(lfsPullArgs(archive));
        } catch (error) {
            throw new BuildError(`${error.message}\n${failed}`); // no git on the PATH
        }
        if (!pulled || readArchiveHead(archive) === "pointer") throw new BuildError(failed);
    }
    try {
        if (unpackLibrary(library)) log(`Unpacked ${library}`);
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

/// Runs `git` with `args`, its output shown: whether it succeeded.
function pullWithGit(args) {
    console.log(`> git ${args.join(" ")}`);
    const result = spawnSync("git", args, { stdio: "inherit" });
    if (result.error) throw new BuildError(`can't run git: ${result.error.message}`);
    return result.status === 0;
}
