// The values of a slider, see resources/slider-value.js.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { valueAt, fractionOf, keyedValue } from "../../resources/slider-value.js";

const range = { min: 80, max: 200, step: 5 };

test("a point on the track gives the nearest value of the step", () => {
    assert.equal(valueAt(0, range), 80);
    assert.equal(valueAt(1, range), 200);
    assert.equal(valueAt(0.5, range), 140);
    assert.equal(valueAt(46 / 120, range), 125); // 126: the nearest step is 125
    assert.equal(valueAt(48 / 120, range), 130); // 128
});

test("a point beyond the track gives the end of the range", () => {
    assert.equal(valueAt(-0.3, range), 80);
    assert.equal(valueAt(1.7, range), 200);
});

test("the place of a value on the track", () => {
    assert.equal(fractionOf(80, range), 0);
    assert.equal(fractionOf(200, range), 1);
    assert.equal(fractionOf(140, range), 0.5);
});

test("a value beyond the range (edited settings) stands at its end", () => {
    assert.equal(fractionOf(60, range), 0);
    assert.equal(fractionOf(300, range), 1);
});

test("the arrows move by a step, Home and End to the ends", () => {
    assert.equal(keyedValue(100, "ArrowRight", range), 105);
    assert.equal(keyedValue(100, "ArrowUp", range), 105);
    assert.equal(keyedValue(100, "ArrowLeft", range), 95);
    assert.equal(keyedValue(100, "ArrowDown", range), 95);
    assert.equal(keyedValue(100, "Home", range), 80);
    assert.equal(keyedValue(100, "End", range), 200);
});

test("the arrows stop at the ends", () => {
    assert.equal(keyedValue(200, "ArrowRight", range), 200);
    assert.equal(keyedValue(80, "ArrowLeft", range), 80);
});

test("from a value off the step (edited settings) the arrows go to the steps beside it", () => {
    assert.equal(keyedValue(112, "ArrowRight", range), 115);
    assert.equal(keyedValue(112, "ArrowLeft", range), 110);
    assert.equal(keyedValue(60, "ArrowRight", range), 80);
    assert.equal(keyedValue(300, "ArrowLeft", range), 200);
});

test("from a value beyond the range the arrows never move it away from the range", () => {
    assert.equal(keyedValue(300, "ArrowRight", range), 300);
    assert.equal(keyedValue(60, "ArrowLeft", range), 60);
});

test("other keys are not the slider's", () => {
    assert.equal(keyedValue(100, "KeyA", range), null);
    assert.equal(keyedValue(100, "Enter", range), null);
});
