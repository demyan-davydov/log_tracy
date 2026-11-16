// The menu of a recent file, see resources/recent-file-menu.js.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { clickOpensRecentFile, recentFileMenu } from "../../resources/recent-file-menu.js";

const commands = items => items.map(({ command, enabled }) => [command, enabled]);

test("a file of the list can be removed, its path copied and shown in its folder", () => {
    assert.deepEqual(commands(recentFileMenu({ exists: true, opened: false })),
        [["show-in-folder", true], ["copy-path", true], ["remove", true]]);
});

test("an open file is not removed: it would be listed again at once", () => {
    assert.deepEqual(commands(recentFileMenu({ exists: true, opened: true })),
        [["show-in-folder", true], ["copy-path", true]]);
});

test("a file not found has no folder to show it in", () => {
    assert.deepEqual(commands(recentFileMenu({ exists: false, opened: false })),
        [["show-in-folder", false], ["copy-path", true], ["remove", true]]);
});

test("a click on a row opens its file, one on its menu button doesn't", () => {
    const inMenu = { closest: selector => selector === ".recent-file-menu" ? {} : null };
    const inRow = { closest: () => null };
    assert.equal(clickOpensRecentFile(inRow), true);
    assert.equal(clickOpensRecentFile(inMenu), false);
});

test("a click whose target is gone opens nothing: it may have been on the menu", () => {
    assert.equal(clickOpensRecentFile(null), false);
});
