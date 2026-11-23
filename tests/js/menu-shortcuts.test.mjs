// The shortcuts of the menu of the window, see resources/menu-shortcuts.js: a key press
// gives the command of the shortcut it is, with exactly its modifiers.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { commandOfKey, shortcutsOf, shortcutTextOf, primaryShortcutText } from "../../resources/menu-shortcuts.js";

const shortcuts = [
    { command: "file.open", code: "KeyO", ctrl: true, shift: false, alt: false },
    { command: "file.saveAs", code: "KeyS", ctrl: true, shift: true, alt: false },
    { command: "app.settings", code: "Comma", ctrl: true, shift: false, alt: false },
];
const key = (code, mods = {}) => ({ code, ctrlKey: false, shiftKey: false, altKey: false, metaKey: false, ...mods });

test("a press with the modifiers of a shortcut gives its command", () => {
    assert.equal(commandOfKey(shortcuts, key("KeyO", { ctrlKey: true })), "file.open");
    assert.equal(commandOfKey(shortcuts, key("KeyS", { ctrlKey: true, shiftKey: true })), "file.saveAs");
    assert.equal(commandOfKey(shortcuts, key("Comma", { ctrlKey: true })), "app.settings");
});

test("other modifiers, or none, give no command", () => {
    assert.equal(commandOfKey(shortcuts, key("KeyO")), null);
    assert.equal(commandOfKey(shortcuts, key("KeyO", { ctrlKey: true, shiftKey: true })), null);
    assert.equal(commandOfKey(shortcuts, key("KeyO", { ctrlKey: true, altKey: true })), null);
    assert.equal(commandOfKey(shortcuts, key("KeyS", { ctrlKey: true })), null);
    assert.equal(commandOfKey(shortcuts, key("KeyO", { metaKey: true })), null);
    assert.equal(commandOfKey(shortcuts, key("KeyO", { ctrlKey: true, metaKey: true })), null);
});

test("no shortcuts, no command", () => {
    assert.equal(commandOfKey([], key("KeyO", { ctrlKey: true })), null);
});

test("the shortcuts of a menu: of its commands at any depth, not those the OS handles", () => {
    const bar = [{ label: "File", items: [
        { command: "file.open", label: "Open", shortcut: { text: "Ctrl+O", code: "KeyO", ctrl: true, shift: false, alt: false, bySystem: false } },
        { separator: true },
        { command: "none", label: "None" },
        { label: "More", items: [
            { command: "x", label: "X", shortcut: { text: "Ctrl+Shift+X", code: "KeyX", ctrl: true, shift: true, alt: false, bySystem: false } },
        ] },
        { command: "app.quit", label: "Exit", shortcut: { text: "Alt+F4", code: "F4", ctrl: false, shift: false, alt: true, bySystem: true } },
    ] }];
    assert.deepEqual(shortcutsOf(bar), [
        { command: "file.open", code: "KeyO", ctrl: true, shift: false, alt: false },
        { command: "x", code: "KeyX", ctrl: true, shift: true, alt: false },
    ]);
    assert.deepEqual(shortcutsOf([]), []);
});

test("the text of the shortcut of a command, at any depth; null without one", () => {
    const menus = [{ label: "File", items: [
        { command: "none", label: "None" },
        { label: "More", items: [{ command: "file.open", label: "Open", shortcut: { text: "Ctrl+O" } }] },
    ] }];
    assert.equal(shortcutTextOf(menus, "file.open"), "Ctrl+O");
    assert.equal(shortcutTextOf(menus, "none"), null);
    assert.equal(shortcutTextOf(menus, "missing"), null);
    assert.equal(shortcutTextOf([], "file.open"), null);
});

test("primaryShortcutText: a key with the primary modifier as each platform shows it", () => {
    assert.equal(primaryShortcutText("C", true), "⌘C");
    assert.equal(primaryShortcutText("C", false), "Ctrl+C");
});
