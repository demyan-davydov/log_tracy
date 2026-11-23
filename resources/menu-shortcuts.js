// The keys of the menu of the window, as the backend describes it
// (backend.menu()): which command a key press is (shortcutsOf gives {command,
// code, ctrl, shift, alt}, code as KeyboardEvent.code), the text of a
// shortcut. Free of Sciter: tests/js.

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
