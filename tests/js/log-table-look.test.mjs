// What the script tells D of the look of the log table (resources/log-table-look.js).
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { collectLook, paletteVariables, spacingVariables } from "../../resources/log-table-look.js";
import { matchColorCount } from "../../resources/match-colors.js";

test("the variables that have a value are collected by the names of the palette, with the scale of the text", () => {
    const values = { "bg-row": "#ffffff", "bg-row-stripe": " #f4f4f4 ", "bg-table-header": "bisque" };
    const look = collectLook(name => values[name], 125);
    assert.deepEqual(look, { row: "#ffffff", stripe: "#f4f4f4", header: "bisque", scale: 1.25, monospacePayload: false });
});

test("whether the Payload is monospace is always told, so that turning it off reaches D too", () => {
    assert.equal(collectLook(() => undefined, 100, [], true).monospacePayload, true);
    assert.equal(collectLook(() => undefined, 100, [], false).monospacePayload, false);
    assert.equal(collectLook(() => undefined).monospacePayload, false, "off by default");
});

test("the least widths of the columns are read by the names the caller gives, by their keys, in dips", () => {
    const values = { "column-min-width": 24, "column-min-width-anchor": 30.5, "column-min-width-dlt-time": 80, "column-min-width-index": "nonsense" };
    const names = ["column-min-width", "column-min-width-anchor", "column-min-width-index", "column-min-width-dlt-time", "column-min-width-logcat-tag", "bg-row"];
    const look = collectLook(name => values[name], 100, names);
    assert.deepEqual(look.minWidths, { default: 24, anchor: 30.5, "dlt-time": 80 }, "no number or no value: no key; a name of no width is not read");
    assert.equal(collectLook(() => 5, 100).minWidths, undefined, "no names, no widths");
});

test("an empty value, a missing one and a failing read leave the color out", () => {
    const look = collectLook(name => {
        if (name === "bg-row") return "";
        if (name === "bg-row-stripe") return null;
        if (name === "bg-row-selected") throw new Error("no such variable");
        if (name === "bg-row-found") return undefined;
        return "#000";
    }, 100);
    assert.equal(look.row, undefined);
    assert.equal(look.stripe, undefined);
    assert.equal(look.selected, undefined);
    assert.equal(look.found, undefined);
    assert.equal(look.border, "#000");
    assert.equal(look.scale, 1);
});

test("the colors of a group of rows come from variables of their own", () => {
    assert.equal(paletteVariables.groupBand, "bg-group");
    assert.equal(paletteVariables.groupPlate, "bg-group-plate");
    assert.equal(paletteVariables.groupLine, "group-line-color");
    assert.equal(paletteVariables.groupInk, "text-group-plate");
});

test("the circle of an anchor comes from the variables of the anchor column", () => {
    assert.equal(paletteVariables.anchorFill, "bg-anchor");
    assert.equal(paletteVariables.anchorLine, "anchor-border-color");
    assert.equal(paletteVariables.anchorFaint, "anchor-faint");
    assert.equal(paletteVariables.anchorRefused, "anchor-refused");
});

test("an object that is not a string is read by its text", () => {
    const color = { toString: () => "rgb(1, 2, 3)" };
    assert.equal(collectLook(() => color).row, "rgb(1, 2, 3)");
    assert.deepEqual(Object.keys(paletteVariables).includes("row"), true);
});

test("every name the script gives is a field of the palette in D, and every variable exists in both themes", () => {
    const painter = readFileSync(new URL("../../source/ui/log_table/log_look.d", import.meta.url), "utf8");
    const body = painter.match(/struct LogPalette\s*\{([\s\S]*?)\n\}/)[1];
    const fields = new Set([...body.matchAll(/\b([A-Za-z_]\w*)\s*=\s*Color\(/g)].map(m => m[1]));
    for (const name of Object.keys(paletteVariables))
        assert.ok(fields.has(name), `${name} is not a field of LogPalette`);
    for (const theme of ["theme-light.css", "theme-dark.css"]) {
        const css = readFileSync(new URL(`../../resources/${theme}`, import.meta.url), "utf8");
        for (const variable of Object.values(paletteVariables))
            assert.ok(css.includes(`--${variable}:`), `--${variable} is not in ${theme}`);
    }
});

test("the margins around the rows are collected as spacing in dips", () => {
    const length = (text, dips) => ({ toString: () => text, valueOf: () => dips });
    const values = { "rows-margin-top": length("2dip", 2), "rows-margin-bottom": length("6dip", 6),
        "rows-margin-left": length("10dip", 10), "rows-margin-right": length("20dip", 20) };
    assert.deepEqual(collectLook(name => values[name], 100).spacing,
        { rowsMarginTop: 2, rowsMarginBottom: 6, rowsMarginLeft: 10, rowsMarginRight: 20 });
});

test("the spacing of the groups is collected as numbers in dips, as Sciter gives a length; a value that is no length is left out", () => {
    const length = (text, dips) => ({ toString: () => text, valueOf: () => dips }); // a length of Sciter: its text, its dips
    const values = { "group-pad-top": length("9pt", 12), "group-pad-bottom": length("1dip", 1) };
    assert.deepEqual(collectLook(name => values[name], 100).spacing, { groupPadTop: 12, groupPadBottom: 1 });
    const wrong = { "group-pad-top": "a lot", "group-pad-bottom": length("-2dip", -2) };
    assert.equal(collectLook(name => wrong[name], 100).spacing, undefined);
    assert.equal(collectLook(() => undefined, 100).spacing, undefined, "no variables: no spacing");
});

test("every spacing name is a field of LogSpacing in D, and its variable is set on the log table", () => {
    const painter = readFileSync(new URL("../../source/ui/log_table/log_look.d", import.meta.url), "utf8");
    const body = painter.match(/struct LogSpacing\s*\{([\s\S]*?)\n\}/)[1];
    const css = readFileSync(new URL("../../resources/table.css", import.meta.url), "utf8");
    for (const [name, variable] of Object.entries(spacingVariables)) {
        assert.ok(new RegExp(`\\b${name}\\b`).test(body), `${name} is not a field of LogSpacing`);
        assert.ok(css.includes(`--${variable}:`), `--${variable} is not in table.css`);
    }
});

test("the colors of the search chips come as an array by their place, a missing one is empty", () => {
    const values = { "match-color-0": "#ffb2b2", "match-color-2": " #ffeb8c " };
    const look = collectLook(name => values[name]);
    assert.equal(look.match.length, matchColorCount);
    assert.deepEqual(look.match.slice(0, 3), ["#ffb2b2", "", "#ffeb8c"]);
    assert.equal(collectLook(() => undefined).match, undefined, "no chip color at all: no array");
});
