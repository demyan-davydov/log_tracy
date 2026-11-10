// The size of the search (bottom) panel as the settings keep it,
// { searchPanelHeight } ("177dip"), and the splitter of a panel, { rows }
// ("*,177dip"), as its frameset takes it. Kept free of Sciter: tests/js.

// The size of the panel in `splitters`: the one measured on the panel
// (searchPanelHeight, see DocumentPane.hide) if it has it, otherwise the one
// its splitter was made of (defaults, splittersOf()). Not read from the
// frameset state: after a drag the frameset may fix the other side and leave
// the panel flexible.
export function panelSizesOf(splitters) {
    const rows = splitters.rows.split(",").map(size => size.trim());
    return { searchPanelHeight: splitters.searchPanelHeight ?? rows[rows.length - 1] };
}

// The splitter of a new panel with the size `saved` (null: none), the
// `defaults` if it isn't saved
export function splittersOf(saved, defaults) {
    return { rows: saved?.searchPanelHeight ? `*,${saved.searchPanelHeight}` : defaults.rows };
}
