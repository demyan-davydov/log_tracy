// The flows of the commands of a document panel (document-pane.js and its parts), free of
// Sciter: what the backend and the dialogs are asked comes in as functions.
// Tests: tests/js/pane-commands.test.mjs.
import { tr, trn } from "./i18n/i18n.js";
import { allFiles } from "./file-types.js";

// ── Search ───────────────────────────────────────────────────────────────────
// The query is committed only by Enter or the Search button; editing it doesn't
// touch the results, the toolbar just shows that what's typed isn't what the
// results were found by (searchPending). See docs/stories/advanced-search.md.
// Search: { committed: JSON of the chips the shown results were found by,
//           colors: their match colors, by their place }

export const noSearch = Object.freeze({ committed: "[]", colors: [] });

// Runs the search for `chips`: an invalid regex is refused here (firstError()
// -> its error, "" if none), the rest by the backend (start(chips) -> its error,
// "" if the search started); colors() gives the match colors of the chips, asked
// for a search that started only.
// @returns { search: committed now, started, message: for the toolbar, "" if none }
export function runSearch(search, chips, colors, firstError, start) {
    const error = firstError() || start(chips);
    if (error) return { search, started: false, message: tr("Search error: {error}", { error }) };
    return { search: Object.freeze({ committed: JSON.stringify(chips), colors: colors() }), started: true, message: "" };
}

// Whether the chips typed aren't those the results were found by
export function searchPending(search, chips) {
    return JSON.stringify(chips) !== search.committed;
}

// ── Rules ────────────────────────────────────────────────────────────────────

// Edits a rule: open(values, error) shows the editor (-> what it closes with,
// null if cancelled), apply(result) gives it to the backend (-> its error, ""
// if taken). A rule the backend refuses (e.g. an invalid regular expression)
// opens the editor again with what was typed and the error.
// @returns true if the rule was applied, false if the editor was cancelled
export function editRule(values, open, apply) {
    let error = "";
    for (;;) {
        const result = open(values, error);
        if (!result) return false;
        error = apply(result);
        if (!error) return true;
        values = result;
    }
}

// ── Filter files ─────────────────────────────────────────────────────────────
// A filter file of DLT Explorer (.logfilter) for any log, a .dlf of dlt-viewer
// for a log that can take one (canDlf of the filters of the document).

// The types of files the dialog to load a filter offers: [[name, patterns], ...]
export function filterFilesToLoad(canDlf) {
    const native = [tr("DLT Explorer Filters"), "*.logfilter"];
    return canDlf
        ? [[tr("Filter Files"), "*.logfilter;*.dlf"], native, [tr("dlt-viewer Filters"), "*.dlf"], allFiles()]
        : [native, allFiles()];
}

// The dialog to export a set whose file (loaded from or exported to last) is
// `fileName` ("" if none): { caption, extension, types, path (absent: none) }
export function filterExportDialog(canDlf, fileName) {
    // The kind of its file is offered first; a .dlf only where the log takes one
    const dlf = canDlf && /\.dlf$/i.test(fileName);
    const native = [tr("DLT Explorer Filters"), "*.logfilter"];
    const dlt = [tr("dlt-viewer Filters"), "*.dlf"];
    const kinds = !canDlf ? [native] : dlf ? [dlt, native] : [native, dlt];
    const dialog = { caption: tr("Export Filter"), extension: dlf ? "dlf" : "logfilter", types: [...kinds, allFiles()] };
    // Without its extension: the dialog adds it itself (name.dlf.dlf otherwise)
    if (fileName) dialog.path = fileName.replace(/\.(dlf|logfilter)$/i, "");
    return dialog;
}

// ── Anchors ──────────────────────────────────────────────────────────────────

// What the user is told when the backend refused an anchor: its answer
// { refused: "limit" | "busy" | null, max }; "" if it wasn't refused
export function anchorRefusalText(answer) {
    if (answer.refused === "limit") return trn("{n} anchor at most", "{n} anchors at most", answer.max);
    if (answer.refused === "busy") return tr("Not while searching or filtering");
    return "";
}
