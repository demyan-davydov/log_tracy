// The sections of Settings, see resources/settings-sections.js.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { initialSection, fontSizeMarks, startFontSize } from "../../resources/settings-sections.js";

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

test("every step of the font size is marked, a label every 20%", () => {
    const marks = fontSizeMarks(110);
    assert.deepEqual(marks.map(m => m.value), [80, 85, 90, 95, 100, 105, 110, 115, 120, 125, 130, 135, 140, 145,
        150, 155, 160, 165, 170, 175, 180, 185, 190, 195, 200]);
    assert.deepEqual(marks.filter(m => m.label).map(m => m.label), ["80%", "100%", "120%", "140%", "160%", "180%", "200%"]);
});

test("the marks are major (labelled), of 10% or of the step", () => {
    const classOf = value => fontSizeMarks(130).find(m => m.value === value).className.split(" ");
    assert.ok(classOf(120).includes("major"));
    assert.ok(classOf(110).includes("ten"));
    assert.ok(classOf(115).includes("step"));
});

test("the normal size and the one the dialog opened with are told apart", () => {
    const marks = fontSizeMarks(110);
    assert.ok(marks.find(m => m.value === 100).className.split(" ").includes("normal"));
    assert.deepEqual(marks.filter(m => m.className.split(" ").includes("initial")).map(m => m.value), [110]);
});

test("a start off the step (edited settings) gets a mark of its own without a label", () => {
    const marks = fontSizeMarks(112);
    assert.deepEqual(marks.filter(m => m.className.split(" ").includes("initial")), [{ value: 112, label: "", className: "initial" }]);
    assert.equal(marks.length, 26);
});

test("an impossible font size (edited settings) starts from 100%", () => {
    for (const size of [undefined, 0, -10, NaN, 112.5])
        assert.equal(startFontSize(size), 100);
    assert.equal(startFontSize(135), 135);
});
