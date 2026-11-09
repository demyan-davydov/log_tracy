// The sections of Settings, see resources/settings-sections.js.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { initialSection, fontSizeOptions } from "../../resources/settings-sections.js";

const sections = ["appearance", "table"];

test("the section the opener asked for", () => {
    assert.equal(initialSection({ section: "table" }, sections), "table");
    assert.equal(initialSection({ section: "appearance" }, sections), "appearance");
});

test("Appearance when none or an unknown one is asked for", () => {
    assert.equal(initialSection({}, sections), "appearance");
    assert.equal(initialSection({ section: "nonsense" }, sections), "appearance");
});

test("Table when opened on its own, without parameters", () => {
    assert.equal(initialSection(null, sections), "table");
});

test("the font sizes mark the one the dialog opened with", () => {
    const options = fontSizeOptions(110);
    assert.deepEqual(options.map(o => o.value), [80, 90, 100, 110, 125, 150, 175, 200]);
    assert.deepEqual(options.filter(o => o.initial).map(o => o.value), [110]);
    assert.equal(options.find(o => o.value === 110).label, "110%");
    assert.equal(options.find(o => o.value === 100).label, "100%");
});

test("a font size not in the list (edited settings) is offered in its place", () => {
    assert.deepEqual(fontSizeOptions(120).map(o => o.value), [80, 90, 100, 110, 120, 125, 150, 175, 200]);
    assert.deepEqual(fontSizeOptions(undefined).filter(o => o.initial).map(o => o.value), [100]);
});
