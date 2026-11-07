// Builds DLT Explorer as scripts/build.mjs does and starts it from its build folder: its
// output (the script's console.log too) goes to this terminal, its exit code is this one's.
//   node scripts/run.mjs [--release] [--arch x64|arm64]   debug for this machine by default
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { BuildError, build, parseCommand } from "./build.mjs";

process.chdir(fileURLToPath(new URL("..", import.meta.url))); // the project root
try {
    const argv = process.argv.slice(2);
    const { command, release, arch } = parseCommand(argv);
    if (command !== "build" || argv.includes("build"))
        throw new BuildError("run.mjs takes the options of a build only: --release, --arch x64|arm64");
    const program = join(build({ release, arch }),
        process.platform === "win32" ? "dlt_explorer.exe" : "dlt_explorer");
    console.log(`> ${program}`);
    const result = spawnSync(program, [], { stdio: "inherit" });
    if (result.error) throw new BuildError(`can't start ${program}: ${result.error.message}`);
    process.exitCode = result.status ?? 1;
} catch (e) {
    if (!(e instanceof BuildError)) throw e;
    console.error(e.message);
    process.exitCode = 1;
}
