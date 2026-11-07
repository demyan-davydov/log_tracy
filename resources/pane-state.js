// What the panel of a document does with its tables and how the panels follow
// the open documents. Pure, so it can be tested with node.
// Tests: tests/js/pane-state.test.mjs.

// What a table of a document shows: { loaded } once it has shown rows,
// { dataVersion } of the view they come from, null while the view isn't a table
export const noTable = { loaded: false, dataVersion: null };

// The next step of a table when its view (a machine of the document: { status,
// dataVersion }) changes:
//   { table: true if the table is shown (else the status of the view),
//     reload: false, "start" (the first rows: scroll to the top) or "keep"
//     (other rows: keep the scroll), resetSelection, shown: the next state }
export function tableStep(shown, vm) {
    if (vm.status !== "ready")
        return { table: false, reload: false, resetSelection: false, shown: { ...shown, dataVersion: null } };
    const next = { loaded: true, dataVersion: vm.dataVersion };
    if (!shown.loaded) return { table: true, reload: "start", resetSelection: true, shown: next };
    // null: a status was shown, the view may have been rebuilt meanwhile
    if (shown.dataVersion === null || shown.dataVersion !== vm.dataVersion)
        return { table: true, reload: "keep", resetSelection: true, shown: next };
    return { table: true, reload: false, resetSelection: false, shown: next };
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
// `room`: the list doesn't fill the table, all its rows are rendered. A row
// added at an end is rendered then: counted out of sight it couldn't be
// scrolled to. In a full list it is counted, the rendered rows stay as many.
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
