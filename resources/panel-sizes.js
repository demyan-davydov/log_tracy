// The sizes of the side panel and the search (bottom) panel as the settings
// keep them, { sidePanelWidth, searchPanelHeight } ("333dip"), and the sizes
// of the splitters of a panel, { cols, rows } ("333dip,*", "*,177dip"), as
// its framesets take them. Kept free of Sciter: tests/js.

// The sizes of the panels in `splitters`: the ones measured on the panel
// (sidePanelWidth, searchPanelHeight, see DocumentPane.hide) if it has them,
// otherwise those its splitters were made of (defaults, splittersOf()). Not
// read from the frameset states: after a drag the frameset may fix the other
// side and leave the panel flexible.
export function panelSizesOf(splitters) {
    const cols = splitters.cols.split(",").map(size => size.trim());
    const rows = splitters.rows.split(",").map(size => size.trim());
    return {
        sidePanelWidth: splitters.sidePanelWidth ?? cols[0],
        searchPanelHeight: splitters.searchPanelHeight ?? rows[rows.length - 1],
    };
}

// The splitters of a new panel with the sizes `saved` (null: none), the
// `defaults` for a size not saved
export function splittersOf(saved, defaults) {
    return {
        cols: saved?.sidePanelWidth ? `${saved.sidePanelWidth},*` : defaults.cols,
        rows: saved?.searchPanelHeight ? `*,${saved.searchPanelHeight}` : defaults.rows,
    };
}
