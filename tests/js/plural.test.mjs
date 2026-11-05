// Which plural form a count takes in a language.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { pluralCategory, pluralCategories } from "../../resources/i18n/plural.js";

const categoriesOf = (locale, counts) => counts.map((n) => pluralCategory(locale, n));

test("english: one for 1, other for the rest", () => {
    assert.deepEqual(categoriesOf("en", [0, 1, 2, 5, 11, 21, 1.5]),
        ["other", "one", "other", "other", "other", "other", "other"]);
});

test("russian: one, few and many by the last digits", () => {
    assert.deepEqual(categoriesOf("ru", [1, 21, 101, 1001]), ["one", "one", "one", "one"]);
    assert.deepEqual(categoriesOf("ru", [2, 3, 4, 22, 34, 102]), ["few", "few", "few", "few", "few", "few"]);
    assert.deepEqual(categoriesOf("ru", [0, 5, 9, 10, 11, 12, 14, 19, 20, 25, 111, 112, 114]),
        Array(13).fill("many"));
});

test("russian: a fraction takes the form of few (1,5 совпадения)", () => {
    assert.equal(pluralCategory("ru", 1.5), "few");
});

test("the rules go by the language of a tag", () => {
    assert.equal(pluralCategory("ru-KZ", 3), "few");
    assert.equal(pluralCategory("en-GB", 3), "other");
    assert.equal(pluralCategory("ru_RU", 3), "few", "a POSIX locale");
    assert.equal(pluralCategory("ru_RU.UTF-8", 3), "few");
});

test("a language without rules counts as english", () => {
    assert.deepEqual(categoriesOf("xx", [1, 3]), ["one", "other"]);
    assert.deepEqual(pluralCategories("xx"), ["one", "other"]);
});

test("the forms a translation of a language must have", () => {
    assert.deepEqual(pluralCategories("en"), ["one", "other"]);
    assert.deepEqual(pluralCategories("ru"), ["one", "few", "many"]);
});
