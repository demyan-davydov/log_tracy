// What the filter sets of a document (the filter panel, getFilters) say as a
// whole. Pure, so it can be tested with node. Tests: tests/js/filter-sets.test.mjs.

// True if any rule works on the log: an enabled rule, applied (no error), of an
// enabled set; a marker counts too (it colors the rows). Marks the tab of the
// filters (DocumentPane.markFiltersTab).
// @param sets - [{enabled, rules: [{enabled, error}]}]
export function filtersActive(sets) {
    return (sets ?? []).some(set => set.enabled && (set.rules ?? []).some(rule => rule.enabled && !rule.error));
}
