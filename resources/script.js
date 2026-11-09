import { $ } from "@sciter";
import { VirtualDltTBody, VirtualMainViewTBody, VirtualSearchViewTBody, moveRowDrag, endRowDrag } from "virtual-dlt-view.js";
import { plusShown, failureReason } from "new-tab.js";
import {
    initialWindow, workspaceChanged, newTabRequested, newTabPressed, newTabClosed, documentPressed,
    documentOpened, openFailed, documentClosed, shown, activeDocId
} from "window-state.js";
import { lastUsedText } from "recent-time.js";
import { DocumentPane } from "document-pane.js";
import { paneChanges, tabProgress } from "pane-state.js";
import { TabStrip } from "tabs.js";
import * as backend from "backend.js";
import * as platform from "platform.js";
import { applyTheme } from "theme.js";
import { showMenuBar } from "menu-bar.js";
import { shortcutTextOf } from "menu-shortcuts.js";
import { currentCatalog, pseudoLocale, setCatalog, tr, trParts } from "i18n/i18n.js";
import { translateTree } from "i18n/dom.js";
import { fileFilter, allFiles } from "file-types.js";
import { requestedLocale } from "i18n/languages.js";

// The table whose context menu is open: "Copy Row" copies its selected rows
let contextList = null;

function copyRowItem() {
    return <li class="copy-row">{tr("Copy Row")}</li>;
}

// The most text Copy Row puts on the clipboard, in characters (16 MB of ASCII)
const copyLimit = 16 * 1024 * 1024;

// The context menu opens on `row`: the selection of its table is what Copy Row
// copies, a row outside it becomes the only selected one
function contextRowClicked(row) {
    const list = row.parentElement;
    const viewIndex = list.viewIndexOf?.(row);
    if (viewIndex === null || viewIndex === undefined) return;
    contextList = list;
    list.selection.contextClick(viewIndex);
    list.updateRowStates();
}

// Copies the selected rows of `list` (a log table tbody); past the limit only
// the first ones, and a notice says so
function copySelectedRows(list) {
    const { text, copied, total, truncated } = list.selectedRowsText(copyLimit);
    if (copied > 0) platform.copyText(text);
    if (truncated)
        showNotice(list, tr("Copied {copied} of {total} rows: the clipboard limit is 16 MB", { copied, total }));
}

// A notice over the bottom of `owner` that hides itself after a few seconds
function showNotice(owner, text) {
    const popup = Element.create(<popup class="notice">{text}</popup>);
    document.body.append(popup);
    owner.popup(popup, { anchorAt: 2, popupAt: 2 }); // bottom-center on bottom-center
    setTimeout(() => {
        popup.state.popup = false;
        popup.remove();
    }, 4000);
}

globalThis.VirtualDltTBody = VirtualDltTBody;
globalThis.VirtualMainViewTBody = VirtualMainViewTBody;
globalThis.VirtualSearchViewTBody = VirtualSearchViewTBody;

let currentTheme = "light";
let currentLanguage = ""; // the setting: a BCP 47 tag, "": the language of the system
// Font size of the log tables, % of the normal one (Settings)
let tableFontSize = 100;
// The state of the window (window-state.js): the documents, the New Tab, the
// file that failed to open. Changed by its events only, rendered by refreshTabs()
let win = initialWindow;
// The placeholder rendered last: { mode, version } (see shown(),
// placeholderVersion), null while a document is shown
let renderedPlaceholder = null;

document.on("ready", function () {
    console.log("Starting DLT Explorer UI...");
    initApp();
});

function stopScroll(element) {
    const currentScroll = element.scrollTop;
    element.scrollTo({ top: currentScroll, behavior: "instant" });
}

// Save UI state while the window and DOM are still fully alive.
// Must not be done from native BEHAVIOR_DETACH: calling scripts during view teardown crashes Sciter.
platform.onWindowCloseRequest(() => {
    try {
        backend.saveAppState(getAppState());
    } catch (e) {
        console.error("saveAppState failed:", e);
    }
});

platform.onWindowClose(() => {
    console.log("Closing Window...");

    // 1. Останавливаем инерционный скролл
    // Перебрасываем скролл в текущую позицию без анимации
    for (const pane of panes.values()) for (const list of pane.lists) stopList(list);

    console.log("Окно закрывается, ресурсы зачищены");
});

function stopList(logList) {
    stopScroll(logList);
    logList.style.behavior = "none";
    logList.state.disabled = true;
    logList.itemAt = null;
    logList.totalItems = 0;

    //logList.vlist.itemsTotal = 0;

    logList.onScroll = null;
    logList.onVisualChange = null;

    //logList.stopTimers();

    logList.remove(); // remove from DOM
    // 2. Если есть специфические таймеры в виртуальной таблице:
    // logList.stopTimers(); // если вы их создавали
}

function initApp() {
    let settings = null;
    try {
        settings = backend.settings();
    } catch (e) {
        console.error("Failed to read the settings:", e);
    }
    restoreSettings(settings);
    restoreLanguage(settings?.language || "");
    setupMenuBar();
    setupEvents();
    refreshTabs();
}

// The theme and the font size of the settings as saved (null: none)
function restoreSettings(settings) {
    try {
        if (settings) {
            if (settings.theme) {
                setTheme(settings.theme);
            }
            if (settings.tableFontSize) setTableFontSize(settings.tableFontSize);
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

// Opens a file in a new tab. On failure the backend keeps it in the recent
// files (where it was, or on top if it is new there), and the placeholder
// (brought up if needed) shows why under it.
function openFile(path) {
    const { failure } = backend.openFile(path);
    if (!failure) return; // opened
    console.error("Can't open", path, ":", failure.error);
    win = openFailed(win, failure); // shown under the file in the recent files
    refreshTabs();
}

function setTheme(theme) {
    applyTheme(theme);
    currentTheme = theme;
    console.log("Theme set to:", theme);
    platform.repaintWindow(); // a switch while the window is shown
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
    for (const pane of panes.values()) pane.applyFontSize(percent);
    console.log("Table font size set to:", percent);
}


// The Settings dialog, on its `section` (Appearance by default); Save applies
// all its sections at once
function openSettingsAction(section = "appearance") {
    const result = platform.showModal("settings.htm", {
        section, theme: currentTheme, tableFontSize,
        language: currentLanguage, languages: backend.languages(), catalog: currentCatalog(),
        columns: backend.columnSettings()
    });
    if (!result) return; // Cancel
    if (result.theme) setTheme(result.theme);
    if (typeof result.language === "string" && result.language !== currentLanguage) setLanguage(result.language);
    if (result.tableFontSize) setTableFontSize(result.tableFontSize);
    if (result.columnLayouts) {
        backend.setColumnLayouts(result.columnLayouts);
        for (const pane of panes.values()) pane.columnsChanged(); // as arranged now
    }
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
        default:
            console.warn("Unhandled menu command:", id);
    }
};

function setupEvents() {
    document.on("click", "#btn-placeholder-open", openFileAction);

    document.on("click", ".recent-file", (evt, item) => openFile(item.getAttribute("path")));

    // Context menu of a log row: "Copy Row" after the default items of a
    // selectable cell (Copy, Select All), alone on the other cells.
    // "contextmenu" comes before the default menu is set, so a menu given there
    // would replace it: the default one is extended on its setup instead.
    // A right click on a row outside the selection selects only that row first.
    document.on("contextmenu", "table.log-table tbody > tr", (evt, row) => {
        contextRowClicked(row);
        if (evt.target.closest("[selectable]")) return; // the default menu
        evt.source = Element.create(<menu class="context">{copyRowItem()}</menu>);
        return true;
    });
    document.on("contextmenusetup", "table.log-table tbody > tr", (evt, row) => {
        contextRowClicked(row);
        const menu = evt.source;
        const item = menu?.$("li.copy-row");
        if (item) item.textContent = tr("Copy Row"); // a menu kept: in the language now
        else if (menu) menu.append(copyRowItem());
    });
    // Context menu of a table header: Settings on its Columns section, which
    // opens on the format of the active document, the one the table shows
    document.on("contextmenu", "table.log-table > thead", evt => {
        evt.source = Element.create(<menu class="context">
            <li class="column-settings">{tr("Settings...")}</li>
        </menu>);
        return true;
    });
    document.on("click", "menu.context > li.column-settings", () => openSettingsAction("columns"));
    document.on("click", "menu.context > li.copy-row", () => {
        if (contextList) copySelectedRows(contextList);
        contextList = null;
    });
    // Cmd+C (Ctrl+C) in a table, see VirtualDltTBody.onkeydown
    document.on("copyrows", "table.log-table > tbody", (evt, list) => copySelectedRows(list));

    // Not consumed: the tab strip follows them too (tabs.js)
    document.on("mousemove", evt => { moveRowDrag(evt); });
    document.on("mouseup", () => { endRowDrag(); });

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

// The tabs (tabs.js): what pressing, closing and moving them does
const tabStrip = new TabStrip({
    pressTab: (docId) => {
        const before = win;
        win = documentPressed(win);
        if (docId !== activeDocId(before)) switchTab(docId); // keeps the tab elements
        else if (before.newTab.active) refreshTabs(); // the document is shown again
    },
    pressNewTab: () => {
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
});

// Shows the status of the document (its panel) on its tab
function showTabStatus(docId, pane) {
    tabStrip.setStatus(docId, pane.mainView?.status, pane.searchView?.status, tabProgress(pane.mainView));
}

// What a panel asks of the window
const paneHost = {
    closeTab: (docId) => closeTab(docId),
    refreshTabs: () => refreshTabs(),
    theme: () => currentTheme,
    tableFontSize: () => tableFontSize,
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
// The sizes of the splitters of the panel shown last: a panel shown next
// gets them, so the panels look the same (see DocumentPane.show)
let splitters = { cols: "200dip, *", rows: "*, 250dip", colsState: null, rowsState: null };

// Shows the panel of the active document, or the placeholder instead of all
// the panels while no document is shown
function showDocument() {
    const view = shown(win);
    const pane = view.placeholder ? null : panes.get(view.docId) ?? null;
    const empty = $("#empty-placeholder");
    empty.style.display = pane ? "none" : "flex";
    $("#document-panes").style.display = pane ? "" : "none";
    if (pane !== shownPane) {
        if (shownPane) splitters = shownPane.hide();
        shownPane = pane;
        if (pane) pane.show(splitters.colsState ? splitters : null);
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
        empty.state.focus = true; // keys don't go to a hidden panel
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

// Native: a file was opened, in a new document or in the one that had it open
// already (then that one is the current document again)
globalThis.onDocumentOpened = function (docId) {
    console.log("Native: onDocumentOpened (int)", docId);
    win = documentOpened(win); // opened from the New Tab: takes its place
    refreshTabs(); // the table reloads when the file is loaded
};

// Native: the document was closed on request of its main view (e.g. Cancel
// while the file was loading)
globalThis.onDocumentClosed = function (docId) {
    console.log("Native: onDocumentClosed", docId);
    win = documentClosed(win);
    refreshTabs();
};

globalThis.getAppState = function () {
    const windowRect = platform.windowFrame();
    const list = panes.get(activeDocId(win))?.mainList; // shown or under the New Tab
    return JSON.stringify({
        windowRect,
        theme: currentTheme,
        tableFontSize,
        language: currentLanguage,
        scrollPosition: list ? (list.state.scrollPos || 0) : 0
    });
}
