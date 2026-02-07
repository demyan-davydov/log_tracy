import { $, $$ } from "@sciter";

//const ROW_HEIGHT = 20; // Exact pixel height of a row (must match CSS)

document.on("ready", function () {
    console.log("Starting Virtual List...");
    initVirtualList();
});

let totalLogs = 0;

function initVirtualList() {
    const view = $("#log-view");
    const table = $("#log-table");

    // Actions
    function openFileAction() {
        const fn = Window.this.selectFile({
            mode: "open",
            filter: "DLT Files (*.dlt)|*.dlt|All Files (*.*)|*.*"
        });
        if (fn) {
            console.log("File selected:", fn);
            Window.this.xcall("openFile", fn);
            reloadLogTable();
        }
    }

    let currentTheme = "light";

    function setTheme(theme) {
        // Robust switching method: remove the old style element and create a new one.
        const oldStyle = $("#theme-style");
        if (oldStyle) oldStyle.remove();

        const newStyle = document.createElement("style");
        newStyle.id = "theme-style";
        newStyle.setAttribute("src", theme === "dark" ? "theme-dark.css" : "theme-light.css");

        // Insert before the main style to ensure proper variable definition before usage
        // Note: In head, prepend works well if other styles follow.
        document.head.prepend(newStyle);

        currentTheme = theme;
        console.log("Theme set to:", theme);

        // Force update just in case
        Window.this.update();
    }

    function openSettingsAction() {
        // Open modal window
        const result = Window.this.modal({
            url: "settings.htm",
            alignment: "center", // relative to parent
            parameters: { theme: currentTheme } // pass current state
        });

        console.log("Settings Closed. Result:", JSON.stringify(result));

        if (result && result.theme) {
            setTheme(result.theme);
        }
    }

    // Expose to global scope for Native Callbacks
    globalThis.openFileAction = openFileAction;
    globalThis.openSettingsAction = openSettingsAction;
    globalThis.setTheme = setTheme;


    // Global Key Handler
    // Attach to the window's document object to catch bubbly events
    document.on("keydown", function (evt) {
        console.log(`Key Event: code=${evt.code}, meta=${evt.metaKey}, ctrl=${evt.ctrlKey}`);

        // MacOS: metaKey (Command), Windows/Linux: ctrlKey
        const modifier = evt.metaKey || evt.ctrlKey;

        if (modifier && (evt.code === "KeyO" || evt.code === "KeyF")) {
            console.log("Hotkey detected: Open File");
            openFileAction();
            return true; // Consume event
        }
    });

    // Listen for file open
    $("#btn-open").on("click", openFileAction);

    // Toggle Theme
    $("#btn-theme").on("click", () => {
        const newTheme = currentTheme === "light" ? "dark" : "light";
        setTheme(newTheme);
    });

    // Load FIBEX
    $("#btn-fibex").on("click", () => {
        const fn = Window.this.selectFile({
            mode: "open",
            filter: "XML Files (*.xml)|*.xml|All Files (*.*)|*.*"
        });
        if (fn) {
            Window.this.xcall("loadFibex", fn);
            reloadLogTable(); // Reload to refresh descriptions
        }
    });


    // Settings Dialog
    $("#btn-settings").on("click", openSettingsAction);

    // Menu Item Listeners (delegated via document)
    document.on("click", "#menu-open", openFileAction);
    document.on("click", "#menu-settings", openSettingsAction);

    // Unified Filter Logic
    const inputs = ["#filter-ecu", "#filter-app", "#filter-ctx", "#filter-payload"];

    function applyFilters() {
        const config = {
            ecuId: $("#filter-ecu").value,
            appId: $("#filter-app").value,
            ctxId: $("#filter-ctx").value,
            payloadRegex: $("#filter-payload").value
        };
        console.log("Applying Filters:", JSON.stringify(config));
        Window.this.xcall("applyFilter", JSON.stringify(config));
        reloadLogTable();
    }

    // Attach listeners
    for (const sel of inputs) {
        const el = $(sel);
        if (el) el.on("change", applyFilters); // Trigger on commit (enter or lost focus)
    }

    // Clear Filters
    $("#btn-clear-filters").on("click", () => {
        for (const sel of inputs) {
            $(sel).value = "";
        }
        applyFilters();
    });

    // Native Virtual List Setup
    const logList = $("#log-list");
    const logView = $("#log-view"); // Keep for context if needed

    // Handle contentrequired event from Sciter's virtual-list behavior
    logList.on("contentrequired", function (evt) {
        // evt.data contains: where (int), start (int), length (int)
        const where = evt.data.where;
        const start = evt.data.start || 0;
        const length = evt.data.length || 0;

        // console.log(`Virtual list requesting: where=${where}, start=${start}, length=${length}, totalLogs=${totalLogs}`);
        // console.log(`Virtual list requesting: where=${where}, start=${start}, length=${length}, totalLogs=${totalLogs}`);

        // Fetch data from backend
        const jsonStr = Window.this.xcall("getLogItems", start, length);
        let items = [];
        try {
            items = JSON.parse(jsonStr);
        } catch (e) {
            console.error("Error parsing log items:", e);
        }

        // Generate rows
        updateTableContent(logList, items, where);

        // Return morebefore/moreafter to tell virtual-list about total size
        return {
            morebefore: start,
            moreafter: Math.max(0, totalLogs - start - items.length)
        };
    });

    // Resize handler to update virtual list
    logView.on("sizechange", () => {
        // Virtual list handles this automatically
    });

    // Tab switching logic
    const tabs = $$(".tab");
    for (const tab of tabs) {
        tab.on("click", () => {
            console.log("Tab clicked:", tab.innerText);
            tabs.forEach(t => t.classList.remove("active"));
            tab.classList.add("active");
            Window.this.xcall("onTabClicked", tab.innerText);
        });
    }
    // ... (existing code) ...

    // Restore Settings
    try {
        const settingsStr = Window.this.xcall("getSettings");
        if (settingsStr) {
            const settings = JSON.parse(settingsStr);
            if (settings.theme) {
                setTheme(settings.theme);
            }

            // If there is an active file, maybe we should restore its scroll?
            // The table is empty at start, so we can't scroll yet.
            // But we can store it to use later when content loads.
            if (settings.activeFile && settings.files) {
                const fileState = settings.files.find(f => f.path === settings.activeFile);
                if (fileState && fileState.scrollPosition > 0) {
                    // Store for later use in reloadLogTable or updateTableContent
                    globalThis.initialScrollPos = fileState.scrollPosition;
                }
            }
        }
    } catch (e) {
        console.error("Failed to load settings from D", e);
    }
}

globalThis.getScrollPosition = function () {
    const list = $("#log-list");
    if (!list) return 0;
    // Sciter virtual-list property 'firstVisibleItem' (check docs, might be scroll-pos)
    // Actually, for behavior: virtual-list, 'firstIndex' or similar might differ.
    // If not standard, we can return list.scroll-top / ROW_HEIGHT?
    // Let's assume standard atomic scroll for now or use scroll state.
    // scrollTop is pixel offset.
    return list.state.scrollPos || 0;
    // Note: state.scrollPos might be pixels. virtual-list handles items.
    // If we simply store scrollTop, we can restore it.
}

globalThis.getAppState = function () {
    console.log("getAppState called");

    const [left, top, width, height] = Window.this.box("xywh", "border", "screen");
    const list = $("#log-list");
    // const activeTab = $(".tab.active");

    return JSON.stringify({
        windowRect: { left, top, width, height },
        scrollPosition: list ? (list.state.scrollPos || 0) : 0
        // activeFile: activeTab ? activeTab.innerText : "" 
    });
}

function updateTableContent(logList, items, where) {
    const rows = items.map(item =>
        <tr>
            <td>{item.index}</td>
            <td>{item.offset}</td>
            <td>{item.timestamp}</td>
            <td>{item.ecu}</td>
            <td>{item.appId}</td>
            <td>{item.ctxId}</td>
            <td>{item.length}</td>
            <td>{item.type}</td>
            <td class={`level-${item.level.toLowerCase()}`}>{item.level}</td>
            <td>{item.payload}</td>
        </tr>
    );

    const tbody = logList; // This is the element with behavior: virtual-list

    if (where === 0) { // Replace (jump)
        tbody.content(rows);
    } else if (where > 0) { // Append (down)
        tbody.append(rows);
    } else if (where < 0) { // Prepend (up)
        tbody.prepend(rows);
    } else {
        // Fallback for initial load if where is undefined/unexpected
        tbody.content(rows);
    }
}

function reloadLogTable() {
    totalLogs = Window.this.xcall("getLogCount");
    console.log("Total Logs:", totalLogs);

    const logList = $("#log-list");

    if (logList) {
        logList.clear();
        logList.scrollTo(0, 0);

        if (totalLogs > 0) {
            // Prime the list manually to kickstart the virtual behavior
            const start = 0;
            const length = 100; // Fetch enough to fill the view
            const jsonStr = Window.this.xcall("getLogItems", start, length);

            let items = [];
            try {
                items = JSON.parse(jsonStr);
            } catch (e) {
                console.error("Error parsing items", e);
            }

            updateTableContent(logList, items, 0);

            // Should we force a scroll event?
            // Usually setting content is enough if the scrollbar appears.
        }
    }
}

