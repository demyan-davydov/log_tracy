// The panel of one open document: everything shown while its tab is active,
// the main view and the pages of the bottom panel: the search bar
// (search-bar.js) with the search results, the filters (filter-panel.js), the
// file info. Each document has its own panel, kept while the document is open
// and only hidden while another tab is shown
// (display: none keeps the rows, the scroll, the selection and the editor as
// they are). A hidden panel touches none of its elements but remembers what
// changed: show() brings it up to date. This module puts the parts together
// and keeps what the two tables (view-table.js, the log table of D) share:
// their anchors, and how each follows the other.

import * as backend from "backend.js";
import * as platform from "platform.js";
import { allFiles, fileFilter } from "file-types.js";
import { anchorRefusalText } from "pane-commands.js";
import { SelectionFollower } from "row-selection.js";
import { tr, trc } from "i18n/i18n.js";
import { translateTree } from "i18n/dom.js";
import { fileInfoRows } from "file-info.js";
import { rememberJump } from "go-to-message.js";
import { showNotice } from "notice.js";
import { FilterPanel } from "filter-panel.js";
import { SearchBar } from "search-bar.js";
import { MainViewTable, SearchViewTable } from "view-table.js";
import { activeTabOf, collapseStep } from "panel-sizes.js";

// True if `element` is `root` or inside it (and still in the document)
function isInside(element, root) {
    for (let el = element; el; el = el.parentElement) if (el === root) return true;
    return false;
}

// The elements of a panel; the size of its splitter is that of the panel
// shown last (see DocumentPane.show)
function renderPane(splitters) {
    return <frameset class="document-pane" rows={splitters.rows}>
        <section class="main-content">
            <div class="tab-content">
                {/* Status views over the table, see .status-view.overlay in
                    tab-content.css. The table fills its slot: the log table of
                    D is put in it when the panel is made (view-table.js). */}
                <div class="status-view overlay main-status" tabindex="0" style="display:none;">
                    <div class="status-body">
                        <div class="status-title"></div>
                        <div class="status-detail"></div>
                    </div>
                </div>
                <div class="status-view overlay source-lost" tabindex="0" style="display:none;">
                    <div class="status-body">
                        <div class="status-title" data-tr="The file is no longer available" />
                        <div class="status-detail status-path source-lost-path"></div>
                        <div class="status-detail status-error source-lost-error"></div>
                        <div class="status-actions">
                            <button class="btn-lost-retry" data-tr="Retry" />
                            <button class="btn-lost-close" data-tr="Close" />
                        </div>
                    </div>
                </div>
                <div class="log-table-slot main-view" />
                {/* The progress of what fills the table while it shows rows
                    (status-view.js showProgress), under it: no row is covered */}
                <div class="view-progress main-progress" style="display:none;">
                    <span class="view-progress-text"></span>
                    <progress value="0" max="100"></progress>
                    <button class="btn-cancel" data-tr="Cancel" />
                </div>
            </div>
        </section>

        {/* An explicit splitter: Sciter styles it (style.css), the default one is a hairline */}
        <splitter />

        {/* The bottom panel: pages over a strip of their tabs, below them.
            One page is shown, the one of the active tab (data-page); the
            container of the pages is hidden while the panel is collapsed */}
        <section class="bottom-panel">
            <div class="bottom-pages">
            <div class="bottom-page search-page" data-page="search">
                {/* The search bar: search-bar.js */}
                <div class="search-bar">
                    <div class="toolbar search-toolbar chip-search-toolbar">
                        <div class="chip-search chip-editor" tabindex="0"></div>
                        <button class="btn-chip-history icon-chevron-down" data-tr-title="Search history (↓)"></button>
                        <button class="btn-chip-search" data-tr="Search" />
                    </div>
                    <div class="chip-search-message" style="display:none;"></div>
                </div>

                <div class="search-body">
                    <div class="status-view overlay compact search-status" tabindex="0" style="display:none;">
                        <div class="status-body">
                            <div class="status-title"></div>
                            <div class="status-detail"></div>
                        </div>
                    </div>
                    <div class="log-table-slot search-view" />
                    {/* The progress of what fills the table while it shows rows
                        (status-view.js showProgress), under it: no row is covered */}
                    <div class="view-progress search-progress" style="display:none;">
                        <span class="view-progress-text"></span>
                        <progress value="0" max="100"></progress>
                        <button class="btn-cancel" data-tr="Cancel" />
                    </div>
                </div>
            </div>
            {/* The filters as chips: filter-panel.js */}
            <div class="bottom-page filter-page" data-page="filters" style="display:none;">
                <div class="toolbar filter-toolbar">
                    <button class="link-button btn-new-dlf" data-tr="New Filter..." />
                    <button class="link-button btn-dlf" data-tr="Load Filter..." />
                    <div class="filter-message" style="display:none;"></div>
                </div>
                <div class="filter-sets"></div>
            </div>
            <div class="bottom-page file-info-page" data-page="file-info" style="display:none;">
                <dl class="file-info"></dl>
            </div>
            {/* Of the whole application, not of the document: only a placeholder for now, not translated */}
            <div class="bottom-page mcp-page" data-page="mcp" style="display:none;">
                <div class="mcp-wip">Work in progress</div>
            </div>
            </div>
            <div class="bottom-tabs">
                {/* Collapses the panel to this strip, expands it again: its icon and title by renderCollapsed */}
                <div class="btn-bottom-panel" />
                {/* Its mark: a query is run (markTab) */}
                <div class="bottom-tab active" data-page="search">
                    <span class="bottom-tab-name" data-tr="Search" data-tr-context="noun" />
                    <span class="bottom-tab-mark" />
                </div>
                {/* Its mark: some rule works on the log (markTab) */}
                <div class="bottom-tab" data-page="filters">
                    <span class="tab-sep" />
                    <span class="bottom-tab-name" data-tr="Filters" />
                    <span class="bottom-tab-mark" />
                </div>
                <div class="bottom-tab" data-page="file-info">
                    <span class="tab-sep" />
                    <span class="bottom-tab-name" data-tr="File Info" />
                </div>
                {/* The tabs of the document on the left, those of the application on the right */}
                <div class="bottom-tabs-gap" />
                <div class="bottom-tab" data-page="mcp">
                    <span class="bottom-tab-name" data-tr="MCP Server" />
                </div>
            </div>
        </section>
    </frameset>;
}

export class DocumentPane {
    // @param docId - the id of the document in the backend
    // @param container - the element the panel is appended to
    // @param splitters - { rows } the splitter starts with; collapsed: the bottom
    //   panel starts collapsed, expanding to searchPanelHeight (panel-sizes.js)
    // @param host - what the panel asks of the window:
    //   closeTab(docId), refreshTabs(), theme() -> "light" | "dark",
    //   tableFontSize() -> % of the normal font of the tables,
    //   shortcutText(command) -> the text of the shortcut of a menu command ("⌘J"),
    //   bottomPanelChanged(shown) - the bottom panel was collapsed or expanded,
    //   focus(take) - take() gives the keys to the panel: now, or when the
    //     press on a tab that shows it ends (press-focus.js)
    constructor(docId, container, splitters, host) {
        this.docId = docId;
        this.host = host;
        this.visible = false;
        this.jumps = []; // the history of Go to Message, the newest first: kept while the tab is open
        this.lastFocus = null; // focused in the panel last (focusin): it gets the keys again when shown
        this.textsStale = false; // the language changed while hidden: rendered again on show
        this.bottomPage = "search"; // the page of the bottom panel shown (data-page)
        this.collapsed = splitters.collapsed === true; // the bottom panel shows only its tabs
        this.expandedHeight = splitters.searchPanelHeight ?? null; // what it expands to; null: as it was made
        this.destroyed = false;

        container.append(renderPane(splitters));
        this.root = container.lastElementChild;
        this.root.style.display = "none";
        translateTree(this.root); // the skeleton in the language now
        this.renderCollapsed();
        // The views shown by the machines of the document (onMainViewChanged,
        // onSearchViewChanged) are theirs, see view-table.js
        const $ = selector => this.root.$(selector);
        this.main = new MainViewTable(docId, { table: $(".log-table-slot.main-view"), status: $(".main-status"),
            progress: $(".main-progress"), lost: $(".source-lost"),
            cancelled: () => this.filterPanel.showResult("") });
        this.search = new SearchViewTable(docId, { table: $(".log-table-slot.search-view"), status: $(".search-status"),
            progress: $(".search-progress") });
        // A row the user selects in one table is shown in the other (followSelection): D tells the row chosen (`logTableRowChosen`)
        this.follower = new SelectionFollower(table => this.followSelection(table));
        for (const table of this.tables) table.logTable.rowChosen = (id, delayed) => this.rowChosen(table, delayed);

        this.filterPanel = new FilterPanel(this.root.$(".filter-page"), docId, {
            theme: () => host.theme(),
            setActive: active => this.markTab("filters", active),
        });
        this.searchBar = new SearchBar(this.root.$(".search-bar"), docId, active => this.markTab("search", active));
        this.bind();
    }

    get tables() {
        return [this.main, this.search];
    }

    // The machines of the document show other views (a snapshot of the
    // workspace, or an event of a view); rendered now if the panel is shown,
    // unless `render` is false (the caller refreshes the panel itself)
    setViews({ mainView, searchView, path }, render = true) {
        if (mainView !== undefined) this.main.view = mainView;
        if (searchView !== undefined) this.search.view = searchView;
        if (path !== undefined) this.main.path = path;
        if (!this.visible || !render) return;
        if (mainView !== undefined) {
            this.updateMainView();
            this.updateFileInfo(); // the records found so far, while the file loads
        }
        if (searchView !== undefined) this.updateSearchView();
    }

    // The language of the interface changed: the filters and the status shown
    // are rendered anew in it, now if the panel is shown, when it is shown
    // otherwise. Its skeleton is translated by translateTree of the document;
    // the tables show data; a message of the backend (an error) stays in the
    // language it came in, until the next one
    languageChanged() {
        if (!this.visible) {
            this.textsStale = true;
            return;
        }
        this.filterPanel.languageChanged();
        this.renderCollapsed(); // the title of its button
        for (const table of this.tables) table.renderTexts();
        this.shownDescriptions = null; // its buttons in the new language too
        this.updateFileInfo();
    }

    // Shows the panel, up to date. `splitters` is the splitter of the panel
    // shown before (rowsState: its frameset state, see hide()), whether its
    // bottom panel is collapsed and to what height it expands (collapsed,
    // searchPanelHeight) and the page of its bottom panel (bottomPage), null to keep its own.
    show(splitters) {
        this.root.style.display = "";
        this.visible = true;
        if (splitters) {
            this.root.frameset.state = splitters.rowsState;
            this.collapsed = splitters.collapsed === true;
            this.expandedHeight = splitters.searchPanelHeight ?? this.expandedHeight;
            if (splitters.bottomPage) this.selectBottomPage(splitters.bottomPage); // refresh() fills it
        }
        if (this.textsStale) { // the language changed while hidden: refresh() renders it all
            this.textsStale = false;
            this.filterPanel.invalidate();
        }
        this.renderCollapsed();
        this.hostSearchTable();
        this.refresh();
        this.takeKeys();
    }

    // Gives the keys to this panel, through the host: now, or when the press
    // on a tab that asked ends. To what had them in it last (lastFocus), unless
    // it is hidden since (a page of the bottom panel, a status view gone),
    // else to defaultFocus()
    takeKeys() {
        const focus = isInside(this.lastFocus, this.root) && this.isDisplayed(this.lastFocus)
            ? this.lastFocus : this.defaultFocus();
        // Still shown and inside when given: the press may end on another tab
        this.host.focus(() => {
            if (this.visible && !this.destroyed && isInside(focus, this.root)) focus.state.focus = true;
        });
    }

    // True if no element from `element` up to the panel is hidden by its own
    // display (pages of the bottom panel, their container while the panel is
    // collapsed, status views)
    isDisplayed(element) {
        for (let el = element; el && el !== this.root; el = el.parentElement)
            if (el.style.display === "none") return false;
        return true;
    }

    // True if the page `page` of the bottom panel isn't shown: not selected, or the panel collapsed
    pageHidden(page) {
        return !this.isDisplayed(page);
    }

    // What takes the keys when nothing in the panel has them: the main table
    // if it shows its rows, otherwise the search editor if its page is shown,
    // otherwise the status view covering the main table
    defaultFocus() {
        if (this.shows(this.main)) return this.main.logTable.element;
        if (!this.pageHidden(this.bottomPageElement("search"))) return this.root.$(".chip-search");
        return this.main.shownCover() ?? this.main.logTable.element;
    }

    // True if `element` is on a page of the bottom panel that isn't shown (all
    // of them while the panel is collapsed)
    inHiddenPage(element) {
        return this.root.$$(".bottom-page").some(page => this.pageHidden(page) && isInside(element, page));
    }

    // Its splitter now: { rows } (a string, for a new panel) and its frameset
    // state { rowsState }
    splitterSizes() {
        return {
            rowsState: this.root.frameset?.state,
            rows: this.root.frameset?.state?.join(",") ?? this.root.getAttribute("rows"),
        };
    }

    // Its splitter now (splitterSizes()), whether its bottom panel is collapsed and
    // its height: as measured, or, collapsed, the one it expands to (none known:
    // panelSizesOf gives the default). Only while the panel is shown: a hidden one has no size
    sizesNow() {
        const height = this.collapsed ? this.expandedHeight ?? undefined : this.measuredHeight();
        return { ...this.splitterSizes(), collapsed: this.collapsed, searchPanelHeight: height };
    }

    // The height of the bottom panel as it is shown ("230dip"): its content box,
    // as a frameset sizes it, without the padding and the borders
    measuredHeight() {
        return `${Math.round(this.root.$(".bottom-panel").state.box("height", "inner"))}dip`;
    }

    // Hides the panel. @returns the size of its splitter for the next panel
    // shown (sizesNow()) and the page of the bottom panel
    hide() {
        // A press on a tab has moved the focus to the strip already: lastFocus
        // keeps what focusin saw then
        const focused = document.$(":focus");
        if (isInside(focused, this.root)) this.lastFocus = focused;
        const splitters = { ...this.sizesNow(), bottomPage: this.bottomPage };
        this.visible = false;
        this.follower.cancel(); // not into a hidden panel
        this.root.style.display = "none";
        return splitters;
    }

    // The document is closed
    destroy() {
        this.destroyed = true;
        this.follower.cancel();
        for (const table of this.tables) table.logTable.destroy();
        this.searchBar.destroy();
        this.root.remove();
    }

    // Brings what is shown up to date with the document
    refresh() {
        this.filterPanel.ensureRendered();
        this.updateMainView();
        this.updateSearchView();
        this.updateFileInfo();
    }

    // ---- the bottom panel ----

    // The page `name` of the bottom panel (its data-page), null if none
    bottomPageElement(name) {
        return this.root.$$(".bottom-page").find(page => page.getAttribute("data-page") === name) ?? null;
    }

    // Shows the page `name` of the bottom panel, up to date, and marks its tab;
    // a collapsed panel is expanded
    showBottomPage(name) {
        if (!this.bottomPageElement(name)) return;
        this.setBottomPanelCollapsed(false);
        this.selectBottomPage(name);
        this.updateFileInfo();
    }

    // Collapses the bottom panel to the strip of its tabs (true) or expands it
    // to the height it had (false). The focus leaves the pages it hides
    setBottomPanelCollapsed(collapsed) {
        if (!this.visible || this.destroyed) return;
        const step = collapseStep(this, collapsed, collapsed ? this.measuredHeight() : null);
        if (!step) return;
        this.collapsed = step.collapsed;
        this.expandedHeight = step.expandedHeight;
        // The pages are shown before the panel gets its height back and hidden after it lost it (rowsFirst): a
        // tall panel without its pages puts the strip of the tabs at its top
        if (step.rowsFirst) this.root.frameset.state = step.rows;
        this.renderCollapsed();
        if (!step.rowsFirst) this.root.frameset.state = step.rows;
        this.hostSearchTable();
        if (collapsed && this.inHiddenPage(document.$(":focus"))) this.defaultFocus().state.focus = true;
        this.host.bottomPanelChanged(!collapsed);
    }

    // The search table out of the column host while its page isn't shown (another page selected, the panel
    // collapsed), back when it is: not seen, it would narrow the columns of the main table (a pane opened on
    // the Filters page, or collapsed, showed its main table empty, its rows blown up)
    hostSearchTable() {
        if (this.pageHidden(this.bottomPageElement("search"))) this.search.logTable.detach();
        else this.search.logTable.attach();
    }

    // The button and the menu command (View, Cmd+J / Ctrl+J)
    toggleBottomPanel() {
        this.setBottomPanelCollapsed(!this.collapsed);
    }

    // Shows whether the bottom panel is collapsed: the container of its pages
    // hidden, the class of the panel (the CSS keeps the height of the strip and
    // hides the splitter), no tab active while collapsed, the icon and the title
    // of its button
    renderCollapsed() {
        this.root.classList.toggle("collapsed", this.collapsed); // the CSS: the height of the strip, the splitter
        // The pages by the display of their container, as a page is hidden by its own (selectBottomPage): a class
        // on the pane that hid them by the CSS left the panel laid out without them now and then once expanded
        this.root.$(".bottom-pages").style.display = this.collapsed ? "none" : "";
        const active = activeTabOf(this);
        for (const tab of this.root.$$(".bottom-tab"))
            tab.classList.toggle("active", tab.getAttribute("data-page") === active);
        const button = this.root.$(".btn-bottom-panel");
        button.classList.toggle("icon-bottom-panel-shown", !this.collapsed);
        button.classList.toggle("icon-bottom-panel-hidden", this.collapsed);
        const shortcut = this.host.shortcutText("view.bottomPanel"); // null: the menu didn't come
        let title;
        if (shortcut) title = this.collapsed ? tr("Show Bottom Panel ({shortcut})", { shortcut })
            : tr("Hide Bottom Panel ({shortcut})", { shortcut });
        else title = this.collapsed ? tr("Show Bottom Panel") : tr("Hide Bottom Panel");
        button.setAttribute("title", title);
    }

    // Find (Cmd+F / Ctrl+F): the search page is shown, the caret at the end of the query.
    // Nothing if the focus is in the query already: the caret stays where it is
    focusSearch() {
        if (!this.visible || this.destroyed) return;
        // A collapsed panel is expanded whatever has the keys
        if (!this.collapsed && isInside(document.$(":focus"), this.root.$(".chip-search"))) return;
        this.showBottomPage("search");
        this.searchBar.editor.focusAtEnd();
    }

    // Lights the mark of the tab of the page `page`: a query is run (Search),
    // some rule works on the log (Filters)
    markTab(page, active) {
        this.root.$(`.bottom-tab[data-page=${page}]`).classList.toggle("marked", active);
    }

    // Shows the page `name` of the bottom panel as it is and marks its tab.
    // The focus leaves a page hidden. @returns false if there is no such page
    selectBottomPage(name) {
        const page = this.bottomPageElement(name);
        if (!page) return false;
        for (const element of this.root.$$(".bottom-page, .bottom-tab")) {
            const shown = element.getAttribute("data-page") === name;
            if (!element.classList.contains("bottom-tab")) element.style.display = shown ? "" : "none";
        }
        this.bottomPage = name;
        const active = activeTabOf(this);
        for (const tab of this.root.$$(".bottom-tab")) tab.classList.toggle("active", tab.getAttribute("data-page") === active);
        this.hostSearchTable();
        if (this.visible && this.inHiddenPage(document.$(":focus"))) this.defaultFocus().state.focus = true;
        return true;
    }

    // Fills the File Info page with what the backend knows of the document now,
    // if it is shown. Only the texts that changed are set: the rows are not
    // rebuilt by the progress of a load, a value being selected stays selected.
    updateFileInfo() {
        if (!this.visible || this.bottomPage !== "file-info") return;
        const rows = fileInfoRows(backend.documentInfo(this.docId), this.main.view?.status);
        const list = this.root.$(".file-info");
        if (list.children.length !== rows.length * 2) {
            list.innerHTML = "";
            this.shownDescriptions = null;
            for (const row of rows) {
                list.append(<dt>{row.label}</dt>);
                list.append(row.descriptions ? <dd class="descriptions" /> : <dd>{row.value}</dd>);
            }
        }
        rows.forEach((row, i) => {
            const label = list.children[2 * i], value = list.children[2 * i + 1];
            if (label.innerText !== row.label) label.innerText = row.label;
            if (row.descriptions) this.renderDescriptions(value, row);
            else if (value.innerText !== row.value) value.innerText = row.value;
        });
    }

    // The FIBEX row (fileInfoRows): what decodes the log, a note under it (a read
    // going on, why one failed), its buttons. Rendered anew only when it changed:
    // not by the progress of a load, a path being selected stays selected
    renderDescriptions(cell, row) {
        const key = JSON.stringify(row);
        if (this.shownDescriptions === key) return;
        this.shownDescriptions = key;
        const d = row.descriptions;
        // The button that had the keys keeps them: the buttons are made anew
        const focused = document.$(":focus");
        const focusedButton = focused && isInside(focused, cell) ? focused.className : null;
        cell.innerHTML = "";
        // JSX gives a description of the elements, not elements: built whole, then appended
        // One line: the FIBEX (or "None", in italics), its × (unload: only with a FIBEX),
        // the chip "Load file | folder" that loads one. A note goes under it; a failed load with no FIBEX
        // keeps its × on the note, the only way to drop the note
        const unload = <button class="link-button btn-fibex-unload icon-close" title={tr("Unload")}></button>;
        cell.append(<div class="descriptions-line">
            <span class={(d.muted ? "descriptions-path muted" : "descriptions-path") + (d.none ? " none" : "")}>{row.value}</span>
            {d.kind ? <span class="descriptions-kind">{d.kind}</span> : []}
            {d.hasPath ? unload : []}
            <span class="text-chip">
                <span class="text-chip-label">{tr("Load")}</span>
                <span class="text-chip-body">
                    <button class="link-button btn-fibex-file">{trc("object", "file...")}</button>
                    <span class="text-chip-sep">|</span>
                    <button class="link-button btn-fibex-folder">{trc("object", "folder...")}</button>
                </span>
            </span>
        </div>);
        if (d.note) {
            cell.append(<div class={d.error ? "descriptions-note error" : "descriptions-note"}>
                <span>{d.note}</span>
                {d.canUnload && !d.hasPath ? <button class="link-button btn-fibex-unload icon-close" title={tr("Unload")}></button> : []}
            </div>);
        }
        const refocus = focusedButton && cell.$("." + focusedButton.split(" ")[0]);
        if (refocus && !refocus.state.disabled) refocus.state.focus = true;
    }

    // Asks the backend to read the FIBEX at `path` for the log: onFileInfoChanged
    // tells how the read goes. Refused (a log that takes none): a notice by `button`
    loadDescriptions(button, path) {
        const error = backend.loadDescriptions(this.docId, path);
        if (error) showNotice(button, error);
    }

    // True if the rows of `table` (a ViewTable) are on screen: the panel is
    // shown and no status view covers it
    shows(table) {
        return this.visible && table.shown.dataVersion !== null;
    }

    // ---- the tables ----

    // Shows the main view as its machine shows it, see ViewTable.update()
    updateMainView() {
        this.main.update();
    }

    // Shows the search view likewise. The rows of the main view show what the search found: D draws them again when the search view
    // is shown anew (ui/log_table/document_model.d, DocumentRows), the script tells it nothing
    updateSearchView() {
        this.search.update();
    }

    // The message index of the current row of the main table, null if none:
    // where Go to Message starts
    currentMessageIndex() {
        return this.main.followedMessage();
    }

    // Go to Message, see MainViewTable.goToMessage()
    goToMessage(index) {
        if (!this.main.goToMessage(index)) return;
        this.jumps = rememberJump(this.jumps, index);
        this.follower.changed(this.main, false); // the search table follows it as a click
    }

    // A row the user selected in `table` (a ViewTable): the other table follows it at once (a click) or when it rests (a drag, the keys).
    // Posted by D: it may come after hide() cancelled the follower, not into a hidden panel
    rowChosen(table, delayed) {
        if (this.visible && !this.destroyed) this.follower.changed(table, delayed);
    }

    // Shows the row selected in `from` in the other table, if that one has its message, also while a load, a filter or a search fills either
    // of them. The keyboard stays in `from`.
    followSelection(from) {
        const to = from === this.main ? this.search : this.main;
        // its rows are being replaced; a load, a filter or a search filling them is followed
        if (!from.showsRowsOfView()) return;
        const index = from.followedMessage();
        if (index !== null) to.showMessage(index);
    }

    // ---- the rows: rule colors and anchors ----

    // Follows the rows an anchor changed (backend: { message, anchored, main,
    // search }): each table reads the row of the message again, also a hidden
    // one (it has the rows kept and draws when shown)
    followAnchorRows(rows) {
        for (const table of this.tables) table.logTable.anchorApplied(rows);
    }

    // ---- events of the elements of the panel ----

    bind() {
        const root = this.root;
        const on = (event, selector, handler) => root.on(event, selector, handler);

        on("click", ".bottom-tab", (evt, tab) => this.showBottomPage(tab.getAttribute("data-page")));
        on("click", ".btn-bottom-panel", () => this.toggleBottomPanel());

        // What has the keys in the panel, read when they come: by the time
        // hide() runs a press on a tab has moved them to the strip. A focus set
        // by the script bubbles here as "focus", not "focusin" (Sciter)
        const keysCame = evt => { if (isInside(evt.target, root)) this.lastFocus = evt.target; };
        root.on("focus", keysCame);
        root.on("focusin", keysCame);

        on("click", ".btn-lost-close", () => this.host.closeTab(this.docId));

        // The FIBEX of the log (File Info): a file, or a folder of them. The system
        // dialogs choose either files or folders, not both: a button each
        on("click", ".btn-fibex-file", (evt, button) => {
            const path = platform.chooseFileToOpen(fileFilter([[tr("FIBEX Files"), "*.xml"], allFiles()]));
            if (path) this.loadDescriptions(button, path);
        });
        on("click", ".btn-fibex-folder", (evt, button) => {
            const path = platform.chooseFolder();
            if (path) this.loadDescriptions(button, path);
        });
        on("click", ".btn-fibex-unload", (evt, button) => {
            const error = backend.unloadDescriptions(this.docId);
            if (error) showNotice(button, error);
        });

        on("click", ".btn-lost-retry", () => {
            // Reopens the file in the same tab; fails while the disk is still missing
            const retryStart = Date.now();
            const error = backend.retryDocument(this.docId);
            const retryTime = Date.now() - retryStart;
            if (error) {
                console.log(`Retry failed after ${retryTime} ms: ${error}`);
                this.main.lostError(tr("Still unavailable: {error}", { error }));
                return;
            }
            const refreshStart = Date.now();
            this.reopened();
            console.log(`Retry: xcall ${retryTime} ms, views refresh ${Date.now() - refreshStart} ms`);
        });
    }

    // The file was opened anew in this tab (Retry, or a file truncated by a rotation):
    // a new document with the same id. Its first rows start at the top, its filters are
    // restored (no message of a command before), it has no search and no anchors yet
    reopened() {
        for (const table of this.tables) table.reset();
        this.searchBar.reset();
        this.filterPanel.reopened();
        this.host.refreshTabs(); // the reopened document starts loading
    }
}
