// The match colors, see resources/match-colors.js: their number is one constant,
// and the stylesheet and both themes define exactly as many.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { matchColorCount, matchColorClass } from "../../resources/match-colors.js";

const resource = name => readFileSync(new URL(`../../resources/${name}`, import.meta.url), "utf8");
const numbers = (text, pattern) => [...text.matchAll(pattern)].map(m => Number(m[1])).sort((a, b) => a - b);
const upTo = n => [...Array(n).keys()];

test("the stylesheet has a class for every match color, and no more", () => {
    assert.deepEqual(numbers(resource("match-colors.css"), /\.match-color-(\d+)\s*\{/g), upTo(matchColorCount));
});

for (const theme of ["theme-light.css", "theme-dark.css"])
    test(`${theme} defines every match color, and no more`, () => {
        const text = resource(theme);
        assert.deepEqual(numbers(text, /--match-color-(\d+):/g), upTo(matchColorCount));
        assert.deepEqual(numbers(text, /@const MATCH_COLOR_(\d+):/g), upTo(matchColorCount));
    });

test("matchColorClass: the colors repeat", () => {
    assert.equal(matchColorClass(0), "match-color-0");
    assert.equal(matchColorClass(matchColorCount + 3), "match-color-3");
    assert.equal(matchColorClass(-1), `match-color-${matchColorCount - 1}`);
});
