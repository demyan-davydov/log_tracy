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
        }
    } catch (e) {
        console.error("Failed to restore settings:", e);
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
    const loading = tabContent.$(".loading-container");
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
    document.on("click", "#btn-open, #btn-add-tab", (evt) => {
        openFileAction();
    });

    document.on("click", "#btn-theme", () => {
        setTheme(currentTheme === "light" ? "dark" : "light");
    });

    document.on("click", "#btn-settings", openSettingsAction);

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
        Window.this.xcall("cancelOperation");
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

    document.on("click", ".tab", function (evt, tab) {
        const docId = parseInt(tab.id);
        if (evt.target.classList.contains("tab-close")) {
            closeTab(docId);
        } else {
            console.log("Tab clicked:", docId);
            switchTab(docId);
        }
    });

    // Mouse-based tab dragging (more reliable than HTML5 drag-and-drop in Sciter)
    let draggedTab = null;
    let dragStartX = 0;

    document.on("mousedown", ".tab", function (evt, tab) {
        // Ignore if clicking on close button
        if (evt.target.classList.contains("tab-close")) return;

        draggedTab = tab;
        dragStartX = evt.clientX;
        tab.classList.add("dragging");
        console.log("Mouse drag started on tab:", tab.id);
        return true; // Prevent default text selection
    });

    document.on("mousemove", function (evt) {
        if (!draggedTab) return;

        // Check if we've moved enough to consider it a drag
        if (Math.abs(evt.clientX - dragStartX) < 5) return;

        // Find which tab we're over
        const tabs = $$(".tab");
        for (const tab of tabs) {
            if (tab === draggedTab) continue;

            const rect = tab.getBoundingClientRect();
            if (evt.clientX >= rect.left && evt.clientX <= rect.right) {
                // Highlight the drop target
                tab.classList.add("drag-over");
            } else {
                tab.classList.remove("drag-over");
            }
        }
    });

    document.on("mouseup", function (evt) {
        if (!draggedTab) return;

        console.log("Mouse drag ended");

        // Find the drop target
        const tabs = $$(".tab");
        let dropTarget = null;
        for (const tab of tabs) {
            if (tab.classList.contains("drag-over")) {
                dropTarget = tab;
                break;
            }
        }

        if (dropTarget && dropTarget !== draggedTab) {
            const draggedId = parseInt(draggedTab.id);
            const targetIndex = parseInt(dropTarget.getAttribute("data-index"));

            console.log("Reordering tab", draggedId, "to index", targetIndex);
            Window.this.xcall("reorderTab", draggedId, targetIndex);
            refreshTabs();
        }

        // Clean up
        draggedTab.classList.remove("dragging");
        for (const tab of tabs) {
            tab.classList.remove("drag-over");
        }
        draggedTab = null;
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
//   docId -> { mainView, search: { state, progress, operation }, lost, path }
// mainView is the view shown by the main view machine (onMainViewChanged):
//   { status, canCancel, <fields of the view> }, see source/ui/main_view_fsm.d
// search (onDocumentEvent): state is a DocumentView.State name ("NotReady",
// "Ready", "BuildingIndex", "Error"), progress is 0..1, operation is the
// Document.Operation name that brought the view to this state ("None" if none).
// Snapshot comes from getWorkspaceInfo in refreshTabs().
const docStatus = new Map();
let activeDocId = null;

function findTab(docId) {
    return $(`#tabs-container > .tab[id="${docId}"]`);
}

// Exposes the status on the tab element for CSS:
//   main-status (status of the main view), search-state / search-progress
//   (progress is 0..100), lost
function applyTabStatus(tab, status) {
    tab.setAttribute("main-status", status.mainView ? status.mainView.status : "");
    tab.setAttribute("search-state", status.search.state);
    tab.setAttribute("search-progress", String(Math.round(status.search.progress * 100)));
    tab.setAttribute("lost", status.lost ? "true" : "false");
}

function refreshTabs() {
    const info = Window.this.xcall("getWorkspaceInfo");
    if (!info) return;
    const docs = JSON.parse(info);
    const container = $("#tabs-container");

    const addBtn = $("#btn-add-tab");
    container.content(addBtn);

    docStatus.clear();
    activeDocId = null;

    for (let i = 0; i < docs.length; i++) {
        const doc = docs[i];
        const status = { mainView: doc.mainView, search: doc.search, lost: doc.lost, path: doc.path };
        docStatus.set(doc.id, status);
        if (doc.active) activeDocId = doc.id;

        const tab = <div class={doc.active ? "tab active" : "tab"} id={doc.id} draggable="true" data-index={i}>
            <span class="tab-name">{doc.name}</span>
            <span class="tab-close">×</span>
        </div>;
        container.append(tab);
        // `tab` is a JSX node, not an element: apply the status to the element
        // that append() created from it
        applyTabStatus(container.lastElementChild, status);
    }

    updateViewMode();
    updateSearchViewMode();
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

// Texts of the main view statuses other than the table and the lost file
const mainViewTexts = {
    loadingFile: (vm) => `Loading DLT file... ${percent(vm.progress)}%`,
    loadFailed: () => "Failed to load DLT file",
    filtering: (vm) => `Filtering... ${percent(vm.progress)}%`,
    filterCancelled: () => "Filter cancelled",
    filterFailed: () => "Filter failed",
};

function percent(progress) {
    return Math.round(progress * 100);
}

// Renders the main view of the active document as its machine shows it
function updateViewMode() {
    const table = getMainViewTable();
    const loading = getLoadingContainer();
    const empty = $("#empty-placeholder");
    const lostView = $("#source-lost");
    const status = docStatus.get(activeDocId);
    const vm = status ? status.mainView : null;

    const showOnly = (shown) => {
        for (const element of [table, loading, empty, lostView])
            element.style.display = element !== shown ? "none"
                : element === table ? "block" // clear inline style to let it act as a table
                : "flex";
    };

    if (!vm) {
        showOnly(empty);
        shownDocId = null;
        shownDataVersion = null;
        return;
    }

    if (vm.status !== "sourceLost") $("#source-lost-error").innerText = "";

    if (vm.status === "ready") {
        showOnly(table);
        if (activeDocId !== shownDocId || vm.dataVersion !== shownDataVersion) {
            console.log("View update: doc", activeDocId, "content", vm.dataVersion);
            reloadLogTable(activeDocId !== shownDocId);
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
        const progress = $("#doc-load-progress");
        const hasProgress = vm.progress !== undefined;
        progress.style.display = hasProgress ? "" : "none";
        if (hasProgress) progress.value = percent(vm.progress);
        const text = mainViewTexts[vm.status];
        $("#doc-load-status").innerText = text ? text(vm) : vm.status;
        $("#btn-cancel-load").style.display = vm.canCancel ? "" : "none";
    }
    shownDocId = activeDocId;
    shownDataVersion = null; // the next table is reloaded, whatever its dataVersion
}

function updateSearchViewMode() {
    const table = getSearchViewTable();
    if (!table) return;

    const loading = $("#search-loading-container");
    const status = docStatus.get(activeDocId);
    if (status?.lost) {
        table.style.display = "none";
        loading.style.display = "flex";
        $("#search-view-progress").style.display = "none";
        $("#search-view-status").innerText = "The file is no longer available";
        $("#btn-cancel-search").style.display = "none";
        return;
    }
    $("#search-view-progress").style.display = "";
    // No document: an empty search result, same as a document before any search
    const search = status ? status.search : { state: "Ready", progress: 1 };
    const progress = Math.round(search.progress * 100);

    if (search.state !== "Ready") {
        const building = search.state === "BuildingIndex";
        table.style.display = "none";
        loading.style.display = "flex";
        $("#search-view-progress").value = progress;
        $("#search-view-status").innerText =
            building ? `Searching... ${progress}%`
            : search.state === "Error" ? "Search failed"
            : "Search cancelled";
        $("#btn-cancel-search").style.display = building ? "" : "none";
    } else {
        table.style.display = "block";
        loading.style.display = "none";

        // Reload search list if it's ready
        const searchList = getSearchViewList();
        if (searchList) {
            searchList.componentUpdate();
            searchList.refreshVisibleRows(); // the rows may show other results now
        }
    }
}

// Native: the file of a document can't be read any more (its disk was removed).
// The document stays open but unusable until it is reopened (Retry) or closed.
globalThis.onSourceLost = function (docId) {
    console.log("Native: onSourceLost", docId);
    const status = docStatus.get(docId);
    if (!status) return;
    status.lost = true;

    const tab = findTab(docId);
    if (tab) applyTabStatus(tab, status);

    // The main view comes from its machine, see onMainViewChanged
    if (docId === activeDocId) updateSearchViewMode();
};

// Native: a search operation changed the status of the search view.
// view is always "search"; state, progress and operation as in docStatus.
// Arrives for every document; only the active one is rendered in the views.
globalThis.onDocumentEvent = function (docId, view, state, progress, operation) {
    const status = docStatus.get(docId);
    if (!status) return; // tab not rendered yet: refreshTabs() will take the snapshot

    status[view] = { state, progress, operation };

    const tab = findTab(docId);
    if (tab) applyTabStatus(tab, status);

    if (state !== "BuildingIndex")
        console.log("Native: onDocumentEvent", docId, view, state);

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

globalThis.reloadLogTable = function (forceReset = false) {
    const logList = getMainViewList();
    if (logList) {
        console.log("Reloading log table", forceReset ? "(force reset)" : "");
        if (forceReset) logList.scrollTo(0, 0);
        logList.componentUpdate();
        logList.refreshVisibleRows(); // the rows may show other messages now

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
