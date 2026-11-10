// resources/debug-eval.js: what the code of a request {"eval": code} of the debug channel gave,
// {value} made plain JSON (elements as summaries, cycles and depth cut) or {thrown}; the response
// line is made of it by ui/debug_protocol.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync(new URL("../../resources/debug-eval.js", import.meta.url), "utf8");
const debugEval = (0, eval)(source);
const answer = code => JSON.parse(debugEval(code));

// An element of Sciter as the summary reads it
class Element {
    constructor(tagName, { id = "", className = "", innerText = "", box = [1, 2, 3, 4] } = {}) {
        Object.assign(this, { tagName, id, className, innerText });
        this.state = { box: (...args) => (args.join() === "xywh,border,window" ? box : null) };
    }
}

test("the value of the last expression, as JSON", () => {
    assert.deepEqual(answer("1 + 2"), { value: 3 });
    assert.deepEqual(answer("const a = [1, 'x', true, null]; a"), { value: [1, "x", true, null] });
    assert.deepEqual(answer("({ a: { b: 2 } })"), { value: { a: { b: 2 } } });
});

test("undefined, a function, a non-finite number, a promise are answered too", () => {
    assert.deepEqual(answer("undefined"), { value: null });
    assert.deepEqual(answer("(function foo() {})"), { value: "function foo" });
    assert.deepEqual(answer("1 / 0"), { value: "Infinity" });
    assert.deepEqual(answer("Promise.resolve(1)"), { value: "[promise]" });
});

test("the code runs in the global scope", () => {
    globalThis.debugEvalProbe = 41;
    try {
        assert.deepEqual(answer("debugEvalProbe + 1"), { value: 42 });
    } finally {
        delete globalThis.debugEvalProbe;
    }
});

test("an exception or a syntax error is what was thrown", () => {
    assert.match(answer("throw new Error('boom')").thrown, /boom/);
    assert.match(answer("1 +").thrown, /SyntaxError/);
    assert.equal(answer("throw new Error('boom')").value, undefined);
});

test("an element is a summary: tag, id, class, text cut, box in the window", () => {
    globalThis.Element = Element;
    try {
        globalThis.probe = new Element("DIV", { id: "x", className: "a b", innerText: `  ${"t".repeat(300)} ` });
        const { value: result } = answer("probe");
        assert.deepEqual(Object.keys(result), ["tag", "id", "class", "text", "box"]);
        assert.equal(result.tag, "div");
        assert.equal(result.class, "a b");
        assert.deepEqual(result.box, [1, 2, 3, 4]);
        assert.equal(result.text.length, 201); // 200 characters and the ellipsis
        assert.ok(result.text.endsWith("…"));
        assert.deepEqual(answer("[new Element('SPAN')]"), { value: [{ tag: "span", box: [1, 2, 3, 4] }] });
    } finally {
        delete globalThis.Element;
        delete globalThis.probe;
    }
});

test("a cycle and a deep value are cut, a long list is cut", () => {
    assert.deepEqual(answer("const o = { n: 1 }; o.self = o; o"), { value: { n: 1, self: "[circular]" } });
    assert.deepEqual(answer("({ a: { b: { c: { d: { e: 1 } } } } })"),
        { value: { a: { b: { c: { d: "[object]" } } } } });
    const { value: result } = answer("Array.from({ length: 150 }, (_, i) => i)");
    assert.equal(result.length, 101);
    assert.equal(result[100], "… 50 more");
});

test("the same object twice is not a cycle", () => {
    assert.deepEqual(answer("const x = { v: 1 }; [x, x]"), { value: [{ v: 1 }, { v: 1 }] });
});
