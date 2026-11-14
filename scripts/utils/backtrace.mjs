// Writes the stacks of every thread of a running Log Tracy into a file: for a hang of the
// indexing or of the task pool, when its output doesn't tell who waits for whom. lldb on macOS,
// gdb on Linux; the process keeps running. The options: `node scripts/utils/backtrace.mjs --help`.
// Tests: tests/js/backtrace-script.test.mjs.
import { spawnSync } from "node:child_process";
import { mkdirSync, realpathSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { alive, readState } from "./app.mjs";

export const backtraceUsage = `Writes the stacks of every thread of a running Log Tracy into a file
(lldb on macOS, gdb on Linux); the process keeps running.

Usage: node scripts/utils/backtrace.mjs [pid] [options]

  pid             the process; by default the copy of scripts/utils/app.mjs while it runs,
                  else the only running log_tracy
  --out FILE      where to write (default build/backtrace-<pid>.txt)
  -h, --help      this help
`;

/// A command line not understood or a process not found: told without a stack.
export class BacktraceError extends Error {}

/// The command line: `{ pid, out, help }`, `pid` null for the only running copy.
export function parseBacktraceArgs(argv) {
    const options = { pid: null, out: null, help: false };
    for (let i = 0; i < argv.length; i++) {
        const arg = argv[i];
        if (arg === "--help" || arg === "-h") options.help = true;
        else if (arg === "--out" || arg.startsWith("--out=")) {
            const value = arg === "--out" ? argv[++i] : arg.slice("--out=".length);
            if (value === undefined || value === "") throw new BacktraceError("--out needs a file");
            options.out = value;
        } else if (arg.startsWith("-")) throw new BacktraceError(`unknown option ${arg} (--help)`);
        else if (!/^\d+$/.test(arg)) throw new BacktraceError(`a pid is a number, not "${arg}"`);
        else if (options.pid !== null) throw new BacktraceError("one pid only");
        else options.pid = Number(arg);
    }
    return options;
}

/// The debugger and its arguments that print the stacks of every thread of `pid` and detach,
/// or null where there is none to take (Windows).
export function debuggerCommand(platform, pid) {
    if (platform === "darwin")
        return { program: "lldb", args: ["--batch", "-p", String(pid), "-o", "thread backtrace all", "-o", "process detach"] };
    if (platform === "linux")
        return { program: "gdb", args: ["-batch", "-p", String(pid), "-ex", "thread apply all bt", "-ex", "detach"] };
    return null;
}

/// The pid of the only process of `listing`: "<pid> <command line>" a line, as `ps -o pid=,command=`
/// prints the processes `pgrep -x` found (not `pgrep -f`: it finds any process whose command
/// line has the path of the project in it).
export function pickProcess(listing) {
    const processes = listing.split("\n").map((line) => line.trim()).filter((line) => line !== "")
        .map((line) => ({ pid: Number(line.split(" ")[0]), command: line.slice(line.indexOf(" ") + 1) }));
    if (processes.length === 0) throw new BacktraceError("No running log_tracy: start it, or give a pid.");
    if (processes.length > 1)
        throw new BacktraceError("Several log_tracy run, give the pid of one:\n"
            + processes.map(({ pid, command }) => `  ${pid} ${command}`).join("\n"));
    return processes[0].pid;
}

/// Whether a command (`ps -o comm=`) is the program: the pid of an old state.json may be of
/// another process by now.
export function isAppCommand(command) {
    return /(^|[\\/])log_tracy(\.exe)?$/.test(command.trim());
}

/// The threads in the output of the debugger, counted from the command that prints the stacks
/// on: lldb also tells the stopped thread on attaching. 0 when the command never ran.
export function countThreads(output, platform) {
    const { args } = debuggerCommand(platform, 0);
    const command = args.at(-3);
    // lldb echoes its commands ("(lldb) thread backtrace all"), gdb -batch doesn't
    const from = platform === "darwin" ? output.indexOf(`(lldb) ${command}`) : 0;
    if (from < 0) return 0;
    return (output.slice(from).match(/^\* ?thread #\d+|^  thread #\d+|^Thread \d+/gm) ?? []).length;
}

/// The pid of the copy scripts/utils/app.mjs started, while that process is still the program, or null.
function appCopy() {
    const state = readState();
    if (!state || !alive(state.pid)) return null;
    const command = spawnSync("ps", ["-o", "comm=", "-p", String(state.pid)], { encoding: "utf8" }).stdout ?? "";
    return isAppCommand(command) ? state.pid : null;
}

function main(argv, cwd) {
    const options = parseBacktraceArgs(argv);
    if (options.help) return process.stdout.write(backtraceUsage);
    const debug = debuggerCommand(process.platform, options.pid ?? 0);
    if (debug === null) throw new BacktraceError("No debugger to take on this system (macOS: lldb, Linux: gdb).");
    let pid = options.pid;
    if (pid === null) pid = appCopy();
    if (pid === null) {
        // by the name of the program, then what each runs (its folder tells the builds apart)
        const pids = (spawnSync("pgrep", ["-x", "log_tracy"], { encoding: "utf8" }).stdout ?? "").trim();
        const listed = pids === "" ? ""
            : spawnSync("ps", ["-o", "pid=,command=", "-p", pids.split(/\s+/).join(",")], { encoding: "utf8" }).stdout;
        pid = pickProcess(listed ?? "");
    }
    const { program, args } = debuggerCommand(process.platform, pid);
    console.log(`> ${program} ${args.join(" ")}`);
    const result = spawnSync(program, args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
    if (result.error) throw new BacktraceError(`can't run ${program}: ${result.error.message}`);
    const out = resolve(cwd, options.out ?? `build/backtrace-${pid}.txt`);
    mkdirSync(dirname(out), { recursive: true });
    writeFileSync(out, result.stdout + (result.stderr ? `\n--- stderr\n${result.stderr}` : ""));
    const threads = countThreads(result.stdout, process.platform);
    if (result.status !== 0 || threads === 0)
        throw new BacktraceError(`${program} gave no stacks (exit ${result.status}), its output: ${out}`
            + (process.platform === "darwin" ? "\nAttaching may need the developer mode: DevToolsSecurity -status." : "")
            + (process.platform === "linux" ? "\nAttaching may need ptrace allowed: /proc/sys/kernel/yama/ptrace_scope." : ""));
    console.log(`The stacks of ${threads} threads of process ${pid}: ${out}`);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === realpathSync(process.argv[1])) {
    const cwd = process.cwd(); // --out is from here
    process.chdir(fileURLToPath(new URL("../..", import.meta.url))); // the project root: build/
    try {
        main(process.argv.slice(2), cwd);
    } catch (e) {
        if (!(e instanceof BacktraceError)) throw e;
        console.error(e.message);
        process.exitCode = 1;
    }
}
