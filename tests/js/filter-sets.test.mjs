// What the filter sets say as a whole, see resources/filter-sets.js.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { filtersActive } from "../../resources/filter-sets.js";

test("filtersActive: an enabled rule of an enabled set", () => {
    assert.equal(filtersActive([{ enabled: true, rules: [{ enabled: true, error: "" }] }]), true);
});

test("filtersActive: a set switched off or a rule switched off works on nothing", () => {
    assert.equal(filtersActive([{ enabled: false, rules: [{ enabled: true, error: "" }] }]), false);
    assert.equal(filtersActive([{ enabled: true, rules: [{ enabled: false, error: "" }] }]), false);
});

test("filtersActive: a rule not applied (its error) doesn't count", () => {
    assert.equal(filtersActive([{ enabled: true, rules: [{ enabled: true, error: "no column" }] }]), false);
});

test("filtersActive: one working rule among others is enough", () => {
    assert.equal(filtersActive([
        { enabled: false, rules: [{ enabled: true, error: "" }] },
        { enabled: true, rules: [{ enabled: false, error: "" }, { enabled: true }] },
    ]), true);
});

test("filtersActive: no sets, no rules", () => {
    assert.equal(filtersActive(undefined), false);
    assert.equal(filtersActive([]), false);
    assert.equal(filtersActive([{ enabled: true, rules: [] }, { enabled: true }]), false);
});
