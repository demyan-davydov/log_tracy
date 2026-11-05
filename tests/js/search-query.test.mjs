// The search query of chips and its text form, see resources/search-query.js.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { queryPrefix, makeChip, formatQuery, parseQuery, typeBar } from "../../resources/search-query.js";

const text = (t, ignoreCase = false) => makeChip(t, { ignoreCase });
const regex = (t, ignoreCase = false) => makeChip(t, { isRegex: true, ignoreCase });

test("a new chip is text and case-sensitive", () => {
    assert.deepEqual(makeChip("error"), { text: "error", isRegex: false, ignoreCase: false });
});

test("formatQuery: chips after the prefix, joined by ' | '", () => {
    assert.equal(formatQuery([text("connection lost"), regex("time(out|d)", true), text("Ok", true)]),
        `${queryPrefix} "connection lost" | /time(out|d)/i | "Ok"i`);
    assert.equal(formatQuery([]), queryPrefix);
});

test("formatQuery: quotes and backslashes of a text, slashes of a regex are escaped", () => {
    assert.equal(formatQuery([text(`a"b\\c`)]), `${queryPrefix} "a\\"b\\\\c"`);
    assert.equal(formatQuery([regex("a/b")]), `${queryPrefix} /a\\/b/`);
    assert.equal(formatQuery([regex("a\\/b")]), `${queryPrefix} /a\\/b/`, "an escaped slash stays as it is");
    assert.equal(formatQuery([regex("\\d+\\.")]), `${queryPrefix} /\\d+\\./`, "other escapes stay as they are");
});

test("parseQuery reverses formatQuery", () => {
    const queries = [
        [],
        [text("error")],
        [text(" spaced "), text("", true)],
        [text(`a"b\\c|d`), regex("x|y/z", true), regex("\\d+\\.\\s")],
        [regex("[/\\\\]"), text("/not a regex/")],
    ];
    for (const chips of queries)
        assert.deepEqual(parseQuery(formatQuery(chips)), chips, formatQuery(chips));
});

test("parseQuery: an escaped slash of a regex is read as a slash", () => {
    assert.deepEqual(parseQuery(`${queryPrefix} /a\\/b/`), [regex("a/b")]);
});

test("parseQuery: spaces around the chips and the separators are optional", () => {
    assert.deepEqual(parseQuery(`${queryPrefix}"a"|/b/i   |  "c"  `), [text("a"), regex("b", true), text("c")]);
    assert.deepEqual(parseQuery(`  ${queryPrefix}  `), []);
});

test("parseQuery: a text without the prefix is not a query", () => {
    assert.equal(parseQuery(`"a" | "b"`), null);
    assert.equal(parseQuery(`see ${queryPrefix} "a"`), null);
    assert.equal(parseQuery(""), null);
});

test("parseQuery: a malformed query is not a query", () => {
    const bad = [
        `"a`,             // unclosed text
        `/a`,             // unclosed regex
        `"a" "b"`,        // no separator
        `"a" |`,          // nothing after a separator
        `| "a"`,          // nothing before a separator
        `a`,              // a chip without quotes
        `"a"ii`,          // a flag twice
        `"a"x`,           // an unknown flag
        `"a\\q"`,         // an unknown escape in a text
    ];
    for (const rest of bad)
        assert.equal(parseQuery(`${queryPrefix} ${rest}`), null, rest);
});

test("typeBar: '|' in a text chip closes it and starts the next one", () => {
    assert.deepEqual(typeBar(text("abc", true), 3), { split: [text("abc", true), text("")] },
        "at the end the next chip is a new one");
    assert.deepEqual(typeBar(text("abcdef", true), 3), { split: [text("abc", true), text("def", true)] },
        "in the middle the rest keeps the properties of the chip");
    assert.deepEqual(typeBar(text("abc"), 0), { split: [text(""), text("abc")] });
});

test("typeBar: '|' right after '\\' replaces it with '|'", () => {
    assert.deepEqual(typeBar(text("a\\b"), 2), { chip: text("a|b"), caret: 2 });
    assert.deepEqual(typeBar(text("a\\"), 2), { chip: text("a|"), caret: 2 });
});

test("typeBar: '|' in a regex chip is a part of the regex", () => {
    assert.deepEqual(typeBar(regex("ab", true), 1), { chip: regex("a|b", true), caret: 2 });
    assert.deepEqual(typeBar(regex("a\\"), 2), { chip: regex("a\\|"), caret: 3 }, "an escaped '|' of the regex");
});
