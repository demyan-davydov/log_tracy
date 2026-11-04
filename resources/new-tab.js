// The New Tab of the tab strip: while documents are open, "+" opens it to show
// the start screen (recent files, Open); a file opened from it takes its
// place. It lives in the UI only, the backend knows documents only.
// State: { open, active }; the functions return a new state. Tests:
// tests/js/new-tab.test.mjs.

export const noNewTab = Object.freeze({ open: false, active: false });
const newTabShown = Object.freeze({ open: true, active: true });

// What "+" does: without documents the start screen already shows the recent
// files, so it opens the file dialog; with documents it opens the new tab
export function plusAction(docCount) {
    return docCount > 0 ? "newTab" : "openDialog";
}

// Opens the new tab, or shows the one already open: never two of them
export function openNewTab() {
    return newTabShown;
}

export function activateNewTab(state) {
    return state.open ? newTabShown : state;
}

// A document tab was activated: the new tab stays in the strip, hidden
export function activateDocument(state) {
    return state.open ? Object.freeze({ open: true, active: false }) : noNewTab;
}

export function closeNewTab() {
    return noNewTab;
}

// A file was opened (or its open tab shown): from the new tab if it was shown,
// so the new tab gives way to the file
export function documentOpened(state) {
    return state.active ? noNewTab : state;
}

// A file failed to open: the reason is shown in the recent files, so the
// placeholder is brought up if a document is shown
export function fileFailed(state, docCount) {
    return showsPlaceholder(state, docCount) ? state : newTabShown;
}

// Without documents the start screen is the same as the new tab: no new tab then
export function documentsCounted(state, docCount) {
    return docCount === 0 ? noNewTab : state;
}

export function showsPlaceholder(state, docCount) {
    return docCount === 0 || state.active;
}

// The document on screen: activeDocId (the backend's current one), or null
// while the placeholder is shown
export function shownDocument(state, docCount, activeDocId) {
    return showsPlaceholder(state, docCount) ? null : activeDocId;
}

// The reason of a failed open for the line under the file: the backend reports
// "Can't open <path> (<reason>)", the path is shown by the item itself
export function failureReason(message) {
    const match = /\(([^()]*)\)$/.exec(message);
    return match ? match[1] : message;
}
