// The pure part of scripts/review-lenses.mjs: which lenses of the review a change needs.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { lensesFor, lenses } from "../../scripts/review-lenses.mjs";

test("no change, no review", () => {
    assert.deepEqual(lensesFor([]), []);
});

test("the rules are checked for every change, docs only too", () => {
    assert.deepEqual(lensesFor(["docs/backlog.md"]), ["rules"]);
    assert.deepEqual(lensesFor([".ai/rules/ux.md"]), ["rules"]);
});

test("performance and threads: the indexing, the formats, the filters, the hot rows", () => {
    for (const path of ["source/domain/log_index.d", "source/formats/dlt/parser.d",
        "source/log_core/rule_filter.d", "source/utils/parallel_scan.d", "source/ui/table_rows.d",
        "source/ui/main_window.d", "source/ui/app_session.d", "scripts/bench_rows.d"])
        assert.deepEqual(lensesFor([path]), ["rules", "performance"], path);
});

test("UX: what the user sees and does", () => {
    for (const path of ["resources/settings.htm", "resources/style.css", "resources/tabs.js",
        "resources/i18n/translations/ru.json", "source/ui/app_menu.d"])
        assert.deepEqual(lensesFor([path]), ["rules", "ux"], path);
});

test("the log table in the script is both hot and seen", () => {
    for (const path of ["resources/table.css", "resources/text-selection.js", "resources/virtual-dlt-view.js",
        "resources/cell-format.js", "resources/row-selection.js", "resources/rule-colors.js"])
        assert.deepEqual(lensesFor([path]), ["rules", "performance", "ux"], path);
});

test("architecture: a change across packages, or of the composition root", () => {
    assert.deepEqual(lensesFor(["source/log_core/log_format.d", "source/formats/logcat.d"]),
        ["rules", "architecture", "performance"]);
    assert.deepEqual(lensesFor(["source/ui/app_session.d", "resources/backend.js"]),
        ["rules", "architecture", "performance"]);
    assert.deepEqual(lensesFor(["source/app.d"]), ["rules", "architecture"]);
    assert.deepEqual(lensesFor(["dub.sdl"]), ["rules", "architecture"]);
});

test("no architecture for a change inside one package, its tests or the docs", () => {
    assert.deepEqual(lensesFor(["source/formats/logcat.d", "source/formats/registry.d"]),
        ["rules", "performance"]);
    assert.deepEqual(lensesFor(["resources/tabs.js", "resources/style.css", "tests/js/new-tab.test.mjs"]),
        ["rules", "ux"]);
    assert.deepEqual(lensesFor(["source/ui/app_menu.d", "docs/backlog.md", ".ai/knowledge/ui.md"]),
        ["rules", "ux"]);
});

test("lenses come in a fixed order, each once", () => {
    assert.deepEqual(lensesFor(["resources/tabs.js", "source/domain/workspace.d", "resources/menu-bar.js"]),
        ["rules", "architecture", "performance", "ux"]);
    assert.deepEqual(lenses, ["rules", "architecture", "performance", "ux"]);
});

test("the backend bridge and the build scripts need the rules only", () => {
    assert.deepEqual(lensesFor(["resources/backend.js"]), ["rules"]);
    assert.deepEqual(lensesFor(["scripts/build.mjs", "tests/js/backend.test.mjs"]), ["rules"]);
});
