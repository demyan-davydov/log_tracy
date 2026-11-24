// The menu of a file of the recent list (the "⋮" button of its row): its
// commands, which of them apply to the file. The labels are the script's.
// Tests: tests/js/recent-file-menu.test.mjs.

// [{ command, enabled }] for a file { exists, opened } of backend.recentFiles()
// in the order shown; Remove is last, apart from the others, and an open file
// has none (it would be listed again at once), nor is it reopened from here: its tab has
// that. Open as is for a file that is there and was not refused by the system: the format
// is not what stops a file from opening then
// (`failureKind`: why the file failed to open, if it did: "system", "unrecognized", "unreadable")
export function recentFileMenu({ exists, opened, failureKind }) {
    const items = [
        { command: "show-in-folder", enabled: exists },
        { command: "copy-path", enabled: true },
        { command: "open-as", enabled: exists && !opened && failureKind !== "system" },
    ];
    if (!opened) items.push({ command: "remove", enabled: true });
    return items;
}

// Whether a click on a row of the recent list opens its file: not when it is on
// the row's "⋮" button or its menu. Sciter may give a click no `target` (seen
// once the list was drawn again under the pointer): where it was is unknown, it
// may have been a command of the menu, so it opens nothing.
export function clickOpensRecentFile(target) {
    return target != null && !target.closest(".recent-file-menu");
}
