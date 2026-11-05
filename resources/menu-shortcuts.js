// The shortcuts of the menu bar the window shows on Windows and Linux: which
// command a key press is. They come with the menu from the backend
// (backend.menuBar(), shortcutsOf gives {command, code, ctrl, shift, alt},
// code as KeyboardEvent.code). Free of Sciter: tests/js.

// The command of the shortcut `evt` presses, with exactly its modifiers; null if none
export function commandOfKey(shortcuts, evt) {
    if (evt.metaKey) return null; // not a modifier of these shortcuts
    const found = shortcuts.find(s => s.code === evt.code && s.ctrl === !!evt.ctrlKey
        && s.shift === !!evt.shiftKey && s.alt === !!evt.altKey);
    return found ? found.command : null;
}

// The shortcuts the script handles in `bar` (backend.menuBar()): those of its
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
