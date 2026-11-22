// The size of the search (bottom) panel as the settings keep it,
// { searchPanelHeight, bottomPanelCollapsed } ("177dip", false), and the
// splitter of a panel, { rows } ("*,177dip"), as its frameset takes it. A
// collapsed panel shows only the strip of its tabs: its splitter is
// { rows, collapsed: true, searchPanelHeight } with the height it expands to.
// Kept free of Sciter: tests/js.

// The height of a panel when nothing else tells one
const defaultHeight = "250dip";

// The splitter of a panel when nothing is saved
export const defaultRows = `*,${defaultHeight}`;

// The last size of the rows of a frameset ("*, 250dip" -> "250dip")
const lastRow = rows => rows.split(",").map(size => size.trim()).pop();

// The size of the panel in `splitters`: the one measured on the panel
// (searchPanelHeight, see DocumentPane.hide) if it has it, otherwise the one
// its splitter was made of (defaults, splittersOf()). Not read from the
// frameset state: after a drag the frameset may fix the other side and leave
// the panel flexible. A collapsed panel always has searchPanelHeight: the
// height it expands to, not that of its tabs
export function panelSizesOf(splitters) {
    const collapsed = splitters.collapsed === true;
    return {
        searchPanelHeight: splitters.searchPanelHeight ?? (collapsed ? defaultHeight : lastRow(splitters.rows)),
        bottomPanelCollapsed: collapsed,
    };
}

// The splitter of a new panel with the size `saved` (null: none), the
// `defaults` if it isn't saved. Saved collapsed: collapsed, with the height
// saved (or that of `defaults`) to expand to
export function splittersOf(saved, defaults) {
    if (saved?.bottomPanelCollapsed === true)
        return { rows: rowsOf(null, true).join(","), collapsed: true,
            searchPanelHeight: saved.searchPanelHeight || lastRow(defaults.rows) };
    return { rows: saved?.searchPanelHeight ? `*,${saved.searchPanelHeight}` : defaults.rows };
}

// The rows of the frameset (frameset.state) of a panel collapsed or expanded
// to `height` (null: the default one). Collapsed, its row is 0: the CSS of
// .bottom-panel.collapsed keeps the height of its tabs (min-height)
export function rowsOf(height, collapsed) {
    return ["1*", collapsed ? "0dip" : height ?? defaultHeight];
}

// The bottom panel in `state` { collapsed, expandedHeight } made `collapsed`, its height now `measured`
// (taken when it collapses): { collapsed, expandedHeight, rows (frameset.state), rowsFirst (the rows are
// set before the pages are hidden or shown) }; null if it is so already
export function collapseStep(state, collapsed, measured) {
    if (collapsed === (state.collapsed === true)) return null;
    const expandedHeight = collapsed ? measured : state.expandedHeight;
    return { collapsed, expandedHeight, rows: rowsOf(expandedHeight, collapsed), rowsFirst: collapsed };
}

// The tab marked active of the bottom panel in `state` { collapsed, bottomPage }: none while collapsed
export function activeTabOf(state) {
    return state.collapsed ? null : state.bottomPage;
}
