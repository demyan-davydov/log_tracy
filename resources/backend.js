// The calls of the backend: one function per xcall of MainWindow.handleEvent
// (source/ui/main_window.d), each done by AppSession (source/ui/app_session.d).
// The id of the document comes first in the calls of a document. JSON results
// come parsed, with the value of "nothing" when the backend gives none; the
// functions named ...Json give the text as it is. Messages for the user are ""
// when there is none. The backend tells the script
// what changed by calling the global functions of script.js (onDocumentOpened,
// onDocumentClosed, onMainViewChanged, onSearchViewChanged, getAppState),
// never from inside one of these calls. Kept free of Sciter but for Window:
// tests/js.

const xcall = (name, ...args) => Window.this.xcall(name, ...args);
const parsed = (text, nothing) => text ? JSON.parse(text) : nothing;
const message = text => text || "";

// ── Settings and the window ──────────────────────────────────────────────────

// The settings as saved: { theme, tableFontSize, recentFiles, ... }, null if none
export const settings = () => parsed(xcall("getSettings"), null);
// The window closes: the settings are written with the state of the script,
// the text getAppState() gives (the backend asks for the same text itself)
export const saveAppState = appStateJson => xcall("saveAppState", appStateJson);
// The menu of the window: { menuBar: whether the script draws it as its menu
// bar (Windows, Linux; macOS: the native menu), menus: [{ label, mnemonic?,
// items }] }. An item { command, label, mnemonic?, shortcut? }, { separator:
// true } or { label, mnemonic?, items }; a mnemonic is the index of its letter
// in the label; a shortcut { text, code (KeyboardEvent.code), ctrl, shift,
// alt, bySystem (the OS handles it) }
export const menu = () => parsed(xcall("getMenu"), { menuBar: false, menus: [] });
// The languages there are translations to: [{ locale, name }] (english, the
// source, is none of them)
export const languages = () => parsed(xcall("getLanguages"), []);
// The texts of the backend (the menu) are in the language `locale` (BCP 47 tag:
// "ru-KZ", the pseudo locale) from now on. Gives the catalog of translations
// it takes for the script: { locale, name, messages }, see i18n/i18n.js; null:
// none, the english source (or the pseudo locale: the script makes it itself)
export const useLanguage = locale => parsed(xcall("useLanguage", locale), null);
// The Columns section of Settings: { current, formats: [...] }, null if none
export const columnSettings = () => parsed(xcall("getColumnSettings"), null);
// The layouts the Settings dialog closed with: { format id: [{ id, visible }] }
export const setColumnLayouts = layouts => xcall("setColumnLayouts", JSON.stringify(layouts));

// ── Files and tabs ───────────────────────────────────────────────────────────

// The recent files, the newest first: [{ path, exists, opened, format, lastUsed }]
export const recentFiles = () => parsed(xcall("getRecentFiles"), []);
// Removes a file from the recent files, with its saved filters and searches:
// whether it was removed (an open file isn't)
export const removeRecentFile = path => xcall("removeRecentFile", path) === true;
// Shows the file in the file manager of the system: why it can't, "" if shown
export const showInFolder = path => message(xcall("showInFolder", path));
// Opens a file: { docId } of its document, or { failure: { path (as in the
// recent files), error } } if it can't be opened
export function openFile(path) {
    const result = xcall("openFile", path);
    if (typeof result !== "string") return { docId: result };
    try {
        return { failure: JSON.parse(result) };
    } catch (e) {
        return { failure: { path, error: result } };
    }
}
// Reopens a lost file in the same tab: why it can't be, "" if it was reopened
export const retryDocument = docId => message(xcall("retryDocument", docId));
// The open documents in the order of the tabs: [{ id, name, path, active,
// mainView, searchView }], null if the backend gives none
export const workspaceInfo = () => parsed(xcall("getWorkspaceInfo"), null);
export const switchTab = docId => xcall("switchTab", docId);
export const closeTab = docId => xcall("closeTab", docId);
export const reorderTab = (docId, index) => xcall("reorderTab", docId, index);
export const loadFibex = path => xcall("loadFibex", path);

// ── The views ────────────────────────────────────────────────────────────────

// A row of a view (see rowLayout in cell-format.js), null if there is no such
// row. Called for every row rendered: straight to xcall, no wrapper
export const mainViewItem = (docId, index) => Window.this.xcall("getMainViewItem", docId, index);
export const searchViewItem = (docId, index) => Window.this.xcall("getSearchViewItem", docId, index);
export const mainViewCount = docId => Window.this.xcall("getMainViewCount", docId);
export const searchViewCount = docId => Window.this.xcall("getSearchViewCount", docId);
// The row of the main / search view that shows message `messageIndex`, null if none does
export const mainViewPosition = (docId, messageIndex) => xcall("getMainViewPosition", docId, messageIndex);
export const searchViewPosition = (docId, messageIndex) => xcall("getSearchViewPosition", docId, messageIndex);
// The columns the tables of the document show, as JSON text ("[]": none): the
// text tells whether they changed
export const tableColumnsJson = docId => xcall("getTableColumns", docId) || "[]";
// All the columns of the document (the rules may test any of them)
export const columns = docId => parsed(xcall("getColumns", docId), []);
// Sets or clears the anchor of a message: true if it changed
export const setAnchor = (docId, messageIndex, value) => xcall("setAnchor", docId, messageIndex, value);
export const cancelMainView = docId => xcall("cancelMainView", docId);
export const cancelSearchView = docId => xcall("cancelSearchView", docId);

// ── Search ───────────────────────────────────────────────────────────────────

// Searches the chips [{ text, isRegex, matchCase }]; none clear the search.
// Returns: the error, "" if the search started
export const startChipSearch = (docId, chips) => message(xcall("startChipSearch", docId, JSON.stringify(chips)));
// The queries searched in the file, the latest first: [[chips]]
export const searchHistory = docId => parsed(xcall("getSearchHistory", docId), []);
// {name, path, format, bytes, records} of the document for its File Info page, null if it isn't open
export const documentInfo = docId => parsed(xcall("getDocumentInfo", docId), null);
// What is wrong with a regular expression, "" if nothing
export const checkRegex = (pattern, matchCase) => message(xcall("checkRegex", pattern, matchCase));

// ── Filters ──────────────────────────────────────────────────────────────────
// The commands return a message for the user (an error, what was lost), "" if none

// The filter sets of the document: { canFilter, canDlf, sets: [...] }, null if none
export const filters = docId => parsed(xcall("getFilters", docId), null);
// The fields of a rule of a set (rule -1: a new one), null if there is no such rule
export const filterRule = (docId, set, rule) => parsed(xcall("getFilterRule", docId, set, rule), null);
// What is wrong with a rule being edited: { error, conditions: [...] } as JSON
// text, parsed by the window of the rule editor
export const checkFilterRuleJson = (docId, rule) => xcall("checkFilterRule", docId, JSON.stringify(rule));
export const loadFilterFile = (docId, path) => message(xcall("loadFilterFile", docId, path));
export const newFilterSet = docId => message(xcall("newFilterSet", docId));
export const exportFilterSet = (docId, set, path) => message(xcall("exportFilterSet", docId, set, path));
export const removeFilterSet = (docId, set) => message(xcall("removeFilterSet", docId, set));
export const enableFilterSet = (docId, set, enabled) => message(xcall("enableFilterSet", docId, set, enabled));
export const addFilterRule = (docId, set, rule) => message(xcall("addFilterRule", docId, set, JSON.stringify(rule)));
export const updateFilterRule = (docId, set, index, rule) =>
    message(xcall("updateFilterRule", docId, set, index, JSON.stringify(rule)));
export const enableFilterRule = (docId, set, index, enabled) =>
    message(xcall("enableFilterRule", docId, set, index, enabled));
export const removeFilterRule = (docId, set, index) => message(xcall("removeFilterRule", docId, set, index));
