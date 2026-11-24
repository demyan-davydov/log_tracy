import test from "node:test";
import assert from "node:assert/strict";
import { PointerHandlers } from "../../resources/pointer-handlers.js";

test("every handler hears every event with its view, in the order they came", () => {
    const heard = [];
    const handlers = new PointerHandlers([(e, v) => heard.push(`a ${e.type} ${v}`)]);
    handlers.add((e, v) => heard.push(`b ${e.type} ${v}`));
    handlers.hand({ type: "click" }, "view");
    assert.deepEqual(heard, ["a click view", "b click view"]);
});

test("a handler that fails is logged, the ones after it still hear the event", () => {
    const heard = [], logged = [];
    const handlers = new PointerHandlers([() => { throw new Error("no"); }], { log: text => logged.push(text) });
    handlers.add(e => heard.push(e.type));
    handlers.hand({ type: "down" });
    assert.deepEqual(heard, ["down"]);
    assert.equal(logged.length, 1);
    assert.match(logged[0], /no/);
});

test("the kinds whose enters and leaves are heard are the union of what the handlers asked; a handler adding none changes nothing", () => {
    const handlers = new PointerHandlers();
    assert.equal(handlers.hears(), "");
    assert.equal(handlers.add(() => {}), false);
    assert.equal(handlers.add(() => {}, ["header"]), true);
    assert.equal(handlers.add(() => {}, ["header"]), false, "asked already");
    assert.deepEqual(handlers.flags(), [1, 0]);
    assert.equal(handlers.add(() => {}, ["cell"]), true);
    assert.equal(handlers.hears(), "header cell");
    assert.deepEqual(handlers.flags(), [1, 1]);
});
