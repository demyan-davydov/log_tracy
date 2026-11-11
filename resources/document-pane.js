// The panel of one open document: everything shown while its tab is active,
// the main view and the pages of the bottom panel: the search bar
// (search-bar.js) with the search results, the filters (filter-panel.js), the
// file info. Each document has its own panel, kept while the document is open
// and only hidden while another tab is shown
// (display: none keeps the rows, the scroll, the selection and the editor as
// they are). A hidden panel touches none of its elements but remembers what
// changed: show() brings it up to date. This module puts the parts together
// and keeps the tables: their views, columns, look, selection and anchors.

import * as backend from "backend.js";
import { anchorRefusalText } from "pane-commands.js";
import { rowLayout } from "cell-format.js";
import { followedRow, SelectionFollower } from "row-selection.js";
import { noTable, tableStep, rowLookStep, keptRowStep, searchViewKey, jumpStep } from "pane-state.js";
import { tr } from "i18n/i18n.js";
import { translateTree } from "i18n/dom.js";
import { fileInfoRows } from "file-info.js";
import { rememberJump } from "go-to-message.js";
import { showNotice } from "notice.js";
import { FilterPanel } from "filter-panel.js";
import { SearchBar } from "search-bar.js";
import { mainViewStatus, searchViewStatus, showProgress, showStatus } from "status-view.js";

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
                        <progress value="0" max="100"></progress>
                        <div class="status-detail"></div>
                        <div class="status-actions">
                            <button class="btn-cancel" data-tr="Cancel" />
                        </div>
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
                            <progress value="0" max="100"></progress>
                            <div class="status-detail"></div>
                            <div class="status-actions">
                                <button class="btn-cancel" data-tr="Cancel" />
                            </div>
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

// Reloads the rows of `list` after its data changed. scrollTo: null keeps the
// scroll position, "start" scrolls to the top, a number scrolls to that row
export function reloadList(list, scrollTo = null) {
    // From the top: other content, maybe still being filled. The rows of before
    // go now, not with the render componentUpdate() posts: the table may be
    // uncovered already, and would show them until then
    if (scrollTo === "start") {
        list.clear();
        list.scrollTo(0, 0);
    }
    // Carried out by the render that componentUpdate() posts, see VirtualList.navigateTarget
    if (scrollTo !== null) list.navigateTarget = scrollTo;
    list.componentUpdate();
    list.refreshVisibleRows(); // the rows may show other messages now
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
        // The views shown by the machines of the document (onMainViewChanged,
        // onSearchViewChanged): { status, canCancel, <fields of the view> },
        // see source/ui/main_view_fsm.d and source/ui/search_view_fsm.d
        this.mainView = null;
        this.searchView = null;
        this.path = "";
        this.visible = false;
        this.mainShown = noTable; // what the tables show, see pane-state.js
        this.jumps = []; // the history of Go to Message, the newest first: kept while the tab is open
        this.searchShown = noTable;
        this.foundShownFor = null; // the search view (searchViewKey) the main rows show the found rows of
        this.appliedColumns = null; // JSON of the columns the tables show
        this.lastFocus = null; // focused in the panel last (focusin): it gets the keys again when shown
        this.coveredFocus = new Set(); // the lists a status view took the focus from
        this.textsStale = false; // the language changed while hidden: rendered again on show
        this.mainStatus = null; // the view a status over the table shows, null: none
        this.searchStatus = null;
        this.mainRunning = null; // the view the progress under the table shows, null: none
        this.searchRunning = null;
        this.bottomPage = "search"; // the page of the bottom panel shown (data-page)
        // How the rows look (Settings): { fontSize (%), singleLine }, as asked
        // and as the tables have it (null: not yet), see applyRowLook()
        this.rowLook = { fontSize: host.tableFontSize(), singleLine: host.singleLineRows() };
        this.appliedRowLook = null;
        // The first rows on screen to scroll back to after the look changed, by
        // list: { top } (see keptRowStep), see applyRowLook()
        this.keptRows = new Map();
        this.keptRowsFrame = false; // a frame is asked to scroll to them
        this.destroyed = false;

        container.append(renderPane(splitters));
        this.root = container.lastElementChild;
        this.root.style.display = "none";
        translateTree(this.root); // the skeleton in the language now
        this.mainTable = this.root.$("table.main-view");
        this.searchTable = this.root.$("table.search-view");
        // The rows they ask the backend for are those of this document
        this.mainList = this.mainTable.$("tbody");
        this.searchList = this.searchTable.$("tbody");
        this.mainList.docId = docId;
        this.searchList.docId = docId;
        // A table resized renders as many rows as it can show (fitWindow).
        // Subscribed with on(): an "on sizechange" method of the class isn't called
        for (const list of this.lists) list.on("sizechange", () => list.fitWindow());
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

    get lists() {
        return [this.mainList, this.searchList];
    }

    // The machines of the document show other views (a snapshot of the
    // workspace, or an event of a view); rendered now if the panel is shown,
    // unless `render` is false (the caller refreshes the panel itself)
    setViews({ mainView, searchView, path }, render = true) {
        if (mainView !== undefined) this.mainView = mainView;
        if (searchView !== undefined) this.searchView = searchView;
        if (path !== undefined) this.path = path;
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
        if (this.mainStatus) showStatus(this.root.$(".main-status"), this.mainStatus, mainViewStatus);
        if (this.searchStatus) showStatus(this.root.$(".search-status"), this.searchStatus, searchViewStatus);
        if (this.mainRunning) showProgress(this.root.$(".main-progress"), this.mainRunning, mainViewStatus);
        if (this.searchRunning) showProgress(this.root.$(".search-progress"), this.searchRunning, searchViewStatus);
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
        if (this.shows(this.mainList)) return this.mainList;
        if (this.bottomPage === "search") return this.root.$(".chip-search");
        return [this.root.$(".main-status"), this.root.$(".source-lost")]
            .find(view => view.style.display === "block") ?? this.mainList;
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
        const rows = fileInfoRows(backend.documentInfo(this.docId), this.mainView?.status);
        const list = this.root.$(".file-info");
        const cells = rows.flatMap(({ label, value }) => [label, value]);
        if (list.children.length !== cells.length) {
            list.innerHTML = "";
            for (const { label, value } of rows) {
                list.append(<dt>{label}</dt>);
                list.append(<dd>{value}</dd>);
            }
            return;
        }
        cells.forEach((text, i) => {
            const cell = list.children[i];
            if (cell.innerText !== text) cell.innerText = text;
        });
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
            for (const list of this.lists)
                if (this.shows(list) && !this.keptRows.has(list))
                    this.keptRows.set(list, { top: list.firstVisibleIndex() });
        for (const table of [this.mainTable, this.searchTable]) {
            table.style.fontSize = `${look.fontSize}%`;
            table.classList.toggle("single-line", look.singleLine);
        }
        this.appliedRowLook = { ...look };
        this.scrollToKeptRows();
    }

    // Scrolls the lists shown to the rows applyRowLook() kept, at the next
    // frame; a list of a hidden page or panel keeps its row until it is shown,
    // a table under a status view until it shows rows again (reloadTable)
    scrollToKeptRows() {
        if (this.keptRowsFrame || this.keptRows.size === 0) return;
        this.keptRowsFrame = true;
        requestAnimationFrame(() => {
            this.keptRowsFrame = false;
            if (this.destroyed || !this.visible) return; // show() asks again
            for (const [list, kept] of this.keptRows) {
                if (this.inHiddenPage(list)) continue; // selectBottomPage() asks again
                list.fitWindow(); // rows of a smaller font: more of them on screen
                const step = keptRowStep(kept, this.shownOf(list), list.totalItems());
                if (step.wait) continue; // reloadTable() asks again
                this.keptRows.delete(list);
                if (step.target === null) continue;
                list.navigateTarget = step.target; // by the render componentUpdate() posts, see VirtualList
                list.componentUpdate();
            }
        });
    }

    // What `list` shows, see tableStep
    shownOf(list) {
        return list === this.mainList ? this.mainShown : this.searchShown;
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
        for (const list of this.lists) {
            if (!this.shows(list)) continue;
            list.componentUpdate();
            list.refreshVisibleRows();
        }
    }

    // True if the rows of `list` are on screen: the panel is shown and no
    // status view covers its table
    shows(list) {
        return this.visible && this.shownOf(list).dataVersion !== null;
    }

    // ---- main view ----

    // Shows the main view as its machine shows it: the table (with the
    // progress of a filter filling it), the lost file or the status of what
    // the document is doing
    updateMainView() {
        const vm = this.mainView;
        if (!vm) return;
        const loading = this.root.$(".main-status");
        const lost = this.root.$(".source-lost");
        if (vm.status !== "sourceLost") this.root.$(".source-lost-error").innerText = "";
        const step = tableStep(this.mainShown, vm, () => this.mainList.totalItems());
        this.mainShown = step.shown;
        const cover = step.table ? null : vm.status === "sourceLost" ? lost : loading;
        this.mainRunning = this.showRunning(".main-progress", step.running ? vm : null, mainViewStatus,
            cover ?? this.mainList);
        this.mainStatus = cover === loading ? vm : null;
        for (const element of [loading, lost])
            element.style.display = element === cover ? "block" : "none";
        this.takeFocus(this.mainList, cover, [loading, lost]);
        if (step.table) {
            this.reloadTable(this.mainList, step);
        } else if (vm.status === "sourceLost") {
            this.root.$(".source-lost-path").innerText = this.path || "";
        } else {
            showStatus(loading, vm, mainViewStatus);
        }
    }

    // A status view covering the table of `list` takes the focus from it: the
    // keys must not scroll or copy rows of a view being rebuilt. The table
    // gets it back when it is uncovered, if the focus didn't go elsewhere.
    // The focus left in a view that covered it (`covers`: on the view or on
    // its Cancel, tabbed to or pressed) goes to the table too: the view is
    // hidden, the keys would go nowhere.
    takeFocus(list, cover, covers) {
        const focused = document.$(":focus");
        if (cover) {
            if (!isInside(focused, list)) return;
            cover.state.focus = true;
            this.coveredFocus.add(list);
            return;
        }
        const taken = this.coveredFocus.delete(list);
        if (covers.some(view => isInside(focused, view)) || (taken && !focused)) list.state.focus = true;
    }

    // The message index of the current row of the main table (followedRow),
    // null if none: where Go to Message starts
    currentMessageIndex() {
        const row = followedRow(this.mainList.selection);
        const index = row === null ? NaN : Number(this.mainList.itemAt(row)?.[rowLayout.messageIndex]);
        return Number.isFinite(index) ? index : null;
    }

    // Go to Message: the row of message `index` in the main table, or of the
    // first one after it the table shows (hidden by the filters), else its
    // last row: selected, the keyboard in the table, near the top unless it is
    // on screen (jumpStep); the search table follows it as a click. Nothing
    // while the table shows no rows (a status view covers it).
    goToMessage(index) {
        if (!this.mainShown.loaded) return;
        const list = this.mainList;
        const step = jumpStep({ status: "ready" }, () => backend.mainViewNearestPosition(this.docId, index),
            { visibleRange: list.wholeRowsRange(), visibleRows: list.visibleRowCount() });
        if (!step) return;
        this.jumps = rememberJump(this.jumps, index);
        list.showRow(step);
        list.state.focus = true;
        list.rowChosen(false);
    }

    // Shows the row selected in the table `from` (followedRow) in the other
    // one, if that one has its message: selected there, near the top unless it
    // is on screen (jumpStep). The keyboard stays in `from`.
    followSelection(from) {
        const fromMain = from === this.mainList;
        if ((fromMain ? this.mainView : this.searchView)?.status !== "ready") return; // its rows are being replaced
        const row = followedRow(from.selection);
        const msgIndex = row === null ? NaN : Number(from.itemAt(row)?.[rowLayout.messageIndex]);
        if (!Number.isFinite(msgIndex)) return;
        const [list, vm, positionOf] = fromMain
            ? [this.searchList, this.searchView, backend.searchViewPosition]
            : [this.mainList, this.mainView, backend.mainViewPosition];
        const step = jumpStep(vm, () => positionOf(this.docId, msgIndex),
            { visibleRange: list.wholeRowsRange(), visibleRows: list.visibleRowCount() });
        if (step) list.showRow(step);
    }

    // Shows the progress `selector` under a table for the view `vm` of a filter
    // or a search filling it, hides it for null: the focus its Cancel took
    // when pressed goes to `next` (the table, or the status view shown instead)
    // then, not left on a hidden button. @returns vm
    showRunning(selector, vm, status, next) {
        const strip = this.root.$(selector);
        const focused = !vm && isInside(document.$(":focus"), strip);
        strip.style.display = vm ? "" : "none";
        if (focused) next.state.focus = true;
        if (vm) showProgress(strip, vm, status);
        return vm;
    }

    reloadTable(list, step) {
        if (step.resetSelection) list.resetSelection(); // the rows are other messages now
        if (step.reload) reloadList(list, step.reload === "start" ? "start" : null);
        else if (step.grow) list.grow(); // more rows of the same content: the ones on screen stay
        // reloaded main rows show what the search found now: not refreshed again for it
        if (step.reload && list === this.mainList) this.foundShownFor = searchViewKey(this.searchView);
        this.scrollToKeptRows(); // kept while a status view covered the table, see applyRowLook()
    }

    // ---- search ----

    updateSearchView() {
        const vm = this.searchView ?? { status: "ready", canCancel: false, dataVersion: null };
        const loading = this.root.$(".search-status");
        const step = tableStep(this.searchShown, vm, () => this.searchList.totalItems());
        this.searchShown = step.shown;
        this.searchRunning = this.showRunning(".search-progress", step.running ? vm : null, searchViewStatus,
            step.table ? this.searchList : loading);
        loading.style.display = step.table ? "none" : "block"; // over the table
        this.searchStatus = step.table ? null : vm;
        this.takeFocus(this.searchList, step.table ? null : loading, [loading]);
        if (step.table) this.reloadTable(this.searchList, step);
        else showStatus(loading, vm, searchViewStatus);
        // The rows of the main view show what the search found: more of them
        // while it runs, other ones after a new search or none after a reset.
        // Only when the search view changed since they were shown, not on
        // every show of the panel.
        const key = searchViewKey(this.searchView);
        if (key !== this.foundShownFor && this.shows(this.mainList)) {
            this.mainList.refreshVisibleRows();
            this.foundShownFor = key;
        }
    }

    // ---- the rows: rule colors and anchors ----

    // The rows on screen refer to the rules again: a change of a rule may change
    // the rule with a color a row matches without filtering the view again
    refreshRuleColors() {
        for (const list of this.lists) if (this.shows(list)) list.refreshVisibleRows();
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
        // by the backend while an operation runs or at the anchor limit: a notice
        // by the cell says why. At the limit the tables are marked anchors-full:
        // their empty anchor cells show on hover that no anchor can be set.
        on("click", "table.log-table td.anchor", (evt, cell) => {
            const index = Number(cell.getAttribute("msg-index"));
            const anchored = cell.getAttribute("has-anchor") === "true";
            const counts = this.lists.map(list => list.totalItems());
            const answer = backend.setAnchor(this.docId, index, !anchored);
            this.markAnchorsFull(answer.full);
            if (answer.refused) showNotice(cell, anchorRefusalText(answer), { at: "right", ms: 2500, untilLeave: true });
            else {
                for (const [i, list] of this.lists.entries()) {
                    const count = list.totalItems();
                    if (count === counts[i]) {
                        list.refreshVisibleRows(); // the row was in the view, and shows the new anchor
                        continue;
                    }
                    // The view gained or lost the row: the selected positions show other rows
                    list.resetSelection();
                    // In place, so the rows on screen stay where they are
                    if (!list.followAnchor(index, count > counts[i])) list.componentUpdate();
                }
            }
            return true; // don't change the row selection
        });

        // Posted: it may come after hide() cancelled the follower, not into a hidden panel
        on("rowchosen", "table.log-table > tbody", (evt, list) => {
            if (this.visible && !this.destroyed) this.follower.changed(list, evt.data?.delayed === true);
        });

        on("click", ".btn-lost-close", () => this.host.closeTab(this.docId));

        on("click", ".btn-lost-retry", () => {
            // Reopens the file in the same tab; fails while the disk is still missing
            const retryStart = Date.now();
            const error = backend.retryDocument(this.docId);
            const retryTime = Date.now() - retryStart;
            if (error) {
                console.log(`Retry failed after ${retryTime} ms: ${error}`);
                root.$(".source-lost-error").innerText = tr("Still unavailable: {error}", { error });
                return;
            }
            // A new document with the same id: its first rows start at the top,
            // its filters are restored (no message of a command before), it has
            // no search and no anchors yet
            this.markAnchorsFull(false);
            this.mainShown = noTable;
            this.searchShown = noTable;
            this.appliedColumns = null;
            this.searchBar.reset();
            this.filterPanel.reopened();
            const refreshStart = Date.now();
            this.host.refreshTabs(); // the reopened document starts loading
            console.log(`Retry: xcall ${retryTime} ms, views refresh ${Date.now() - refreshStart} ms`);
        });

        on("click", ".search-status .btn-cancel, .search-progress .btn-cancel", () => backend.cancelSearchView(this.docId));

        // What Cancel means (stop the filter, close a loading document) is decided
        // by the main view machine of the document
        on("click", ".main-status .btn-cancel, .main-progress .btn-cancel", () => backend.cancelMainView(this.docId));
    }
}
