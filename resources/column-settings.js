// The Columns section of the Settings dialog, without Sciter (tests/js).
// A format is as getColumnSettings gives it: { id, name, payload (the title
// of the last column), defaults (the ids in the order of the format),
// columns: [{ id, title, visible }] in the order shown }. Index and Payload
// are not in `columns`: they are always shown, first and last. Every
// function returns a new format and leaves the one it got as it is.
import { moveItem } from "./drag-order.js";

// The format with the column `id` shown if it was hidden and hidden if shown
export function toggleColumn(format, id) {
    const columns = format.columns.map(c => c.id === id ? { ...c, visible: !c.visible } : c);
    return { ...format, columns };
}

// The format with the column at `from` moved to the place `to`
export function moveColumn(format, from, to) {
    return { ...format, columns: moveItem(format.columns, from, to) };
}

// The format with its columns as they are without a layout
export function resetColumns(format) {
    const columns = format.defaults
        .map(id => format.columns.find(c => c.id === id))
        .filter(c => c)
        .map(c => ({ ...c, visible: true }));
    return { ...format, columns };
}

// true if the format shows its columns as it does without a layout
export function isDefaultLayout(format) {
    return format.columns.length === format.defaults.length
        && format.columns.every((c, i) => c.visible && c.id === format.defaults[i]);
}

// The layouts of `formats` for setColumnLayouts: { id: [{ id, visible }] }
export function layoutsOf(formats) {
    const layouts = {};
    for (const format of formats)
        layouts[format.id] = format.columns.map(c => ({ id: c.id, visible: c.visible }));
    return layouts;
}

// The index in `formats` of the format to show first: `current` (that of the
// active document) if it has columns to arrange, else the first one
export function initialFormat(formats, current) {
    if (!formats.length) return -1;
    return Math.max(0, formats.findIndex(f => f.id === current));
}

// The name of a format in the list of formats; that of the active document
// (`current`) is marked
export function formatLabel(format, current) {
    return format.id === current ? `${format.name} (current file)` : format.name;
}
