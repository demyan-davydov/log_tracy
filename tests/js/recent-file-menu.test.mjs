// The menu of a recent file, see resources/recent-file-menu.js.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { clickOpensRecentFile, recentFileMenu } from "../../resources/recent-file-menu.js";

const commands = items => items.map(({ command, enabled }) => [command, enabled]);

test("a file of the list can be removed, its path copied and shown in its folder", () => {
    assert.deepEqual(commands(recentFileMenu({ exists: true, opened: false })),
        [["show-in-folder", true], ["copy-path", true], ["open-as", true], ["remove", true]]);
});

test("an open file is not removed: it would be listed again at once", () => {
    assert.deepEqual(commands(recentFileMenu({ exists: true, opened: true })),
        [["show-in-folder", true], ["copy-path", true], ["open-as", false]]);
});

test("a file not found has no folder to show it in", () => {
    assert.deepEqual(commands(recentFileMenu({ exists: false, opened: false })),
        [["show-in-folder", false], ["copy-path", true], ["open-as", false], ["remove", true]]);
});

test("an open file is reopened in its own tab (the menu of the tab, File Info), not from the list", () => {
    assert.equal(recentFileMenu({ exists: true, opened: true }).find(item => item.command === "open-as").enabled, false);
});

test("Open as is for a file that was found: not when the system refused it, whatever the format", () => {
    const openAs = failureKind => recentFileMenu({ exists: true, opened: false, failureKind })
        .find(item => item.command === "open-as").enabled;
    assert.equal(openAs("system"), false, "no right, no disk: the format is not the matter");
    assert.equal(openAs("unrecognized"), true, "no format knew it: pick one");
    assert.equal(openAs("unreadable"), true, "the one picked did not read it: pick another");
    assert.equal(openAs(undefined), true, "not failed");
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
