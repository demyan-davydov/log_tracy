// The keys of the menu of the window, as the backend describes it
// (backend.menu()): which command a key press is (shortcutsOf gives {command,
// code, ctrl, shift, alt}, code as KeyboardEvent.code), the text of a
// shortcut, the mnemonic letter of a label. Free of Sciter: tests/js.

// The command of the shortcut `evt` presses, with exactly its modifiers; null if none
export function commandOfKey(shortcuts, evt) {
    if (evt.metaKey) return null; // not a modifier of these shortcuts
    const found = shortcuts.find(s => s.code === evt.code && s.ctrl === !!evt.ctrlKey
        && s.shift === !!evt.shiftKey && s.alt === !!evt.altKey);
    return found ? found.command : null;
}

// The shortcuts the script handles in `bar` (backend.menu().menus): those of its
// commands at any depth, but not those the OS handles itself (Alt+F4)
export function shortcutsOf(bar) {
    const shortcuts = [];
    const collect = items => {
        for (const item of items) {
            if (item.items) collect(item.items);
            else if (item.shortcut && !item.shortcut.bySystem) {
                const { code, ctrl, shift, alt } = item.shortcut;
                shortcuts.push({ command: item.command, code, ctrl, shift, alt });
            }
        }
    };
    collect(bar);
    return shortcuts;
}

// The text of the shortcut of `command` in `menus` ("Ctrl+O", "⌘O"), null if none
export function shortcutTextOf(menus, command) {
    for (const item of menus) {
        const text = item.items ? shortcutTextOf(item.items, command)
            : item.command === command ? item.shortcut?.text : null;
        if (text) return text;
    }
    return null;
}

// A label with a mnemonic split around its letter: { before, key, after }, null
// if it has none
export function mnemonicParts(item) {
    const i = item.mnemonic;
    if (!(i >= 0 && i < item.label.length)) return null;
    const key = String.fromCodePoint(item.label.codePointAt(i)); // whole, if a surrogate pair
    return { before: item.label.slice(0, i), key, after: item.label.slice(i + key.length) };
}

// The index in `items` of the item whose mnemonic letter `evt` presses, -1 if
// none: with Alt alone on the bar (`bar`), the letter alone in an open menu
export function mnemonicOf(items, evt, bar) {
    if (evt.ctrlKey || evt.shiftKey || evt.metaKey || !!evt.altKey !== bar) return -1;
    if (!evt.code?.startsWith("Key")) return -1; // letters only, by the key as shortcuts
    const letter = evt.code.slice(3).toLowerCase();
    return items.findIndex(item => mnemonicParts(item)?.key.toLowerCase() === letter);
}
