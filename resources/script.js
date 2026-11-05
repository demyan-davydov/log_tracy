import { $, $$ } from "@sciter";
import { VirtualDltTBody, VirtualMainViewTBody, VirtualSearchViewTBody, moveRowDrag, endRowDrag } from "virtual-dlt-view.js";
import {
    noNewTab, plusShown, openNewTab, activateNewTab, activateDocument,
    closeNewTab, documentOpened, documentsCounted, showsPlaceholder,
    shownDocument, fileFailed, failureReason
} from "new-tab.js";
import { lastUsedText } from "recent-time.js";
import { DocumentPane } from "document-pane.js";
import { paneChanges } from "pane-state.js";
import { clampShift, dragTarget, settleShift } from "drag-order.js";

// The table whose context menu is open: "Copy Row" copies its selected rows
let contextList = null;

function copyRowItem() {
    return <li class="copy-row">Copy Row</li>;
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
    if (copied > 0) Clipboard.writeText(text);
    if (truncated)
        showNotice(list, `Copied ${copied} of ${total} rows: the clipboard limit is 16 MB`);
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
// Font size of the log tables, % of the normal one (Settings)
let tableFontSize = 100;
// The placeholder rendered last: "start", "newTab", null while a document is shown
let shownPlaceholder = null;

document.on("ready", function () {
    console.log("Starting DLT Explorer UI...");
    initApp();

    console.log(Window.this.frameType, Window.this.blurBehind)
});

function stopScroll(element) {
    const currentScroll = element.scrollTop;
    element.scrollTo({ top: currentScroll, behavior: "instant" });
}

// Save UI state while the window and DOM are still fully alive.
// Must not be done from native BEHAVIOR_DETACH: calling scripts during view teardown crashes Sciter.
Window.this.on("closerequest", () => {
    try {
        Window.this.xcall("saveAppState", getAppState());
    } catch (e) {
        console.error("saveAppState failed:", e);
    }
});

Window.this.on("close", (evt) => {
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
    restoreSettings();
    setupEvents();
    refreshTabs();
}

function restoreSettings() {
    try {
        const settingsStr = Window.this.xcall("getSettings");
        if (settingsStr) {
            const settings = JSON.parse(settingsStr);
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
        return JSON.parse(Window.this.xcall("getRecentFiles") || "[]");
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
    const title = newTab.active ? "Open a file" : "No file open";
    placeholder.content(<div class="placeholder-body">
        <div class="placeholder-title">{title}</div>
        <div class="placeholder-hint">
            <button class="inline-button" id="btn-placeholder-open">Open</button> a log with <kbd>⌘O</kbd>
        </div>
    </div>);
    const recentFiles = getRecentFiles();
    if (!recentFiles.length) return;

    // Items one by one: append() of JSX is known to work, nested arrays aren't
    placeholder.$(".placeholder-body").append(<div class="recent-files">
        <div class="recent-files-header">Recent files</div>
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
            added.$(".recent-file-head").append(<div class="recent-file-when opened">Opened</div>);
        else if (lastUsed)
            added.$(".recent-file-head").append(<div class="recent-file-when">{lastUsedText(lastUsed, now)}</div>);
        // Under the path: why the file can't be opened
        const failed = openFailure && openFailure.path === path;
        if (failed || !exists) {
            added.classList.add(failed ? "failed" : "missing");
            const note = failed ? `Failed to open: ${failureReason(openFailure.error)}` : "File not found";
            added.$(".recent-file-text").append(<div class="recent-file-note">{note}</div>);
        }
    }
}

// The file that failed to open last: { path (as in the recent list), error },
// shown under its item in the recent files until a file opens or "+" is pressed
let openFailure = null;

// Opens a file in a new tab. On failure the backend keeps it in the recent
// files (where it was, or on top if it is new there), and the placeholder
// (brought up if needed) shows why under it.
function openFile(path) {
    const result = Window.this.xcall("openFile", path);
    if (typeof result !== "string") return; // the id of the document: opened
    try {
        openFailure = JSON.parse(result);
    } catch (e) {
        openFailure = { path, error: result };
    }
    console.error("Can't open", path, ":", openFailure.error);
    newTab = fileFailed(newTab, docCount);
    shownPlaceholder = null; // render it again, with the failure
    refreshTabs();
}

function setTheme(theme) {
    const oldStyle = $("#theme-style");
    if (oldStyle) oldStyle.remove();

    const newStyle = document.createElement("style");
    newStyle.id = "theme-style";
    newStyle.setAttribute("src", theme === "dark" ? "theme-dark.css" : "theme-light.css");
    document.head.prepend(newStyle);

    currentTheme = theme;
    console.log("Theme set to:", theme);
    Window.this.update();
}

// Scales the log tables: the font of each column keeps its proportion to the
// others (the cells set theirs in % of the table's). The column widths stay as
// they are: they are minimums, the auxiliary columns keep their values on one line
function setTableFontSize(percent) {
    tableFontSize = percent;
    for (const pane of panes.values()) pane.applyFontSize(percent);
    console.log("Table font size set to:", percent);
}


// The Settings dialog; Save applies all its sections at once
function openSettingsAction() {
    const result = Window.this.modal({
        url: "settings.htm",
        alignment: "center",
        parameters: {
            theme: currentTheme, tableFontSize,
            columns: JSON.parse(Window.this.xcall("getColumnSettings") || "null")
        }
    });
    if (!result) return; // Cancel
    if (result.theme) setTheme(result.theme);
    if (result.tableFontSize) setTableFontSize(result.tableFontSize);
    if (result.columnLayouts) {
        Window.this.xcall("setColumnLayouts", JSON.stringify(result.columnLayouts));
        for (const pane of panes.values()) pane.columnsChanged(); // as arranged now
    }
}

function openFileAction() {
    const fn = Window.this.selectFile({
        mode: "open",
        filter: "Log Files (*.dlt;*.log;*.txt)|*.dlt;*.log;*.txt|DLT Files (*.dlt)|*.dlt|Text Logs (*.log;*.txt)|*.log;*.txt|All Files (*.*)|*.*"
    });
    if (fn) {
        console.log("File selected:", fn);
        openFile(fn);
    }
}

// Called from the native (macOS) menu: see source/ui/main_menu_loader.d
globalThis.onMenuCommand = function (id) {
    switch (id) {
        case "app.settings":
            openSettingsAction();
            break;
        case "file.open":
            openFileAction();
            break;
        default:
            console.warn("Unhandled menu command:", id);
    }
};

function setupEvents() {
    document.on("click", "#btn-add-tab", () => {
        newTab = openNewTab();
        openFailure = null; // a fresh start
        shownPlaceholder = null; // render it again, without the failure
        refreshTabs();
    });
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
        if (menu && !menu.$("li.copy-row")) menu.append(copyRowItem());
    });
    document.on("click", "menu.context > li.copy-row", () => {
        if (contextList) copySelectedRows(contextList);
        contextList = null;
    });
    // Cmd+C (Ctrl+C) in a table, see VirtualDltTBody.onkeydown
    document.on("copyrows", "table.log-table > tbody", (evt, list) => copySelectedRows(list));

    // A tab is activated on mousedown (as in browsers) and can then be dragged;
    // click only handles the close button
    document.on("click", ".tab .tab-close", function (evt, close) {
        if (close.parentElement.id === NEW_TAB_ID) {
            newTab = closeNewTab();
            refreshTabs();
        } else {
            closeTab(close.parentElement.id);
        }
        return true;
    });

    document.on("mousedown", ".tab", function (evt, tab) {
        // Only the left button activates and drags: the right (2) and middle
        // (4) bits are the same in DOM and in Sciter (PROP_/MIDDLE_MOUSE_BUTTON)
        if (evt.buttons & 6) return;
        if (evt.target.classList.contains("tab-close")) return;
        if (tabDrag?.settling) return; // the previous drop is still settling
        if (tabDrag) finishTabDrag(false); // released outside the window: the press is dropped
        if (tab.id === NEW_TAB_ID) { // stays the last one: not dragged
            if (newTab.active) return true; // shown already
            newTab = activateNewTab(newTab);
            refreshTabs();
            return true;
        }
        const docId = parseInt(tab.id);
        const leavingNewTab = newTab.active;
        newTab = activateDocument(newTab);
        if (docId !== activeDocId) switchTab(docId); // keeps the tab elements
        else if (leavingNewTab) refreshTabs(); // the document is shown again
        beginTabDrag(tab, evt.clientX);
        return true; // no text selection
    });

    document.on("mousemove", function (evt) {
        if (tabDrag) moveTabDrag(evt.clientX);
        moveRowDrag(evt);
    });

    document.on("mouseup", function (evt) {
        if (tabDrag) endTabDrag();
        endRowDrag();
    });

    document.on("keydown", function (evt) {
        const modifier = evt.metaKey || evt.ctrlKey;
        if (modifier && (evt.code === "KeyO" || evt.code === "KeyF")) {
            openFileAction();
            return true;
        }
    });
}

// The panels of the open documents: docId -> DocumentPane (document-pane.js).
// Each keeps the views its document shows, the snapshot comes from
// getWorkspaceInfo in refreshTabs(), the changes from onMainViewChanged and
// onSearchViewChanged.
const panes = new Map();
let activeDocId = null; // active in the backend; hidden while the New Tab is shown
let docCount = 0;

// The New Tab (see new-tab.js): the last tab of the strip while open
const NEW_TAB_ID = "new-tab";
let newTab = noNewTab;

// The tabs of the documents, without the New Tab
const DOC_TABS = `#tabs-container > .tab:not(#${NEW_TAB_ID})`;

function findTab(docId) {
    return $(`#tabs-container > .tab[id="${docId}"]`);
}

// Exposes the status of the document (its panel) on the tab element for CSS:
// main-status, search-status
function applyTabStatus(tab, pane) {
    tab.setAttribute("main-status", pane.mainView ? pane.mainView.status : "");
    tab.setAttribute("search-status", pane.searchView ? pane.searchView.status : "");
}

// What a panel asks of the window
const paneHost = {
    closeTab: (docId) => closeTab(docId),
    refreshTabs: () => refreshTabs(),
    theme: () => currentTheme,
    tableFontSize: () => tableFontSize,
};

function refreshTabs() {
    if (tabDrag) { // the tabs are being dragged: render them after the drop
        tabDrag.refreshPending = true;
        return;
    }
    const info = Window.this.xcall("getWorkspaceInfo");
    if (!info) return;
    const docs = JSON.parse(info);
    const container = $("#tabs-container");
    docCount = docs.length;
    newTab = documentsCounted(newTab, docCount);

    activeDocId = docs.find(doc => doc.active)?.id ?? null;
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

    // Same documents in the same order (e.g. another tab was activated): the
    // elements are kept, so a tab being pressed or dragged stays in the DOM
    let tabs = [...$$(DOC_TABS)];
    const sameTabs = tabs.length === docs.length
        && tabs.every((tab, i) => parseInt(tab.id) === docs[i].id);
    if (!sameTabs) {
        // The + button is kept, the tabs follow it
        for (const tab of tabs) tab.remove();
        const newTabElement = $(`#${NEW_TAB_ID}`); // kept, after the documents
        for (const doc of docs) {
            container.append(<div class="tab" id={doc.id}>
                <span class="tab-sep"></span>
                <span class="tab-name"></span>
                <span class="tab-close">×</span>
            </div>);
            if (newTabElement) container.insertBefore(container.lastElementChild, newTabElement);
        }
        tabs = [...$$(DOC_TABS)];
    }
    $("#btn-add-tab").style.display = plusShown(docs.length) ? "" : "none";
    docs.forEach((doc, i) => {
        const tab = tabs[i];
        if (doc.active && !newTab.active) tab.classList.add("active");
        else tab.classList.remove("active");
        tab.$(".tab-name").textContent = doc.name;
        applyTabStatus(tab, panes.get(doc.id));
    });
    renderNewTab();

    showDocument();
}


// The New Tab element: after all the document tabs while open
function renderNewTab() {
    const container = $("#tabs-container");
    let tab = $(`#${NEW_TAB_ID}`);
    if (!newTab.open) {
        if (tab) tab.remove();
        return;
    }
    if (!tab) {
        container.append(<div class="tab" id={NEW_TAB_ID}>
            <span class="tab-sep"></span>
            <span class="tab-name">New Tab</span>
            <span class="tab-close">×</span>
        </div>);
        tab = container.lastElementChild;
    }
    if (newTab.active) tab.classList.add("active");
    else tab.classList.remove("active");
}

function switchTab(docId) {
    const id = parseInt(docId);
    console.log("Requesting switch to doc (int):", id);
    Window.this.xcall("switchTab", id);
    refreshTabs(); // reloads the table of the other document if it is ready
}

function closeTab(docId) {
    const id = parseInt(docId);
    Window.this.xcall("closeTab", id);
    shownPlaceholder = null; // the recent files show when the file was used, not "Opened"
    refreshTabs();
}

// Chrome-like dragging of a tab: the tab follows the mouse along the strip,
// the tabs it passes slide aside to free its new place, a marker shows where
// it will land; on drop it slides into that place and the workspace order is
// updated. No tooltips while a tab is held: they would cover the strip
// (see TabTooltip).
// tabDrag: { tab, tabs, rects, spans, from, to, startX, dx, sep,
//            markerOrigin, active, settling, refreshPending }, null when no
//            tab is held.
const TAB_DRAG_THRESHOLD = 4; // px of mouse movement before a press becomes a drag
const TAB_SETTLE_MS = 160;    // a bit longer than the .settling transition
let tabDrag = null;

function setTabShift(tab, dx) {
    tab.style.transform = dx ? `translate(${dx}px, 0)` : "";
}

// Tooltip of the tab strip: the full name Sciter shows by itself for a name
// cut by text-overflow (tabs have no title). style.css gives it this
// prototype: one that is about to appear while a tab is held is closed at
// once, the shown ones are tracked to close them when a tab is pressed (they
// can't be found with a selector).
const shownTabTooltips = new Set();

globalThis.TabTooltip = class extends Element {
    componentDidMount() {
        if (tabDrag) this.state.popup = false;
        else shownTabTooltips.add(this);
    }
    componentWillUnmount() {
        shownTabTooltips.delete(this);
    }
};

function closeTabTooltips() {
    for (const popup of [...shownTabTooltips]) {
        shownTabTooltips.delete(popup);
        try { popup.state.popup = false; } catch (e) { }
    }
}

// The marker is on the edge of the place the tab will land on, between it and
// the tab it was moved past; hidden while the tab would stay where it was.
// It takes exactly the rectangle of a separator on that edge (d.sep), so it
// covers the separator there; its origin is calibrated on the first show.
function showTabDropMarker(d) {
    const marker = $("#tab-drop-marker");
    if (!marker) return;
    if (d.to === d.from) {
        marker.style.display = "none";
        return;
    }
    marker.style.display = "block";
    if (!d.markerOrigin) {
        marker.style.left = "0px";
        marker.style.top = "0px";
        const r = marker.getBoundingClientRect();
        d.markerOrigin = { left: r.left, top: r.top };
    }
    const edge = d.to > d.from ? d.rects[d.to].right : d.rects[d.to].left;
    marker.style.left = `${edge + d.sep.offset - d.markerOrigin.left}px`;
    marker.style.top = `${d.sep.top - d.markerOrigin.top}px`;
    marker.style.width = `${d.sep.width}px`;
    marker.style.height = `${d.sep.height}px`;
}

// Rectangle of a separator relative to the left edge of its tab
function measureTabSeparator(tab, tabRect) {
    const r = tab.$(".tab-sep").getBoundingClientRect();
    return { offset: r.left - tabRect.left, top: r.top, width: r.right - r.left, height: r.bottom - r.top };
}

function beginTabDrag(tab, clientX) {
    const tabs = [...$$(DOC_TABS)];
    const rects = tabs.map(t => t.getBoundingClientRect());
    const from = tabs.indexOf(tab);
    if (from < 0) return;
    tabDrag = {
        tab, tabs, rects, from, to: from,
        spans: rects.map(r => ({ start: r.left, end: r.right })), // see drag-order.js
        startX: clientX, dx: 0,
        sep: measureTabSeparator(tabs[0], rects[0]), markerOrigin: null,
        active: false, settling: false, refreshPending: false
    };
    closeTabTooltips();
}

function moveTabDrag(clientX) {
    const d = tabDrag;
    if (d.settling) return;
    const dx = clientX - d.startX;
    if (!d.active) {
        if (Math.abs(dx) < TAB_DRAG_THRESHOLD) return;
        d.active = true;
        closeTabTooltips();
        d.tab.classList.add("dragging");
        for (const t of d.tabs) if (t !== d.tab) t.classList.add("shifting");
        $("#tabs-container").append(<div id="tab-drop-marker"></div>);
    }
    d.dx = clampShift(d.spans, d.from, dx); // the tab stays within the strip
    setTabShift(d.tab, d.dx);

    // The tab takes the place of every tab whose middle its leading edge has passed
    const { to, shifts } = dragTarget(d.spans, d.from, d.dx);
    d.tabs.forEach((t, i) => { if (i !== d.from) setTabShift(t, shifts[i]); });
    d.to = to;
    showTabDropMarker(d);
}

function endTabDrag() {
    const d = tabDrag;
    if (d.settling) return;
    if (!d.active) { // a plain click
        finishTabDrag(false);
        return;
    }
    // Slide into the free place, then commit the new order
    d.settling = true;
    d.tab.classList.add("settling");
    setTabShift(d.tab, settleShift(d.spans, d.from, d.to));
    setTimeout(() => finishTabDrag(d.to !== d.from), TAB_SETTLE_MS);
}

function finishTabDrag(moved) {
    const d = tabDrag;
    tabDrag = null;
    const marker = $("#tab-drop-marker");
    if (marker) marker.remove();
    if (moved) {
        console.log("Tab", d.tab.id, "moved from", d.from, "to", d.to);
        Window.this.xcall("reorderTab", parseInt(d.tab.id), d.to);
        refreshTabs(); // renders the tabs in the new order, without shifts
        return;
    }
    for (const t of d.tabs) {
        for (const cls of ["dragging", "shifting", "settling"]) t.classList.remove(cls);
        setTabShift(t, 0);
    }
    if (d.refreshPending) refreshTabs();
}

// The panel shown: that of the document of the active tab, none while the
// placeholder is (no document, or the New Tab)
let shownPane = null;
// The sizes of the splitters of the panel shown last: a panel shown next
// gets them, so the panels look the same (see DocumentPane.show)
let splitters = { cols: "200px, *", rows: "*, 250dip", colsState: null, rowsState: null };

// Shows the panel of the active document, or the placeholder instead of all
// the panels while no document is shown
function showDocument() {
    const docId = shownDocument(newTab, docCount, activeDocId);
    const pane = docId === null ? null : panes.get(docId) ?? null;
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
        shownPlaceholder = null;
        return;
    }
    // Rendered on entering it only: not on every event of a hidden
    // document, which would rebuild the list under the mouse
    const mode = newTab.active ? "newTab" : "start";
    if (shownPlaceholder !== mode) {
        renderPlaceholder();
        empty.state.focus = true; // keys don't go to a hidden panel
    }
    shownPlaceholder = mode;
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
    const tab = findTab(docId);
    if (tab) applyTabStatus(tab, pane);
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
    const tab = findTab(docId);
    if (tab) applyTabStatus(tab, pane);
};

// Native: a file was opened, in a new document or in the one that had it open
// already (then that one is the current document again)
globalThis.onDocumentOpened = function (docId) {
    console.log("Native: onDocumentOpened (int)", docId);
    newTab = documentOpened(newTab); // opened from the New Tab: takes its place
    openFailure = null;
    refreshTabs(); // the table reloads when the file is loaded
};

// Native: the document was closed on request of its main view (e.g. Cancel
// while the file was loading)
globalThis.onDocumentClosed = function (docId) {
    console.log("Native: onDocumentClosed", docId);
    shownPlaceholder = null; // the recent files show when the file was used, not "Opened"
    refreshTabs();
};

// Native: the rows of the main view shown look different now (decoding)
globalThis.reloadLogTable = function () {
    shownPane?.reloadMainRows();
};

globalThis.getAppState = function () {
    const [left, top, width, height] = Window.this.box("xywh", "border", "screen", true);
    const list = panes.get(activeDocId)?.mainList; // shown or under the New Tab
    return JSON.stringify({
        windowRect: { left, top, width, height },
        theme: currentTheme,
        tableFontSize,
        scrollPosition: list ? (list.state.scrollPos || 0) : 0
    });
}
