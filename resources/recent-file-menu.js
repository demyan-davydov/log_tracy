// The menu of a file of the recent list (the "⋮" button of its row): its
// commands, which of them apply to the file. The labels are the script's.
// Tests: tests/js/recent-file-menu.test.mjs.

// [{ command, enabled }] for a file { exists, opened } of backend.recentFiles()
// in the order shown; Remove is last, apart from the others, and an open file
// has none (it would be listed again at once)
export function recentFileMenu({ exists, opened }) {
    const items = [
        { command: "show-in-folder", enabled: exists },
        { command: "copy-path", enabled: true },
    ];
    if (!opened) items.push({ command: "remove", enabled: true });
    return items;
}
