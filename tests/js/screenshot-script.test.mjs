// The pure part of scripts/screenshot.mjs: the command line, the environment of the app, which
// window is captured.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { parseShotArgs, absolutePaths, appEnv, mainWindow, programName, systemEnv, windowList,
    xdotoolIds, xdotoolWindow } from "../../scripts/screenshot.mjs";

test("a debug build, no logs, the default file and wait", () => {
    assert.deepEqual(parseShotArgs([]), {
        open: [], out: null, wait: 3, settings: null, env: {},
        release: false, build: true, help: false
    });
});

test("logs, a file, a wait, settings, variables and the build", () => {
    assert.deepEqual(parseShotArgs(["--open", "a.dlt", "--open=b.log", "--out", "x.png", "--wait", "0.5",
        "--settings", "s.json", "--env", "PSEUDO_LOCALE=1", "--env=MENU_BAR_PLATFORM=windows",
        "--release", "--no-build"]), {
        open: ["a.dlt", "b.log"], out: "x.png", wait: 0.5, settings: "s.json",
        env: { PSEUDO_LOCALE: "1", MENU_BAR_PLATFORM: "windows" }, release: true, build: false, help: false
    });
    assert.equal(parseShotArgs(["--help"]).help, true);
});

test("a wrong option, a missing value, a bad wait or variable is an error", () => {
    assert.throws(() => parseShotArgs(["--opn", "a.dlt"]), /--opn/);
    assert.throws(() => parseShotArgs(["--open"]), /--open/);
    assert.throws(() => parseShotArgs(["--wait", "soon"]), /--wait/);
    assert.throws(() => parseShotArgs(["--wait", "-1"]), /--wait/);
    assert.throws(() => parseShotArgs(["--env", "NOVALUE"]), /NAME=VALUE/);
    assert.throws(() => parseShotArgs(["--release=x"]), /--release/);
});

test("the paths given are taken from the folder the command was run in", () => {
    const options = absolutePaths(parseShotArgs(["--open", "a.dlt", "--open", "/l/b.log",
        "--settings", "s.json", "--out", "shots/x.png"]), "/work");
    assert.deepEqual(options.open, ["/work/a.dlt", "/l/b.log"]);
    assert.equal(options.settings, "/work/s.json");
    assert.equal(options.out, "/work/shots/x.png");
    const defaults = absolutePaths(parseShotArgs([]), "/work");
    assert.equal(defaults.settings, null);
    assert.equal(defaults.out, null, "the default is in build/ of the project, wherever run from");
});

test("the logs to open go to the app as OPEN_AT_START, with the variables given", () => {
    const options = parseShotArgs(["--open", "/l/a.dlt", "--open", "/l/b.log", "--env", "MENU_BAR_PLATFORM=linux"]);
    assert.deepEqual(appEnv(options), { MENU_BAR_PLATFORM: "linux", OPEN_AT_START: "/l/a.dlt\n/l/b.log" });
    assert.deepEqual(appEnv(parseShotArgs([])), {}, "no OPEN_AT_START without logs");
});

test("the main window: on screen, normal layer, the largest", () => {
    assert.equal(mainWindow([]), null);
    assert.equal(mainWindow([
        { id: 1, layer: 0, onscreen: false, width: 500, height: 500 }, // off-screen: a blank shot
        { id: 2, layer: 25, onscreen: true, width: 1200, height: 900 }, // a popup or menu
        { id: 3, layer: 0, onscreen: true, width: 100, height: 30 },
        { id: 4, layer: 0, onscreen: true, width: 1000, height: 800 }
    ]), 4);
    assert.equal(mainWindow([{ id: 1, layer: 0, onscreen: false, width: 500, height: 500 }]), null);
});

test("the program of each system", () => {
    assert.equal(programName("win32"), "log_tracy.exe");
    assert.equal(programName("linux"), "log_tracy");
    assert.equal(programName("darwin"), "log_tracy");
});

test("the window list of a lister: JSON, or no window when it printed anything else", () => {
    assert.deepEqual(windowList(`[{"id":4,"layer":0,"onscreen":true,"width":10,"height":20}]\n`),
        [{ id: 4, layer: 0, onscreen: true, width: 10, height: 20 }]);
    assert.deepEqual(windowList(""), []);
    assert.deepEqual(windowList("WARNING: profile not loaded\n[]"), []);
    assert.deepEqual(windowList(`{"id":4}`), [], "not a list");
});

test("on Linux the app runs on X11 (XWayland in a Wayland session): its windows can be captured", () => {
    assert.deepEqual(systemEnv("linux"), { GDK_BACKEND: "x11" });
    assert.deepEqual(systemEnv("darwin"), {});
    assert.deepEqual(systemEnv("win32"), {});
});

test("the windows of a process on X11, from xdotool", () => {
    assert.deepEqual(xdotoolIds("41943047\n41943050\n\n"), [41943047, 41943050]);
    assert.deepEqual(xdotoolIds(""), []);
    assert.deepEqual(xdotoolWindow(41943047, "WINDOW=41943047\nX=10\nY=20\nWIDTH=1000\nHEIGHT=830\nSCREEN=0\n"),
        { id: 41943047, layer: 0, onscreen: true, width: 1000, height: 830 });
    assert.equal(xdotoolWindow(1, "garbage"), null);
});
