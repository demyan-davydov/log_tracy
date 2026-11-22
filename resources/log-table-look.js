//! The look of the log table as the script collects it for D (`logTableSetLook(json)`): the colors of the
//! theme's CSS variables by the names of the fields of the palette (source/ui/log_table/log_look.d, LogPalette), the
//! lengths of the variables of `.log-table` in dips by the names of the fields of the spacing (LogSpacing) and the
//! scale and font of the text. Pure: the value of a variable comes from the `read` function the caller gives, so this is
//! tested without Sciter (tests/js/log-table-look.test.mjs). D parses the colors (source/ui/log_table/look_json.d); a
//! name the theme has no variable for, or whose value is empty, is left out and D keeps the color it has.

import { matchColorCount } from "./match-colors.js";

// The fields of the palette and the CSS variables of the table that give them, named as Sciter's
// `style.variable(name)` takes them (without the `--`; with it the answer is undefined). Sciter answers a color
// of any form (`bisque`, `morph()`) as `#rrggbb`.
export const paletteVariables = {
    row: "bg-row",
    stripe: "bg-row-stripe",
    selected: "bg-row-selected",
    found: "bg-row-found",
    foundStripe: "bg-row-found-stripe",
    currentRow: "border-row-current",
    currentRowInactive: "border-row-current-inactive",
    header: "bg-table-header",
    border: "border-color",
    textSelected: "bg-text-selected",
    ink: "text-main",
    selectedInk: "text-row-selected",
    fatalBg: "log-fatal-bg",
    fatalText: "log-fatal-text",
    error: "log-error",
    warn: "log-warn",
    info: "log-info",
    debug_: "log-debug",
    groupBand: "bg-group",
    groupPlate: "bg-group-plate",
    groupLine: "group-line-color",
    groupInk: "text-group-plate",
    anchorFill: "bg-anchor",
    anchorLine: "anchor-border-color",
    anchorFaint: "anchor-faint",
    anchorRefused: "anchor-refused",
};

// The fields of the spacing of the log table (source/ui/log_table/log_look.d, LogSpacing) and the CSS variables of
// `.log-table` that give them (resources/table.css). Sciter answers a length as an object whose number is its size in
// dips, whatever its unit (9pt is 12, 1.5em is in the element's font): a length in any unit of CSS comes as dips.
export const spacingVariables = {
    groupPadTop: "group-pad-top",
    groupPadBottom: "group-pad-bottom",
    payloadPadLeft: "payload-pad-left",
    payloadPadRight: "payload-pad-right",
    rowsMarginTop: "rows-margin-top",
    rowsMarginBottom: "rows-margin-bottom",
    rowsMarginLeft: "rows-margin-left",
    rowsMarginRight: "rows-margin-right",
};

// The size in dips of a length `read` gave, NaN if it is none (a text that is no number, below 0)
const dipsOf = value => {
    if (value === null || value === undefined || typeof value === "string") return NaN;
    const dips = Number(value);
    return Number.isFinite(dips) && dips >= 0 ? dips : NaN;
};

// The text of a value `read` gave: a string as it is, a color or another object by its own text
const textOf = value => {
    if (value === null || value === undefined) return "";
    const text = typeof value === "string" ? value : String(value);
    return text === "undefined" || text === "null" ? "" : text.trim();
};

// The key of the least width a variable gives (D names the variables, resources/../ui/log_table/column_widths.d): `column-min-width-dlt-time`
// is `dlt-time`, the plain `column-min-width` is `default`; "" for a name of another kind
export const minWidthKey = name => {
    const prefix = "column-min-width";
    if (name === prefix) return "default";
    return name.startsWith(prefix + "-") && name.length > prefix.length + 1 ? name.slice(prefix.length + 1) : "";
};

// What `setLook` is told: { name: "css color", ..., spacing: { name: dips }, scale, monospacePayload } for the variables
// that have a value; `percent` is the font size of the tables in % of the normal one, `monospacePayload` whether the
// Payload is in the monospace font of the levels (Settings, both). The monospace is always told: D keeps what
// a look does not say, so leaving it out would never turn it off
export function collectLook(read, percent = 100, minWidthNames = [], monospacePayload = false) {
    const look = {};
    for (const [name, variable] of Object.entries(paletteVariables)) {
        let value = "";
        try {
            value = textOf(read(variable));
        } catch (e) {
            value = "";
        }
        if (value) look[name] = value;
    }
    const spacing = {};
    for (const [name, variable] of Object.entries(spacingVariables)) {
        let dips = NaN;
        try {
            dips = dipsOf(read(variable));
        } catch (e) {
            dips = NaN;
        }
        if (!Number.isNaN(dips)) spacing[name] = dips;
    }
    // the colors of the search chips, an array by their place: a missing or empty one is left as "" for D to keep its color
    const match = [];
    for (let i = 0; i < matchColorCount; i++) {
        let value = "";
        try {
            value = textOf(read(`match-color-${i}`));
        } catch (e) {
            value = "";
        }
        match.push(value);
    }
    if (match.some(Boolean)) look.match = match;
    // the least widths of the columns in dips, by the keys D knows (the name without `column-min-width-`, `default` for the plain one)
    const minWidths = {};
    for (const name of minWidthNames) {
        const key = minWidthKey(name);
        if (!key) continue;
        let dips = NaN;
        try {
            dips = dipsOf(read(name));
        } catch (e) {
            dips = NaN;
        }
        if (!Number.isNaN(dips)) minWidths[key] = dips;
    }
    if (Object.keys(minWidths).length) look.minWidths = minWidths;
    if (Object.keys(spacing).length) look.spacing = spacing;
    if (percent > 0) look.scale = percent / 100;
    look.monospacePayload = monospacePayload === true;
    return look;
}
