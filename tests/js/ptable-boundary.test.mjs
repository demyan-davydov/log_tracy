// The package of the log table (source/ptable) imports only itself and the standard library: it can
// move to a repository of its own as it is (docs/stories/painted-table.md).
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync } from "node:fs";

const dir = new URL("../../source/ptable/", import.meta.url);

// The modules a D file imports: `import a.b, c.d : x;`, public or not, also inside `version (unittest)`
export const importsOf = text => [...text.matchAll(/^\s*(?:public\s+|static\s+)?import\s+([^;]+);/gm)]
    .flatMap(m => m[1].split(":")[0].split(",")) // after a colon come the names taken from the last module
    .map(part => part.trim().replace(/^\w+\s*=\s*/, ""))
    .filter(Boolean);

test("imports are read from D code", () => {
    assert.deepEqual(importsOf("import std.conv : to;\n    public import ptable.layout;\nimport a.b, c.d : x, y;"),
        ["std.conv", "ptable.layout", "a.b", "c.d"]);
});

test("the table's package imports only itself, std and core", () => {
    const files = readdirSync(dir).filter(name => name.endsWith(".d"));
    assert.ok(files.length >= 4, "the modules are found");
    for (const file of files) {
        const foreign = importsOf(readFileSync(new URL(file, dir), "utf8"))
            .filter(name => !/^(ptable|std|core)(\.|$)/.test(name));
        assert.deepEqual(foreign, [], `${file} imports what the package must not know`);
    }
});

// ptable is the table without any knowledge of what a cell holds: the text (its style, its wrap, its words, its measuring) is
// the package ptable_text, which imports ptable and never the other way round. The names of the text must not occur in ptable's code.
const textDir = new URL("../../source/ptable_text/", import.meta.url);
const textNames = /\b(LineSpan|wrapLines|firstLineWidth|glyphWidth|maxMeasuredChars|TextMeasurer|FontMetrics|TextPlace|ColumnStyle|CellStyle|Halign|Valign|alignedX|alignOffset|wordAt|charAt|caretAt|wholeText|TextSpot|caretInText|rectsInText|unitInText)\b/;
const codeOf = text => text.replace(/\/\*[\s\S]*?\*\//g, "").split("\n").map(line => line.replace(/\/\/.*$/, "")).join("\n");

test("ptable's code names nothing of the text", () => {
    for (const file of readdirSync(dir).filter(name => name.endsWith(".d"))) {
        const found = codeOf(readFileSync(new URL(file, dir), "utf8")).match(new RegExp(textNames, "g")) ?? [];
        assert.deepEqual([...new Set(found)], [], `${file} names the text: it belongs to ptable_text`);
    }
});

test("ptable_text imports only ptable, itself, std and core", () => {
    assert.ok(existsSync(textDir), "the package exists");
    const files = readdirSync(textDir).filter(name => name.endsWith(".d"));
    assert.ok(files.length >= 3, "the modules are found");
    for (const file of files) {
        const foreign = importsOf(readFileSync(new URL(file, textDir), "utf8"))
            .filter(name => !/^(ptable|ptable_text|std|core)(\.|$)/.test(name));
        assert.deepEqual(foreign, [], `${file} imports what the package must not know`);
    }
});

// The layers of the host of the table: the Sciter layer and the log layer do not know each other (the glue,
// ui/log_table_behavior and the session, joins them); both know ptable and ui/look; the log layer is free of Sciter.
const uiDir = folder => new URL(`../../source/ui/${folder}/`, import.meta.url);
const importsIn = folder => readdirSync(uiDir(folder)).filter(n => n.endsWith(".d"))
    .map(file => [file, importsOf(readFileSync(new URL(file, uiDir(folder)), "utf8"))]);

test("the Sciter layer of the table does not import the log layer", () => {
    const files = importsIn("sciter_table");
    assert.ok(files.length >= 1, "the modules are found");
    for (const [file, imports] of files)
        assert.deepEqual(imports.filter(n => /^ui\.log_table(\.|$)/.test(n) || /^domain(\.|$)/.test(n)), [], `${file} knows the log`);
});

test("the log layer of the table does not import Sciter", () => {
    const files = importsIn("log_table");
    assert.ok(files.length >= 4, "the modules are found");
    for (const [file, imports] of files)
        assert.deepEqual(imports.filter(n => /^sciter(\.|$)/.test(n) || /^ui\.sciter_table(\.|$)/.test(n)), [], `${file} knows Sciter`);
});
