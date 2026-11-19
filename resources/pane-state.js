// What the panel of a document does with its tables and how the panels follow
// the open documents. Pure, so it can be tested with node.
// Tests: tests/js/pane-state.test.mjs.
import { scrollTarget } from "./row-selection.js";

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
//     (other rows: keep the scroll), resetSelection,
//     grow: the content is the one shown and may have more rows now: they are
//       counted, the rows on screen, the scroll and the selection stay,
//     running: a filter or a search is filling the table: its progress and
//       Cancel are shown by the table,
//     shown: the next state }
// The content of one dataVersion only grows (see ReadyView.dataVersion in
// source/ui/main_view_fsm.d), whatever the status: while an operation fills
// it and after, for a source that never ends.
export function tableStep(shown, vm) {
    if (!showsRows(vm)) {
        return { table: false, reload: false, resetSelection: false, grow: false, running: false,
            shown: { ...shown, dataVersion: null } };
    }
    const filling = vm.status !== "ready";
    const step = { table: true, reload: false, resetSelection: false, grow: false,
        running: runsUnder(vm), shown: { loaded: true, dataVersion: vm.dataVersion } };
    // New content being filled starts at the top: it has no rows yet to keep the scroll at
    if (!shown.loaded) return { ...step, reload: "start", resetSelection: true };
    // null: a status was shown, the view may have been rebuilt meanwhile
    if (shown.dataVersion === null || shown.dataVersion !== vm.dataVersion)
        return { ...step, reload: filling ? "start" : "keep", resetSelection: true };
    return { ...step, grow: true };
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

// How a table follows an anchor that added (`added`) or removed the row of
// message `message` from its view, keeping the rows on screen where they are
// (vlist: itemsBefore/itemsAfter are changed for rows outside the rendered ones):
//   { before: -1, 0 or 1 rows before the rendered ones, after: the same after
//     them, insertAt / removeAt: the place among the rendered rows, or null }
// `rendered`: the messages of the rendered rows, in order. null if there are none.
// `room`: all the rows of the view are rendered and the window of the list has room
// for one more. A row added at an end is rendered then, even past the height of the
// table: a list whose window has room doesn't ask for a row counted after the rendered
// ones, so it couldn't be scrolled to by the wheel. With the window full the row is
// counted, the rendered rows stay as many.
export function anchorEdit(rendered, message, added, room) {
    if (rendered.length === 0) return null;
    const step = added ? 1 : -1;
    const result = { before: 0, after: 0, insertAt: null, removeAt: null };
    if (added && room && message < rendered[0]) result.insertAt = 0;
    else if (added && room && message > rendered[rendered.length - 1]) result.insertAt = rendered.length;
    else if (message < rendered[0]) result.before = step;
    else if (message > rendered[rendered.length - 1]) result.after = step;
    else if (added) result.insertAt = rendered.findIndex(m => m > message);
    else result.removeAt = rendered.indexOf(message);
    return result;
}

// The progress a tab shows under its name: the part of the file loaded (0..1)
// while the main view (vm: { status, progress }) loads it, null otherwise (no bar)
export function tabProgress(vm) {
    if (vm?.status !== "loadingFile") return null;
    return Math.min(1, Math.max(0, vm.progress || 0));
}

// What a panel does when the look of the rows of its tables (Settings:
// { fontSize, singleLine }) is asked to be `asked`:
//   { apply: the tables get it now, keep: the first rows on screen are to be
//     scrolled back to the top once the rows are laid out anew }
// `applied`: the look the tables have, null: none yet (a new panel, no rows to
// keep). A hidden panel takes it when shown: rows that changed height under
// its scroll position couldn't be found again
export function rowLookStep(applied, asked, visible) {
    if (applied === null) return { apply: true, keep: false };
    if (applied.fontSize === asked.fontSize && applied.singleLine === asked.singleLine)
        return { apply: false, keep: false };
    return visible ? { apply: true, keep: true } : { apply: false, keep: false };
}

// What a table does with the first row kept on screen (`kept`: { top, null:
// none }) when the look of its rows changed, once they are laid out anew:
//   { wait: a status view covers the table (`shown`, see tableStep), it
//     scrolls when it shows rows again; target: the row to scroll to the top,
//     null: none }
// Rows reloaded since keep their position (tableStep "keep"): the same row
// number, within the `total` rows; their scroll in pixels came from the old
// height of the rows and could be past the end
export function keptRowStep(kept, shown, total) {
    if (shown.dataVersion === null) return { wait: true, target: null };
    if (kept.top === null || total === 0) return { wait: false, target: null };
    return { wait: false, target: Math.min(kept.top, total - 1) };
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
// one selected, top: the first row to show so that it is near the top, null
// if it is on screen already and stays where it is }, or null if that table
// doesn't show the message or doesn't show rows of the content of its view
// (showsRowsOf): a status instead of rows, or the rows of a content being
// replaced, whose positions are of another content; the backend is not asked
// then. While a load, a filter or a search fills that table it goes to the
// rows found so far.
// @param shown - what that table shows (see tableStep)
// @param vm - the view of that table
// @param positionOf - () => the row of the message there, null if none (the backend)
// @param visibleRange - [first, last] rows wholly on screen there (not cut by an edge), null if none
// @param visibleRows - the rows that table has room for
export function jumpStep(shown, vm, positionOf, { visibleRange, visibleRows }) {
    if (!showsRowsOf(shown, vm)) return null;
    const position = positionOf();
    if (position === null || position === undefined) return null;
    const onScreen = visibleRange && position >= visibleRange[0] && position <= visibleRange[1];
    return { position, top: onScreen ? null : scrollTarget(position, visibleRows) };
}

// The rows of a table wholly in view and how many it has room for, from what the table says of itself (`view` of D: `first` and `last`, the first
// and the last row in sight with where their tops are, `rows` [first, past the last), `size`): `visibleRange` [first, last] of the rows not cut
// by an edge, null if none; `visibleRows` the rows in sight, the ones cut included. What `jumpStep` is given.
// @param heightOf - (row) => the height of the row, asked for the last row only
export function wholeRows(view, heightOf) {
    const [firstRow, past] = view.rows;
    if (past <= firstRow) return { visibleRange: null, visibleRows: 0 };
    const first = view.first.dy >= 0 ? firstRow : firstRow + 1;
    const last = view.last.dy + heightOf(view.last.row) <= view.size.h + 1e-6 ? past - 1 : past - 2;
    return { visibleRange: first <= last ? [first, last] : null, visibleRows: past - firstRow };
}

