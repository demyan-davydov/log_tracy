// The pure part of scripts/app.mjs: the command line, the steps of a scenario, the port the app
// listens on, the request lines.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { parseAppArgs, parseSteps, listeningPort, requestLine, waitVerdict, parseResponse, shotOutcome, hoverTarget, hoverPointOf } from "../../scripts/app.mjs";

test("start takes logs, settings, variables and the build", () => {
    assert.deepEqual(parseAppArgs(["start", "--open", "a.dlt", "--open=b.log", "--settings", "s.json",
        "--env", "PSEUDO_LOCALE=1", "--no-build"]), {
        command: "start", args: [], open: ["a.dlt", "b.log"], settings: "s.json",
        env: { PSEUDO_LOCALE: "1" }, build: false, timeout: 10, help: false
    });
});

test("the commands and their arguments", () => {
    assert.deepEqual(parseAppArgs(["eval", "document.title"]).args, ["document.title"]);
    const wait = parseAppArgs(["wait", "$('table')", "--timeout", "2.5"]);
    assert.deepEqual([wait.command, wait.args, wait.timeout], ["wait", ["$('table')"], 2.5]);
    assert.deepEqual(parseAppArgs(["shot"]).args, []);
    assert.deepEqual(parseAppArgs(["shot", "x.png"]).args, ["x.png"]);
    assert.equal(parseAppArgs(["stop"]).command, "stop");
    assert.equal(parseAppArgs(["log"]).command, "log");
    assert.deepEqual(parseAppArgs(["run", "steps.txt"]).args, ["steps.txt"]);
    assert.equal(parseAppArgs([]).help, true);
    assert.equal(parseAppArgs(["--help"]).help, true);
});

test("a wrong command, a missing or extra argument, a bad option is an error", () => {
    assert.throws(() => parseAppArgs(["evil", "x"]), /evil/);
    assert.throws(() => parseAppArgs(["eval"]), /eval/);
    assert.throws(() => parseAppArgs(["eval", "a", "b"]), /eval/);
    assert.throws(() => parseAppArgs(["wait"]), /wait/);
    assert.throws(() => parseAppArgs(["run"]), /run/);
    assert.throws(() => parseAppArgs(["stop", "x"]), /stop/);
    assert.throws(() => parseAppArgs(["wait", "x", "--timeout", "soon"]), /--timeout/);
    assert.throws(() => parseAppArgs(["start", "--opn", "a"]), /--opn/);
    assert.throws(() => parseAppArgs(["start", "--env", "NOVALUE"]), /NAME=VALUE/);
});

test("a scenario: a step a line, comments and empty lines skipped", () => {
    const text = [
        "# open the settings",
        "",
        "eval openSettings()",
        "  wait document.$('.settings') != null  ",
        "wait 2s document.$('x')",
        "shot build/settings.png",
    ].join("\n");
    assert.deepEqual(parseSteps(text), [
        { line: 3, command: "eval", text: "openSettings()" },
        { line: 4, command: "wait", text: "document.$('.settings') != null", timeout: 10 },
        { line: 5, command: "wait", text: "document.$('x')", timeout: 2 },
        { line: 6, command: "shot", text: "build/settings.png" },
    ]);
});

test("a wait step's code may start with a number: only <n>s is a timeout", () => {
    assert.deepEqual(parseSteps("wait 0 < document.$$('tr').length\nwait 0.5s x"), [
        { line: 1, command: "wait", text: "0 < document.$$('tr').length", timeout: 10 },
        { line: 2, command: "wait", text: "x", timeout: 0.5 },
    ]);
});

test("wait goes on while the value is false or the code throws, gives up on code that can't run", () => {
    assert.equal(waitVerdict({ result: true }), "done");
    assert.equal(waitVerdict({ result: { tag: "div" } }), "done");
    assert.equal(waitVerdict({ result: false }), "retry");
    assert.equal(waitVerdict({ result: null }), "retry");
    assert.equal(waitVerdict({ error: "TypeError: cannot read property 'x' of null" }), "retry");
    assert.equal(waitVerdict({ error: "SyntaxError: unexpected token" }), "fail");
    assert.equal(waitVerdict({ result: "[promise]" }), "fail"); // the channel never awaits it
});

test("a response line that is no JSON object is an error response", () => {
    assert.deepEqual(parseResponse(`{"result":1}`), { result: 1 });
    assert.match(parseResponse("garbage").error, /garbage/);
    assert.match(parseResponse("[1]").error, /\[1\]/);
});

test("a wrong step names its line", () => {
    assert.throws(() => parseSteps("eval 1\nclick 10 20"), /line 2.*click/);
    assert.throws(() => parseSteps("eval"), /line 1/);
    assert.throws(() => parseSteps("shot"), /line 1/);
});

test("the port is read from the app's output, null until it listens", () => {
    assert.equal(listeningPort("Log Tracy starting...\n"), null);
    assert.equal(listeningPort("a\nDebug channel: listening on 127.0.0.1:51234\nb"), 51234);
});

test("a request is one line of JSON", () => {
    assert.equal(requestLine("eval", "a\n'b'"), `{"eval":"a\\n'b'"}\n`);
    assert.equal(requestLine("shot", "/x.png"), `{"shot":"/x.png"}\n`);
});

test("a popup closed before its image is told as closed", () => {
    const element = { tag: "popup", box: [1, 2, 3, 4] };
    assert.deepEqual(shotOutcome({ path: "/s/a.png", bytes: 3, popups: [{ closed: true, element }] }),
        { path: "/s/a.png", popups: [{ closed: true, element }] });
});

test("a shot tells its file, and the file and the element of every open popup", () => {
    assert.equal(shotOutcome({ path: "/s/a.png", bytes: 3 }), "/s/a.png");
    const element = { tag: "menu", class: "context", box: [648, 308, 128, 71] };
    assert.deepEqual(shotOutcome({ path: "/s/a.png", bytes: 3,
        popups: [{ path: "/s/a.popup-1.png", bytes: 2, element }] }),
        { path: "/s/a.png", popups: [{ path: "/s/a.popup-1.png", element }] });
});

test("hover, key and type: a command each, and steps of a scenario", () => {
    assert.deepEqual(parseAppArgs(["hover", "10 20"]).args, ["10 20"]);
    assert.deepEqual(parseAppArgs(["key", "Cmd+A"]).args, ["Cmd+A"]);
    assert.deepEqual(parseAppArgs(["type", "abc"]).args, ["abc"]);
    assert.throws(() => parseAppArgs(["hover"]), /hover/);
    assert.throws(() => parseAppArgs(["key"]), /key/);
    assert.deepEqual(parseSteps("hover .btn-chip-history\nkey Escape\ntype error 42"), [
        { line: 1, command: "hover", text: ".btn-chip-history" },
        { line: 2, command: "key", text: "Escape" },
        { line: 3, command: "type", text: "error 42" },
    ]);
    assert.throws(() => parseSteps("type"), /line 1/);
});

test("hover goes to a point of the window or to the middle of an element", () => {
    assert.deepEqual(hoverTarget("10 20"), { point: "10 20" });
    assert.deepEqual(hoverTarget(" 10.5  7 "), { point: "10.5 7" });
    assert.deepEqual(hoverTarget(".tab:nth-child(2)"), { selector: ".tab:nth-child(2)" });
    assert.deepEqual(hoverTarget("#a b"), { selector: "#a b" });
    // a point with a minus is a point (the channel says it is outside), not a selector
    assert.deepEqual(hoverTarget("-5 10"), { point: "-5 10" });
});

test("hover goes to the middle of an element in the window, says why not otherwise", () => {
    const window = [1000, 800];
    assert.deepEqual(hoverPointOf(".x", [100, 200, 40, 20], window), { point: "120 210" });
    assert.deepEqual(hoverPointOf(".x", [0, 0, 11, 11], window), { point: "6 6" }); // rounded
    assert.match(hoverPointOf(".x", null, window).error, /No element \.x/);
    assert.match(hoverPointOf(".x", [10, 10, 0, 0], window).error, /\.x is not shown/);
    assert.match(hoverPointOf(".row", [100, -50, 40, 20], window).error, /\.row is outside the window.*scrollIntoView/);
    assert.match(hoverPointOf(".row", [100, 900, 40, 20], window).error, /outside the window/);
});

test("a type step keeps the spaces of its text: one space after the command, the rest is the text", () => {
    assert.deepEqual(parseSteps("type   indented \nkey Enter"), [
        { line: 1, command: "type", text: "  indented " },
        { line: 2, command: "key", text: "Enter" },
    ]);
    assert.deepEqual(parseSteps("  type a b\r\n"), [{ line: 1, command: "type", text: "a b" }]);
});

test("after -- every argument is an argument, even one starting with --", () => {
    assert.deepEqual(parseAppArgs(["type", "--", "--flag"]).args, ["--flag"]);
    assert.deepEqual(parseAppArgs(["eval", "--", "--x"]).args, ["--x"]);
    assert.throws(() => parseAppArgs(["type", "--flag"]), /--flag/);
});
