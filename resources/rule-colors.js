// The colors of the filter rules for the rows of the log table: a row refers
// by its id to the first rule with a color its record matches (the backend
// passes by the rules without one), its color is looked up here; and the color
// of a text on a rule's color (its chip in the Filters page). Pure, so it can
// be tested with node.
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

// The text color that reads best on `color` (#rrggbb): black or white, the one
// of the higher contrast ratio by WCAG 2 (Sciter has no contrast-color())
export function contrastText(color) {
    const linear = c => c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
    const channel = i => linear(parseInt(color.substr(1 + 2 * i, 2), 16) / 255);
    const luminance = 0.2126 * channel(0) + 0.7152 * channel(1) + 0.0722 * channel(2);
    // (L + 0.05) / 0.05 against black, 1.05 / (L + 0.05) against white
    return (luminance + 0.05) ** 2 >= 1.05 * 0.05 ? "#000000" : "#ffffff";
}
