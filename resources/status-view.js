// The status views of a document panel: what covers a table while its view
// isn't showing rows (the file loading, a filter or a search running or
// failed). The texts of each status of the main view and the search view, see
// source/ui/main_view_fsm.d and source/ui/search_view_fsm.d, and the filling
// of a view (an element of .status-view).

import { tr } from "i18n/i18n.js";

export function percent(progress) {
    return Math.round(progress * 100);
}

// The main view: the title and the line under it of each status other than the
// table and the lost file
export const mainViewStatus = {
    texts: {
        loadingFile: (vm) => tr("Loading file... {percent}%", { percent: percent(vm.progress) }),
        loadFailed: () => tr("Failed to load the file"),
        filtering: (vm) => tr("Filtering... {percent}%", { percent: percent(vm.progress) }),
        filterCancelled: () => tr("Filter cancelled"),
        filterFailed: () => tr("Filter failed"),
    },
    // What the user can do, or the error
    details: {
        loadingFile: () => tr("Cancel closes the file"),
        loadFailed: (vm) => vm.error || "",
        filterCancelled: () => tr("Change or clear the filters to show messages again"),
        filterFailed: (vm) => vm.error || "",
    },
};

// The search view: likewise, for each status other than the results
export const searchViewStatus = {
    texts: {
        waitingForView: () => tr("Waiting for the log view..."),
        searching: (vm) => tr("Searching... {percent}%", { percent: percent(vm.progress) }),
        searchCancelled: () => tr("Search cancelled"),
        searchFailed: () => tr("Search failed"),
        sourceLost: () => tr("The file is no longer available"),
    },
    details: {
        searchCancelled: () => tr("Run the search again to see results"),
        searchFailed: (vm) => vm.error || "",
    },
};

// Fills a status view (an element of .status-view) with the view `vm` as
// `status` (mainViewStatus, searchViewStatus) tells it: text, progress (hidden
// without one), detail, Cancel (its row hidden when the status can't be cancelled)
export function showStatus(view, vm, status) {
    const progress = view.$("progress");
    const hasProgress = vm.progress !== undefined;
    progress.style.display = hasProgress ? "" : "none";
    if (hasProgress) progress.value = percent(vm.progress);
    const text = status.texts[vm.status];
    view.$(".status-title").innerText = text ? text(vm) : vm.status;
    const detail = status.details[vm.status];
    const detailText = detail ? detail(vm) : "";
    const detailView = view.$(".status-detail");
    detailView.innerText = detailText;
    // Not left to .status-detail:empty: Sciter doesn't restyle it when the
    // text changes, only on the next state change (a click on the panel)
    detailView.style.display = detailText ? "block" : "none";
    view.$(".btn-cancel").parentElement.style.display = vm.canCancel ? "" : "none";
}
