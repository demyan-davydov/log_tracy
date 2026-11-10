// The calls of the script to the backend are named in two languages: each
// xcall of resources/backend.js has its case in MainWindow.handleEvent
// (source/ui/main_window.d), and each case is called by backend.js, the only
// way the script reaches the backend.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const root = new URL("../../", import.meta.url);
const read = path => readFileSync(new URL(path, root), "utf8");

// The names of the calls: the first argument of xcall in backend.js, the
// labels of the cases of handleEvent in the window (a switch elsewhere in the
// file is not about the calls of the script)
const scriptCalls = text => new Set([...text.matchAll(/\bxcall\(\s*"(\w+)"/g)].map(m => m[1]));
const handleEventOf = text => {
    const start = text.search(/\bbool handleEvent\(/);
    const end = text.indexOf("\n    }\n", start); // the method ends at the indent of its class members
    return start < 0 || end < 0 ? "" : text.slice(start, end);
};
const windowCalls = text => new Set([...handleEventOf(text).matchAll(/^\s*case\s+"(\w+)"\s*:/gm)].map(m => m[1]));

const missing = (names, from) => [...names].filter(name => !from.has(name)).sort();

test("the names are read from both sides", () => {
    assert.deepEqual([...scriptCalls(`xcall("a", 1); xcall( "b")`)], ["a", "b"]);
    const window = `    void other()\n    {\n        case "x":\n    }\n`
        + `    override bool handleEvent(HELEMENT he)\n    {\n        case "a":\n            case "b":\n    }\n`
        + `    void after()\n    {\n        case "y":\n    }\n`;
    assert.deepEqual([...windowCalls(window)], ["a", "b"], "only the cases of handleEvent");
});

test("every call of backend.js has its case in the window, and every case is called", () => {
    const script = scriptCalls(read("resources/backend.js"));
    const window = windowCalls(read("source/ui/main_window.d"));
    assert.ok(script.size > 0 && window.size > 0, "no calls found: the patterns are out of date");
    assert.deepEqual(missing(script, window), [], "called by backend.js, unknown to the window");
    assert.deepEqual(missing(window, script), [], "a case of the window backend.js never calls");
});
