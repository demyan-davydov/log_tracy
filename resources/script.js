import { $, $$ } from "@sciter";
import { VirtualDltTBody, VirtualMainViewTBody, VirtualSearchViewTBody, setColumns, renderHeader, setRuleColors, setMatchColors, moveRowDrag, endRowDrag } from "virtual-dlt-view.js";
import { scrollTarget } from "row-selection.js";
import { ruleColors } from "rule-colors.js";
import {
    noNewTab, plusShown, openNewTab, activateNewTab, activateDocument,
    closeNewTab, documentOpened, documentsCounted, showsPlaceholder,
    shownDocument, fileFailed, failureReason
} from "new-tab.js";
import { lastUsedText } from "recent-time.js";
import { SearchEditor } from "search-editor.js";
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
// Main view rendered last time: the table is reloaded when another document is
// shown or the content of the shown one changes (dataVersion of the ready view).
// shownDataVersion is null while the view isn't the table.
let shownDocId = null;
// The placeholder rendered last: "start", "newTab", null while a document is shown
let shownPlaceholder = null;
let shownDataVersion = null;
// State of the table of each document when another one was shown:
//   docId -> { dataVersion, index, selection }, index is the first visible row,
//   selection comes from VirtualDltTBody.saveSelection().
// Restored only for the same content (dataVersion), otherwise the table starts over.
const mainViewStates = new Map();
// The same for the search results of each document
const searchViewStates = new Map();

document.on("ready", function () {
    console.log("Starting DLT Explorer UI...");
    initApp();
    initChipSearch();

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
    const logList = getMainViewList();
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

    console.log("Окно закрывается, ресурсы зачищены");
});

function initApp() {
    restoreSettings();
    setupEvents();
    refreshTabs();
}

// Search panel: the chip search editor (search-editor.js, docs/stories/advanced-search.md),
// a query of chips over the payload of the active document. The query is
// committed only by Enter or the Search button; editing it doesn't touch the
// results, the panel just shows that what's typed isn't what the results were
// found by (updateChipPending). Both the draft and the committed query belong
// to the document: switching tabs puts the document's own draft into the editor.
//   docId -> { chips, message, history } of the editor (history: its undo steps)
const chipDrafts = new Map();
//   docId -> JSON of the chips the shown search was run with
const committedChips = new Map();
//   docId -> the match colors of those chips, by their place: the results show
//   what each chip found in its color (setMatchColors)
const committedColors = new Map();
// The document whose draft the editor shows
let chipEditorDocId = null;
let chipEditor = null;

function initChipSearch() {
    chipEditor = new SearchEditor($("#chip-search"), {
        checkRegex: (pattern, ignoreCase) => Window.this.xcall("checkRegex", pattern, ignoreCase),
        onEdited: () => {
            saveChipDraft();
            updateChipPending();
        },
        onCommit: runChipSearch,
        history: () => activeDocId === null ? []
            : JSON.parse(Window.this.xcall("getSearchHistory", activeDocId) || "[]"),
        historyButton: $("#btn-chip-history"),
    });
    document.on("click", "#btn-chip-search", () => {
        chipEditor.closeChip();
        runChipSearch();
    });
    showChipDraft();
    updateChipPending();
}

function runChipSearch() {
    const chips = chipEditor.searchChips();
    // an invalid regex chip is refused here; the backend checks again
    let error = chipEditor.firstError();
    if (!error) error = activeDocId === null ? "no document"
        : Window.this.xcall("startChipSearch", activeDocId, JSON.stringify(chips));
    $("#chip-search-message").innerText = error ? `Search error: ${error}` : "";
    if (!error && activeDocId !== null) {
        committedChips.set(activeDocId, JSON.stringify(chips));
        committedColors.set(activeDocId, chipEditor.searchChipColors());
        setMatchColors(committedColors.get(activeDocId)); // before the results come
    }
    saveChipDraft();
    updateChipPending();
}

function updateChipPending() {
    const pending = activeDocId !== null && chipEditor !== null
        && JSON.stringify(chipEditor.searchChips()) !== (committedChips.get(activeDocId) ?? "[]");
    $(".chip-search-toolbar").classList.toggle("pending", pending);
    $("#btn-chip-search").classList.toggle("primary", pending);
}

function saveChipDraft() {
    if (chipEditorDocId === null || !docStatus.has(chipEditorDocId) || chipEditor === null) return;
    chipDrafts.set(chipEditorDocId,
        { chips: chipEditor.chips, message: $("#chip-search-message").innerText || "", history: chipEditor.history });
}

function showChipDraft() {
    if (chipEditorDocId === activeDocId || chipEditor === null) return;
    const draft = chipDrafts.get(activeDocId) || { chips: [], message: "", history: null };
    chipEditor.setChips(draft.chips, draft.history);
    $("#chip-search-message").innerText = draft.message;
    chipEditorDocId = activeDocId;
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

// Opens a file in a new tab. On failure the backend puts it on top of the
// recent files, and the placeholder (brought up if needed) shows why.
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
    for (const table of $$("table.log-table"))
        table.style.fontSize = `${percent}%`;
    console.log("Table font size set to:", percent);
}

globalThis.getTabContent = function () {
    const tabContent = $("#tab-content");
    return tabContent;
}

globalThis.getLoadingContainer = function () {
    const tabContent = getTabContent();
    const loading = tabContent.$("#loading-container");
    return loading;
}

globalThis.getMainViewTable = function () {
    const tabContent = getTabContent();
    const list = tabContent.$("table.main-view");
    return list;
}

globalThis.getMainViewList = function () {
    const logTable = getMainViewTable();
    const list = logTable.$("tbody");
    return list;
}

globalThis.getSearchViewTable = function () {
    const list = $("table.search-view");
    return list;
}

globalThis.getSearchViewList = function () {
    const logTable = getSearchViewTable();
    const list = logTable.$("tbody");
    return list;
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
        applyColumns(); // the tables show the columns as arranged now
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

    // Anchor column: toggles the anchor of the message in both views. Ignored by
    // the backend while an operation runs or at the anchor limit.
    document.on("click", "table.log-table td.anchor", (evt, cell) => {
        const index = Number(cell.getAttribute("msg-index"));
        const anchored = cell.getAttribute("has-anchor") === "true";
        const lists = [getMainViewList(), getSearchViewList()].filter(list => list);
        const counts = lists.map(list => list.totalItems());
        const docId = cell.closest("tbody")?.docId;
        if (docId == null) return true;
        if (Window.this.xcall("setAnchor", docId, index, !anchored)) {
            for (const [i, list] of lists.entries()) {
                // The view gained or lost the row: the selected positions show other rows
                if (list.totalItems() !== counts[i]) list.resetSelection();
                list.componentUpdate(); // the view may gain or lose the row
                list.refreshVisibleRows(); // rows kept on screen show the new anchor
            }
        }
        return true; // don't change the row selection
    });

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

    // A double click on a search result shows its message in the main view:
    // current and the only one selected, near the top
    document.on("dblclick", "table.search-view > tbody > tr", (evt, row) => {
        if (evt.target.closest("td.anchor")) return; // toggles the anchor only
        const msgIndex = Number(row.$("td.anchor")?.getAttribute("msg-index"));
        if (!Number.isFinite(msgIndex)) return;
        // Only into a main view that shows its rows: while it is rebuilt the
        // positions belong to the content being replaced
        if (docStatus.get(activeDocId)?.mainView?.status !== "ready") return;
        const list = getMainViewList();
        if (!list) return;
        const position = Window.this.xcall("getMainViewPosition", list.docId, msgIndex);
        if (position === null || position === undefined) return;
        list.selection.moveTo(position);
        list.navigateTarget = scrollTarget(position, list.visibleRowCount());
        list.componentUpdate();
        list.updateRowStates();
        list.state.focus = true;
        return true;
    });

    document.on("click", "#btn-lost-close", () => {
        if (activeDocId !== null) closeTab(activeDocId);
    });

    document.on("click", "#btn-lost-retry", () => {
        if (activeDocId === null) return;
        // Reopens the file in the same tab; fails while the disk is still missing
        const retryStart = Date.now();
        const error = Window.this.xcall("retryDocument", activeDocId);
        const retryTime = Date.now() - retryStart;
        if (error) {
            console.log(`Retry failed after ${retryTime} ms: ${error}`);
            $("#source-lost-error").innerText = `Still unavailable: ${error}`;
            return;
        }
        const refreshStart = Date.now();
        refreshTabs(); // the reopened document starts loading: the table reloads when it is ready
        showFilters(); // a new document with the same id: its filters are restored
        console.log(`Retry: xcall ${retryTime} ms, views refresh ${Date.now() - refreshStart} ms`);
    });

    document.on("click", "#btn-cancel-search", () => {
        if (activeDocId !== null) Window.this.xcall("cancelSearchView", activeDocId);
    });

    // What Cancel means (stop the filter, close a loading document) is decided
    // by the main view machine of the document
    document.on("click", "#btn-cancel-load", () => {
        if (activeDocId !== null) Window.this.xcall("cancelMainView", activeDocId);
    });

    document.on("click", "#btn-fibex", () => {
        const fn = Window.this.selectFile({
            mode: "open",
            filter: "XML Files (*.xml)|*.xml|All Files (*.*)|*.*"
        });
        if (fn) {
            Window.this.xcall("loadFibex", fn);
            reloadLogTable();
        }
    });

    // Filter sets are only appended; each one has its remove button. A filter
    // file of DLT Explorer for any log, a .dlf of dlt-viewer for a DLT one.
    document.on("click", "#btn-dlf", () => {
        const filter = shownFilters.canDlf
            ? "Filter Files (*.logfilter;*.dlf)|*.logfilter;*.dlf|DLT Explorer Filters (*.logfilter)|*.logfilter|dlt-viewer Filters (*.dlf)|*.dlf|All Files (*.*)|*.*"
            : "DLT Explorer Filters (*.logfilter)|*.logfilter|All Files (*.*)|*.*";
        const fn = Window.this.selectFile({ mode: "open", filter });
        if (fn) filterCommand("loadFilterFile", fn);
    });

    // An empty set, kept with the log like a loaded one; its first rule is
    // asked for right away
    document.on("click", "#btn-new-dlf", () => {
        if (activeDocId === null) return;
        filterCommand("newFilterSet");
        if (filterMessages.get(activeDocId)) return;
        const set = shownFilters.sets.length - 1;
        // No first rule: no set either, so cancelled tries don't pile up
        if (!editRule(set, -1)) filterCommand("removeFilterSet", set);
    });

    document.on("click", ".filter-add", (evt, button) => {
        editRule(parseInt(button.parentElement.getAttribute("set-index")), -1);
        return true;
    });

    // A set is a copy kept with the log: exported to share it, to a filter file
    // of DLT Explorer or (DLT logs) to a .dlf for dlt-viewer
    document.on("click", ".filter-export", (evt, button) => {
        const set = parseInt(button.parentElement.getAttribute("set-index"));
        // Offered the file the set was loaded from or exported to last, or
        // <name>.<format>.logfilter; its kind is offered first
        const fileName = shownFilters.sets[set]?.fileName || "";
        const dlf = shownFilters.canDlf && /\.dlf$/i.test(fileName);
        const native = "DLT Explorer Filters (*.logfilter)|*.logfilter";
        const dlt = "dlt-viewer Filters (*.dlf)|*.dlf";
        const kinds = !shownFilters.canDlf ? [native] : dlf ? [dlt, native] : [native, dlt];
        const params = {
            mode: "save",
            caption: "Export Filter",
            extension: dlf ? "dlf" : "logfilter",
            filter: kinds.join("|") + "|All Files (*.*)|*.*"
        };
        // Without its extension: the dialog adds it itself (name.dlf.dlf otherwise)
        if (fileName) params.path = fileName.replace(/\.(dlf|logfilter)$/i, "");
        const fn = Window.this.selectFile(params);
        if (fn) filterCommand("exportFilterSet", set, fn);
        return true;
    });

    document.on("click", ".filter-rule-edit", (evt, button) => {
        const row = button.parentElement;
        editRule(parseInt(row.getAttribute("set-index")), parseInt(row.getAttribute("rule-index")));
        return true;
    });

    document.on("dblclick", ".filter-rule", (evt, row) => {
        if (evt.target.tag === "input") return; // the switch
        editRule(parseInt(row.getAttribute("set-index")), parseInt(row.getAttribute("rule-index")));
        return true;
    });

    document.on("click", ".filter-rule-remove", (evt, button) => {
        const row = button.parentElement;
        filterCommand("removeFilterRule", parseInt(row.getAttribute("set-index")),
            parseInt(row.getAttribute("rule-index")));
        return true;
    });

    document.on("change", ".filter-set-switch", (evt, input) => {
        const row = input.parentElement;
        filterCommand("enableFilterSet", parseInt(row.getAttribute("set-index")), input.value);
    });

    document.on("change", ".filter-rule-switch", (evt, input) => {
        const row = input.parentElement;
        filterCommand("enableFilterRule", parseInt(row.getAttribute("set-index")),
            parseInt(row.getAttribute("rule-index")), input.value);
    });

    document.on("click", ".filter-remove", (evt, button) => {
        filterCommand("removeFilterSet", parseInt(button.parentElement.getAttribute("set-index")));
        return true;
    });

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

// The filter sets live in the backend (DocumentFilters), per document; the
// panel shows those of the active document. Only the error message of the last
// filter command is kept here: docId -> message
const filterMessages = new Map();
let filtersDocId; // the document the panel shows; undefined: not shown yet

const ruleKindMarks = { include: "+", exclude: "\u2212", marker: "\u25C6" };
const ruleKindTitles = {
    include: "Shows the records it matches",
    exclude: "Hides the records it matches",
    marker: "Marks the records it matches with its color"
};

// Runs a filter command of the active document and shows the sets again; the
// table reloads when the filter operation reports completion
function filterCommand(name, ...args) {
    if (activeDocId === null) return;
    const error = Window.this.xcall(name, activeDocId, ...args);
    filterMessages.set(activeDocId, error || "");
    showFilters();
    refreshRuleColors();
}

// The rows on screen refer to the rules again: a change of a rule may change
// the rule with a color a row matches without filtering the view again
function refreshRuleColors() {
    for (const list of [getMainViewList(), getSearchViewList()])
        list?.refreshVisibleRows?.();
}

let shownFilters = { canFilter: false, canDlf: false, sets: [] }; // what showFilters() got last

// Opens the editor of a rule of a set of the active document (rule -1: a new
// one) and applies what it closes with. A rule the backend refuses (e.g. an
// invalid regular expression) opens the editor again with the error.
// @returns true if the rule was applied, false if the editor was cancelled
function editRule(set, rule) {
    if (activeDocId === null) return false;
    const docId = activeDocId;
    let values = JSON.parse(Window.this.xcall("getFilterRule", docId, set, rule) || "null");
    if (!values) return false;
    let error = "";
    for (;;) {
        const result = Window.this.modal({
            url: "rule-editor.htm",
            alignment: "center",
            parameters: {
                title: rule < 0 ? "New Rule" : "Edit Rule", theme: currentTheme, rule: values, error,
                columns: JSON.parse(Window.this.xcall("getColumns", docId) || "[]"),
                // What is wrong with the rule, while it is edited: the editor
                // marks it at once instead of being reopened with the error
                check: rule => Window.this.xcall("checkFilterRule", docId, JSON.stringify(rule))
            }
        });
        if (!result) return false;
        const json = JSON.stringify(result);
        error = rule < 0 ? Window.this.xcall("addFilterRule", docId, set, json)
            : Window.this.xcall("updateFilterRule", docId, set, rule, json);
        if (!error) break;
        values = result;
    }
    filterMessages.set(activeDocId, "");
    showFilters();
    refreshRuleColors();
    return true;
}

// Shows the filter sets of the active document: a set is a row with its
// switch, name and remove button, followed by a row per rule
function showFilters() {
    const info = activeDocId === null
        ? { canFilter: false, canDlf: false, sets: [] }
        : JSON.parse(Window.this.xcall("getFilters", activeDocId) || "{}");
    shownFilters = info;
    setRuleColors(ruleColors(info.sets)); // the rows refer to the rules by id
    const panel = $("#filter-sets");
    // Built from scratch, as the quick filter was: reused inputs keep their state
    panel.clear();
    if (!info.sets || info.sets.length === 0)
        panel.append(<div class="filters-empty">{info.canFilter
            ? "No filters: load a filter file or create a new one"
            : "This log has no columns to filter by"}</div>);
    (info.sets || []).forEach((set, s) => {
        const element = <div class={set.enabled ? "filter-set" : "filter-set off"}>
            <div class="filter-row filter-set-head" set-index={s}>
                <input type="checkbox" class="filter-set-switch" />
                <span class="filter-name" title={set.source ? `Loaded from ${set.source}` : ""}>{set.name}</span>
                <span class="filter-button filter-export" title="Export to a filter file">⤓</span>
                <span class="filter-button filter-add" title="Add a rule">+</span>
                <span class="filter-button filter-remove" title="Remove this filter">×</span>
            </div>
        </div>;
        panel.append(element);
        const block = panel.lastElementChild;
        block.$(".filter-set-switch").value = set.enabled;
        set.rules.forEach((rule, r) => {
            const classes = ["filter-row", "filter-rule"];
            if (!rule.enabled) classes.push("off");
            if (rule.error) classes.push("error");
            block.append(<div class={classes.join(" ")} set-index={s} rule-index={r}>
                <input type="checkbox" class="filter-rule-switch" />
                <span class="filter-kind" title={ruleKindTitles[rule.kind]}>{ruleKindMarks[rule.kind]}</span>
                <span class="filter-swatch" />
                <span class="filter-name">{rule.name || "(no name)"}</span>
                <span class="filter-button filter-rule-edit" title="Edit this rule (or double-click it)">✎</span>
                <span class="filter-button filter-rule-remove" title="Remove this rule">×</span>
            </div>);
            const row = block.lastElementChild;
            row.$(".filter-rule-switch").value = rule.enabled;
            if (rule.color) row.$(".filter-swatch").style.setProperty("background-color", rule.color);
            if (rule.error)
                block.append(<div class="filter-note">{`Not applied: ${rule.error}`}</div>);
        });
    });
    $("#btn-dlf").style.display = info.canFilter ? "" : "none";
    $("#btn-new-dlf").style.display = info.canFilter ? "" : "none";
    $("#filter-message").innerText = filterMessages.get(activeDocId) ?? "";
    filtersDocId = activeDocId;
}

// Status of every open document, kept up to date for all documents, not only
// the active one:
//   docId -> { mainView, searchView, path }
// mainView and searchView are the views shown by the machines of the document
// (onMainViewChanged, onSearchViewChanged): { status, canCancel, <fields of the
// view> }, see source/ui/main_view_fsm.d and source/ui/search_view_fsm.d.
// Snapshot comes from getWorkspaceInfo in refreshTabs().
const docStatus = new Map();
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

// Exposes the status on the tab element for CSS: main-status, search-status
function applyTabStatus(tab, status) {
    tab.setAttribute("main-status", status.mainView ? status.mainView.status : "");
    tab.setAttribute("search-status", status.searchView ? status.searchView.status : "");
}

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

    saveChipDraft(); // the editor may be about to show another document
    docStatus.clear();
    activeDocId = null;
    for (const doc of docs) {
        docStatus.set(doc.id, { mainView: doc.mainView, searchView: doc.searchView, path: doc.path });
        if (doc.active) activeDocId = doc.id;
    }
    // The tables show the rows of the active document
    for (const list of [getMainViewList(), getSearchViewList()])
        if (list) list.docId = activeDocId;
    // The filters first: the rows the columns re-render refer to its rules
    if (activeDocId !== filtersDocId) showFilters(); // the sets change by commands only
    applyColumns();
    setMatchColors(committedColors.get(activeDocId) ?? []); // before the results are shown

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
        applyTabStatus(tab, docStatus.get(doc.id));
    });
    renderNewTab();

    for (const docId of mainViewStates.keys())
        if (!docStatus.has(docId)) mainViewStates.delete(docId); // closed
    for (const docId of searchViewStates.keys())
        if (!docStatus.has(docId)) searchViewStates.delete(docId);
    for (const docId of chipDrafts.keys())
        if (!docStatus.has(docId)) chipDrafts.delete(docId);
    for (const docId of committedChips.keys())
        if (!docStatus.has(docId)) committedChips.delete(docId);
    for (const docId of committedColors.keys())
        if (!docStatus.has(docId)) committedColors.delete(docId);
    for (const docId of filterMessages.keys())
        if (!docStatus.has(docId)) filterMessages.delete(docId);

    updateViewMode();
    updateSearchViewMode();
    showChipDraft();
    updateChipPending();
}

// The columns of the log tables follow the format of the active document, as
// the layout of the format in Settings arranges them. The tables are rebuilt
// only when they change: switching between documents of the same format keeps
// them as they are.
// @returns the JSON of the columns of the tables, "[]" if no document
let appliedColumns = null; // JSON of the columns the tables show
function applyColumns() {
    const json = activeDocId === null ? "[]" : Window.this.xcall("getTableColumns", activeDocId) || "[]";
    if (json === "[]" || json === appliedColumns) return json; // none, or unchanged
    appliedColumns = json;
    setColumns(JSON.parse(json));
    for (const table of $$("table.log-table")) {
        table.$("thead").content(renderHeader());
        const list = table.$("tbody");
        list.componentUpdate?.();
        list.refreshVisibleRows?.(); // rows on screen get the new cells
    }
    return json;
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

// Texts of the main view statuses other than the table and the lost file
const mainViewTexts = {
    loadingFile: (vm) => `Loading file... ${percent(vm.progress)}%`,
    loadFailed: () => "Failed to load the file",
    filtering: (vm) => `Filtering... ${percent(vm.progress)}%`,
    filterCancelled: () => "Filter cancelled",
    filterFailed: () => "Filter failed",
};

// Line under the text of a status: what the user can do, or the error
const mainViewDetails = {
    loadingFile: () => "Cancel closes the file",
    loadFailed: (vm) => vm.error || "",
    filterCancelled: () => "Change or clear the filters to show messages again",
    filterFailed: (vm) => vm.error || "",
};

const searchViewDetails = {
    searchCancelled: () => "Run the search again to see results",
    searchFailed: (vm) => vm.error || "",
};

// Fills a status view: text, progress (hidden without one), detail, Cancel
// (its row hidden when the status can't be cancelled)
function showStatus(ids, vm, texts, details) {
    const progress = $(ids.progress);
    const hasProgress = vm.progress !== undefined;
    progress.style.display = hasProgress ? "" : "none";
    if (hasProgress) progress.value = percent(vm.progress);
    const text = texts[vm.status];
    $(ids.status).innerText = text ? text(vm) : vm.status;
    const detail = details[vm.status];
    $(ids.detail).innerText = detail ? detail(vm) : "";
    $(ids.cancel).parentElement.style.display = vm.canCancel ? "" : "none";
}

function percent(progress) {
    return Math.round(progress * 100);
}

// Remembers in `states` the scroll and the selection of `list` for `docId`;
// call while the list still shows that document
function saveListState(list, states, docId, dataVersion) {
    const index = list?.vlist?.firstVisibleItemIndex;
    if (typeof index === "number")
        states.set(docId, { dataVersion, index, selection: list.saveSelection() });
}

// Returns: the state to restore when the list shows `docId` again, null if
// it wasn't shown before or its content has changed since
function savedListState(states, docId, dataVersion) {
    const saved = states.get(docId);
    return saved && saved.dataVersion === dataVersion ? saved : null;
}

// Reloads the rows of `list` after its data changed. scrollTo: null keeps the
// scroll position, "start" scrolls to the top, a number scrolls to that row
function reloadList(list, scrollTo = null) {
    if (scrollTo === "start") list.scrollTo(0, 0);
    // Carried out by the render that componentUpdate() posts, see VirtualList.navigateTarget
    if (scrollTo !== null) list.navigateTarget = scrollTo;
    list.componentUpdate();
    list.refreshVisibleRows(); // the rows may show other messages now
}

// Renders the main view of the active document as its machine shows it, or
// the placeholder instead of all the panels while no document is open
function updateViewMode() {
    const table = getMainViewTable();
    const loading = getLoadingContainer();
    const empty = $("#empty-placeholder");
    const lostView = $("#source-lost");
    // The document shown: none while the placeholder is (the New Tab too)
    const docId = shownDocument(newTab, docCount, activeDocId);
    const status = docStatus.get(docId);
    const vm = status ? status.mainView : null;

    // Leaving the table of another document: the rows on screen are still its own
    if (shownDocId !== null && shownDocId !== docId && shownDataVersion !== null)
        saveListState(getMainViewList(), mainViewStates, shownDocId, shownDataVersion);

    // No document shown: the placeholder replaces all the panels, the filters too
    empty.style.display = vm ? "none" : "flex";
    $("#document-views").style.display = vm ? "" : "none";

    const showOnly = (shown) => {
        for (const element of [table, loading, lostView])
            element.style.display = element !== shown ? "none" : "block";
    };

    if (!vm) {
        // Rendered on entering it only: not on every event of a hidden
        // document, which would rebuild the list under the mouse
        const mode = newTab.active ? "newTab" : "start";
        if (shownPlaceholder !== mode) renderPlaceholder();
        shownPlaceholder = mode;
        shownDocId = null;
        shownDataVersion = null;
        return;
    }

    shownPlaceholder = null;
    if (vm.status !== "sourceLost") $("#source-lost-error").innerText = "";

    if (vm.status === "ready") {
        showOnly(table);
        if (docId !== shownDocId) {
            console.log("View update: doc", docId, "content", vm.dataVersion);
            const saved = savedListState(mainViewStates, docId, vm.dataVersion);
            getMainViewList().restoreSelection(saved ? saved.selection : null);
            reloadLogTable(saved ? saved.index : "start");
        } else if (vm.dataVersion !== shownDataVersion) {
            console.log("View update: content", vm.dataVersion, "of doc", docId);
            getMainViewList().resetSelection(); // the rows are other messages now
            reloadLogTable();
        }
        shownDocId = docId;
        shownDataVersion = vm.dataVersion;
        return;
    }

    if (vm.status === "sourceLost") {
        showOnly(lostView);
        $("#source-lost-path").innerText = status.path || "";
    } else {
        showOnly(loading);
        showStatus({ status: "#doc-load-status", progress: "#doc-load-progress",
            detail: "#doc-load-detail", cancel: "#btn-cancel-load" }, vm, mainViewTexts, mainViewDetails);
    }
    shownDocId = docId;
    shownDataVersion = null; // the next table is reloaded, whatever its dataVersion
}

// Texts of the search view statuses other than the results
const searchViewTexts = {
    waitingForView: () => "Waiting for the log view...",
    searching: (vm) => `Searching... ${percent(vm.progress)}%`,
    searchCancelled: () => "Search cancelled",
    searchFailed: () => "Search failed",
    sourceLost: () => "The file is no longer available",
};

// Search results rendered last time, as shownDocId / shownDataVersion for the
// main view: the list reloads when another document or content is shown
let shownSearchDocId = null;
let shownSearchDataVersion = null;

// Renders the search view of the active document as its machine shows it.
// No document: an empty result, same as a document before any search.
function updateSearchViewMode() {
    const table = getSearchViewTable();
    if (!table) return;

    const loading = $("#search-loading-container");
    const status = docStatus.get(activeDocId);
    const vm = status ? status.searchView : { status: "ready", canCancel: false, dataVersion: null };
    const searchList = getSearchViewList();

    // Leaving the results of another document: the rows on screen are still its own
    if (searchList && shownSearchDocId !== null && shownSearchDocId !== activeDocId
            && shownSearchDataVersion !== null)
        saveListState(searchList, searchViewStates, shownSearchDocId, shownSearchDataVersion);

    if (vm.status === "ready") {
        table.style.display = "block";
        loading.style.display = "none";
        if (searchList && activeDocId !== shownSearchDocId) {
            const saved = savedListState(searchViewStates, activeDocId, vm.dataVersion);
            searchList.restoreSelection(saved ? saved.selection : null);
            reloadList(searchList, saved ? saved.index : "start");
        } else if (searchList && vm.dataVersion !== shownSearchDataVersion) {
            searchList.resetSelection(); // the rows are other messages now
            reloadList(searchList);
        }
        shownSearchDocId = activeDocId;
        shownSearchDataVersion = vm.dataVersion;
        return;
    }

    table.style.display = "none";
    loading.style.display = "block";
    showStatus({ status: "#search-view-status", progress: "#search-view-progress",
        detail: "#search-view-detail", cancel: "#btn-cancel-search" }, vm, searchViewTexts, searchViewDetails);

    shownSearchDocId = activeDocId;
    shownSearchDataVersion = null; // the next result is reloaded, whatever its dataVersion
}

// Native: the search view of a document shows something else now.
// json: { status, canCancel, <fields of the view> }, see source/ui/search_view_fsm.d
// Arrives for every document; only the active one is rendered.
globalThis.onSearchViewChanged = function (docId, json) {
    const status = docStatus.get(docId);
    if (!status) return; // tab not rendered yet: refreshTabs() will take the snapshot

    status.searchView = JSON.parse(json);
    if (status.searchView.status !== "searching")
        console.log("Native: onSearchViewChanged", docId, json);

    const tab = findTab(docId);
    if (tab) applyTabStatus(tab, status);

    if (docId === shownDocument(newTab, docCount, activeDocId)) updateSearchViewMode();
};

// Native: the main view of a document shows something else now.
// json: { status, canCancel, <fields of the view> }, see source/ui/main_view_fsm.d
// Arrives for every document; only the active one is rendered.
globalThis.onMainViewChanged = function (docId, json) {
    const status = docStatus.get(docId);
    if (!status) return; // tab not rendered yet: refreshTabs() will take the snapshot

    status.mainView = JSON.parse(json);
    if (status.mainView.status !== "loadingFile" && status.mainView.status !== "filtering")
        console.log("Native: onMainViewChanged", docId, json);

    const tab = findTab(docId);
    if (tab) applyTabStatus(tab, status);

    if (docId === shownDocument(newTab, docCount, activeDocId)) updateViewMode();
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

// scrollTo: null keeps the scroll position, "start" scrolls to the top,
// a number scrolls to that row
globalThis.reloadLogTable = function (scrollTo = null) {
    const logList = getMainViewList();
    if (logList) {
        console.log("Reloading log table", scrollTo !== null ? `(scroll to ${scrollTo})` : "");
        reloadList(logList, scrollTo);

        // Print DOM tree of the table after a short delay so vlist has time to render
        /*setTimeout(() => {
            const table = getMainViewTable();
            if (table) {
                console.log("\n--- DOM TREE DUMP (table) ---");
                console.log(table.outerHTML);
                console.log("-----------------------------\n");
            }
        }, 500);
        */
    }
};

globalThis.getAppState = function () {
    const [left, top, width, height] = Window.this.box("xywh", "border", "screen", true);
    const list = getMainViewList();
    return JSON.stringify({
        windowRect: { left, top, width, height },
        theme: currentTheme,
        tableFontSize,
        scrollPosition: list ? (list.state.scrollPos || 0) : 0
    });
}
