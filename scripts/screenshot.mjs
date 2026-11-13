// Takes a screenshot of the window of Log Tracy (macOS, Windows, Linux on X11): builds the
// app (as build.mjs does), starts a copy of it in a folder of its own, with settings of its own (the developer's
// settings.json is never touched), opens the logs given (OPEN_AT_START), waits, captures that window
// only (never the screen) and stops the copy. For people and agents checking what a change
// looks like. `node scripts/screenshot.mjs --help` for the options.
import { spawn, spawnSync } from "node:child_process";
import { closeSync, copyFileSync, existsSync, mkdirSync, openSync, readdirSync, readFileSync,
    realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { BuildError, build, targetPath } from "./build.mjs";

export const shotUsage = `Takes a screenshot of the Log Tracy window: macOS, Windows, Linux on X11
(also XWayland; needs xdotool and ImageMagick).

  node scripts/screenshot.mjs [options]

  --open <log>          open this log at start (repeat for several tabs)
  --out <file.png>      where to write the screenshot (default build/screenshot.png)
  --wait <seconds>      how long to wait after the window shows (default 3): loading a log
  --settings <file>     start with this settings.json (theme, language, column layouts, ...)
  --env NAME=VALUE      an environment variable for the app (PSEUDO_LOCALE=1,
                        MENU_BAR_PLATFORM=windows, ...), repeatable
  --release             a release build (default: debug)
  --no-build            take the build as it is
  --help                this text
`;

/// The options of the command line: { open, out, wait, settings, env, release, build, help };
/// `out` and `settings` null when not given
export function parseShotArgs(argv) {
    const options = {
        open: [], out: null, wait: 3, settings: null, env: {},
        release: false, build: true, help: false
    };
    for (let i = 0; i < argv.length; i++) {
        const [name, inline] = argv[i].split(/=(.*)/s, 2);
        const value = () => {
            if (inline !== undefined) return inline;
            if (i + 1 >= argv.length) throw new BuildError(`${name} needs a value (--help)`);
            return argv[++i];
        };
        if (name === "--open") options.open.push(value());
        else if (name === "--out") options.out = value();
        else if (name === "--settings") options.settings = value();
        else if (name === "--wait") {
            const text = value();
            const seconds = Number(text);
            if (text === "" || !Number.isFinite(seconds) || seconds < 0)
                throw new BuildError(`--wait takes seconds, not "${text}"`);
            options.wait = seconds;
        } else if (name === "--env") {
            const text = value();
            const at = text.indexOf("=");
            if (at <= 0) throw new BuildError(`--env takes NAME=VALUE, not "${text}"`);
            options.env[text.slice(0, at)] = text.slice(at + 1);
        } else if (["--release", "--no-build", "--help", "-h"].includes(name)) {
            if (inline !== undefined) throw new BuildError(`${name} takes no value (--help)`);
            if (name === "--release") options.release = true;
            else if (name === "--no-build") options.build = false;
            else options.help = true;
        } else throw new BuildError(`unknown option ${argv[i]} (--help)`);
    }
    return options;
}

/// The options with their paths (logs, settings, the screenshot) made absolute from `cwd`, the
/// folder the command was run in: the script itself works from the project root
export function absolutePaths(options, cwd) {
    return {
        ...options,
        open: options.open.map(log => resolve(cwd, log)),
        settings: options.settings && resolve(cwd, options.settings),
        out: options.out && resolve(cwd, options.out)
    };
}

/// The environment of the app: `env` of the options, with the logs to open as OPEN_AT_START,
/// one per line
export function appEnv(options) {
    const env = { ...options.env };
    if (options.open.length > 0) env.OPEN_AT_START = options.open.join("\n");
    return env;
}

/// The id of the main window among the windows of the app (`windows`: [{ id, layer, onscreen,
/// width, height }]): on screen, of the normal layer, the largest; null while there is none.
/// The app also owns off-screen windows of layer 0: one of them gives a blank shot.
export function mainWindow(windows) {
    const candidates = windows.filter(w => w.onscreen && w.layer === 0);
    if (candidates.length === 0) return null;
    const area = w => w.width * w.height;
    return candidates.reduce((best, w) => (area(w) > area(best) ? w : best)).id;
}

/// The file name of the program on a system
export function programName(platform) {
    return platform === "win32" ? "log_tracy.exe" : "log_tracy";
}

/// The environment the app needs on a system for its window to be captured: on Linux the X11
/// backend of GTK, XWayland in a Wayland session (Wayland lets no program capture another's
/// window)
export function systemEnv(platform) {
    return platform === "linux" ? { GDK_BACKEND: "x11" } : {};
}

/// The windows a lister printed as JSON ([{ id, layer, onscreen, width, height }]); none when
/// it printed anything else (a warning, a part of a line): the window is looked for again
export function windowList(text) {
    try {
        const windows = JSON.parse(text);
        return Array.isArray(windows) ? windows : [];
    } catch {
        return [];
    }
}

/// The window ids `xdotool search` printed, one per line
export function xdotoolIds(text) {
    return text.split(/\r?\n/).filter(line => /^\d+$/.test(line.trim())).map(line => Number(line.trim()));
}

/// The window `id` as mainWindow() takes it, from `xdotool getwindowgeometry --shell`; null if
/// the text has no size
export function xdotoolWindow(id, text) {
    const value = name => Number(text.match(new RegExp(`^${name}=(\\d+)$`, "m"))?.[1]);
    const width = value("WIDTH"), height = value("HEIGHT");
    if (!Number.isFinite(width) || !Number.isFinite(height)) return null;
    // `search --onlyvisible` lists only the windows shown
    return { id, layer: 0, onscreen: true, width, height };
}

// A file of build/tools, written when its text changed
function toolFile(name, text) {
    const tools = "build/tools";
    mkdirSync(tools, { recursive: true });
    const path = join(tools, name);
    if (!existsSync(path) || readFileSync(path, "utf8") !== text) writeFileSync(path, text);
    return path;
}

// macOS: the windows of a process as mainWindow() takes them, listed by a small Swift program
// (CGWindowListCopyWindowInfo: ids and bounds need no permission)
const macWindowListSource = `import CoreGraphics
import Foundation
let pid = Int32(CommandLine.arguments[1])!
let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
var windows: [[String: Any]] = []
for w in all where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
    let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    windows.append([
        "id": w[kCGWindowNumber as String] as? Int ?? 0,
        "layer": w[kCGWindowLayer as String] as? Int ?? -1,
        "onscreen": w[kCGWindowIsOnscreen as String] as? Bool ?? false,
        "width": bounds["Width"] as? Double ?? 0,
        "height": bounds["Height"] as? Double ?? 0,
    ])
}
let data = try! JSONSerialization.data(withJSONObject: windows)
print(String(data: data, encoding: .utf8)!)
`;

// Windows: the windows of a process (as mainWindow() takes them: an owned window, a popup, is
// not on screen for it) and the capture of one, by user32. PrintWindow with
// PW_RENDERFULLCONTENT draws the window itself, whatever covers it. The C# is compiled once
// into build/tools/WindowShot.dll (again when its source changed), PowerShell loads it.
const windowsShotSource = String.raw`using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public static class WindowShot {
    delegate bool EnumProc(IntPtr window, IntPtr parameter);
    [StructLayout(LayoutKind.Sequential)] struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, IntPtr parameter);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr window, uint command);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr window, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    public static string List(uint pid) {
        var items = new List<string>();
        EnumWindows((window, parameter) => {
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            if (owner == pid) {
                Rect rect;
                GetWindowRect(window, out rect);
                bool shown = IsWindowVisible(window) && !IsIconic(window) && GetWindow(window, 4) == IntPtr.Zero;
                items.Add(String.Format("{{\"id\":{0},\"layer\":0,\"onscreen\":{1},\"width\":{2},\"height\":{3}}}",
                    window.ToInt64(), shown ? "true" : "false", rect.Right - rect.Left, rect.Bottom - rect.Top));
            }
            return true;
        }, IntPtr.Zero);
        return "[" + String.Join(",", items) + "]";
    }
    public static bool Capture(long id, string path) {
        var window = new IntPtr(id);
        Rect rect;
        if (!GetWindowRect(window, out rect)) return false;
        using (var bitmap = new Bitmap(rect.Right - rect.Left, rect.Bottom - rect.Top, PixelFormat.Format32bppArgb))
        using (var graphics = Graphics.FromImage(bitmap)) {
            var hdc = graphics.GetHdc();
            bool drawn = PrintWindow(window, hdc, 2);
            graphics.ReleaseHdc(hdc);
            if (!drawn) return false;
            bitmap.Save(path, ImageFormat.Png);
            return true;
        }
    }
}
`;

const windowsShotScript = String.raw`param([string]$Mode, [string]$Id, [string]$Out)
$ErrorActionPreference = "Stop"
$source = Join-Path $PSScriptRoot "WindowShot.cs"
$library = Join-Path $PSScriptRoot "WindowShot.dll"
if (-not (Test-Path $library) -or (Get-Item $source).LastWriteTime -gt (Get-Item $library).LastWriteTime) {
    Add-Type -Path $source -ReferencedAssemblies System.Drawing -OutputAssembly $library -OutputType Library
}
Add-Type -Path $library
[WindowShot]::SetProcessDPIAware() | Out-Null
if ($Mode -eq "list") { [WindowShot]::List([uint32]$Id) }
elseif (-not [WindowShot]::Capture([int64]$Id, $Out)) { exit 1 }
`;

const succeeded = result => !result.error && result.status === 0;

// What a system finds the windows of a process with and captures one with:
// { windows(pid) → [{ id, layer, onscreen, width, height }], capture(id, out) → whether done,
// failure: what to check when the capture failed }. Stops with what to install when a tool is
// missing.
function capturer(platform) {
    if (platform === "darwin") {
        const program = join("build/tools", "window-list");
        const source = toolFile("window-list.swift", macWindowListSource);
        if (!existsSync(program) || statSync(program).mtimeMs < statSync(source).mtimeMs) {
            if (!succeeded(spawnSync("swiftc", ["-O", source, "-o", program], { stdio: "inherit" })))
                throw new BuildError("Can't compile the window lister: swiftc (the Xcode command line tools) is needed.");
        }
        return {
            windows: pid => {
                const result = spawnSync(program, [String(pid)], { encoding: "utf8" });
                return succeeded(result) ? windowList(result.stdout) : [];
            },
            capture: (id, out) => succeeded(spawnSync("screencapture", ["-x", "-o", `-l${id}`, out], { stdio: "inherit" })),
            failure: "the terminal may need the Screen Recording permission"
        };
    }
    if (platform === "win32") {
        toolFile("WindowShot.cs", windowsShotSource);
        const script = toolFile("window-shot.ps1", windowsShotScript);
        const powershell = args => spawnSync("powershell.exe",
            ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, ...args],
            { encoding: "utf8" });
        return {
            windows: pid => {
                const result = powershell(["list", String(pid)]);
                return succeeded(result) ? windowList(result.stdout) : [];
            },
            capture: (id, out) => succeeded(powershell(["capture", String(id), out])),
            failure: "PrintWindow failed on the window"
        };
    }
    if (platform === "linux") {
        if (!process.env.DISPLAY)
            throw new BuildError("No X11 display (DISPLAY): on Wayland alone a window of another program can't be captured.");
        const missing = [["xdotool", ["--version"], "xdotool"], ["import", ["-version"], "ImageMagick"]]
            .filter(([tool, args]) => !succeeded(spawnSync(tool, args, { stdio: "ignore" })))
            .map(([, , pkg]) => pkg);
        if (missing.length > 0) throw new BuildError(`Install ${missing.join(" and ")} to take screenshots on Linux.`);
        return {
            windows: pid => {
                const search = spawnSync("xdotool", ["search", "--onlyvisible", "--pid", String(pid)], { encoding: "utf8" });
                return xdotoolIds(search.stdout ?? "")
                    .map(id => xdotoolWindow(id, spawnSync("xdotool", ["getwindowgeometry", "--shell", String(id)],
                        { encoding: "utf8" }).stdout ?? ""))
                    .filter(window => window !== null);
            },
            // import reads the window's area from the screen: the window is raised first, so
            // that no other window covers it
            capture: (id, out) => {
                spawnSync("xdotool", ["windowraise", String(id)], { stdio: "ignore" });
                spawnSync("xdotool", ["sleep", "0.3"], { stdio: "ignore" });
                return succeeded(spawnSync("import", ["-window", String(id), out], { stdio: "inherit" }));
            },
            failure: "ImageMagick's import failed on the window"
        };
    }
    throw new BuildError(`No screenshots on ${platform}.`);
}

const sleep = seconds => new Promise(done => setTimeout(done, seconds * 1000));
// A wait that doesn't keep Node alive once nothing else does
const deadline = seconds => new Promise(done => setTimeout(done, seconds * 1000).unref());

/// A copy of the program of `buildDir` in `dir`, emptied first, with `settings` (a settings.json,
/// or null) as its settings: its settings.json and settings.lock are its own. New files only:
/// macOS kills a signed program copied over an older one at start. Also used by app.mjs.
export function copyProgram(buildDir, dir, settings) {
    rmSync(dir, { recursive: true, force: true });
    mkdirSync(dir, { recursive: true });
    for (const name of readdirSync(buildDir)) {
        if (name.startsWith("settings.")) continue;
        const from = join(buildDir, name);
        if (statSync(from).isFile()) copyFileSync(from, join(dir, name));
    }
    if (settings) copyFileSync(settings, join(dir, "settings.json"));
    return dir;
}

async function shoot(options) {
    for (const log of options.open)
        if (!existsSync(log)) throw new BuildError(`No log ${log}`);
    const out = options.out ?? resolve("build/screenshot.png");
    const system = capturer(process.platform);
    const buildDir = options.build
        ? build({ release: options.release, arch: null })
        : targetPath({ release: options.release, arch: null });
    const dir = copyProgram(buildDir, join(tmpdir(), `log-tracy-shot-${process.pid}`), options.settings);
    const logFile = join(dir, "app.log");
    const output = openSync(logFile, "w");
    const app = spawn(join(dir, programName(process.platform)), [], {
        cwd: dir, stdio: ["ignore", output, output],
        env: { ...process.env, ...systemEnv(process.platform), ...appEnv(options) }
    });
    closeSync(output);
    const exit = new Promise(done => app.on("exit", done));
    let exited = false;
    exit.then(() => { exited = true; });
    let shot = false;
    try {
        let id = null;
        const giveUp = Date.now() + 20_000; // a lister may take a while itself (PowerShell)
        while (id === null) {
            if (exited) throw new BuildError(`The app exited before its window showed: ${logFile}`);
            if (Date.now() > giveUp) throw new BuildError(`No window of the app after 20 s: ${logFile}`);
            await sleep(0.25);
            id = mainWindow(system.windows(app.pid));
        }
        await sleep(options.wait);
        mkdirSync(dirname(out), { recursive: true });
        // The window found first may be gone by now (the app replaces windows while it starts:
        // "could not create image from window" on macOS): the windows are listed again before
        // each try
        const captured = async () => {
            for (let tries = 0; tries < 3; tries++) {
                if (tries > 0) await sleep(1);
                const current = mainWindow(system.windows(app.pid));
                if (current === null) continue;
                rmSync(out, { force: true });
                if (system.capture(current, out) && existsSync(out)) return true;
            }
            return false;
        };
        if (!await captured())
            throw new BuildError(`The capture failed: ${system.failure} (the app's output: ${logFile}).`);
        shot = true;
        console.log(`Screenshot: ${out}`);
    } finally {
        if (!exited) app.kill("SIGTERM");
        await Promise.race([exit, deadline(5)]);
    }
    // The copy is kept only when something went wrong: its output tells what
    if (shot) rmSync(dir, { recursive: true, force: true });
}

// run, not imported (by the tests)
if (process.argv[1] && fileURLToPath(import.meta.url) === realpathSync(process.argv[1])) {
    const cwd = process.cwd(); // the paths given are from here
    process.chdir(fileURLToPath(new URL("..", import.meta.url))); // the project root
    try {
        const options = absolutePaths(parseShotArgs(process.argv.slice(2)), cwd);
        if (options.help) process.stdout.write(shotUsage);
        else await shoot(options);
    } catch (e) {
        if (!(e instanceof BuildError)) throw e;
        console.error(e.message);
        process.exitCode = 1;
    }
}
