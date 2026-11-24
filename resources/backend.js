// The calls of the backend: one function per xcall of MainWindow.handleEvent
// (source/ui/main_window.d), each done by AppSession (source/ui/app_session.d), but those of the
// log tables, which MainWindow does itself for now (.ai/knowledge/architecture.md, Script ↔ Backend).
// The id of the document comes first in the calls of a document. JSON results
// come parsed, with the value of "nothing" when the backend gives none; the
// functions named ...Json give the text as it is. Messages for the user are ""
// when there is none. The backend tells the script
// what changed by calling the global functions of script.js (onDocumentOpened,
// onMainViewChanged, onSearchViewChanged, onAnchorApplied, onAttachmentsChanged,
// onFileInfoChanged, onDocumentReopened, getAppState),
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
// The user moved or resized the window: the settings are written soon, with
// the frame of getAppState()
export const windowFrameChanged = () => xcall("windowFrameChanged");
// The menu of the window: { drawn: whether the script draws it (Windows, Linux;
// macOS: the native menu), platform: "mac" | "windows" | "linux", the interface
// of which platform, menus: [item] }. An item { command, label, shortcut? },
// { separator: true } or { label, items } (a submenu: macOS only, the list of
// Windows and Linux is flat); a shortcut { text, code
// (KeyboardEvent.code), ctrl, shift, alt, bySystem (the OS handles it) }
export const menu = () => parsed(xcall("getMenu"), { drawn: false, platform: "mac", menus: [] });
// The bottom panel of the documents is shown (true) or collapsed: the menu
// labels its command by it (the native menu of macOS is retitled; menu() gives
// the new labels)
export const setBottomPanelShown = shown => xcall("setBottomPanelShown", shown);
// The languages there are translations to: [{ locale, name }] (english, the
// source, is none of them)
export const languages = () => parsed(xcall("getLanguages"), []);
// The paths of the files to open at start (OPEN_AT_START, for a look at the app
// with a log): [path]
export const startFiles = () => parsed(xcall("getStartFiles"), []);
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
// Opens a file in a new tab, as it was last time or detected: { docId } of its document, or
// { failure: { path (as in the recent files), error, kind ("system", "unrecognized",
// "unreadable"), format (the name of the one picked, when there was one) } } if it can't be opened
export const openFile = path => opened(path, xcall("openFile", path));
// The same in the format `formatId` the user picked (formats()), detected again if "" (not as it
// was last time)
export const openFileAs = (path, formatId) => opened(path, xcall("openFileAs", path, formatId));
function opened(path, result) {
    if (typeof result !== "string") return { docId: result };
    try {
        return { failure: JSON.parse(result) };
    } catch (e) {
        return { failure: { path, error: result } };
    }
}
// Reopens a lost file in the same tab: why it can't be, "" if it was reopened
export const retryDocument = docId => message(xcall("retryDocument", docId));
// Opens the file of a document anew in its tab in the format `formatId` (formats()), detected
// again if "": why it can't be, "" if it was (the tab is then reset: DocumentPane.reopened)
export const reopenAs = (docId, formatId) => message(xcall("reopenAs", docId, formatId));
// The formats a log can be opened as by hand: [{ id, name, shortName }]
export const formats = () => parsed(xcall("getFormats"), []);
// The open documents in the order of the tabs: [{ id, name, path, active,
// mainView, searchView }], null if the backend gives none
export const workspaceInfo = () => parsed(xcall("getWorkspaceInfo"), null);
export const switchTab = docId => xcall("switchTab", docId);
export const closeTab = docId => xcall("closeTab", docId);
export const reorderTab = (docId, index) => xcall("reorderTab", docId, index);

// The log table, drawn by D (log-table-view.js, ui/log_table_behavior.d): a call to the table of the number its element carries
// (the attribute `table`), null if there is none (not attached yet, or no more)
export const logTableCall = (tableId, method, ...args) => Window.this.xcall("logTableCall", tableId, method, ...args);
// What is the application's, not a table's: the look of every table, and whether the rows of all of them are one line high
export const logTableSetLook = json => Window.this.xcall("logTableSetLook", json);
export const logTableMinWidthNames = () => parsed(Window.this.xcall("logTableMinWidthNames"), []);
export const logTableSingleLine = on => Window.this.xcall("logTableSingleLine", on);

// ── The views ────────────────────────────────────────────────────────────────

// The row of the main / search view that shows message `messageIndex`, null if none does
export const mainViewPosition = (docId, messageIndex) => xcall("getMainViewPosition", docId, messageIndex);
export const searchViewPosition = (docId, messageIndex) => xcall("getSearchViewPosition", docId, messageIndex);
// The row of the main view Go to Message lands on for message `messageIndex`: its own,
// or of the first message after it shown, else the last row; null for an empty view
export const mainViewNearestPosition = (docId, messageIndex) => xcall("getMainViewNearestPosition", docId, messageIndex);
// All the columns of the document (the rules may test any of them)
export const columns = docId => parsed(xcall("getColumns", docId), []);
// Sets or clears the anchor of a message: { refused, max, full, pending, rows },
// refused: "limit" | "unavailable" (nothing changed then), null if done; max: the
// anchor limit; full: no room for another anchor (the text: anchorRefusalText in
// pane-commands.js); pending: taken while a pass runs, onAnchorApplied tells its
// rows later; rows: the rows it changed now, { message, anchored, main, search },
// null if refused, pending or no row came or went
export const setAnchor = (docId, messageIndex, value) =>
    parsed(xcall("setAnchor", docId, messageIndex, value), { refused: null, max: 0, full: false, pending: false, rows: null });
export const cancelMainView = docId => xcall("cancelMainView", docId);
export const cancelSearchView = docId => xcall("cancelSearchView", docId);

// ── Search ───────────────────────────────────────────────────────────────────

// Searches the chips [{ text, isRegex, matchCase }]; none clear the search.
// Returns: the error, "" if the search started
export const startChipSearch = (docId, chips) => message(xcall("startChipSearch", docId, JSON.stringify(chips)));
// The queries searched in the file, the latest first: [[chips]]
export const searchHistory = docId => parsed(xcall("getSearchHistory", docId), []);
// Removes a query [chips] from the history of the file: whether it was there
export const removeSearch = (docId, chips) => xcall("removeSearch", docId, JSON.stringify(chips)) === true;
// {name, path, format, formatId, bytes, records, descriptions} of the document for its File Info page,
// null if it isn't open. descriptions: null for a log that takes none (no FIBEX row), else
// {taken, folder, choice, read, reading, problem} (source/ui/app_session.d, documentInfoJson)
export const documentInfo = docId => parsed(xcall("getDocumentInfo", docId), null);
// Reads the FIBEX file or folder at `path` for the document in the background; how the read
// goes is told by onFileInfoChanged. Returns: why it can't be, "" if it was asked
export const loadDescriptions = (docId, path) => message(xcall("loadDescriptions", docId, path));
// Drops the FIBEX of the document. Returns: why it can't be, "" if it was dropped
export const unloadDescriptions = docId => message(xcall("unloadDescriptions", docId));
// What is wrong with a regular expression, "" if nothing
export const checkRegex = (pattern, matchCase) => message(xcall("checkRegex", pattern, matchCase));

// ── Files sent in the log ────────────────────────────────────────────────────

// The files sent in the log of the document so far (onAttachmentsChanged tells a
// change): [{ id, name, date, size, packets, received, inTurn, state ("sending",
// "complete", "incomplete", "failed"), record (the message that opened it),
// serial (null if unknown), error, osError }]
export const attachments = docId => parsed(xcall("getAttachments", docId), []);
// Saves the file `id` to `path`: its bytes from its first packet in turn.
// Returns: the error, "" if it was saved
export const saveAttachment = (docId, id, path) => message(xcall("saveAttachment", docId, id, path));

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
export const renameFilterSet = (docId, set, name) => message(xcall("renameFilterSet", docId, set, name));
export const addFilterRule = (docId, set, rule) => message(xcall("addFilterRule", docId, set, JSON.stringify(rule)));
export const updateFilterRule = (docId, set, index, rule) =>
    message(xcall("updateFilterRule", docId, set, index, JSON.stringify(rule)));
export const enableFilterRule = (docId, set, index, enabled) =>
    message(xcall("enableFilterRule", docId, set, index, enabled));
export const removeFilterRule = (docId, set, index) => message(xcall("removeFilterRule", docId, set, index));
