// The shortcuts of the menu bar, see resources/menu-shortcuts.js: a key press
// gives the command of the shortcut it is, with exactly its modifiers.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { commandOfKey, shortcutsOf, shortcutTextOf, mnemonicParts, mnemonicOf } from "../../resources/menu-shortcuts.js";

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

test("a label with its mnemonic: the letter and the text around it", () => {
    assert.deepEqual(mnemonicParts({ label: "Exit", mnemonic: 1 }), { before: "E", key: "x", after: "it" });
    assert.deepEqual(mnemonicParts({ label: "File", mnemonic: 0 }), { before: "", key: "F", after: "ile" });
    assert.equal(mnemonicParts({ label: "File" }), null);
    assert.equal(mnemonicParts({ label: "File", mnemonic: 9 }), null);
    assert.equal(mnemonicParts({ label: "File", mnemonic: -1 }), null);
    // A letter outside the BMP stays whole
    assert.deepEqual(mnemonicParts({ label: "a\u{1D400}b", mnemonic: 1 }), { before: "a", key: "\u{1D400}", after: "b" });
});

test("the item of a mnemonic key: Alt+letter on the bar, the letter alone in an open menu", () => {
    const items = [
        { label: "File", mnemonic: 0, items: [] },
        { separator: true },
        { label: "Exit", mnemonic: 1, command: "app.quit" },
        { label: "None", command: "none" },
    ];
    assert.equal(mnemonicOf(items, key("KeyF"), false), 0);
    assert.equal(mnemonicOf(items, key("KeyX"), false), 2);
    assert.equal(mnemonicOf(items, key("KeyF", { altKey: true }), true), 0);
    assert.equal(mnemonicOf(items, key("KeyF"), true), -1); // the bar needs Alt
    assert.equal(mnemonicOf(items, key("KeyF", { altKey: true }), false), -1);
    assert.equal(mnemonicOf(items, key("KeyF", { ctrlKey: true }), false), -1);
    assert.equal(mnemonicOf(items, key("KeyF", { shiftKey: true, altKey: true }), true), -1);
    assert.equal(mnemonicOf(items, key("KeyN"), false), -1);
    assert.equal(mnemonicOf(items, key("Digit1"), false), -1);
});

test("a cyrillic mnemonic is the key of its letter on the russian layout, whatever layout is on", () => {
    const items = [
        { label: "Файл", mnemonic: 0, items: [] },
        { label: "Выход", mnemonic: 1, command: "app.quit" },
        { label: "Жёлтый", mnemonic: 1, command: "yellow" },
        { label: "Юг", mnemonic: 0, command: "south" },
    ];
    assert.equal(mnemonicOf(items, key("KeyA", { altKey: true }), true), 0); // Ф
    assert.equal(mnemonicOf(items, key("KeyS"), false), 1); // ы
    assert.equal(mnemonicOf(items, key("Backquote"), false), 2); // ё
    assert.equal(mnemonicOf(items, key("Period"), false), 3); // Ю
    assert.equal(mnemonicOf(items, key("KeyF"), false), -1);
});

test("a mnemonic of no known key is none", () => {
    assert.equal(mnemonicOf([{ label: "1st", mnemonic: 0, command: "a" }], key("Digit1"), false), -1);
    assert.equal(mnemonicOf([{ label: "Ω", mnemonic: 0, command: "a" }], key("KeyW"), false), -1);
});
