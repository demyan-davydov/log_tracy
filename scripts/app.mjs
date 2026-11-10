// Drives a running copy of DLT Explorer through its debug channel (ui/debug_channel, debug builds
// only): starts a copy in a folder of its own (its own settings, its output in app.log) that
// keeps running, runs JavaScript in its window, waits for a condition, renders the window into a
// PNG, stops it. For agents and people checking what the app does without guessing from a
// screenshot. `node scripts/app.mjs --help` for the commands.
import { spawn } from "node:child_process";
import { closeSync, existsSync, openSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { createConnection } from "node:net";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { BuildError, build, targetPath } from "./build.mjs";
import { copyProgram, programName, systemEnv } from "./screenshot.mjs";

export const appUsage = `Drives a copy of DLT Explorer (a debug build) through its debug channel.

  node scripts/app.mjs <command> [options]

  start                 builds the app, starts a copy of it with settings of its own (it keeps
                        running; a copy started before is stopped first)
      --open <log>      open this log at start (repeat for several tabs)
      --settings <file> start with this settings.json
      --env NAME=VALUE  an environment variable for the app, repeatable
      --no-build        take the debug build as it is
  eval "<js>"           runs the code in the window, prints the value of its last expression
                        as JSON (an element as {tag, id, class, text, box}); fails on an error
  wait "<js>"           runs the code until its value is true (an error such as a missing
                        element is tried again; a syntax error or a promise fails at once)
      --timeout <s>     how long to wait (default 10)
  shot [file.png]       renders the window into a PNG (default build/screenshot.png)
  run <file>            the steps of a file, one a line, stopping at the first failure:
                        eval <js> | wait [<seconds>s] <js> | shot <file.png>; # a comment.
                        A shot's file is taken from the folder of the steps file
  log                   the output of the copy
  stop                  closes the copy (kills it only if it answers but doesn't close)
  --help                this text

The code runs in the global scope of the window: what the modules put on globalThis
(the callbacks of the backend), document, Window.this; document.$(...) finds elements.
`;

const commands = { start: [0, 0], eval: [1, 1], wait: [1, 1], shot: [0, 1], run: [1, 1], log: [0, 0], stop: [0, 0] };

/// The command line: { command, args, open, settings, env, build, timeout, help }
export function parseAppArgs(argv) {
    const options = { command: null, args: [], open: [], settings: null, env: {}, build: true, timeout: 10, help: false };
    for (let i = 0; i < argv.length; i++) {
        const arg = argv[i];
        if (!arg.startsWith("--")) {
            if (options.command === null) {
                if (!(arg in commands)) throw new BuildError(`unknown command ${arg} (--help)`);
                options.command = arg;
            } else options.args.push(arg);
            continue;
        }
        const [name, inline] = arg.split(/=(.*)/s, 2);
        const value = () => {
            if (inline !== undefined) return inline;
            if (i + 1 >= argv.length) throw new BuildError(`${name} needs a value (--help)`);
            return argv[++i];
        };
        if (name === "--open") options.open.push(value());
        else if (name === "--settings") options.settings = value();
        else if (name === "--env") {
            const text = value();
            const at = text.indexOf("=");
            if (at <= 0) throw new BuildError(`--env takes NAME=VALUE, not "${text}"`);
            options.env[text.slice(0, at)] = text.slice(at + 1);
        } else if (name === "--timeout") options.timeout = seconds(value(), "--timeout");
        else if (name === "--no-build") options.build = false;
        else if (name === "--help") options.help = true;
        else throw new BuildError(`unknown option ${arg} (--help)`);
    }
    if (options.command === null) options.help = true;
    else {
        const [min, max] = commands[options.command];
        if (options.args.length < min || options.args.length > max)
            throw new BuildError(`${options.command} takes ${min === max ? min : `${min} to ${max}`} argument(s) (--help)`);
    }
    return options;
}

function seconds(text, what) {
    const value = Number(text);
    if (text === "" || !Number.isFinite(value) || value < 0) throw new BuildError(`${what} takes seconds, not "${text}"`);
    return value;
}

/// The steps of a scenario file: [{ line, command, text, timeout? }]
export function parseSteps(text) {
    const steps = [];
    text.split(/\r?\n/).forEach((raw, index) => {
        const line = index + 1;
        const source = raw.trim();
        if (source === "" || source.startsWith("#")) return;
        const [, command, rest = ""] = source.match(/^(\S+)\s*(.*)$/s);
        const fail = why => { throw new BuildError(`line ${line}: ${why}: ${source}`); };
        if (!["eval", "wait", "shot"].includes(command)) fail(`unknown step ${command}`);
        if (rest === "") fail(`${command} needs ${command === "shot" ? "a file" : "code"}`);
        if (command !== "wait") return steps.push({ line, command, text: rest });
        // "<n>s", not a bare number: code may start with one ("0 < ...")
        const timed = rest.match(/^(\d+(?:\.\d+)?)s\s+(.+)$/s);
        steps.push(timed ? { line, command, text: timed[2], timeout: Number(timed[1]) }
            : { line, command, text: rest, timeout: 10 });
    });
    return steps;
}

/// What wait does after a response: "done" (a true value), "retry" (false, or the code threw:
/// what it looks at may not be there yet) or "fail" (the code can't run, or its value is a
/// promise, which the channel never awaits and which is always true)
export function waitVerdict(response) {
    if ("error" in response) return /^SyntaxError\b/.test(response.error) ? "fail" : "retry";
    if (response.result === "[promise]") return "fail";
    return response.result ? "done" : "retry";
}

/// A response line as an object: {"result": ...} or {"error": ...}; a line that is no JSON
/// object becomes an error
export function parseResponse(line) {
    try {
        const response = JSON.parse(line);
        if (response !== null && typeof response === "object" && !Array.isArray(response)) return response;
    } catch {
        // below
    }
    return { error: `not a response of the channel: ${line}` };
}

/// The port the app wrote it listens on, null until it did
export function listeningPort(output) {
    const found = output.match(/^Debug channel: listening on 127\.0\.0\.1:(\d+)/m);
    return found ? Number(found[1]) : null;
}

/// A request line of the debug channel (ui/debug_protocol)
export function requestLine(kind, text) {
    return JSON.stringify({ [kind]: text }) + "\n";
}

// ── Talking to the copy ───────────────────────────────────────────────────

// The copy and its output: build/app of the project, wherever the command is run from
const copyDir = fileURLToPath(new URL("../build/app", import.meta.url));
const stateFile = join(copyDir, "state.json");
const logFile = join(copyDir, "app.log");
const sleep = s => new Promise(done => setTimeout(done, s * 1000));

function readState() {
    try {
        return JSON.parse(readFileSync(stateFile, "utf8"));
    } catch {
        return null;
    }
}

function alive(pid) {
    try {
        process.kill(pid, 0);
        return true;
    } catch {
        return false;
    }
}

// The connection to the copy: request() sends a line and gives the response
async function connect() {
    const state = readState();
    if (!state || !alive(state.pid)) throw new BuildError("No copy is running: node scripts/app.mjs start");
    const socket = createConnection({ host: "127.0.0.1", port: state.port });
    await new Promise((done, fail) => {
        socket.once("connect", done);
        socket.once("error", e => fail(new BuildError(`Can't connect to the copy: ${e.message}`)));
    });
    let buffer = "";
    const waiting = [];
    socket.setEncoding("utf8");
    socket.on("data", chunk => {
        buffer += chunk;
        for (let end; (end = buffer.indexOf("\n")) >= 0;) {
            const line = buffer.slice(0, end);
            buffer = buffer.slice(end + 1);
            waiting.shift()?.done(parseResponse(line));
        }
    });
    const gone = () => { while (waiting.length) waiting.shift().fail(new BuildError("The copy closed the channel")); };
    socket.on("close", gone);
    socket.on("error", gone);
    return {
        request: (kind, text) => new Promise((done, fail) => {
            waiting.push({ done, fail });
            socket.write(requestLine(kind, text));
        }),
        close: () => socket.end()
    };
}

const print = value => console.log(typeof value === "string" ? value : JSON.stringify(value, null, 2));

async function evalStep(channel, code) {
    const response = await channel.request("eval", code);
    if ("error" in response) throw new BuildError(response.error);
    return response.result;
}

async function waitStep(channel, code, timeout) {
    const giveUp = Date.now() + timeout * 1000;
    for (;;) {
        const response = await channel.request("eval", code);
        const verdict = waitVerdict(response);
        if (verdict === "done") return response.result;
        if (verdict === "fail")
            throw new BuildError("error" in response ? response.error
                : `The value is a promise, never true or false for wait: ${code}`);
        if (Date.now() > giveUp)
            throw new BuildError(`Still not true after ${timeout} s: ${code}${"error" in response ? `\n${response.error}` : ""}`);
        await sleep(0.2);
    }
}

async function shotStep(channel, file) {
    const response = await channel.request("shot", resolve(file));
    if ("error" in response) throw new BuildError(response.error);
    return response.result.path;
}

async function start(options) {
    for (const log of options.open)
        if (!existsSync(log)) throw new BuildError(`No log ${log}`);
    const buildDir = options.build ? build({ release: false, arch: null }) : targetPath({ release: false, arch: null });
    await stop(true);
    copyProgram(buildDir, copyDir, options.settings);
    const env = { ...process.env, ...systemEnv(process.platform), ...options.env, SCITER_DEBUG_PORT: "0" };
    if (options.open.length > 0) env.OPEN_AT_START = options.open.join("\n");
    const output = openSync(logFile, "w");
    const app = spawn(join(copyDir, programName(process.platform)), [], {
        cwd: copyDir, stdio: ["ignore", output, output], env, detached: true
    });
    closeSync(output);
    let exited = false;
    app.on("exit", () => { exited = true; });
    const giveUp = Date.now() + 20_000;
    for (let port = null; ;) {
        await sleep(0.2);
        port = listeningPort(readFileSync(logFile, "utf8"));
        if (port !== null) {
            writeFileSync(stateFile, JSON.stringify({ pid: app.pid, port }));
            app.unref();
            console.log(`Started (process ${app.pid}, port ${port}); its output: ${logFile}`);
            return;
        }
        if (exited) throw new BuildError(`The copy exited at start: ${logFile}`);
        if (Date.now() > giveUp) {
            app.kill();
            throw new BuildError(`The copy opened no debug channel in 20 s: ${logFile}`);
        }
    }
}

// Closes the copy; `quiet` when start stops a copy before starting another. Only a copy that
// answers on its channel is killed when it doesn't close: a pid of an old state.json may be of
// another program by now.
async function stop(quiet = false) {
    const say = text => { if (!quiet) console.log(text); };
    const state = readState();
    if (!state || !alive(state.pid)) {
        rmSync(stateFile, { force: true });
        return say("No copy is running");
    }
    let channel;
    try {
        channel = await connect();
    } catch {
        rmSync(stateFile, { force: true });
        return say(`The copy doesn't answer on its channel: process ${state.pid} is left alone`);
    }
    await channel.request("eval", "Window.this.close(); true").catch(() => {});
    channel.close();
    for (let tries = 0; tries < 25 && alive(state.pid); tries++) await sleep(0.2);
    if (alive(state.pid)) {
        process.kill(state.pid);
        say(`The copy didn't close in 5 s: process ${state.pid} killed`);
    } else say("Stopped");
    rmSync(stateFile, { force: true });
}

async function main(options) {
    switch (options.command) {
        case "start": return start(options);
        case "stop": return stop();
        case "log":
            if (!existsSync(logFile)) throw new BuildError("No copy was started: node scripts/app.mjs start");
            return process.stdout.write(readFileSync(logFile, "utf8"));
    }
    const channel = await connect();
    try {
        if (options.command === "eval") print(await evalStep(channel, options.args[0]));
        else if (options.command === "wait") print(await waitStep(channel, options.args[0], options.timeout));
        else if (options.command === "shot") print(await shotStep(channel, options.args[0] ?? "build/screenshot.png"));
        else {
            const file = options.args[0];
            for (const step of parseSteps(readFileSync(file, "utf8"))) {
                const run = step.command === "eval" ? evalStep(channel, step.text)
                    : step.command === "wait" ? waitStep(channel, step.text, step.timeout)
                    : shotStep(channel, resolve(dirname(file), step.text)); // from the scenario's folder
                try {
                    console.log(`${step.line} ${step.command}: ${JSON.stringify(await run)}`);
                } catch (e) {
                    if (e instanceof BuildError) e.message = `line ${step.line}: ${e.message}`;
                    throw e;
                }
            }
        }
    } finally {
        channel.close();
    }
}

// run, not imported (by the tests)
if (process.argv[1] && fileURLToPath(import.meta.url) === realpathSync(process.argv[1])) {
    const cwd = process.cwd(); // the paths given are from here
    process.chdir(fileURLToPath(new URL("..", import.meta.url))); // the project root
    try {
        const options = parseAppArgs(process.argv.slice(2));
        options.open = options.open.map(log => resolve(cwd, log));
        if (options.settings) options.settings = resolve(cwd, options.settings);
        if (options.command === "shot" && options.args[0]) options.args[0] = resolve(cwd, options.args[0]);
        if (options.command === "run") options.args[0] = resolve(cwd, options.args[0]);
        if (options.help) process.stdout.write(appUsage);
        else await main(options);
    } catch (e) {
        if (!(e instanceof BuildError)) throw e;
        console.error(e.message);
        process.exitCode = 1;
    }
}
