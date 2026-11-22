import { $ } from "@sciter";
import { logTableLookChanged } from "log-table-view.js";
import { plusShown, failureReason } from "new-tab.js";
import {
    initialWindow, workspaceChanged, newTabRequested, newTabPressed, newTabClosed, documentPressed,
    documentOpened, openFailed, documentClosed, recentFileRemoved, shown, activeDocId
} from "window-state.js";
import { lastUsedText } from "recent-time.js";
import { clickOpensRecentFile, recentFileMenu } from "recent-file-menu.js";
import { DocumentPane } from "document-pane.js";
import { paneChanges, tabProgress } from "pane-state.js";
import { TabStrip, NEW_TAB_ID } from "tabs.js";
import { PressFocus } from "press-focus.js";
import * as backend from "backend.js";
import * as platform from "platform.js";
import { menuOpensByMouse, watchMenuInput } from "menu-gate.js";
import { applyTheme } from "theme.js";
import { showMenuBar } from "menu-bar.js";
import { shortcutTextOf } from "menu-shortcuts.js";
import { currentCatalog, pseudoLocale, setCatalog, tr, trParts } from "i18n/i18n.js";
import { translateTree } from "i18n/dom.js";
import { fileFilter, allFiles } from "file-types.js";
import { requestedLocale } from "i18n/languages.js";
import { showNotice } from "notice.js";
import { restorableFrame } from "window-frame.js";
import { defaultRows, savedSizesOf, splittersOf } from "panel-sizes.js";


let currentTheme = "light";
let currentLanguage = ""; // the setting: a BCP 47 tag, "": the language of the system
// Font size of the log tables, % of the normal one (Settings)
let tableFontSize = 100;
// Every row of the log tables one line high, the payload cut (Settings)
let singleLineRows = false;
// The payload of the log tables in the monospace font of the levels (Settings)
let monospacePayload = false;
// The state of the window (window-state.js): the documents, the New Tab, the
// file that failed to open. Changed by its events only, rendered by refreshTabs()
let win = initialWindow;
// The placeholder rendered last: { mode, version } (see shown(),
// placeholderVersion), null while a document is shown
let renderedPlaceholder = null;

document.on("ready", function () {
    console.log("Starting Log Tracy UI...");
    initApp();
});

// Save UI state while the window and DOM are still fully alive.
// Must not be done from native BEHAVIOR_DETACH: calling scripts during view teardown crashes Sciter.
platform.onWindowCloseRequest(() => {
    try {
        backend.saveAppState(getAppState());
    } catch (e) {
        console.error("saveAppState failed:", e);
    }
});

// The frame is written once the user is done with it: a Quit that can't ask
// the script any more (the Dock, logging out) or a crash keeps it
platform.onWindowFrameChanged(() => backend.windowFrameChanged());

function initApp() {
    let settings = null;
    try {
        settings = backend.settings();
    } catch (e) {
        console.error("Failed to read the settings:", e);
    }
    // Not before "ready": a window moved while the document loads is laid out
    // again by Sciter, its frame then is not the one given
    restoreWindowFrame(settings?.windowRect);
    restoreSplitters(settings);
    restoreSettings(settings);
    restoreLanguage(settings?.language || "");
    setupMenuBar();
    setupEvents();
    refreshTabs();
    for (const path of backend.startFiles()) openFile(path);
}

// The frame of the window as saved, unless none was or it is out of reach now
// (window-frame.js); the markup sizes the window otherwise
function restoreWindowFrame(saved) {
    try {
        const frame = restorableFrame(saved, platform.workAreas());
        if (frame) platform.moveWindow(frame);
    } catch (e) {
        console.error("Failed to restore the window frame:", e);
    }
}

// The size of the bottom panel as saved on exit (searchPanelHeight of the
// settings) and whether it was collapsed (bottomPanelCollapsed), for the first
// panel; the default of `splitters` if not saved. The menu labels its command by it
function restoreSplitters(settings) {
    splitters = { ...splittersOf(settings, splitters), rowsState: null };
    backend.setBottomPanelShown(splitters.collapsed !== true);
}

// The bottom panel of the documents was collapsed or expanded: the menu says
// the other (the native one retitled by the backend, the menu bar drawn again
// once the event is done: the command may come from a click on that bar, and a
// list drawn again under the pointer mid-click is a trap of Sciter, see refreshTabsSoon)
function bottomPanelChanged(shown) {
    backend.setBottomPanelShown(shown);
    if (windowMenu.menuBar) document.post(() => setupMenuBar());
}

// The theme and the font size of the settings as saved (null: none)
function restoreSettings(settings) {
    try {
        if (settings) {
            if (settings.theme) {
                setTheme(settings.theme);
            }
            if (settings.tableFontSize) setTableFontSize(settings.tableFontSize);
            setSingleLineRows(settings.singleLineRows === true);
            setMonospacePayload(settings.monospacePayload === true);
        }
    } catch (e) {
        console.error("Failed to restore settings:", e);
    }
}

// Recent files shown by the placeholder, the newest first: [{path, exists,
// opened, format: {shortName, name} if the file was opened before,
// lastUsed: ms since the Unix epoch if known}].
// The backend keeps the list: it adds a file once it is opened and saves the
// list at once. Files not found stay listed (a removed drive may come back).
function getRecentFiles() {
    try {
        return backend.recentFiles();
    } catch (e) {
        console.error("Failed to get recent files:", e);
        return [];
    }
}

function splitPath(path) {
    const cut = Math.max(path.lastIndexOf("/"), path.lastIndexOf("\\"));
    return { dir: path.slice(0, cut + 1), name: path.slice(cut + 1) };
}

// Fills the placeholder: the start screen while no document is open, the
// content of the New Tab otherwise
function renderPlaceholder() {
    const placeholder = $("#empty-placeholder");
    const title = win.newTab.active ? tr("Open a file") : tr("No file open");
    const openShortcut = shortcutTextOf(windowMenu.menus, "file.open");
    const open = <button class="inline-button" id="btn-placeholder-open">{tr("Open")}</button>;
    placeholder.content(<div class="placeholder-body">
        <div class="placeholder-title">{title}</div>
        <div class="placeholder-hint">{openShortcut
            ? trParts("{open} a log with {shortcut}", { open, shortcut: <kbd>{openShortcut}</kbd> })
            : trParts("{open} a log", { open })}
        </div>
    </div>);
    const recentFiles = getRecentFiles();
    if (!recentFiles.length) return;

    // Items one by one: append() of JSX is known to work, nested arrays aren't
    placeholder.$(".placeholder-body").append(<div class="recent-files">
        <div class="recent-files-header">{tr("Recent files")}</div>
    </div>);
    const list = placeholder.$(".recent-files");
    const now = Date.now();
    for (const { path, exists, opened, format, lastUsed } of recentFiles) {
        const { dir, name } = splitPath(path);
        // The badge of the format the file opens in; an empty one keeps the names aligned
        const badge = format
            ? <div class="recent-file-badge" title={format.name}>{format.shortName}</div>
            : <div class="recent-file-badge empty"></div>;
        const item = <div class="recent-file" path={path} title={path}>
            {badge}
            <div class="recent-file-text">
                <div class="recent-file-head">
                    <div class="recent-file-name">{name}</div>
                </div>
                <div class="recent-file-dir">{dir}</div>
            </div>
            {recentFileMenuButton({ exists, opened })}
        </div>;
        list.append(item);
        const added = list.lastElementChild;
        // Right of the name: an open file is only switched to; the others show
        // when they were worked with last, if that is known
        if (opened)
            added.$(".recent-file-head").append(<div class="recent-file-when opened">{tr("Opened")}</div>);
        else if (lastUsed)
            added.$(".recent-file-head").append(<div class="recent-file-when">{lastUsedText(lastUsed, now)}</div>);
        // Under the path: why the file can't be opened
        const failure = win.failure;
        const failed = failure && failure.path === path;
        if (failed || !exists) {
            added.classList.add(failed ? "failed" : "missing");
            const note = failed ? tr("Failed to open: {reason}", { reason: failureReason(failure.error) }) : tr("File not found");
            added.$(".recent-file-text").append(<div class="recent-file-note">{note}</div>);
        }
    }
}

// The "⋮" button at the right of a recent file, shown on hover: a dropdown of
// what can be done with the file (recent-file-menu.js)
function recentFileMenuButton(file) {
    const labels = {
        "show-in-folder": tr("Show in Folder"),
        "copy-path": tr("Copy Path"),
        "remove": tr("Remove from Recent"),
    };
    // Flat: nested arrays of JSX aren't known to work; Remove apart from the others
    const items = [];
    for (const { command, enabled } of recentFileMenu(file)) {
        if (command === "remove") items.push(<hr />);
        items.push(enabled
            ? <li command={command}>{labels[command]}</li>
            : <li command={command} disabled>{labels[command]}</li>);
    }
    // Its icon is its foreground (style.css), not a :before, which ignores visibility (sciter-quirks)
    // Out of the Tab order: it is hidden until the file is hovered
    return <button type="menu" class="recent-file-menu" tabindex="-1">
        <menu class="popup">{items}</menu>
    </button>;
}

// A command of the menu of the recent file `path`
function recentFileCommand(command, path) {
    switch (command) {
        case "show-in-folder": {
            const error = backend.showInFolder(path);
            if (error) console.error("Can't show", path, "in its folder:", error);
            break;
        }
        case "copy-path":
            platform.copyText(path);
            break;
        case "remove":
            if (backend.removeRecentFile(path)) {
                win = recentFileRemoved(win, path);
                refreshTabsSoon();
            }
            break;
    }
}

// Opens a file in a new tab. On failure the backend keeps it in the recent
// files (where it was, or on top if it is new there), and the placeholder
// (brought up if needed) shows why under it.
function openFile(path) {
    const { failure } = backend.openFile(path);
    if (!failure) return; // opened
    console.error("Can't open", path, ":", failure.error);
    win = openFailed(win, failure); // shown under the file in the recent files
    refreshTabsSoon();
}

function setTheme(theme) {
    applyTheme(theme);
    currentTheme = theme;
    // the table drawn by D reads the colors of the theme once its styles are applied
    setTimeout(() => logTableLookChanged(), 0);
    console.log("Theme set to:", theme);
}

// The language of the settings, apart from the rest of them: whatever fails
// there, the setting must be known, or closing would save the system's instead
function restoreLanguage(setting) {
    currentLanguage = setting;
    try {
        setLanguage(setting);
    } catch (e) {
        console.error("Failed to set the language:", e);
        setCatalog(null); // english, but the marked texts and titles still there
        translateTree(document);
    }
}

// The texts are in the language `setting` asks for (see i18n/languages.js)
function setLanguage(setting) {
    const { language, country } = platform.systemLanguage();
    const locale = requestedLocale(setting, language, country);
    const catalog = backend.useLanguage(locale); // the menu of the backend too
    currentLanguage = setting;
    setCatalog(locale === pseudoLocale ? { locale, messages: {} } : catalog);
    console.log("Language set to:", setting || "system", "->", currentCatalog()?.locale ?? "en");
    translateTree(document); // what is built once: the markup, the skeletons of the panels
    if (!menuSetUp) return; // starting: the rest is rendered in this language anyway
    // Rendered already: anew, in this language
    setupMenuBar();
    renderedPlaceholder = null;
    refreshTabs();
    for (const pane of panes.values()) pane.languageChanged();
}

// Scales the log tables: the font of each column keeps its proportion to the
// others (the cells set theirs in % of the table's). The columns follow: the
// auxiliary ones are as wide as their values, which stay on one line
function setTableFontSize(percent) {
    tableFontSize = percent;
    globalThis.logTableFontSize = percent; // for a table that starts later
    setTimeout(() => logTableLookChanged(), 0);
    console.log("Table font size set to:", percent);
}

// Makes every row of the log tables one line high (the payload cut at the
// edge of the table) or lets the payload wrap
function setSingleLineRows(on) {
    singleLineRows = on;
    backend.logTableSingleLine(on); // D keeps it for every table, those that start later too
}

// Sets the payload of the log tables in the monospace font of the levels or
// in the system's font: a change of the fonts, as of their size
function setMonospacePayload(on) {
    monospacePayload = on;
    globalThis.logTableMonospacePayload = on; // for a table that starts later
    setTimeout(() => logTableLookChanged(), 0);
}


// The Settings dialog, on its `section` (Appearance by default); Save applies
// all its sections at once
function openSettingsAction(section = "appearance") {
    const result = platform.showModal("settings.htm", {
        section, theme: currentTheme, tableFontSize, singleLineRows, monospacePayload,
        language: currentLanguage, languages: backend.languages(), catalog: currentCatalog(),
        columns: backend.columnSettings()
    });
    if (!result) return; // Cancel
    if (result.theme) setTheme(result.theme);
    if (typeof result.language === "string" && result.language !== currentLanguage) setLanguage(result.language);
    if (result.tableFontSize) setTableFontSize(result.tableFontSize);
    if (typeof result.singleLineRows === "boolean") setSingleLineRows(result.singleLineRows);
    if (typeof result.monospacePayload === "boolean" && result.monospacePayload !== monospacePayload)
        setMonospacePayload(result.monospacePayload);
    if (result.columnLayouts) {
        backend.setColumnLayouts(result.columnLayouts); // the log tables hear of it from the backend
    }
}

// Go to Message of the active document: its window asks for the index of a
// message, its main table goes to it (DocumentPane.goToMessage). Nothing
// without a document, or before a record is found
function goToMessageAction() {
    const pane = shownPane;
    const count = pane ? backend.documentInfo(pane.docId)?.records : 0;
    if (!count) return;
    const index = platform.showModal("go-to-message.htm", {
        theme: currentTheme, catalog: currentCatalog(), count, current: pane.currentMessageIndex(),
        jumps: pane.jumps
    });
    if (Number.isFinite(index) && pane === shownPane && !pane.destroyed) pane.goToMessage(index);
}

function openFileAction() {
    const fn = platform.chooseFileToOpen(fileFilter([[tr("Log Files"), "*.dlt;*.log;*.txt"],
        [tr("DLT Files"), "*.dlt"], [tr("Text Logs"), "*.log;*.txt"], allFiles()]));
    if (fn) {
        console.log("File selected:", fn);
        openFile(fn);
    }
}

// Called from the main menu (source/ui/app_menu.d): the native one on macOS
globalThis.onMenuCommand = function (id) {
    switch (id) {
        case "app.settings":
            openSettingsAction();
            break;
        case "file.open":
            openFileAction();
            break;
        case "app.quit": // Windows, Linux (macOS: terminate: of the native menu)
            platform.closeWindow();
            break;
        case "window.minimize":
            platform.minimizeWindow();
            break;
        case "navigation.find":
            if (shownPane) shownPane.focusSearch();
            break;
        case "navigation.goToMessage":
            goToMessageAction();
            break;
        case "view.bottomPanel":
            if (shownPane) shownPane.toggleBottomPanel();
            break;
        default:
            console.warn("Unhandled menu command:", id);
    }
};

function setupEvents() {
    document.on("click", "#btn-placeholder-open", openFileAction);

    document.on("click", ".recent-file", (evt, item) => {
        if (clickOpensRecentFile(evt.target)) openFile(item.getAttribute("path"));
    });
    document.on("click", ".recent-file-menu li[command]", (evt, li) => {
        if (li.hasAttribute("disabled")) return;
        recentFileCommand(li.getAttribute("command"), li.closest(".recent-file").getAttribute("path"));
    });

    // Context menus open by the mouse only, not by the keyboard (menu-gate.js)
    watchMenuInput(document);
    // Context menu of a document's tab (not the + one): Copy Path and Copy File Name, of its file
    document.on("contextmenu", `#tabs-container > .tab:not(#${NEW_TAB_ID})`, (evt, tab) => {
        if (!menuOpensByMouse()) return true; // the Menu key, Shift+F10: no menu
        evt.source = Element.create(<menu class="context">
            <li class="copy-tab-path" docid={tab.id}>{tr("Copy Path")}</li>
            <li class="copy-tab-name" docid={tab.id}>{tr("Copy File Name")}</li>
        </menu>);
        return true;
    });
    document.on("click", "menu.context > li.copy-tab-path, menu.context > li.copy-tab-name", (evt, item) => {
        const info = backend.documentInfo(parseInt(item.getAttribute("docid")));
        const text = item.classList.contains("copy-tab-name") ? info?.name : info?.path;
        if (text) platform.copyText(text);
    });
    document.on("click", "menu.context > li.column-settings", () => openSettingsAction("table"));
}

// The menu of the window, as the backend describes it: its shortcut texts are
// shown in hints, and on Windows and Linux it is drawn as the menu bar (macOS:
// the native menu)
let windowMenu = { menuBar: false, menus: [] };
let menuSetUp = false; // by setupMenuBar: set up again when the language changes

function setupMenuBar() {
    windowMenu = backend.menu();
    menuSetUp = true;
    if (windowMenu.menuBar) showMenuBar($("#main-menu"), windowMenu.menus, id => onMenuCommand(id));
}

// The panels of the open documents: docId -> DocumentPane (document-pane.js).
// Each keeps the views its document shows, the snapshot comes from
// getWorkspaceInfo in refreshTabs(), the changes from onMainViewChanged and
// onSearchViewChanged.
const panes = new Map();

// Where the keys go when a press on a tab shows a panel: to it once the press
// ends (press-focus.js)
const pressFocus = new PressFocus();

// The tabs (tabs.js): what pressing, closing and moving them does
const tabStrip = new TabStrip({
    pressTab: (docId) => {
        pressFocus.press();
        const before = win;
        win = documentPressed(win);
        if (docId !== activeDocId(before)) switchTab(docId); // keeps the tab elements
        else if (before.newTab.active) refreshTabs(); // the document is shown again
        else shownPane?.takeKeys(); // the press moved the keys to the strip: back when it ends
    },
    pressNewTab: () => {
        pressFocus.press();
        if (win.newTab.active) return; // shown already
        win = newTabPressed(win);
        refreshTabs();
    },
    addTab: () => {
        win = newTabRequested(win);
        refreshTabs();
    },
    closeNewTab: () => {
        win = newTabClosed(win);
        refreshTabs();
    },
    closeTab: (docId) => closeTab(docId),
    moveTab: (docId, index) => {
        backend.reorderTab(docId, index);
        refreshTabs(); // renders the tabs in the new order, without shifts
    },
    refresh: () => refreshTabs(),
    released: () => pressFocus.release(),
});

// A key while a press on a tab seems to last: its release was lost outside the
// window. The focus it asked is given now, before what the key does (Cmd+O
// opening a file must get the keys at once)
document.on("^keydown", () => { if (pressFocus.pressing) pressFocus.release(); });

// Shows the status of the document (its panel) on its tab
function showTabStatus(docId, pane) {
    tabStrip.setStatus(docId, pane.main.view?.status, pane.search.view?.status, tabProgress(pane.main.view));
}

// What a panel asks of the window
const paneHost = {
    closeTab: (docId) => closeTab(docId),
    focus: (take) => pressFocus.request(take),
    refreshTabs: () => refreshTabs(),
    theme: () => currentTheme,
    tableFontSize: () => tableFontSize,
    singleLineRows: () => singleLineRows,
    shortcutText: (command) => shortcutTextOf(windowMenu.menus, command),
    bottomPanelChanged: (shown) => bottomPanelChanged(shown),
};

function refreshTabs() {
    if (tabStrip.holdWhileDragging()) return; // rendered after the drop
    const docs = backend.workspaceInfo();
    if (!docs) return;
    win = workspaceChanged(win, docs);
    // A panel per open document
    const changes = paneChanges([...panes.keys()], docs.map(doc => doc.id));
    for (const docId of changes.remove) {
        const pane = panes.get(docId);
        if (pane === shownPane) {
            splitters = pane.hide(); // the next panel looks the same
            shownPane = null;
        }
        pane.destroy();
        panes.delete(docId);
    }
    for (const docId of changes.create)
        panes.set(docId, new DocumentPane(docId, $("#document-panes"), splitters, paneHost));
    for (const doc of docs)
        panes.get(doc.id).setViews({ mainView: doc.mainView, searchView: doc.searchView, path: doc.path },
            false); // rendered by showDocument() below

    tabStrip.render(win.docs, win.newTab, plusShown(win.docs.length));
    for (const doc of docs) showTabStatus(doc.id, panes.get(doc.id));

    showDocument();
}

// refreshTabs() once the event being handled is done, one for any number of
// calls till then. For a change made by a click on the recent files: the list
// drawn again under the pointer in the middle of a click is suspected to leave
// Sciter's next click with no target, or lost (seen once, not reproduced again:
// .ai/knowledge/sciter.md)
let refreshPosted = false;
function refreshTabsSoon() {
    if (refreshPosted) return;
    refreshPosted = true;
    document.post(() => {
        refreshPosted = false;
        refreshTabs();
    });
}

function switchTab(docId) {
    const id = parseInt(docId);
    console.log("Requesting switch to doc (int):", id);
    backend.switchTab(id);
    refreshTabs(); // reloads the table of the other document if it is ready
}

function closeTab(docId) {
    const id = parseInt(docId);
    backend.closeTab(id);
    win = documentClosed(win);
    refreshTabs();
}

// The panel shown: that of the document of the active tab, none while the
// placeholder is (no document, or the New Tab)
let shownPane = null;
// The splitter of the panel shown last: a panel shown next gets it, so the
// panels look the same (see DocumentPane.show)
let splitters = { rows: defaultRows, rowsState: null };

// Shows the panel of the active document, or the placeholder instead of all
// the panels while no document is shown
function showDocument() {
    const view = shown(win);
    const pane = view.placeholder ? null : panes.get(view.docId) ?? null;
    const empty = $("#empty-placeholder");
    empty.style.display = pane ? "none" : "flex";
    // Hidden before its container is: hide() measures the panels it shows
    if (pane !== shownPane && shownPane) splitters = shownPane.hide();
    $("#document-panes").style.display = pane ? "" : "none";
    if (pane !== shownPane) {
        shownPane = pane;
        if (pane) pane.show(splitters.rowsState ? splitters : null);
    } else if (pane) {
        pane.refresh();
    }
    if (pane) {
        renderedPlaceholder = null;
        return;
    }
    // Rendered on entering it, or when what it shows changed (placeholderVersion):
    // not on every event of a hidden document, which would rebuild the list
    // under the mouse
    const mode = view.placeholder ?? "start"; // "start" too for a document without its panel yet
    if (renderedPlaceholder?.mode !== mode || renderedPlaceholder.version !== win.placeholderVersion) {
        renderPlaceholder();
        // Keys don't go to a hidden panel; when the press on a tab that shows it ends
        pressFocus.request(() => { if (!shownPane) empty.state.focus = true; });
    }
    renderedPlaceholder = { mode, version: win.placeholderVersion };
}

// Native: the search view of a document shows something else now.
// json: { status, canCancel, <fields of the view> }, see source/ui/search_view_fsm.d
// Arrives for every document; a hidden panel renders it when shown.
globalThis.onSearchViewChanged = function (docId, json) {
    const pane = panes.get(docId);
    if (!pane) return; // tab not rendered yet: refreshTabs() will take the snapshot

    const vm = JSON.parse(json);
    if (vm.status !== "searching")
        console.log("Native: onSearchViewChanged", docId, json);
    pane.setViews({ searchView: vm });
    showTabStatus(docId, pane);
};

// Native: the main view of a document shows something else now.
// json: { status, canCancel, <fields of the view> }, see source/ui/main_view_fsm.d
// Arrives for every document; a hidden panel renders it when shown.
globalThis.onMainViewChanged = function (docId, json) {
    const pane = panes.get(docId);
    if (!pane) return; // tab not rendered yet: refreshTabs() will take the snapshot

    const vm = JSON.parse(json);
    if (vm.status !== "loadingFile" && vm.status !== "filtering")
        console.log("Native: onMainViewChanged", docId, json);
    pane.setViews({ mainView: vm });
    showTabStatus(docId, pane);
};

// Native: the files sent in the log of a document changed (backend.attachments):
// told while the file loads, as their packets come. Nothing shows them yet
// (docs/stories/file-transfer.md)
globalThis.onAttachmentsChanged = function (docId) {
};

// Native: what the File Info page shows of a document changed: its FIBEX is read,
// failed, taken or dropped. A hidden page is filled when shown
globalThis.onFileInfoChanged = function (docId) {
    panes.get(docId)?.updateFileInfo();
};

// Native: an anchor taken while a load, a filter or a search ran is in the views
// now. json: the rows it changed, { message, anchored, main, search }
globalThis.onAnchorApplied = function (docId, json) {
    panes.get(docId)?.followAnchorRows(JSON.parse(json));
};

// Native: the file of a document was truncated (a rotation by copying it and emptying it)
// and opened anew in its tab, from its start
globalThis.onDocumentReopened = function (docId) {
    console.log("Native: onDocumentReopened", docId);
    panes.get(docId)?.reopened();
};

// Native: a file was opened, in a new document or in the one that had it open
// already (then that one is the current document again)
globalThis.onDocumentOpened = function (docId) {
    console.log("Native: onDocumentOpened (int)", docId);
    win = documentOpened(win); // opened from the New Tab: takes its place
    refreshTabs(); // the table reloads when the file is loaded
};

globalThis.getAppState = function () {
    // Left out (the saved one kept) while the window isn't shown normally
    const windowRect = platform.windowFrame() ?? undefined;
    // Of the panel shown, or as the last one shown left them: written with the
    // rest, not on each move of a splitter. Not measured on a minimized window:
    // its panels have no size then (a collapsed one needs no measure)
    const measured = shownPane && !shownPane.collapsed && !platform.windowMinimized() ? shownPane.measuredHeight() : null;
    const sizes = savedSizesOf(splitters, shownPane, measured);
    return JSON.stringify({
        windowRect,
        theme: currentTheme,
        tableFontSize,
        singleLineRows,
        monospacePayload,
        language: currentLanguage,
        ...sizes
    });
}
