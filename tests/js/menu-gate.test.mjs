// A context menu opens by the mouse only (resources/menu-gate.js)
import test from "node:test";
import assert from "node:assert/strict";
import { menuGate, menuOpensByMouse } from "../../resources/menu-gate.js";

test("a press lets one menu open; a key after it, or no press at all, lets none", () => {
    const gate = menuGate();
    assert.equal(gate.take(), false, "nothing pressed: the keyboard's menu");
    gate.pressed();
    assert.equal(gate.take(), true, "a right click");
    assert.equal(gate.take(), false, "taken: the next one needs a press of its own");
    gate.pressed();
    gate.keyed();
    assert.equal(gate.take(), false, "the Menu key after a click");
    gate.keyed();
    gate.pressed();
    assert.equal(gate.take(), true, "Control held, then a click (Control+click on macOS)");
});

test("no window gate yet: no menu", () => {
    assert.equal(menuOpensByMouse(), false);
});
