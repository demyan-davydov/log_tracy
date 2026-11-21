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
        assert.deepEqual(numbers(resource(theme), /--match-color-(\d+):/g), upTo(matchColorCount));
    });

test("matchColorClass: the colors repeat", () => {
    assert.equal(matchColorClass(0), "match-color-0");
    assert.equal(matchColorClass(matchColorCount + 3), "match-color-3");
    assert.equal(matchColorClass(-1), `match-color-${matchColorCount - 1}`);
});

test("the painter in D has as many chip colors as the stylesheet, and the colors of the light theme", () => {
    const painter = resource("../source/ui/log_table/log_look.d");
    assert.equal(Number(painter.match(/enum size_t matchColorCount = (\d+);/)[1]), matchColorCount);
    const body = painter.match(/Color\[matchColorCount\] match = \[([\s\S]*?)\];/)[1];
    const defaults = [...body.matchAll(/Color\(0x(\w\w), 0x(\w\w), 0x(\w\w)\)/g)].map(m => `#${m[1]}${m[2]}${m[3]}`);
    const light = [...resource("theme-light.css").matchAll(/--match-color-\d+:\s*(#\w+);/g)].map(m => m[1]);
    assert.deepEqual(defaults, light);
});
