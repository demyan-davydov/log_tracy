// The colors of the filter rules for the rows of the log table: a row refers
// by its id to the first rule with a color its record matches (the backend
// passes by the rules without one), its color is looked up here. Pure, so it can be tested with node.
// Tests: tests/js/rule-colors.test.mjs.

// @param sets - the sets of the filter panel (getFilters): [{rules: [{id, color}]}]
// @returns Map of rule id -> "#rrggbb"
export function ruleColors(sets) {
    const colors = new Map();
    for (const set of sets ?? [])
        for (const rule of set.rules ?? [])
            if (rule.color) // #rrggbb: the backend gives no other (DocumentFilters.toJson)
                colors.set(rule.id, rule.color);
    return colors;
}
