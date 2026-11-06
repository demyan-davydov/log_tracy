// The search query of chips and its text form, see resources/search-query.js.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { queryPrefix, makeChip, formatQuery, parseQuery, typeBar, pastedText, pasteLimit } from "../../resources/search-query.js";

const text = (t, ignoreCase = false) => makeChip(t, { ignoreCase });
const regex = (t, ignoreCase = false) => makeChip(t, { isRegex: true, ignoreCase });

test("a new chip is text and ignores case", () => {
    assert.deepEqual(makeChip("error"), { text: "error", isRegex: false, ignoreCase: true });
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
    assert.deepEqual(typeBar(text("abc", true), 3), { split: [text("abc", true), makeChip("")] },
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

test("pastedText: a short line is pasted as it is", () => {
    assert.equal(pastedText("timeout after 30s"), "timeout after 30s");
    assert.equal(pastedText(""), "");
});

test("pastedText: line breaks become spaces", () => {
    assert.equal(pastedText("a\nb\r\nc\rd"), "a b c d");
});

test("pastedText: a long text is cut, an ellipsis shows it was", () => {
    const long = "x".repeat(pasteLimit + 10);
    assert.equal(pastedText(long), "x".repeat(pasteLimit) + "…");
    assert.equal(pastedText("x".repeat(pasteLimit)), "x".repeat(pasteLimit), "exactly the limit is kept whole");
    assert.equal(pastedText("😀".repeat(pasteLimit + 1)), "😀".repeat(pasteLimit) + "…", "by characters, not halves of them");
    assert.equal(pastedText("a\n".repeat(pasteLimit)), "a ".repeat(pasteLimit / 2) + "…", "the breaks first, then the cut");
});

test("pastedText: a regex is not cut, its line breaks become spaces", () => {
    const pattern = "(" + "alpha|".repeat(20) + "omega)";
    assert.equal(pastedText(pattern, { isRegex: true }), pattern);
    assert.equal(pastedText("a\nb", { isRegex: true }), "a b");
});
