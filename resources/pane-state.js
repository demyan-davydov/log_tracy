// What the panel of a document does with its tables and how the panels follow
// the open documents. Pure, so it can be tested with node.
// Tests: tests/js/pane-state.test.mjs.

// What a table of a document shows: { loaded } once it has shown rows,
// { dataVersion } of the view they come from, null while the view isn't a table
export const noTable = { loaded: false, dataVersion: null };

// True if the table of the view `vm` shows rows, not the status of the view:
// by what the view has, not by its status, so a new status of a machine falls
// on the right side. A view with content (dataVersion, see ReadyView.dataVersion
// in source/ui/main_view_fsm.d) shows it, complete or being filled (a load, a
// filter, a search), the table empty until its first row. A view without one
// (a cancel, a failure, a lost file, a search waiting for the log view) is a
// status over the table.
function showsRows(vm) {
    return vm.dataVersion !== undefined;
}

// True if an operation filling the table of the view `vm` shows its progress
// and Cancel under it (a filter, a search): the one that can be cancelled. A
// load can't: its tab shows the progress, closing the tab stops it.
function runsUnder(vm) {
    return vm.canCancel === true;
}

// The next step of a table when its view (a machine of the document: { status,
// dataVersion, ... }) changes or tells its progress:
//   { table: true if the table is shown (else the status of the view),
//     reload: false, "start" (the first rows: scroll to the top) or "keep"
//     (other rows: keep the scroll); what the table does with its rows and its
//     selection, D decides (ViewChangeTracker, ui/log_table/view_events.d),
//     running: a filter or a search is filling the table: its progress and
//       Cancel are shown by the table,
//     shown: the next state }
// The content of one dataVersion only grows (see ReadyView.dataVersion in
// source/ui/main_view_fsm.d), whatever the status: while an operation fills
// it and after, for a source that never ends.
export function tableStep(shown, vm) {
    if (!showsRows(vm)) {
        return { table: false, reload: false, running: false,
            shown: { ...shown, dataVersion: null } };
    }
    const filling = vm.status !== "ready";
    const step = { table: true, reload: false,
        running: runsUnder(vm), shown: { loaded: true, dataVersion: vm.dataVersion } };
    // New content being filled starts at the top: it has no rows yet to keep the scroll at
    if (!shown.loaded) return { ...step, reload: "start" };
    // null: a status was shown, the view may have been rebuilt meanwhile
    if (shown.dataVersion === null || shown.dataVersion !== vm.dataVersion)
        return { ...step, reload: filling ? "start" : "keep" };
    return step;
}

// The panels to create and remove for the documents open now
// @param paneIds - the documents that have a panel
// @param docIds - the documents open now
export function paneChanges(paneIds, docIds) {
    return {
        create: docIds.filter(id => !paneIds.includes(id)),
        remove: paneIds.filter(id => !docIds.includes(id)),
    };
}

// The progress a tab shows under its name: the part of the file loaded (0..1)
// while the main view (vm: { status, progress }) loads it, null otherwise (no bar)
export function tabProgress(vm) {
    if (vm?.status !== "loadingFile") return null;
    return Math.min(1, Math.max(0, vm.progress || 0));
}

// The search view (vm of the search machine, null if none yet) as a value: the
// rows of the main table show what the search found, and are refreshed when
// this changes. The models come as new objects with every snapshot of the
// workspace (refreshTabs), so they are compared by what they say.
export function searchViewKey(vm) {
    if (!vm) return "";
    return `${vm.status}/${vm.dataVersion ?? ""}/${vm.progress ?? ""}`;
}

// True if the rows a table shows (`shown`, see tableStep) are of the content of
// its view `vm`: a status doesn't cover them and they aren't the rows of a
// content being replaced. A load, a filter or a search filling the view counts:
// its content only grows, the rows shown keep their positions.
export function showsRowsOf(shown, vm) {
    return shown.dataVersion !== null && vm != null && shown.dataVersion === vm.dataVersion;
}

// Where a row selected in one table takes the other one (the same rules both
// ways): { position: the row of the message there, made current and the only
// one selected }, or null if that table doesn't show the message or doesn't
// show rows of the content of its view (showsRowsOf): a status instead of rows,
// or the rows of a content being replaced, whose positions are of another
// content; the backend is not asked then. While a load, a filter or a search
// fills that table it goes to the rows found so far. Whether the row is in
// view and where it is brought to is the table's (`reveal`, ptable).
// @param shown - what that table shows (see tableStep)
// @param vm - the view of that table
// @param positionOf - () => the row of the message there, null if none (the backend)
export function jumpStep(shown, vm, positionOf) {
    if (!showsRowsOf(shown, vm)) return null;
    const position = positionOf();
    if (position === null || position === undefined) return null;
    return { position };
}
