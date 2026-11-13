// The colors of the rules the rows refer to, see resources/rule-colors.js.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { ruleColors, contrastText } from "../../resources/rule-colors.js";

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

test("contrastText: black on a light color, white on a dark one", () => {
    assert.equal(contrastText("#ffffff"), "#000000");
    assert.equal(contrastText("#ffff00"), "#000000", "yellow");
    assert.equal(contrastText("#00ff00"), "#000000", "green");
    assert.equal(contrastText("#ff9999"), "#000000", "pink");
    assert.equal(contrastText("#000000"), "#ffffff");
    assert.equal(contrastText("#0000ff"), "#ffffff", "blue");
    assert.equal(contrastText("#ff0000"), "#000000", "red: black has the higher contrast");
    assert.equal(contrastText("#800000"), "#ffffff", "dark red");
});

test("contrastText: the case of the hex digits doesn't matter", () => {
    assert.equal(contrastText("#FFFF00"), contrastText("#ffff00"));
    assert.equal(contrastText("#0000FF"), "#ffffff");
});
