// The sections of Settings, see resources/settings-sections.js.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { initialSection } from "../../resources/settings-sections.js";

const sections = ["appearance", "columns"];

test("the section the opener asked for", () => {
    assert.equal(initialSection({ section: "columns" }, sections), "columns");
    assert.equal(initialSection({ section: "appearance" }, sections), "appearance");
});

test("Appearance when none or an unknown one is asked for", () => {
    assert.equal(initialSection({}, sections), "appearance");
    assert.equal(initialSection({ section: "nonsense" }, sections), "appearance");
});

test("Columns when opened on its own, without parameters", () => {
    assert.equal(initialSection(null, sections), "columns");
});
