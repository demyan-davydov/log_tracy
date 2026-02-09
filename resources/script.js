import { $, $$ } from "@sciter";
import { VirtualDltTBody } from "virtual-dlt-view.js";

globalThis.VirtualDltTBody = VirtualDltTBody;

let currentTheme = "light";
let lastProgress = -1;
let lastDocId = null;

document.on("ready", function () {
    console.log("Starting DLT Explorer UI...");
    initApp();
});

function initApp() {
    restoreSettings();
    setupEvents();
    refreshTabs();
    pollLoadingProgress();
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

    for (const doc of docs) {
        const tab = <div class={doc.active ? "tab active" : "tab"} id={doc.id}>
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

    const table = $("#log-table");
    const loading = $("#loading-container");
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
    const progress = Window.this.xcall("getDocProgress");

    if (!isReady) {
        table.style.display = "none";
        loading.style.display = "flex";
        $("#doc-load-progress").value = progress;
        $("#doc-load-status").innerText = `Loading DLT file... ${progress}%`;
    } else {
        table.style.display = "block";
        loading.style.display = "none";

        if (currentDocId !== lastDocId || (lastProgress !== 100 && lastProgress !== -1)) {
            console.log("View update: doc transition or ready state", currentDocId);
            reloadLogTable(currentDocId !== lastDocId);
        }
    }
    lastProgress = isReady ? 100 : progress;
    lastDocId = currentDocId;
}

function pollLoadingProgress() {
    setInterval(() => {
        updateViewMode();
    }, 500);
}

globalThis.onDocumentAdded = function (docId) {
    console.log("Native: onDocumentAdded (int)", docId);
    refreshTabs();
    reloadLogTable();
};

globalThis.reloadLogTable = function (forceReset = false) {
    const logList = $("#log-list");
    if (logList) {
        console.log("Reloading log table", forceReset ? "(force reset)" : "");
        if (forceReset) logList.scrollTo(0, 0);
        logList.componentUpdate();
    }
};

globalThis.getAppState = function () {
    const [left, top, width, height] = Window.this.box("xywh", "border", "screen", true);
    const list = $("#log-list");
    return JSON.stringify({
        windowRect: { left, top, width, height },
        scrollPosition: list ? (list.state.scrollPos || 0) : 0
    });
}
