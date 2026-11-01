import { $, $$ } from "@sciter";
import { VirtualDltTBody, VirtualMainViewTBody, VirtualSearchViewTBody } from "virtual-dlt-view.js";
import { QueryBuilder } from "query-builder.js";

globalThis.VirtualDltTBody = VirtualDltTBody;
globalThis.VirtualMainViewTBody = VirtualMainViewTBody;
globalThis.VirtualSearchViewTBody = VirtualSearchViewTBody;
globalThis.QueryBuilder = QueryBuilder;

let currentTheme = "light";
let lastProgress = -1;
let lastDocId = null;

document.on("ready", function () {
    console.log("Starting DLT Explorer UI...");
    initApp();
    initQueryBuilder();
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
    pollLoadingProgress();
}

function initQueryBuilder() {
    const builder = new QueryBuilder();
    builder.initMRU(5); // Хранить 5 последних
    $("#query-builder").append(builder);

    // Listen for search event from query builder
    // Using document.on because builder element (the reactor component) 
    // might be replaced/re-rendered, causing "Element was deleted" if bound directly.
    document.on("search", "#query-builder", (evt) => {
        console.log("query-builder.js: search event detected via document");
        const regexStr = evt.detail ? evt.detail.regex : builder.getCurrentRegex();
        console.log("query-builder.js: searching for: ", regexStr);
        Window.this.xcall("startSearch", regexStr);
        updateHistoryUI();
        $("#result-output").innerText = "Search started: /" + regexStr + "/";
    });
    document.on("click", "#btn-get-regex", () => {
        const regexStr = builder.getCurrentRegex();
        $("#result-output").innerText = "/" + regexStr + "/";

        // Можно сразу проверить валидность
        try {
            new RegExp(regexStr);
        } catch (e) {
            $("#result-output").innerText += "\n[Error]: Invalid Regex Logic!";
        }
    });

    // 2. Сохранение в MRU (обычно происходит при нажатии Enter или кнопки Поиск)
    function updateHistoryUI() {
        const selectMru = $("#select-mru");
        selectMru.innerHTML = ""; // Очистка
        let elOption = document.createElement("option");
        elOption.text = "History...";
        selectMru.append(elOption);

        const list = builder.getMRUList();
        list.forEach((json, index) => {
            // Генерируем краткое описание для UI (обрезаем JSON для красоты)
            // В идеале: распарсить JSON и сделать human-readable строку "Error & (500 | 404)"
            let label = `Query #${index + 1}`;
            let elOption = document.createElement("option");
            elOption.text = label;
            elOption.value = json;
            selectMru.append(elOption);
        });
    }

    document.on("click", "#btn-save-mru", () => {
        builder.saveCurrentToMRU();
        updateHistoryUI();
        $("#result-output").innerText = "Saved to History";
    });

    // 3. Загрузка из MRU
    document.on("change", "#select-mru", (evt, select) => {
        const json = select.value;
        if (json) {
            builder.loadCurrentFromJson(json);
            // Сбрасываем селект обратно в дефолт
            select.value = "";
        }
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

function setupEvents() {
    document.on("click", "#btn-open, #btn-add-tab", (evt) => {
        openFileAction();
    });

    document.on("click", "#btn-theme", () => {
        setTheme(currentTheme === "light" ? "dark" : "light");
    });

    document.on("click", "#btn-settings", openSettingsAction);

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
    Window.this.xcall("applyFilter", JSON.stringify(config));
    reloadLogTable();
}

function refreshTabs() {
    const info = Window.this.xcall("getWorkspaceInfo");
    if (!info) return;
    const docs = JSON.parse(info);
    const container = $("#tabs-container");

    const addBtn = $("#btn-add-tab");
    container.content(addBtn);

    for (let i = 0; i < docs.length; i++) {
        const doc = docs[i];
        const tab = <div class={doc.active ? "tab active" : "tab"} id={doc.id} draggable="true" data-index={i}>
            <span class="tab-name">{doc.name}</span>
            <span class="tab-close">×</span>
        </div>;
        container.append(tab);
    }

    updateViewMode();
}

function switchTab(docId) {
    const id = parseInt(docId);
    console.log("Requesting switch to doc (int):", id);
    Window.this.xcall("switchTab", id);
    refreshTabs();
    reloadLogTable(true);
}

function closeTab(docId) {
    const id = parseInt(docId);
    Window.this.xcall("closeTab", id);
    refreshTabs();
}

function updateViewMode() {
    const info = Window.this.xcall("getWorkspaceInfo");
    if (!info) return;
    const docs = JSON.parse(info);
    const activeDoc = docs.find(d => d.active);
    const currentDocId = activeDoc ? activeDoc.id : null;

    const table = getMainViewTable();
    const loading = getLoadingContainer();
    const empty = $("#empty-placeholder");

    if (docs.length === 0) {
        table.style.display = "none";
        loading.style.display = "none";
        empty.style.display = "flex";
        lastDocId = null;
        lastProgress = -1;
        return;
    }

    empty.style.display = "none";

    const isReady = Window.this.xcall("isDocReady");
    const progress01 = Window.this.xcall("getDocProgress");
    const progress = Math.round(progress01 * 100);

    if (!isReady) {
        table.style.display = "none";
        loading.style.display = "flex";
        $("#doc-load-progress").value = progress;
        $("#doc-load-status").innerText = `Loading DLT file... ${progress}%`;
    } else {
        table.style.display = "block"; // clear inline style to let it act as a table
        loading.style.display = "none";

        if (currentDocId !== lastDocId || (lastProgress !== 100 && lastProgress !== -1)) {
            console.log("View update: doc transition or ready state, docId: ", currentDocId);
            reloadLogTable(currentDocId !== lastDocId);
        }
    }
    lastProgress = isReady ? 100 : progress;
    lastDocId = currentDocId;
}

function updateSearchViewMode() {
    const table = getSearchViewTable();
    if (!table) return;

    const loading = $("#search-loading-container");
    const isReady = Window.this.xcall("isSearchReady");
    const progress01 = Window.this.xcall("getSearchProgress");
    const progress = Math.round(progress01 * 100);

    if (!isReady) {
        table.style.display = "none";
        loading.style.display = "flex";
        $("#search-view-progress").value = progress;
        $("#search-view-status").innerText = `Searching... ${progress}%`;
    } else {
        table.style.display = "block";
        loading.style.display = "none";

        // Reload search list if it's ready
        const searchList = getSearchViewList();
        if (searchList) {
            searchList.componentUpdate();
        }
    }
}

function pollLoadingProgress() {
    setInterval(() => {
        updateViewMode();
        updateSearchViewMode();
    }, 500);
}

globalThis.onDocumentAdded = function (docId) {
    console.log("Native: onDocumentAdded (int)", docId);
    refreshTabs();
    reloadLogTable();
};

globalThis.reloadLogTable = function (forceReset = false) {
    const logList = getMainViewList();
    if (logList) {
        console.log("Reloading log table", forceReset ? "(force reset)" : "");
        if (forceReset) logList.scrollTo(0, 0);
        logList.componentUpdate();

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
