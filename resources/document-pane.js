// The panel of one open document: everything shown while its tab is active,
// the filters of the sidebar, the main view, the search editor and the search
// results. Each document has its own panel, kept while the document is open
// and only hidden while another tab is shown (display: none keeps the rows,
// the scroll, the selection and the editor as they are). A hidden panel
// touches none of its elements but remembers what changed: show() brings it
// up to date.

import { SearchEditor } from "search-editor.js";
import * as backend from "backend.js";
import * as platform from "platform.js";
import { noSearch, runSearch, searchPending, editRule } from "pane-commands.js";
import { ruleColors } from "rule-colors.js";
import { scrollTarget } from "row-selection.js";
import { noTable, tableStep } from "pane-state.js";
import { currentCatalog, tr } from "i18n/i18n.js";
import { translateTree } from "i18n/dom.js";
import { fileFilter, allFiles } from "file-types.js";

// Texts of the main view statuses other than the table and the lost file
const mainViewTexts = {
    loadingFile: (vm) => tr("Loading file... {percent}%", { percent: percent(vm.progress) }),
    loadFailed: () => tr("Failed to load the file"),
    filtering: (vm) => tr("Filtering... {percent}%", { percent: percent(vm.progress) }),
    filterCancelled: () => tr("Filter cancelled"),
    filterFailed: () => tr("Filter failed"),
};

// Line under the text of a status: what the user can do, or the error
const mainViewDetails = {
    loadingFile: () => tr("Cancel closes the file"),
    loadFailed: (vm) => vm.error || "",
    filterCancelled: () => tr("Change or clear the filters to show messages again"),
    filterFailed: (vm) => vm.error || "",
};

// Texts of the search view statuses other than the results
const searchViewTexts = {
    waitingForView: () => tr("Waiting for the log view..."),
    searching: (vm) => tr("Searching... {percent}%", { percent: percent(vm.progress) }),
    searchCancelled: () => tr("Search cancelled"),
    searchFailed: () => tr("Search failed"),
    sourceLost: () => tr("The file is no longer available"),
};

const searchViewDetails = {
    searchCancelled: () => tr("Run the search again to see results"),
    searchFailed: (vm) => vm.error || "",
};

const ruleKindMarks = { include: "+", exclude: "−", marker: "◆" };
const ruleKindTitles = {
    include: () => tr("Shows the records it matches"),
    exclude: () => tr("Hides the records it matches"),
    marker: () => tr("Marks the records it matches with its color"),
};

const noFilters = { canFilter: false, canDlf: false, sets: [] };

function percent(progress) {
    return Math.round(progress * 100);
}

// True if `element` is `root` or inside it (and still in the document)
function isInside(element, root) {
    for (let el = element; el; el = el.parentElement) if (el === root) return true;
    return false;
}

// The elements of a panel; the sizes of the splitters are those of the panel
// shown last (see DocumentPane.show)
function renderPane(splitters) {
    return <frameset class="document-pane" cols={splitters.cols}>
        <section class="left-panel sidebar">
            <header data-tr="Filters" />
            <div class="filter-sets"></div>
            <div class="filter-message"></div>
            <div class="filter-actions">
                <button class="btn-new-dlf" data-tr="New Filter" />
                <button class="btn-dlf" data-tr="Load Filter" />
            </div>
        </section>

        <frameset rows={splitters.rows}>
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
                </div>
            </section>

            <section class="search-results-panel">
                <div class="toolbar search-toolbar chip-search-toolbar">
                    <div class="chip-search chip-editor" tabindex="0"></div>
                    <button class="btn-chip-history" data-tr-title="Search history (↓)">▾</button>
                    <button class="btn-chip-search" data-tr="Search" />
                </div>
                <div class="chip-search-message"></div>

                <header data-tr="Details / Search Results" />
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
                </div>
            </section>
        </frameset>
    </frameset>;
}

// Fills a status view (an element of .status-view): text, progress (hidden
// without one), detail, Cancel (its row hidden when the status can't be cancelled)
function showStatus(view, vm, texts, details) {
    const progress = view.$("progress");
    const hasProgress = vm.progress !== undefined;
    progress.style.display = hasProgress ? "" : "none";
    if (hasProgress) progress.value = percent(vm.progress);
    const text = texts[vm.status];
    view.$(".status-title").innerText = text ? text(vm) : vm.status;
    const detail = details[vm.status];
    view.$(".status-detail").innerText = detail ? detail(vm) : "";
    view.$(".btn-cancel").parentElement.style.display = vm.canCancel ? "" : "none";
}

// Reloads the rows of `list` after its data changed. scrollTo: null keeps the
// scroll position, "start" scrolls to the top, a number scrolls to that row
export function reloadList(list, scrollTo = null) {
    if (scrollTo === "start") list.scrollTo(0, 0);
    // Carried out by the render that componentUpdate() posts, see VirtualList.navigateTarget
    if (scrollTo !== null) list.navigateTarget = scrollTo;
    list.componentUpdate();
    list.refreshVisibleRows(); // the rows may show other messages now
}

export class DocumentPane {
    // @param docId - the id of the document in the backend
    // @param container - the element the panel is appended to
    // @param splitters - { cols, rows } the splitters start with
    // @param host - what the panel asks of the window:
    //   closeTab(docId), refreshTabs(), theme() -> "light" | "dark",
    //   tableFontSize() -> % of the normal font of the tables
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
        this.searchShown = noTable;
        this.appliedColumns = null; // JSON of the columns the tables show
        this.filtersShown = false; // the filter panel is built on the first show
        this.filters = noFilters; // what showFilters() got last
        this.filterMessage = ""; // the error of the last filter command
        this.ruleColors = new Map(); // of the rules of the filters, by rule id
        this.search = noSearch; // the search the results were found by (pane-commands.js)
        this.lastFocus = null; // focused in the panel when it was hidden
        this.coveredFocus = new Set(); // the lists a status view took the focus from
        this.textsStale = false; // the language changed while hidden: rendered again on show
        this.mainStatus = null; // the view a status over the table shows, null: none
        this.searchStatus = null;

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
        this.applyFontSize(host.tableFontSize());

        this.chipEditor = new SearchEditor(this.root.$(".chip-search"), {
            checkRegex: (pattern, ignoreCase) => backend.checkRegex(pattern, ignoreCase),
            onEdited: () => this.updateChipPending(),
            onCommit: () => this.runChipSearch(),
            history: () => backend.searchHistory(this.docId),
            historyButton: this.root.$(".btn-chip-history"),
        });
        this.updateChipPending();
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
        if (mainView !== undefined) this.updateMainView();
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
        if (this.filtersShown) this.showFilters();
        if (this.mainStatus)
            showStatus(this.root.$(".main-status"), this.mainStatus, mainViewTexts, mainViewDetails);
        if (this.searchStatus)
            showStatus(this.root.$(".search-status"), this.searchStatus, searchViewTexts, searchViewDetails);
    }

    // Shows the panel, up to date. `splitters` are the sizes of the panel
    // shown before (colsState, rowsState: its frameset states, see hide()),
    // null to keep its own.
    show(splitters) {
        this.root.style.display = "";
        this.visible = true;
        if (splitters) {
            this.root.frameset.state = splitters.colsState;
            this.root.$("frameset").frameset.state = splitters.rowsState;
        }
        if (this.textsStale) { // the language changed while hidden: refresh() renders it all
            this.textsStale = false;
            this.filtersShown = false;
        }
        this.refresh();
        // Keys go to this panel, not to the hidden one; not into a hidden table
        const focus = isInside(this.lastFocus, this.root) ? this.lastFocus
            : this.shows(this.mainList) ? this.mainList : this.root.$(".chip-search");
        focus.state.focus = true;
    }

    // Hides the panel. @returns the sizes of its splitters for the next panel
    // shown: { cols, rows } (strings, for a new panel) and their frameset states
    hide() {
        const focused = document.$(":focus");
        this.lastFocus = isInside(focused, this.root) ? focused : null;
        const inner = this.root.$("frameset");
        const splitters = {
            colsState: this.root.frameset?.state, rowsState: inner.frameset?.state,
            cols: this.root.frameset?.state?.join(",") ?? this.root.getAttribute("cols"),
            rows: inner.frameset?.state?.join(",") ?? inner.getAttribute("rows"),
        };
        this.visible = false;
        this.root.style.display = "none";
        return splitters;
    }

    // The document is closed
    destroy() {
        this.chipEditor.destroy();
        this.root.remove();
    }

    // Brings what is shown up to date with the document
    refresh() {
        if (!this.filtersShown) this.showFilters();
        // The rules first: the rows the columns re-render refer to them
        for (const list of this.lists) list.ruleColors = this.ruleColors;
        this.searchList.matchColors = this.search.colors;
        // The columns before the rows: a reload of a view renders them with these
        const changed = this.setColumns();
        this.updateMainView();
        this.updateSearchView();
        if (changed) this.renderShownRows();
    }

    applyFontSize(percent) {
        for (const table of [this.mainTable, this.searchTable]) table.style.fontSize = `${percent}%`;
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
        const shown = list === this.mainList ? this.mainShown : this.searchShown;
        return this.visible && shown.dataVersion !== null;
    }

    // ---- main view ----

    // Shows the main view as its machine shows it: the table, the lost file
    // or the status of what the document is doing
    updateMainView() {
        const vm = this.mainView;
        if (!vm) return;
        const loading = this.root.$(".main-status");
        const lost = this.root.$(".source-lost");
        if (vm.status !== "sourceLost") this.root.$(".source-lost-error").innerText = "";
        const step = tableStep(this.mainShown, vm);
        this.mainShown = step.shown;
        const cover = step.table ? null : vm.status === "sourceLost" ? lost : loading;
        this.mainStatus = cover === loading ? vm : null;
        for (const element of [loading, lost])
            element.style.display = element === cover ? "block" : "none";
        this.takeFocus(this.mainList, cover);
        if (step.table) {
            this.reloadTable(this.mainList, step);
        } else if (vm.status === "sourceLost") {
            this.root.$(".source-lost-path").innerText = this.path || "";
        } else {
            showStatus(loading, vm, mainViewTexts, mainViewDetails);
        }
    }

    // A status view covering the table of `list` takes the focus from it: the
    // keys must not scroll or copy rows of a view being rebuilt. The table
    // gets it back when it is uncovered, if the focus didn't go elsewhere.
    takeFocus(list, cover) {
        const focused = document.$(":focus");
        if (cover) {
            if (!isInside(focused, list)) return;
            cover.state.focus = true;
            this.coveredFocus.add(list);
        } else if (this.coveredFocus.delete(list)) {
            if (!focused || focused.classList.contains("overlay")) list.state.focus = true;
        }
    }

    reloadTable(list, step) {
        if (step.resetSelection) list.resetSelection(); // the rows are other messages now
        if (step.reload) reloadList(list, step.reload === "start" ? "start" : null);
    }

    // Reloads the rows of the main view in place (e.g. decoding changed)
    reloadMainRows() {
        if (this.visible) reloadList(this.mainList);
    }

    // ---- search ----

    updateSearchView() {
        const vm = this.searchView ?? { status: "ready", canCancel: false, dataVersion: null };
        const loading = this.root.$(".search-status");
        const step = tableStep(this.searchShown, vm);
        this.searchShown = step.shown;
        loading.style.display = step.table ? "none" : "block"; // over the table
        this.searchStatus = step.table ? null : vm;
        this.takeFocus(this.searchList, step.table ? null : loading);
        if (step.table) this.reloadTable(this.searchList, step);
        else showStatus(loading, vm, searchViewTexts, searchViewDetails);
    }

    // Runs the search for the chips of the editor (Enter, the Search button),
    // see runSearch
    runChipSearch() {
        const editor = this.chipEditor;
        const run = runSearch(this.search, editor.searchChips(), () => editor.searchChipColors(),
            () => editor.firstError(), chips => backend.startChipSearch(this.docId, chips));
        this.search = run.search;
        this.root.$(".chip-search-message").innerText = run.message;
        if (run.started) this.searchList.matchColors = this.search.colors; // before the results come
        this.updateChipPending();
    }

    updateChipPending() {
        const pending = searchPending(this.search, this.chipEditor.searchChips());
        this.root.$(".chip-search-toolbar").classList.toggle("pending", pending);
        this.root.$(".btn-chip-search").classList.toggle("primary", pending);
    }

    // ---- filters ----

    // The filter sets live in the backend (DocumentFilters), per document.
    // Shows the sets again after a filter command of the backend, with its
    // message; the table reloads when the filter operation reports completion.
    showFilterResult(error) {
        this.filterMessage = error || "";
        this.showFilters();
        this.refreshRuleColors();
    }

    // The rows on screen refer to the rules again: a change of a rule may change
    // the rule with a color a row matches without filtering the view again
    refreshRuleColors() {
        for (const list of this.lists) if (this.shows(list)) list.refreshVisibleRows();
    }

    // Opens the editor of a rule of a set (rule -1: a new one) and applies
    // what it closes with, see editRule in pane-commands.js.
    // @returns true if the rule was applied, false if the editor was cancelled
    editRule(set, rule) {
        const docId = this.docId;
        const values = backend.filterRule(docId, set, rule);
        if (!values) return false;
        const open = (values, error) => platform.showModal("rule-editor.htm", {
            title: rule < 0 ? tr("New Rule") : tr("Edit Rule"), theme: this.host.theme(), rule: values, error,
            catalog: currentCatalog(),
            columns: backend.columns(docId),
            // What is wrong with the rule, while it is edited: the editor
            // marks it at once instead of being reopened with the error
            check: rule => backend.checkFilterRuleJson(docId, rule)
        });
        const apply = result => rule < 0 ? backend.addFilterRule(docId, set, result)
            : backend.updateFilterRule(docId, set, rule, result);
        if (!editRule(values, open, apply)) return false;
        this.filterMessage = "";
        this.showFilters();
        this.refreshRuleColors();
        return true;
    }

    // Shows the filter sets: a set is a row with its switch, name and remove
    // button, followed by a row per rule
    showFilters() {
        const info = backend.filters(this.docId) ?? noFilters;
        this.filters = info;
        this.filtersShown = true;
        this.ruleColors = ruleColors(info.sets); // the rows refer to the rules by id
        for (const list of this.lists) list.ruleColors = this.ruleColors;
        const panel = this.root.$(".filter-sets");
        // Built from scratch, as the quick filter was: reused inputs keep their state
        panel.clear();
        if (!info.sets || info.sets.length === 0)
            panel.append(<div class="filters-empty">{info.canFilter
                ? tr("No filters: load a filter file or create a new one")
                : tr("This log has no columns to filter by")}</div>);
        (info.sets || []).forEach((set, s) => {
            const element = <div class={set.enabled ? "filter-set" : "filter-set off"}>
                <div class="filter-row filter-set-head" set-index={s}>
                    <input type="checkbox" class="filter-set-switch" />
                    <span class="filter-name" title={set.source ? tr("Loaded from {file}", { file: set.source }) : ""}>{set.name}</span>
                    <span class="filter-button filter-export" title={tr("Export to a filter file")}>⤓</span>
                    <span class="filter-button filter-add" title={tr("Add a rule")}>+</span>
                    <span class="filter-button filter-remove" title={tr("Remove this filter")}>×</span>
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
                    <span class="filter-kind" title={ruleKindTitles[rule.kind]?.() ?? ""}>{ruleKindMarks[rule.kind]}</span>
                    <span class="filter-swatch" />
                    <span class="filter-name">{rule.name || tr("(no name)")}</span>
                    <span class="filter-button filter-rule-edit" title={tr("Edit this rule (or double-click it)")}>✎</span>
                    <span class="filter-button filter-rule-remove" title={tr("Remove this rule")}>×</span>
                </div>);
                const row = block.lastElementChild;
                row.$(".filter-rule-switch").value = rule.enabled;
                if (rule.color) row.$(".filter-swatch").style.setProperty("background-color", rule.color);
                if (rule.error)
                    block.append(<div class="filter-note">{tr("Not applied: {error}", { error: rule.error })}</div>);
            });
        });
        this.root.$(".btn-dlf").style.display = info.canFilter ? "" : "none";
        this.root.$(".btn-new-dlf").style.display = info.canFilter ? "" : "none";
        this.root.$(".filter-message").innerText = this.filterMessage;
    }

    // ---- events of the elements of the panel ----

    bind() {
        const root = this.root;
        const on = (event, selector, handler) => root.on(event, selector, handler);
        const setOf = (element) => parseInt(element.getAttribute("set-index"));
        const ruleOf = (element) => parseInt(element.getAttribute("rule-index"));

        on("click", ".btn-chip-search", () => {
            this.chipEditor.closeChip();
            this.runChipSearch();
        });

        // Anchor column: toggles the anchor of the message in both views. Ignored by
        // the backend while an operation runs or at the anchor limit.
        on("click", "table.log-table td.anchor", (evt, cell) => {
            const index = Number(cell.getAttribute("msg-index"));
            const anchored = cell.getAttribute("has-anchor") === "true";
            const counts = this.lists.map(list => list.totalItems());
            if (backend.setAnchor(this.docId, index, !anchored)) {
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

        // A double click on a search result shows its message in the main view:
        // current and the only one selected, near the top
        on("dblclick", "table.search-view > tbody > tr", (evt, row) => {
            if (evt.target.closest("td.anchor")) return; // toggles the anchor only
            const msgIndex = Number(row.$("td.anchor")?.getAttribute("msg-index"));
            if (!Number.isFinite(msgIndex)) return;
            // Only into a main view that shows its rows: while it is rebuilt the
            // positions belong to the content being replaced
            if (this.mainView?.status !== "ready") return;
            const list = this.mainList;
            const position = backend.mainViewPosition(this.docId, msgIndex);
            if (position === null || position === undefined) return;
            list.selection.moveTo(position);
            list.navigateTarget = scrollTarget(position, list.visibleRowCount());
            list.componentUpdate();
            list.updateRowStates();
            list.state.focus = true;
            return true;
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
            // its filters are restored, it has no search yet
            this.mainShown = noTable;
            this.searchShown = noTable;
            this.appliedColumns = null;
            this.search = noSearch;
            this.updateChipPending();
            this.showFilters();
            const refreshStart = Date.now();
            this.host.refreshTabs(); // the reopened document starts loading
            console.log(`Retry: xcall ${retryTime} ms, views refresh ${Date.now() - refreshStart} ms`);
        });

        on("click", ".search-status .btn-cancel", () => backend.cancelSearchView(this.docId));

        // What Cancel means (stop the filter, close a loading document) is decided
        // by the main view machine of the document
        on("click", ".main-status .btn-cancel", () => backend.cancelMainView(this.docId));

        on("click", ".btn-fibex", () => {
            const fn = platform.chooseFileToOpen(fileFilter([[tr("XML Files"), "*.xml"], allFiles()]));
            if (fn) {
                backend.loadFibex(fn);
                this.reloadMainRows();
            }
        });

        // Filter sets are only appended; each one has its remove button. A filter
        // file of DLT Explorer for any log, a .dlf of dlt-viewer for a DLT one.
        on("click", ".btn-dlf", () => {
            const native = [tr("DLT Explorer Filters"), "*.logfilter"];
            const types = this.filters.canDlf
                ? [[tr("Filter Files"), "*.logfilter;*.dlf"], native, [tr("dlt-viewer Filters"), "*.dlf"], allFiles()]
                : [native, allFiles()];
            const fn = platform.chooseFileToOpen(fileFilter(types));
            if (fn) this.showFilterResult(backend.loadFilterFile(this.docId, fn));
        });

        // An empty set, kept with the log like a loaded one; its first rule is
        // asked for right away
        on("click", ".btn-new-dlf", () => {
            this.showFilterResult(backend.newFilterSet(this.docId));
            if (this.filterMessage) return;
            const set = this.filters.sets.length - 1;
            // No first rule: no set either, so cancelled tries don't pile up
            if (!this.editRule(set, -1)) this.showFilterResult(backend.removeFilterSet(this.docId, set));
        });

        on("click", ".filter-add", (evt, button) => {
            this.editRule(setOf(button.parentElement), -1);
            return true;
        });

        // A set is a copy kept with the log: exported to share it, to a filter file
        // of DLT Explorer or (DLT logs) to a .dlf for dlt-viewer
        on("click", ".filter-export", (evt, button) => {
            const set = setOf(button.parentElement);
            const canDlf = this.filters.canDlf;
            // Offered the file the set was loaded from or exported to last, or
            // <name>.<format>.logfilter; its kind is offered first
            const fileName = this.filters.sets[set]?.fileName || "";
            const dlf = canDlf && /\.dlf$/i.test(fileName);
            const native = [tr("DLT Explorer Filters"), "*.logfilter"];
            const dlt = [tr("dlt-viewer Filters"), "*.dlf"];
            const kinds = !canDlf ? [native] : dlf ? [dlt, native] : [native, dlt];
            const params = {
                caption: tr("Export Filter"),
                extension: dlf ? "dlf" : "logfilter",
                filter: fileFilter([...kinds, allFiles()])
            };
            // Without its extension: the dialog adds it itself (name.dlf.dlf otherwise)
            if (fileName) params.path = fileName.replace(/\.(dlf|logfilter)$/i, "");
            const fn = platform.chooseFileToSave(params);
            if (fn) this.showFilterResult(backend.exportFilterSet(this.docId, set, fn));
            return true;
        });

        on("click", ".filter-rule-edit", (evt, button) => {
            const row = button.parentElement;
            this.editRule(setOf(row), ruleOf(row));
            return true;
        });

        on("dblclick", ".filter-rule", (evt, row) => {
            if (evt.target.tag === "input") return; // the switch
            this.editRule(setOf(row), ruleOf(row));
            return true;
        });

        on("click", ".filter-rule-remove", (evt, button) => {
            const row = button.parentElement;
            this.showFilterResult(backend.removeFilterRule(this.docId, setOf(row), ruleOf(row)));
            return true;
        });

        on("change", ".filter-set-switch", (evt, input) => {
            this.showFilterResult(backend.enableFilterSet(this.docId, setOf(input.parentElement), input.value));
        });

        on("change", ".filter-rule-switch", (evt, input) => {
            const row = input.parentElement;
            this.showFilterResult(backend.enableFilterRule(this.docId, setOf(row), ruleOf(row), input.value));
        });

        on("click", ".filter-remove", (evt, button) => {
            this.showFilterResult(backend.removeFilterSet(this.docId, setOf(button.parentElement)));
            return true;
        });
    }
}
