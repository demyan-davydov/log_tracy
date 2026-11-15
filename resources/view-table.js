// A table of a document panel with what shows over and under it: the view of
// a machine of the document it shows (source/ui/main_view_fsm.d,
// source/ui/search_view_fsm.d), the status views covering it while the view
// isn't a table, the progress under it while a filter or a search fills it,
// the focus the covers take from it. ViewTable is what both tables share;
// MainViewTable and SearchViewTable add what only one of them has. How the
// two tables follow each other is the panel's (document-pane.js). The table
// itself is never hidden: status views cover it (see renderPane).

import * as backend from "backend.js";
import { rowLayout } from "cell-format.js";
import { followedRow } from "row-selection.js";
import { noTable, tableStep, jumpStep, showsRowsOf } from "pane-state.js";
import { mainViewStatus, searchViewStatus, showProgress, showStatus } from "status-view.js";

// True if `element` is `root` or inside it (and still in the document)
function isInside(element, root) {
    for (let el = element; el; el = el.parentElement) if (el === root) return true;
    return false;
}

// Reloads the rows of `list` after its data changed. scrollTo: null keeps the
// scroll position, "start" scrolls to the top, a number scrolls to that row
function reloadList(list, scrollTo = null) {
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

export class ViewTable {
    // @param docId - the document whose rows the table shows
    // @param elements - { table, status (the status view over it),
    //   progress (the strip under it) }
    // @param statusTexts - mainViewStatus or searchViewStatus (status-view.js)
    constructor(docId, { table, status, progress }, statusTexts) {
        this.docId = docId;
        this.table = table;
        this.list = table.$("tbody");
        this.list.docId = docId; // the rows it asks the backend for are those of this document
        this.statusView = status;
        this.progress = progress;
        this.statusTexts = statusTexts;
        // The view the machine shows: { status, canCancel, <fields of the view> }, null: none yet
        this.view = null;
        this.shown = noTable; // what the table shows, see pane-state.js
        this.status = null; // the view the status over the table shows, null: none
        this.running = null; // the view the progress under the table shows, null: none
        this.focusCovered = false; // a status view took the focus from the table
        // Cancel of the status view and of the progress: what it means is decided by the
        // machine of the view (stop the filter or the search)
        for (const button of [status.$(".btn-cancel"), progress.$(".btn-cancel")])
            button.on("click", () => this.cancel());
    }

    // Cancels what the view is doing (backend)
    cancel() {
        throw new Error("ViewTable.cancel: of a subclass");
    }

    // A new document under the same id (Retry of a lost file): the table shows
    // none of its rows yet, the next update() starts it from the top
    reset() {
        this.shown = noTable;
        this.focusCovered = false;
    }

    // The status views that may cover the table, see coverFor()
    get covers() {
        return [this.statusView];
    }

    // The view to show now, null: nothing to show yet
    currentView() {
        return this.view;
    }

    // The status view covering the table for the view `vm` that isn't a table
    coverFor(vm) {
        return this.statusView;
    }

    // Fills `cover` (one of covers) with the view `vm`
    fillCover(cover, vm) {
        showStatus(cover, vm, this.statusTexts);
    }

    // The status view covering the table now, null if none
    shownCover() {
        return this.covers.find(view => view.style.display === "block") ?? null;
    }

    // The position of message `index` in the view (backend), null if it hasn't it
    positionOf(index) {
        throw new Error("ViewTable.positionOf: of a subclass");
    }

    // Shows the view as its machine shows it: the table (with the progress of
    // a filter or a search filling it) or a status view over it.
    // @returns the step of tableStep, null if there is no view to show; with a
    // reload (step.table) the rows are reloaded already
    update() {
        const vm = this.currentView();
        if (!vm) return null;
        const step = tableStep(this.shown, vm, () => this.list.totalItems());
        this.shown = step.shown;
        const cover = step.table ? null : this.coverFor(vm);
        this.running = this.showRunning(step.running ? vm : null, cover ?? this.list);
        this.status = cover === this.statusView ? vm : null;
        for (const view of this.covers) view.style.display = view === cover ? "block" : "none";
        this.takeFocus(cover);
        if (step.table) this.reloadRows(step);
        else this.fillCover(cover, vm);
        return step;
    }

    // The texts of the status and the progress shown again: the language changed
    renderTexts() {
        if (this.status) showStatus(this.statusView, this.status, this.statusTexts);
        if (this.running) showProgress(this.progress, this.running, this.statusTexts);
    }

    // Shows the progress under the table for the view `vm` of a filter or a
    // search filling it, hides it for null: the focus its Cancel took when
    // pressed goes to `next` (the table, or the status view shown instead)
    // then, not left on a hidden button. @returns vm
    showRunning(vm, next) {
        const strip = this.progress;
        const focused = !vm && isInside(document.$(":focus"), strip);
        strip.style.display = vm ? "" : "none";
        if (focused) next.state.focus = true;
        if (vm) showProgress(strip, vm, this.statusTexts);
        return vm;
    }

    // A status view covering the table (`cover`) takes the focus from it: the
    // keys must not scroll or copy rows of a view being rebuilt. The table
    // gets it back when it is uncovered, if the focus didn't go elsewhere.
    // The focus left in a view that covered it (on the view or on its Cancel,
    // tabbed to or pressed) goes to the table too: the view is hidden, the
    // keys would go nowhere.
    takeFocus(cover) {
        const list = this.list;
        const focused = document.$(":focus");
        if (cover) {
            if (!isInside(focused, list)) return;
            cover.state.focus = true;
            this.focusCovered = true;
            return;
        }
        const taken = this.focusCovered;
        this.focusCovered = false;
        if (this.covers.some(view => isInside(focused, view)) || (taken && !focused)) list.state.focus = true;
    }

    reloadRows(step) {
        const list = this.list;
        if (step.resetSelection) list.resetSelection(); // the rows are other messages now
        if (step.reload) reloadList(list, step.reload === "start" ? "start" : null);
        else if (step.grow) list.grow(); // more rows of the same content: the ones on screen stay
    }

    // True if the rows on screen are of the content of the view (showsRowsOf):
    // not covered by a status, not the rows of a content being replaced
    showsRowsOfView() {
        return showsRowsOf(this.shown, this.view);
    }

    // The message index of the row of the table the other one follows
    // (followedRow), null if none
    followedMessage() {
        const row = followedRow(this.list.selection);
        const index = row === null ? NaN : Number(this.list.itemAt(row)?.[rowLayout.messageIndex]);
        return Number.isFinite(index) ? index : null;
    }

    // Shows the row of message `index` if the view has it: selected, near the
    // top unless it is on screen (jumpStep). The keyboard stays where it is.
    // Also while a load, a filter or a search fills it: the rows found so far.
    // By the view of the machine, not currentView(): a search view before any
    // search has no rows to look the message up in.
    showMessage(index) {
        const step = jumpStep(this.shown, this.view, () => this.positionOf(index),
            { visibleRange: this.list.wholeRowsRange(), visibleRows: this.list.visibleRowCount() });
        if (step) this.list.showRow(step);
    }
}

// The main view: the log as the filters show it. Its file may be lost: the
// view then covers the table with a view of its own (Retry, Close).
export class MainViewTable extends ViewTable {
    // @param elements - as ViewTable, and lost: the view of the lost file
    constructor(docId, elements) {
        super(docId, elements, mainViewStatus);
        this.lostView = elements.lost;
        this.path = ""; // of the file, shown by the lost view
    }

    get covers() {
        return [this.statusView, this.lostView];
    }

    coverFor(vm) {
        return vm.status === "sourceLost" ? this.lostView : this.statusView;
    }

    fillCover(cover, vm) {
        if (cover === this.lostView) this.lostView.$(".source-lost-path").innerText = this.path || "";
        else super.fillCover(cover, vm);
    }

    update() {
        // The error of a Retry is of the lost file: gone with it
        if (this.view && this.view.status !== "sourceLost") this.lostError("");
        return super.update();
    }

    // Shows why Retry failed in the lost view ("" clears it)
    lostError(text) {
        this.lostView.$(".source-lost-error").innerText = text;
    }

    positionOf(index) {
        return backend.mainViewPosition(this.docId, index);
    }

    cancel() {
        backend.cancelMainView(this.docId);
    }

    // Go to Message: the row of message `index`, or of the first one after it
    // the table shows (hidden by the filters), else its last row: selected,
    // the keyboard in the table, near the top unless it is on screen
    // (jumpStep); the search table follows it as a click. Nothing while the
    // table shows no rows (a status view covers it). @returns true if it went
    goToMessage(index) {
        const list = this.list;
        const step = jumpStep(this.shown, this.currentView(), () => backend.mainViewNearestPosition(this.docId, index),
            { visibleRange: list.wholeRowsRange(), visibleRows: list.visibleRowCount() });
        if (!step) return false;
        list.showRow(step);
        list.state.focus = true;
        list.rowChosen(false);
        return true;
    }
}

// The search view: the records the search found. Before any search it is
// ready and empty.
export class SearchViewTable extends ViewTable {
    constructor(docId, elements) {
        super(docId, elements, searchViewStatus);
    }

    currentView() {
        return this.view ?? { status: "ready", canCancel: false, dataVersion: null };
    }

    positionOf(index) {
        return backend.searchViewPosition(this.docId, index);
    }

    cancel() {
        backend.cancelSearchView(this.docId);
    }
}
