// The panel of one open document: everything shown while its tab is active,
// the main view and the pages of the bottom panel: the search bar
// (search-bar.js) with the search results, the filters (filter-panel.js), the
// file info. Each document has its own panel, kept while the document is open
// and only hidden while another tab is shown
// (display: none keeps the rows, the scroll, the selection and the editor as
// they are). A hidden panel touches none of its elements but remembers what
// changed: show() brings it up to date. This module puts the parts together
// and keeps what the two tables (view-table.js) share: their columns, look
// and anchors, and how each follows the other.

import * as backend from "backend.js";
import * as platform from "platform.js";
import { allFiles, fileFilter } from "file-types.js";
import { anchorRefusalText } from "pane-commands.js";
import { SelectionFollower } from "row-selection.js";
import { rowLookStep, keptRowStep, searchViewKey } from "pane-state.js";
import { tr } from "i18n/i18n.js";
import { translateTree } from "i18n/dom.js";
import { fileInfoRows } from "file-info.js";
import { rememberJump } from "go-to-message.js";
import { showNotice } from "notice.js";
import { FilterPanel } from "filter-panel.js";
import { SearchBar } from "search-bar.js";
import { MainViewTable, SearchViewTable } from "view-table.js";

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
                    tab-content.css. The table itself is never hidden: one
                    hidden before it was ever laid out keeps the cells of
                    its rows 1px wide for good (Sciter). */}
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
                <table class="log-table main-view" fixed-layout="true">
                    <thead>
                        <tr>
                            <th class="col-anchor">⚓</th>
                            <th class="col-index">Index</th>
                            <th class="payload">Payload</th>
                        </tr>
                    </thead>
                    <tbody />
                </table>
                {/* The progress of what fills the table while it shows rows
                    (status-view.js showProgress), under it: no row is covered */}
                <div class="view-progress main-progress" style="display:none;">
                    <span class="view-progress-text"></span>
                    <progress value="0" max="100"></progress>
                    <button class="btn-cancel" data-tr="Cancel" />
                </div>
            </div>
        </section>

        {/* The bottom panel: pages over a strip of their tabs, below them.
            One page is shown, the one of the active tab (data-page) */}
        <section class="bottom-panel">
            <div class="bottom-page search-page" data-page="search">
                {/* The search bar: search-bar.js */}
                <div class="search-bar">
                    <div class="toolbar search-toolbar chip-search-toolbar">
                        <div class="chip-search chip-editor" tabindex="0"></div>
                        <button class="btn-chip-history" data-tr-title="Search history (↓)">▾</button>
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
                    <table class="log-table search-view" fixed-layout="true">
                        <thead>
                            <tr>
                                <th class="col-anchor">⚓</th>
                                <th class="col-index">Index</th>
                                <th class="payload">Payload</th>
                            </tr>
                        </thead>
                        <tbody />
                    </table>
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
                    <button class="btn-new-dlf" data-tr="New Filter" />
                    <button class="btn-dlf" data-tr="Load Filter" />
                    <div class="filter-message" style="display:none;"></div>
                </div>
                <div class="filter-sets"></div>
            </div>
            <div class="bottom-page file-info-page" data-page="file-info" style="display:none;">
                <dl class="file-info"></dl>
            </div>
            {/* Of the whole application, not of the document: empty for now */}
            <div class="bottom-page mcp-page" data-page="mcp" style="display:none;"></div>
            <div class="bottom-tabs">
                <div class="bottom-tab active" data-page="search">
                    <span class="bottom-tab-name" data-tr="Search" data-tr-context="noun" />
                </div>
                {/* Its dot: some rule works on the log (markFiltersTab) */}
                <div class="bottom-tab" data-page="filters">
                    <span class="bottom-tab-name" data-tr="Filters" />
                    <span class="bottom-tab-dot" />
                </div>
                <div class="bottom-tab" data-page="file-info">
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
    // @param splitters - { rows } the splitter starts with
    // @param host - what the panel asks of the window:
    //   closeTab(docId), refreshTabs(), theme() -> "light" | "dark",
    //   tableFontSize() -> % of the normal font of the tables,
    //   focus(take) - take() gives the keys to the panel: now, or when the
    //     press on a tab that shows it ends (press-focus.js)
    constructor(docId, container, splitters, host) {
        this.docId = docId;
        this.host = host;
        this.visible = false;
        this.jumps = []; // the history of Go to Message, the newest first: kept while the tab is open
        this.foundShownFor = null; // the search view (searchViewKey) the main rows show the found rows of
        this.appliedColumns = null; // JSON of the columns the tables show
        this.lastFocus = null; // focused in the panel last (focusin): it gets the keys again when shown
        this.textsStale = false; // the language changed while hidden: rendered again on show
        // What an anchor left to do while hidden, done on show: table -> "rebuild" (it
        // moved its rows) or "repaint" (its rows show the anchor)
        this.staleTables = new Map();
        this.bottomPage = "search"; // the page of the bottom panel shown (data-page)
        // How the rows look (Settings): { fontSize (%), singleLine }, as asked
        // and as the tables have it (null: not yet), see applyRowLook()
        this.rowLook = { fontSize: host.tableFontSize(), singleLine: host.singleLineRows() };
        this.appliedRowLook = null;
        // The first rows on screen to scroll back to after the look changed, by
        // table (ViewTable): { top } (see keptRowStep), see applyRowLook()
        this.keptRows = new Map();
        this.keptRowsFrame = false; // a frame is asked to scroll to them
        this.destroyed = false;

        container.append(renderPane(splitters));
        this.root = container.lastElementChild;
        this.root.style.display = "none";
        translateTree(this.root); // the skeleton in the language now
        // The views shown by the machines of the document (onMainViewChanged,
        // onSearchViewChanged) are theirs, see view-table.js
        const $ = selector => this.root.$(selector);
        this.main = new MainViewTable(docId, { table: $("table.main-view"), status: $(".main-status"),
            progress: $(".main-progress"), lost: $(".source-lost") });
        this.search = new SearchViewTable(docId, { table: $("table.search-view"), status: $(".search-status"),
            progress: $(".search-progress") });
        // A row the user selects in one table is shown in the other (followSelection,
        // the "rowchosen" events of the tables)
        this.follower = new SelectionFollower(list => this.followSelection(list));
        this.applyRowLook();

        this.filterPanel = new FilterPanel(this.root.$(".filter-page"), docId, {
            theme: () => host.theme(),
            setRuleColors: colors => { for (const list of this.lists) list.ruleColors = colors; },
            refreshRows: () => this.refreshRuleColors(),
            setActive: active => this.markFiltersTab(active),
        });
        this.searchBar = new SearchBar(this.root.$(".search-bar"), docId, {
            setMatchColors: colors => { for (const list of this.lists) list.matchColors = colors; },
        });
        this.bind();
    }

    get tables() {
        return [this.main, this.search];
    }

    get lists() {
        return this.tables.map(table => table.list);
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
        for (const table of this.tables) table.renderTexts();
        this.shownDescriptions = null; // its buttons in the new language too
        this.updateFileInfo();
    }

    // Shows the panel, up to date. `splitters` is the splitter of the panel
    // shown before (rowsState: its frameset state, see hide())
    // and the page of its bottom panel (bottomPage), null to keep its own.
    show(splitters) {
        this.root.style.display = "";
        this.visible = true;
        this.applyRowLook(); // changed in Settings while hidden
        this.scrollToKeptRows(); // of a hidden page or panel, see applyRowLook()
        if (splitters) {
            this.root.frameset.state = splitters.rowsState;
            if (splitters.bottomPage) this.selectBottomPage(splitters.bottomPage); // refresh() fills it
        }
        if (this.textsStale) { // the language changed while hidden: refresh() renders it all
            this.textsStale = false;
            this.filterPanel.invalidate();
        }
        for (const [table, todo] of this.staleTables) { // of an anchor applied while hidden
            if (todo === "repaint") {
                table.list.refreshVisibleRows();
                continue;
            }
            table.list.resetSelection();
            table.list.componentUpdate();
        }
        this.staleTables.clear();
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
    // display (pages of the bottom panel, status views)
    isDisplayed(element) {
        for (let el = element; el && el !== this.root; el = el.parentElement)
            if (el.style.display === "none") return false;
        return true;
    }

    // What takes the keys when nothing in the panel has them: the main table
    // if it shows its rows, otherwise the search editor if its page is shown,
    // otherwise the status view covering the main table
    defaultFocus() {
        if (this.shows(this.main)) return this.main.list;
        if (this.bottomPage === "search") return this.root.$(".chip-search");
        return this.main.shownCover() ?? this.main.list;
    }

    // True if `element` is on a page of the bottom panel that isn't shown
    inHiddenPage(element) {
        return this.root.$$(".bottom-page").some(page => page.style.display === "none" && isInside(element, page));
    }

    // Its splitter now: { rows } (a string, for a new panel) and its frameset
    // state { rowsState }
    splitterSizes() {
        return {
            rowsState: this.root.frameset?.state,
            rows: this.root.frameset?.state?.join(",") ?? this.root.getAttribute("rows"),
        };
    }

    // The height of the search (bottom) panel as it is shown:
    // { searchPanelHeight } ("230dip"). Only while the panel is shown: a hidden
    // one has no size. Its content box: a frameset sizes that, without the
    // padding and the borders.
    panelSizes() {
        const height = Math.round(this.root.$(".bottom-panel").state.box("height", "inner"));
        return { searchPanelHeight: `${height}dip` };
    }

    // Hides the panel. @returns the size of its splitter for the next panel
    // shown (splitterSizes(), panelSizes()) and the page of the bottom panel
    hide() {
        // A press on a tab has moved the focus to the strip already: lastFocus
        // keeps what focusin saw then
        const focused = document.$(":focus");
        if (isInside(focused, this.root)) this.lastFocus = focused;
        const splitters = { ...this.splitterSizes(), ...this.panelSizes(), bottomPage: this.bottomPage };
        this.visible = false;
        this.follower.cancel(); // not into a hidden panel
        this.root.style.display = "none";
        return splitters;
    }

    // The document is closed
    destroy() {
        this.destroyed = true; // a frame asked by applyRowLook() leaves the lists alone
        this.follower.cancel();
        this.keptRows.clear();
        this.searchBar.destroy();
        this.root.remove();
    }

    // Brings what is shown up to date with the document
    refresh() {
        // The rules first: the rows the columns re-render refer to them. The colors
        // of the rules and of the chips reach the tables only from the parts
        // (setRuleColors, setMatchColors), when they change
        this.filterPanel.ensureRendered();
        // The columns before the rows: a reload of a view renders them with these
        const changed = this.setColumns();
        this.updateMainView();
        this.updateSearchView();
        this.updateFileInfo();
        if (changed) this.renderShownRows();
    }

    // ---- the bottom panel ----

    // The page `name` of the bottom panel (its data-page), null if none
    bottomPageElement(name) {
        return this.root.$$(".bottom-page").find(page => page.getAttribute("data-page") === name) ?? null;
    }

    // Shows the page `name` of the bottom panel, up to date, and marks its tab
    showBottomPage(name) {
        if (!this.selectBottomPage(name)) return;
        this.updateFileInfo();
    }

    // Marks the tab of the Filters page with its dot while some rule works on the log
    markFiltersTab(active) {
        this.root.$(".bottom-tab[data-page=filters]").classList.toggle("marked", active);
    }

    // Shows the page `name` of the bottom panel as it is and marks its tab.
    // The focus leaves a page hidden. @returns false if there is no such page
    selectBottomPage(name) {
        const page = this.bottomPageElement(name);
        if (!page) return false;
        for (const element of this.root.$$(".bottom-page, .bottom-tab")) {
            const shown = element.getAttribute("data-page") === name;
            if (element.classList.contains("bottom-tab")) element.classList.toggle("active", shown);
            else element.style.display = shown ? "" : "none";
        }
        this.bottomPage = name;
        if (this.visible && this.inHiddenPage(document.$(":focus"))) this.defaultFocus().state.focus = true;
        this.scrollToKeptRows(); // of the list of this page, see applyRowLook()
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
        cell.append(<div class="descriptions-value">
            <span class={d.muted ? "descriptions-path muted" : "descriptions-path"}>{row.value}</span>
            {d.kind ? <span class="descriptions-kind">{d.kind}</span> : []}
        </div>);
        if (d.note) cell.append(<div class={d.error ? "descriptions-note error" : "descriptions-note"}>{d.note}</div>);
        cell.append(<div class="descriptions-buttons">
            <button class="btn-fibex-file">{tr("Load File...")}</button>
            <button class="btn-fibex-folder">{tr("Load Folder...")}</button>
            <button class="btn-fibex-unload">{tr("Unload")}</button>
        </div>);
        cell.$(".btn-fibex-unload").state.disabled = !d.canUnload;
        const refocus = focusedButton && cell.$("." + focusedButton.split(" ")[0]);
        if (refocus && !refocus.state.disabled) refocus.state.focus = true;
    }

    // Asks the backend to read the FIBEX at `path` for the log: onFileInfoChanged
    // tells how the read goes. Refused (a log that takes none): a notice by `button`
    loadDescriptions(button, path) {
        const error = backend.loadDescriptions(this.docId, path);
        if (error) showNotice(button, error);
    }

    // The font size of the tables (Settings), % of the normal one
    applyFontSize(percent) {
        this.rowLook = { ...this.rowLook, fontSize: percent };
        this.applyRowLook();
    }

    // Single-line rows (Settings): see .log-table.single-line in table.css
    applySingleLineRows(on) {
        this.rowLook = { ...this.rowLook, singleLine: on };
        this.applyRowLook();
    }

    // Gives the tables the look of the rows asked (rowLook); a hidden panel
    // gets it when shown (see rowLookStep). Rows of another height move the
    // content under the scroll position of a list, which is in pixels: rows
    // that got lower leave it past the end, with no row on screen. So the first
    // row on screen before the change is scrolled back to the top after it
    // (scrollToKeptRows), at the next frame: until then Sciter hasn't laid the
    // rows out anew (not even in a posted call) and a navigation would go by
    // the old geometry. A list whose row is kept already (a change before that
    // frame, a list of a hidden page) keeps it: its geometry is the old one.
    applyRowLook() {
        const look = this.rowLook;
        const step = rowLookStep(this.appliedRowLook, look, this.visible);
        if (!step.apply) return;
        if (step.keep)
            for (const table of this.tables)
                if (this.shows(table) && !this.keptRows.has(table))
                    this.keptRows.set(table, { top: table.list.firstVisibleIndex() });
        for (const { table } of this.tables) {
            table.style.fontSize = `${look.fontSize}%`;
            table.classList.toggle("single-line", look.singleLine);
        }
        this.appliedRowLook = { ...look };
        this.scrollToKeptRows();
    }

    // Scrolls the lists shown to the rows applyRowLook() kept, at the next
    // frame; a list of a hidden page or panel keeps its row until it is shown,
    // a table under a status view until it shows rows again (updateMainView, updateSearchView)
    scrollToKeptRows() {
        if (this.keptRowsFrame || this.keptRows.size === 0) return;
        this.keptRowsFrame = true;
        requestAnimationFrame(() => {
            this.keptRowsFrame = false;
            if (this.destroyed || !this.visible) return; // show() asks again
            for (const [table, kept] of this.keptRows) {
                const list = table.list;
                if (this.inHiddenPage(list)) continue; // selectBottomPage() asks again
                const step = keptRowStep(kept, table.shown, list.totalItems());
                if (step.wait) continue; // updateMainView(), updateSearchView() ask again
                this.keptRows.delete(table);
                if (step.target === null) continue;
                list.navigateTarget = step.target; // by the render componentUpdate() posts, see VirtualList
                list.componentUpdate();
            }
        });
    }

    // The layouts of the columns changed (Settings): the tables show them
    // when the panel is shown
    columnsChanged() {
        this.appliedColumns = null;
        if (this.visible && this.setColumns()) this.renderShownRows();
    }

    // The columns of the tables follow the format of the document, as the
    // layout of the format in Settings arranges them: sets them (the header
    // and what the rows are rendered with) when they change.
    // @returns true if they changed
    setColumns() {
        const json = backend.tableColumnsJson(this.docId);
        if (json === "[]" || json === this.appliedColumns) return false; // none yet, or unchanged
        this.appliedColumns = json;
        const columns = JSON.parse(json);
        for (const list of this.lists) list.setColumns(columns);
        return true;
    }

    // Renders the rows on screen again (e.g. with new columns). A table under
    // a status view renders its rows when the view shows them again.
    renderShownRows() {
        for (const { list } of this.tables.filter(table => this.shows(table))) {
            list.componentUpdate();
            list.refreshVisibleRows();
        }
    }

    // True if the rows of `table` (a ViewTable) are on screen: the panel is
    // shown and no status view covers it
    shows(table) {
        return this.visible && table.shown.dataVersion !== null;
    }

    // ---- the tables ----

    // Shows the main view as its machine shows it, see ViewTable.update()
    updateMainView() {
        const step = this.main.update();
        if (!step?.table) return;
        // reloaded main rows show what the search found now: not refreshed again for it
        if (step.reload) this.foundShownFor = searchViewKey(this.search.view);
        this.scrollToKeptRows(); // kept while a status view covered the table, see applyRowLook()
    }

    // Shows the search view likewise. The rows of the main view show what the
    // search found: more of them while it runs, other ones after a new search
    // or none after a reset. Only when the search view changed since they
    // were shown, not on every show of the panel.
    updateSearchView() {
        const step = this.search.update();
        if (step.table) this.scrollToKeptRows();
        const key = searchViewKey(this.search.view);
        if (key !== this.foundShownFor && this.shows(this.main)) {
            this.main.list.refreshVisibleRows();
            this.foundShownFor = key;
        }
    }

    // The message index of the current row of the main table, null if none:
    // where Go to Message starts
    currentMessageIndex() {
        return this.main.followedMessage();
    }

    // Go to Message, see MainViewTable.goToMessage()
    goToMessage(index) {
        if (this.main.goToMessage(index)) this.jumps = rememberJump(this.jumps, index);
    }

    // Shows the row selected in the table of `list` (followedRow) in the other
    // one, if that one has its message, also while a load, a filter or a
    // search fills either of them. The keyboard stays in `list`.
    followSelection(list) {
        const [from, to] = list === this.main.list ? [this.main, this.search] : [this.search, this.main];
        // its rows are being replaced; a load, a filter or a search filling them is followed
        if (!from.showsRowsOfView()) return;
        const index = from.followedMessage();
        if (index !== null) to.showMessage(index);
    }

    // ---- the rows: rule colors and anchors ----

    // The rows on screen refer to the rules again: a change of a rule may change
    // the rule with a color a row matches without filtering the view again
    refreshRuleColors() {
        for (const table of this.tables) if (this.shows(table)) table.list.refreshVisibleRows();
    }

    // Follows the rows an anchor changed (backend: { message, anchored, main,
    // search }): a table whose view gained or lost the row of the message
    // edits its rows in place, so the rows on screen stay where they are; the
    // other one repaints its rows, the row shows the new anchor
    // A hidden panel does it when shown (its rows can't be measured now): it
    // rebuilds the list of such a table, the other one keeps its rows and selection
    followAnchorRows(rows) {
        for (const [table, changed] of [[this.main, rows.main], [this.search, rows.search]]) {
            const list = table.list;
            if (!this.visible) {
                if (changed || !this.staleTables.has(table)) this.staleTables.set(table, changed ? "rebuild" : "repaint");
                continue;
            }
            if (!changed) {
                list.refreshVisibleRows();
                continue;
            }
            list.resetSelection(); // the selected positions show other rows now
            if (!list.followAnchor(rows.message, rows.anchored)) list.componentUpdate();
        }
    }

    // No room for another anchor (`full`): the empty anchor cells of both
    // tables show on hover that none can be set (anchors-full in table.css)
    markAnchorsFull(full) {
        for (const table of this.root.$$("table.log-table")) table.classList.toggle("anchors-full", full);
    }

    // ---- events of the elements of the panel ----

    bind() {
        const root = this.root;
        const on = (event, selector, handler) => root.on(event, selector, handler);

        on("click", ".bottom-tab", (evt, tab) => this.showBottomPage(tab.getAttribute("data-page")));

        // What has the keys in the panel, read when they come: by the time
        // hide() runs a press on a tab has moved them to the strip. A focus set
        // by the script bubbles here as "focus", not "focusin" (Sciter)
        const keysCame = evt => { if (isInside(evt.target, root)) this.lastFocus = evt.target; };
        root.on("focus", keysCame);
        root.on("focusin", keysCame);

        // Anchor column: toggles the anchor of the message in both views. Refused
        // by the backend at the anchor limit or for a file that is gone: a notice
        // by the cell says why. At the limit the tables are marked anchors-full:
        // their empty anchor cells show on hover that no anchor can be set. Taken
        // while a load, a filter or a search runs, the views list it a moment
        // later (onAnchorApplied): the rows on screen show the anchor at once.
        on("click", "table.log-table td.anchor", (evt, cell) => {
            const index = Number(cell.getAttribute("msg-index"));
            const anchored = cell.parentElement.getAttribute("has-anchor") === "true";
            const answer = backend.setAnchor(this.docId, index, !anchored);
            this.markAnchorsFull(answer.full);
            if (answer.refused) showNotice(cell, anchorRefusalText(answer), { at: "right", ms: 2500, untilLeave: true });
            else if (answer.rows) this.followAnchorRows(answer.rows);
            else for (const list of this.lists) list.refreshVisibleRows();
            return true; // don't change the row selection
        });

        // Posted: it may come after hide() cancelled the follower, not into a hidden panel
        on("rowchosen", "table.log-table > tbody", (evt, list) => {
            if (this.visible && !this.destroyed) this.follower.changed(list, evt.data?.delayed === true);
        });

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
        this.markAnchorsFull(false);
        for (const table of this.tables) table.reset();
        this.appliedColumns = null;
        this.searchBar.reset();
        this.filterPanel.reopened();
        this.host.refreshTabs(); // the reopened document starts loading
    }
}
