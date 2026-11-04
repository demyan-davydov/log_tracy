import { $, $$ } from "@sciter";
import { VirtualDltTBody, VirtualMainViewTBody, VirtualSearchViewTBody } from "virtual-dlt-view.js";

globalThis.VirtualDltTBody = VirtualDltTBody;
globalThis.VirtualMainViewTBody = VirtualMainViewTBody;
globalThis.VirtualSearchViewTBody = VirtualSearchViewTBody;

let currentTheme = "light";
// Main view rendered last time: the table is reloaded when another document is
// shown or the content of the shown one changes (dataVersion of the ready view).
// shownDataVersion is null while the view isn't the table.
let shownDocId = null;
let shownDataVersion = null;
// State of the table of each document when another one was shown:
//   docId -> { dataVersion, index, selection }, index is the first visible row,
//   selection comes from VirtualDltTBody.saveSelection().
// Restored only for the same content (dataVersion), otherwise the table starts over.
const mainViewStates = new Map();

document.on("ready", function () {
    console.log("Starting DLT Explorer UI...");
    initApp();
    initSearch();

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

// Search panel: a text or regex query over the payload of the active document.
// The search runs on Enter or the Search button, and again when a mode switch
// changes, so the result always matches what the controls show.
function initSearch() {
    const runSearch = () => {
        const query = $("#search-input").value || "";
        const isRegex = $("#search-regex").state.checked;
        const ignoreCase = $("#search-ignore-case").state.checked;
        // Returns an error message (e.g. an invalid regex) or "" when started
        const error = Window.this.xcall("startSearch", query, isRegex, ignoreCase);
        $("#search-message").innerText = error ? `Search error: ${error}` : "";
    };

    document.on("keydown", "#search-input", (evt) => {
        if (evt.code === "Enter") {
            runSearch();
            return true;
        }
    });
    document.on("click", "#btn-search", runSearch);
    document.on("change", "#search-regex, #search-ignore-case", () => {
        if ($("#search-input").value) runSearch();
    });
}

function restoreSettings() {
    try {
        const settingsStr = Window.this.xcall("getSettings");
        if (settingsStr) {
            const settings = JSON.parse(settingsStr);
            if (settings.theme) {
                setTheme(settings.theme);
            }
            // Files open at the end of the last session, the active one first
            const paths = (settings.files || []).map(f => f.path);
            if (settings.activeFile) paths.unshift(settings.activeFile);
            for (const path of paths.reverse()) rememberRecentFile(path);
        }
    } catch (e) {
        console.error("Failed to restore settings:", e);
    }
}

// Recent files shown by the placeholder, most recent first: the files of the
// last session, then every file open in this one
const RECENT_FILES_MAX = 8;
let recentFiles = [];

function rememberRecentFile(path) {
    if (!path) return;
    recentFiles = [path, ...recentFiles.filter(p => p !== path)].slice(0, RECENT_FILES_MAX);
}

function splitPath(path) {
    const cut = Math.max(path.lastIndexOf("/"), path.lastIndexOf("\\"));
    return { dir: path.slice(0, cut + 1), name: path.slice(cut + 1) };
}

// Fills the placeholder shown while no document is open
function renderPlaceholder() {
    const placeholder = $("#empty-placeholder");
    placeholder.content(<div class="placeholder-body">
        <div class="placeholder-title">No file open</div>
        <div class="placeholder-hint">
            Open a DLT log with <kbd>⌘O</kbd> or <b>+ Open File</b> above
        </div>
    </div>);
    if (!recentFiles.length) return;

    // Items one by one: append() of JSX is known to work, nested arrays aren't
    placeholder.$(".placeholder-body").append(<div class="recent-files">
        <div class="recent-files-header">Recent files</div>
    </div>);
    const list = placeholder.$(".recent-files");
    for (const path of recentFiles) {
        const { dir, name } = splitPath(path);
        list.append(<div class="recent-file" path={path} title={path}>
            <div class="recent-file-name">{name}</div>
            <div class="recent-file-dir">{dir}</div>
        </div>);
    }
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

function openSettingsAction() {
    const result = Window.this.modal({
        url: "settings.htm",
        alignment: "center",
        parameters: { theme: currentTheme }
    });
    if (result && result.theme) {
        setTheme(result.theme);
    }
}

function openFileAction() {
    const fn = Window.this.selectFile({
        mode: "open",
        filter: "DLT Files (*.dlt)|*.dlt|All Files (*.*)|*.*"
    });
    if (fn) {
        console.log("File selected:", fn);
        Window.this.xcall("openFile", fn);
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
    document.on("click", "#btn-add-tab", openFileAction);

    document.on("click", ".recent-file", (evt, item) => {
        Window.this.xcall("openFile", item.getAttribute("path"));
    });

    // Anchor column: toggles the anchor of the message in both views. Ignored by
    // the backend while an operation runs or at the anchor limit.
    document.on("click", "table.log-table td.anchor", (evt, cell) => {
        const index = Number(cell.getAttribute("msg-index"));
        const anchored = cell.getAttribute("has-anchor") === "true";
        if (Window.this.xcall("setAnchor", index, !anchored)) {
            for (const list of [getMainViewList(), getSearchViewList()]) {
                if (!list) continue;
                list.componentUpdate(); // the view may gain or lose the row
                list.refreshVisibleRows(); // rows kept on screen show the new anchor
            }
        }
        return true; // don't change the row selection
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

    document.on("click", "#btn-dlf", () => {
        const fn = Window.this.selectFile({
            mode: "open",
            filter: "DLT Filter Files (*.dlf)|*.dlf|All Files (*.*)|*.*"
        });
        if (fn) {
            try {
                const json = Window.this.xcall("loadDlf", fn);
                if (json) {
                    const config = JSON.parse(json);
                    console.log("Loaded DLF config:", config);

                    $("#filter-ecu").value = config.ecuId || "";
                    $("#filter-app").value = config.appId || "";
                    $("#filter-ctx").value = config.ctxId || "";
                    $("#filter-payload").value = config.payloadRegex || "";

                    applyFilters();
                }
            } catch (e) {
                console.error("Failed to load DLF:", e);
            }
        }
    });

    document.on("click", "#btn-clear-filters", () => {
        for (const sel of ["#filter-ecu", "#filter-app", "#filter-ctx", "#filter-payload"]) {
            $(sel).value = "";
        }
        applyFilters();
    });

    document.on("change", ".filter-group input", applyFilters);

    // A tab is activated on mousedown (as in browsers) and can then be dragged;
    // click only handles the close button
    document.on("click", ".tab .tab-close", function (evt, close) {
        closeTab(close.parentElement.id);
        return true;
    });

    document.on("mousedown", ".tab", function (evt, tab) {
        // Only the left button activates and drags: the right (2) and middle
        // (4) bits are the same in DOM and in Sciter (PROP_/MIDDLE_MOUSE_BUTTON)
        if (evt.buttons & 6) return;
        if (evt.target.classList.contains("tab-close")) return;
        if (tabDrag) return; // the previous drop is still settling
        const docId = parseInt(tab.id);
        if (docId !== activeDocId) switchTab(docId); // keeps the tab elements
        beginTabDrag(tab, evt.clientX);
        return true; // no text selection
    });

    document.on("mousemove", function (evt) {
        if (tabDrag) moveTabDrag(evt.clientX);
    });

    document.on("mouseup", function (evt) {
        if (tabDrag) endTabDrag();
    });

    document.on("keydown", function (evt) {
        const modifier = evt.metaKey || evt.ctrlKey;
        if (modifier && (evt.code === "KeyO" || evt.code === "KeyF")) {
            openFileAction();
            return true;
        }
    });
}

function applyFilters() {
    const config = {
        ecuId: $("#filter-ecu").value,
        appId: $("#filter-app").value,
        ctxId: $("#filter-ctx").value,
        payloadRegex: $("#filter-payload").value
    };
    // The table reloads when the filter operation reports completion
    Window.this.xcall("applyFilter", JSON.stringify(config));
}

// Status of every open document, kept up to date for all documents, not only
// the active one:
//   docId -> { mainView, searchView, path }
// mainView and searchView are the views shown by the machines of the document
// (onMainViewChanged, onSearchViewChanged): { status, canCancel, <fields of the
// view> }, see source/ui/main_view_fsm.d and source/ui/search_view_fsm.d.
// Snapshot comes from getWorkspaceInfo in refreshTabs().
const docStatus = new Map();
let activeDocId = null;

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

    docStatus.clear();
    activeDocId = null;
    for (const doc of docs) {
        docStatus.set(doc.id, { mainView: doc.mainView, searchView: doc.searchView, path: doc.path });
        if (doc.active) activeDocId = doc.id;
    }
    for (const doc of [...docs].reverse()) rememberRecentFile(doc.path);

    // Same documents in the same order (e.g. another tab was activated): the
    // elements are kept, so a tab being pressed or dragged stays in the DOM
    let tabs = [...$$("#tabs-container > .tab")];
    const sameTabs = tabs.length === docs.length
        && tabs.every((tab, i) => parseInt(tab.id) === docs[i].id);
    if (!sameTabs) {
        // The + button is kept: it animates between its two looks
        for (const tab of tabs) tab.remove();
        for (const doc of docs)
            container.append(<div class="tab" id={doc.id}>
                <span class="tab-sep"></span>
                <span class="tab-name"></span>
                <span class="tab-close">×</span>
            </div>);
        tabs = [...$$("#tabs-container > .tab")];
    }
    updateAddTabButton(docs.length === 0);
    docs.forEach((doc, i) => {
        const tab = tabs[i];
        if (doc.active) tab.classList.add("active");
        else tab.classList.remove("active");
        tab.$(".tab-name").textContent = doc.name;
        applyTabStatus(tab, docStatus.get(doc.id));
    });

    for (const docId of mainViewStates.keys())
        if (!docStatus.has(docId)) mainViewStates.delete(docId); // closed

    updateViewMode();
    updateSearchViewMode();
}

// The + button: "+ Open File" while no document is open, a small round "+"
// in the corner of the tab strip otherwise (the label then is its tooltip)
function updateAddTabButton(wide) {
    const button = $("#btn-add-tab");
    if (wide) {
        button.classList.add("wide");
        button.removeAttribute("title");
    } else {
        button.classList.remove("wide");
        button.setAttribute("title", "Open File (⌘O)");
    }
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
    refreshTabs();
}

// Chrome-like dragging of a tab: the tab follows the mouse along the strip,
// the tabs it passes slide aside to free its new place, a marker shows where
// it will land; on drop it slides into that place and the workspace order is
// updated. No tooltips while a tab is held: they would cover the strip
// (see TabTooltip).
// tabDrag: { tab, tabs, rects, from, to, startX, dx, minDx, maxDx, sep,
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
    const tabs = [...$$("#tabs-container > .tab")];
    const rects = tabs.map(t => t.getBoundingClientRect());
    const from = tabs.indexOf(tab);
    if (from < 0) return;
    tabDrag = {
        tab, tabs, rects, from, to: from,
        startX: clientX, dx: 0,
        // the tab stays within the strip
        minDx: rects[0].left - rects[from].left,
        maxDx: rects[rects.length - 1].right - rects[from].right,
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
    d.dx = Math.max(d.minDx, Math.min(d.maxDx, dx));
    setTabShift(d.tab, d.dx);

    // The tab takes the place of every tab whose middle its leading edge has
    // passed (with equal widths, the strip end is exactly the middle of the
    // last tab, hence the non-strict comparison)
    const r = d.rects[d.from];
    const width = r.right - r.left;
    const left = r.left + d.dx, right = r.right + d.dx;
    let to = d.from;
    for (let i = 0; i < d.tabs.length; i++) {
        if (i === d.from) continue;
        const ri = d.rects[i];
        const middle = (ri.left + ri.right) / 2;
        let shift = 0;
        if (i > d.from && right >= middle) { shift = -width; to++; }
        else if (i < d.from && left <= middle) { shift = width; to--; }
        setTabShift(d.tabs[i], shift);
    }
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
    let target = 0;
    if (d.to > d.from)
        target = d.rects[d.to].right - d.rects[d.from].right;
    else if (d.to < d.from)
        target = d.rects[d.to].left - d.rects[d.from].left;
    d.settling = true;
    d.tab.classList.add("settling");
    setTabShift(d.tab, target);
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
    loadingFile: (vm) => `Loading DLT file... ${percent(vm.progress)}%`,
    loadFailed: () => "Failed to load DLT file",
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

// Remembers the scroll and the selection of the table of `docId`; call while
// it still shows that document
function saveMainViewState(docId, dataVersion) {
    const list = getMainViewList();
    const index = list?.vlist?.firstVisibleItemIndex;
    if (typeof index === "number")
        mainViewStates.set(docId, { dataVersion, index, selection: list.saveSelection() });
}

// Returns: the state to restore when the table shows `docId` again, null if
// it wasn't shown before or its content has changed since
function savedMainViewState(docId, dataVersion) {
    const saved = mainViewStates.get(docId);
    return saved && saved.dataVersion === dataVersion ? saved : null;
}

// Renders the main view of the active document as its machine shows it, or
// the placeholder instead of all the panels while no document is open
function updateViewMode() {
    const table = getMainViewTable();
    const loading = getLoadingContainer();
    const empty = $("#empty-placeholder");
    const lostView = $("#source-lost");
    const status = docStatus.get(activeDocId);
    const vm = status ? status.mainView : null;

    // Leaving the table of another document: the rows on screen are still its own
    if (shownDocId !== null && shownDocId !== activeDocId && shownDataVersion !== null)
        saveMainViewState(shownDocId, shownDataVersion);

    // No document: the placeholder replaces all the panels, the filters too
    empty.style.display = vm ? "none" : "flex";
    $("#document-views").style.display = vm ? "" : "none";

    const showOnly = (shown) => {
        for (const element of [table, loading, lostView])
            element.style.display = element !== shown ? "none" : "block";
    };

    if (!vm) {
        renderPlaceholder();
        shownDocId = null;
        shownDataVersion = null;
        return;
    }

    if (vm.status !== "sourceLost") $("#source-lost-error").innerText = "";

    if (vm.status === "ready") {
        showOnly(table);
        if (activeDocId !== shownDocId) {
            console.log("View update: doc", activeDocId, "content", vm.dataVersion);
            const saved = savedMainViewState(activeDocId, vm.dataVersion);
            getMainViewList().restoreSelection(saved ? saved.selection : null);
            reloadLogTable(saved ? saved.index : "start");
        } else if (vm.dataVersion !== shownDataVersion) {
            console.log("View update: content", vm.dataVersion, "of doc", activeDocId);
            reloadLogTable();
        }
        shownDocId = activeDocId;
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
    shownDocId = activeDocId;
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

    if (vm.status === "ready") {
        table.style.display = "block";
        loading.style.display = "none";
        if (activeDocId !== shownSearchDocId || vm.dataVersion !== shownSearchDataVersion) {
            const searchList = getSearchViewList();
            if (searchList) {
                searchList.componentUpdate();
                searchList.refreshVisibleRows(); // the rows may show other results now
            }
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

    if (docId === activeDocId) updateSearchViewMode();
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

    if (docId === activeDocId) updateViewMode();
};

globalThis.onDocumentAdded = function (docId) {
    console.log("Native: onDocumentAdded (int)", docId);
    refreshTabs(); // the table reloads when the file is loaded
};

// Native: the document was closed on request of its main view (e.g. Cancel
// while the file was loading)
globalThis.onDocumentClosed = function (docId) {
    console.log("Native: onDocumentClosed", docId);
    refreshTabs();
};

// scrollTo: null keeps the scroll position, "start" scrolls to the top,
// a number scrolls to that row
globalThis.reloadLogTable = function (scrollTo = null) {
    const logList = getMainViewList();
    if (logList) {
        console.log("Reloading log table", scrollTo !== null ? `(scroll to ${scrollTo})` : "");
        if (scrollTo === "start") logList.scrollTo(0, 0);
        logList.componentUpdate();
        logList.refreshVisibleRows(); // the rows may show other messages now
        // Posted after the navigation that render() may post when the number of items changes
        if (typeof scrollTo === "number") logList.post(() => logList.vlist?.navigateTo(scrollTo));

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
        scrollPosition: list ? (list.state.scrollPos || 0) : 0
    });
}
