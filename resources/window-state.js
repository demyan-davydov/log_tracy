// The state of the window: the open documents as the backend reports them
// (backend.workspaceInfo), the New Tab (new-tab.js), the file that failed to
// open last, and from them what is on screen. Each event is a function that
// returns the new state; script.js renders the state. Kept free of Sciter:
// tests/js/window-state.test.mjs.
//
// State: {
//   docs - [{ id, name, path, active, mainView, searchView }] in the order of the tabs
//   newTab - { open, active }
//   failure - { path (as in the recent files), error } of the file that failed
//             to open last, shown under it in the placeholder; null if none
//   placeholderVersion - grows when what the placeholder shows changed (it is
//             rendered again then, not on every change of the documents: that
//             would rebuild the recent files under the mouse)
// }
import {
    noNewTab, openNewTab, activateNewTab, activateDocument, closeNewTab,
    documentOpened as newTabOnOpened, fileFailed, documentsCounted, shownDocument
} from "./new-tab.js";

export const initialWindow = Object.freeze({ docs: [], newTab: noNewTab, failure: null, placeholderVersion: 0 });

const next = (state, changes) => Object.freeze({ ...state, ...changes });
const renderPlaceholder = state => state.placeholderVersion + 1;

// The documents as the backend reports them now
export function workspaceChanged(state, docs) {
    return next(state, { docs, newTab: documentsCounted(state.newTab, docs.length) });
}

// "+": the New Tab, a fresh start
export function newTabRequested(state) {
    return next(state, { newTab: openNewTab(), failure: null, placeholderVersion: renderPlaceholder(state) });
}

// The tab of the New Tab was pressed
export function newTabPressed(state) {
    return next(state, { newTab: activateNewTab(state.newTab) });
}

export function newTabClosed(state) {
    return next(state, { newTab: closeNewTab() });
}

// The tab of a document was pressed: the New Tab stays, hidden. The document
// itself becomes active in the backend (the caller asks it if activeDocId isn't
// it), and so here with the next workspaceChanged
export function documentPressed(state) {
    return next(state, { newTab: activateDocument(state.newTab) });
}

// A file was opened, or its open tab shown: from the New Tab if it was shown.
// A failure shown in the placeholder goes with it.
export function documentOpened(state) {
    return next(state, {
        newTab: newTabOnOpened(state.newTab), failure: null,
        placeholderVersion: state.failure ? renderPlaceholder(state) : state.placeholderVersion
    });
}

// A file failed to open: its reason is shown in the recent files, the
// placeholder brought up if a document is shown
export function openFailed(state, failure) {
    return next(state, {
        newTab: fileFailed(state.newTab, state.docs.length), failure,
        placeholderVersion: renderPlaceholder(state)
    });
}

// A document was closed: the recent files show when its file was used now,
// not "Opened"
export function documentClosed(state) {
    return next(state, { placeholderVersion: renderPlaceholder(state) });
}

// The active document of the backend; null if none
export function activeDocId(state) {
    return state.docs.find(doc => doc.active)?.id ?? null;
}

// What is on screen: { docId } of a document, or { placeholder: "start" |
// "newTab" } (the start screen without documents, the New Tab with them)
export function shown(state) {
    const docId = shownDocument(state.newTab, state.docs.length, activeDocId(state));
    if (docId !== null) return { docId };
    return { placeholder: state.newTab.active ? "newTab" : "start" };
}
