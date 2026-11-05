// The colors of the rules the rows refer to, see resources/rule-colors.js.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { ruleColors } from "../../resources/rule-colors.js";

test("ruleColors: the color of every rule that has one, by its id, across the sets", () => {
    const colors = ruleColors([
        { rules: [{ id: 1, color: "#ff0000" }, { id: 2, color: "" }] },
        { rules: [{ id: 5, color: "#00FF7f" }] },
    ]);
    assert.equal(colors.get(1), "#ff0000");
    assert.equal(colors.get(5), "#00FF7f");
    assert.equal(colors.has(2), false, "a rule without a color");
    assert.equal(colors.size, 2);
});

test("ruleColors: no sets, no colors", () => {
    assert.equal(ruleColors(undefined).size, 0);
    assert.equal(ruleColors([{ rules: [] }, {}]).size, 0);
});
