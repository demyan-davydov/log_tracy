// The pure part of scripts/utils/backtrace.mjs: its command line, the debugger of each system and
// the process it takes when no pid is given.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { parseBacktraceArgs, debuggerCommand, pickProcess, backtraceUsage, countThreads, isAppCommand }
    from "../../scripts/utils/backtrace.mjs";

test("the pid is optional, --out names the file", () => {
    assert.deepEqual(parseBacktraceArgs([]), { pid: null, out: null, help: false });
    assert.deepEqual(parseBacktraceArgs(["4242", "--out", "hang.txt"]), { pid: 4242, out: "hang.txt", help: false });
    assert.deepEqual(parseBacktraceArgs(["--out=hang.txt"]), { pid: null, out: "hang.txt", help: false });
    assert.equal(parseBacktraceArgs(["-h"]).help, true);
    assert.throws(() => parseBacktraceArgs(["abc"]), /abc/);
    assert.throws(() => parseBacktraceArgs(["1", "2"]), /one/);
    assert.throws(() => parseBacktraceArgs(["--out"]), /--out/);
    assert.throws(() => parseBacktraceArgs(["--all"]), /--all/);
    assert.match(backtraceUsage, /--out/);
});

test("lldb on macOS and gdb on Linux print every thread and leave the process running", () => {
    assert.deepEqual(debuggerCommand("darwin", 42),
        { program: "lldb", args: ["--batch", "-p", "42", "-o", "thread backtrace all", "-o", "process detach"] });
    assert.deepEqual(debuggerCommand("linux", 42),
        { program: "gdb", args: ["-batch", "-p", "42", "-ex", "thread apply all bt", "-ex", "detach"] });
    assert.equal(debuggerCommand("win32", 42), null);
});

test("without a pid the only running copy is taken; none or several are told", () => {
    assert.equal(pickProcess("  4242 /p/build/osx-aarch64-debug/log_tracy\n"), 4242);
    assert.throws(() => pickProcess(""), /no running/i);
    assert.throws(() => pickProcess("1 /a/log_tracy\n2 /b/log_tracy --x\n"), (e) =>
        /several/i.test(e.message) && /\/a\/log_tracy/.test(e.message) && /\/b\/log_tracy/.test(e.message));
});

test("the threads are counted in the stacks only, not in what lldb tells on attaching", () => {
    const attach = "(lldb) process attach --pid 42\n* thread #1, queue = 'main', stop reason = signal SIGSTOP\n";
    const stacks = "(lldb) thread backtrace all\n* thread #1, queue = 'main'\n  frame #0: x\n  thread #2\n  frame #0: y\n";
    assert.equal(countThreads(attach + stacks, "darwin"), 2);
    assert.equal(countThreads(attach + "(lldb) thread backtrace all\nerror: no process\n", "darwin"), 0);
    assert.equal(countThreads(attach, "darwin"), 0); // the command never ran
    assert.equal(countThreads("Thread 2 (Thread 0x7f (LWP 11)):\n#0 x\nThread 1 (Thread 0x7e (LWP 10)):\n#0 y\n", "linux"), 2);
});

test("a pid of an old state.json is the app's only while that process is still log_tracy", () => {
    assert.equal(isAppCommand("/p/build/app/log_tracy"), true);
    assert.equal(isAppCommand("log_tracy"), true);
    assert.equal(isAppCommand("C:\\p\\log_tracy.exe"), true);
    assert.equal(isAppCommand("/Applications/Safari.app/Contents/MacOS/Safari"), false);
    assert.equal(isAppCommand(""), false);
});
