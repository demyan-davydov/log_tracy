// The status views of a document panel and the progress under its tables, see
// source/ui/main_view_fsm.d and source/ui/search_view_fsm.d. A view without
// content (a cancel, a failure, a search waiting for the log view) covers its
// table with a status view (an element of .status-view): a title and the line
// under it, no progress, no Cancel. An operation filling a table (a filter, a
// search) shows its progress and Cancel in the strip under it (.view-progress),
// the table showing what it found so far: never over it (pane-state.js tableStep).

import { tr } from "i18n/i18n.js";

export function percent(progress) {
    return Math.round(progress * 100);
}

// The main view: the texts of each status covering the table (but the lost
// file, a view of its own) and of each operation filling it
export const mainViewStatus = {
    // The status over the table: its title, and the line under it (what the
    // user can do, or the error)
    covers: {
        loadFailed: { title: () => tr("Failed to load the file"), detail: (vm) => vm.error || "" },
        filterCancelled: {
            title: () => tr("Filter cancelled"),
            detail: () => tr("Change or clear the filters to show messages again"),
        },
        filterFailed: { title: () => tr("Filter failed"), detail: (vm) => vm.error || "" },
    },
    // The text of the progress under the table
    progress: {
        filtering: (vm) => tr("Filtering... {percent}%", { percent: percent(vm.progress) }),
    },
};

// The search view: likewise
export const searchViewStatus = {
    covers: {
        waitingForView: { title: () => tr("Waiting for the log view...") },
        searchCancelled: { title: () => tr("Search cancelled"), detail: () => tr("Run the search again to see results") },
        searchFailed: { title: () => tr("Search failed"), detail: (vm) => vm.error || "" },
        sourceLost: { title: () => tr("The file is no longer available") },
    },
    progress: {
        searching: (vm) => tr("Searching... {percent}%", { percent: percent(vm.progress) }),
    },
};

// Fills the progress of a table (an element of .view-progress, under a table
// that shows what an operation found so far) with the view `vm` as `status`
// (mainViewStatus, searchViewStatus) tells it: its text and progress; its
// Cancel is always there. A status with no text shows its name.
export function showProgress(strip, vm, status) {
    const text = status.progress[vm.status];
    strip.$(".view-progress-text").innerText = text ? text(vm) : vm.status;
    strip.$("progress").value = percent(vm.progress ?? 0);
}

// Fills a status view (an element of .status-view) with the view `vm` as
// `status` tells it: its title (its name if it has none) and the line under it
export function showStatus(view, vm, status) {
    const cover = status.covers[vm.status];
    view.$(".status-title").innerText = cover ? cover.title(vm) : vm.status;
    const detailText = cover?.detail ? cover.detail(vm) : "";
    const detailView = view.$(".status-detail");
    detailView.innerText = detailText;
    // Not left to .status-detail:empty: Sciter doesn't restyle it when the
    // text changes, only on the next state change (a click on the panel)
    detailView.style.display = detailText ? "block" : "none";
}
