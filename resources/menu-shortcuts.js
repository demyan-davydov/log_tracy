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

// The text of `key` with the primary modifier ("⌘C" on macOS, "Ctrl+C" elsewhere), as the
// backend writes the shortcuts of the window's menu (ui/app_menu `shortcutText`): for the
// items of the context menus, which the window's menu doesn't hold
export function primaryShortcutText(key, mac) {
    return mac ? `⌘${key}` : `Ctrl+${key}`;
}

// A label with a mnemonic split around its letter: { before, key, after }, null
// if it has none
export function mnemonicParts(item) {
    const i = item.mnemonic;
    if (!(i >= 0 && i < item.label.length)) return null;
    const key = String.fromCodePoint(item.label.codePointAt(i)); // whole, if a surrogate pair
    return { before: item.label.slice(0, i), key, after: item.label.slice(i + key.length) };
}

// The keys of the cyrillic letters on the russian layout (ЙЦУКЕН), by KeyboardEvent.code
const russianKeys = {
    й: "KeyQ", ц: "KeyW", у: "KeyE", к: "KeyR", е: "KeyT", н: "KeyY", г: "KeyU", ш: "KeyI", щ: "KeyO",
    з: "KeyP", х: "BracketLeft", ъ: "BracketRight", ф: "KeyA", ы: "KeyS", в: "KeyD", а: "KeyF",
    п: "KeyG", р: "KeyH", о: "KeyJ", л: "KeyK", д: "KeyL", ж: "Semicolon", э: "Quote", я: "KeyZ",
    ч: "KeyX", с: "KeyC", м: "KeyV", и: "KeyB", т: "KeyN", ь: "KeyM", б: "Comma", ю: "Period",
    ё: "Backquote",
};

// The key (KeyboardEvent.code) of the mnemonic letter `letter`: a latin one is its key, a
// cyrillic one that of the russian layout; null if none
function keyOfLetter(letter) {
    const lower = letter.toLowerCase();
    if (lower >= "a" && lower <= "z" && lower.length === 1) return `Key${lower.toUpperCase()}`;
    return russianKeys[lower] ?? null;
}

// The index in `items` of the item whose mnemonic letter `evt` presses, -1 if
// none: with Alt alone on the bar (`bar`), the letter alone in an open menu.
// By the key, as shortcuts: whatever layout is on (and macOS's Option, which
// types other letters); a translated label's letter by its layout (russian)
export function mnemonicOf(items, evt, bar) {
    if (evt.ctrlKey || evt.shiftKey || evt.metaKey || !!evt.altKey !== bar) return -1;
    if (!evt.code) return -1;
    return items.findIndex(item => {
        const parts = mnemonicParts(item);
        return parts !== null && keyOfLetter(parts.key) === evt.code;
    });
}
