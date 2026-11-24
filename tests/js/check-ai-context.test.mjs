// The pure part of scripts/utils/check-ai-context.mjs: the names in backquotes of the shared context
// and which of them the code no longer has.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { codeSpans, classify, staleReason, indexCode, isContext } from "../../scripts/utils/check-ai-context.mjs";

test("the spans in backquotes come with their line, the fenced blocks left out", () => {
    const text = "See `formats/dlt/fields` and `LogDocument`.\n```sh\nnode `x`\n```\nThen ``a `b` c`` and `--threads`.\n";
    assert.deepEqual(codeSpans(text), [
        { line: 1, span: "formats/dlt/fields" },
        { line: 1, span: "LogDocument" },
        { line: 5, span: "a `b` c" },
        { line: 5, span: "--threads" },
    ]);
});

test("a span is a path, an identifier, an option or something else to leave alone", () => {
    assert.equal(classify("formats/dlt/fields"), "path");
    assert.equal(classify("scripts/build.mjs"), "path");
    assert.equal(classify(".ai/rules/ux.md"), "path");
    assert.equal(classify("bench_rows.d"), "path");
    assert.equal(classify("LogDocument"), "identifier");
    assert.equal(classify("removeAttribute"), "identifier");
    assert.equal(classify("doc.applySearchFilter()"), "identifier");
    assert.equal(classify("Element.append"), "identifier");
    assert.equal(classify("--threads"), "option");
    assert.equal(classify("--arch=arm64"), "option");
    for (const other of ["display: none", "master", "ldc2", "attributes[\"x\"] = null", "build/<platform>-<arch>",
        "N modules passed unittests", "ldc2 -unittest -main", "ui/*.d", "http://x/y", "ref", "-preview=in"])
        assert.equal(classify(other), null, other);
});

test("a path is found in the repository, a D module by its name in source/, a bare file by its name anywhere", () => {
    const code = indexCode(["source/formats/dlt/fields.d", "source/ui/app_session.d", "scripts/build.mjs",
        "resources/backend.js", ".ai/rules/ux.md", "scripts/utils/bench_rows.d"], "");
    assert.equal(staleReason("formats/dlt/fields", code), null);
    assert.equal(staleReason("source/ui/app_session.d", code), null);
    assert.equal(staleReason("ui/app_session", code), null);
    assert.equal(staleReason("resources/backend.js", code), null);
    assert.equal(staleReason("backend.js", code), null);
    assert.equal(staleReason("bench_rows.d", code), null);
    assert.equal(staleReason(".ai/rules/ux.md", code), null);
    assert.equal(staleReason("source/formats", code), null); // a folder
    assert.equal(staleReason("formats/", code), null);
    assert.equal(staleReason("scripts/build.mjs:42", code), null); // a line of it
    assert.match(staleReason("formats/dlt/headers", code), /no file/);
    assert.match(staleReason("old.mjs", code), /no file/);
});

test("an identifier or an option is found as a word of the code", () => {
    const code = indexCode([], "class LogDocument { void applySearchFilter() {} }\nel.removeAttribute('x');\n"
        + 'getopt(args, "threads", &threads); usage("--release")');
    assert.equal(staleReason("LogDocument", code), null);
    assert.equal(staleReason("doc.applySearchFilter()", code), null);
    assert.equal(staleReason("removeAttribute", code), null);
    assert.equal(staleReason("--release", code), null);
    assert.equal(staleReason("--threads", code), null); // getopt names it without the dashes
    assert.match(staleReason("LogDocumentView", code), /not in the code/);
    assert.match(staleReason("--fast", code), /not in the code/);
});

test("a member of a module (`ui/filter_commands.DocumentFilters`) is its module and its name", () => {
    const code = indexCode(["source/ui/filter_commands.d", "resources/i18n/dom.js"], "struct DocumentFilters {}\nfunction translateTree() {}");
    assert.equal(staleReason("ui/filter_commands.DocumentFilters", code), null);
    assert.equal(staleReason("i18n/dom.translateTree", code), null);
    assert.match(staleReason("ui/filter_commands.RuleFilters", code), /RuleFilters is not in the code/);
    assert.match(staleReason("ui/old_commands.DocumentFilters", code), /no file or folder ui\/old_commands/);
});

test("a path outside the repository (local logs, builds, the Sciter SDK) is left alone", () => {
    const code = indexCode([], "");
    for (const path of ["test_data/", "build/screenshot.png", "build/tools/window-list", "samples.sciter/popup", "bin/"])
        assert.equal(staleReason(path, code), null, path);
});

test("an option is found as a whole option or a quoted name, not as the start of a longer one", () => {
    const code = indexCode([], 'usage("--faster --release-notes"); x = "fast-mode";');
    assert.match(staleReason("--fast", code), /not in the code/);
    assert.match(staleReason("--release", code), /not in the code/);
    assert.equal(staleReason("--faster", code), null);
});

test("the shared context is AGENTS.md, CLAUDE.md and the Markdown of .ai/ and .claude/", () => {
    for (const file of ["AGENTS.md", "CLAUDE.md", ".ai/INDEX.md", ".claude/skills/app/SKILL.md"])
        assert.equal(isContext(file), true, file);
    for (const file of ["README.md", "docs/building.md", ".ai/notes.txt"])
        assert.equal(isContext(file), false, file);
});

test("as a hook of dub with the hooks off it does nothing: scripts/test.mjs runs it itself", async () => {
    const { spawnSync } = await import("node:child_process");
    const { fileURLToPath } = await import("node:url"); // a URL's pathname is "/D:/..." on Windows
    const script = fileURLToPath(new URL("../../scripts/utils/check-ai-context.mjs", import.meta.url));
    const result = spawnSync(process.execPath, [script, "--hook"], {
        encoding: "utf8", env: { ...process.env, NO_DUB_HOOKS: "1" } });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, "");
});
