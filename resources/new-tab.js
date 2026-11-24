// The New Tab of the tab strip: while documents are open, "+" opens it to show
// the start screen (recent files, Open); a file opened from it takes its
// place. It lives in the UI only, the backend knows documents only.
// State: { open, active }; the functions return a new state. Tests:
// tests/js/new-tab.test.mjs.

import { tr } from "./i18n/i18n.js";

export const noNewTab = Object.freeze({ open: false, active: false });
const newTabShown = Object.freeze({ open: true, active: true });

// "+" is there only while documents are open: without them the start screen
// already offers Open and the recent files
export function plusShown(docCount) {
    return docCount > 0;
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
// "Can't open <path> (<reason>)" (the error of the OS), the path is shown by the
// item itself; another message as it is
export function failureReason(message) {
    const match = /\(([^()]*)\)$/.exec(message);
    return match ? match[1] : message;
}

// The line under a file that failed to open (`failure` of backend.openFile: error, kind
// "system" | "unrecognized" | "unreadable", format: the name of the one asked for): what the
// user can do depends on it. Of the system (no file, no right) nothing of the format helps; no
// format knew the data: choose one; the one asked for did not read it: choose another
export function failureNote(failure) {
    const reason = failureReason(failure.error);
    if (failure.kind === "unrecognized") return tr("Format not recognized");
    if (failure.kind === "unreadable") {
        return failure.format
            ? tr("Failed to open as {format}: {reason}", { format: failure.format, reason })
            : tr("Failed to open in that format: {reason}", { reason });
    }
    return tr("Failed to open: {reason}", { reason });
}
