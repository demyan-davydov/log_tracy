// The sections of the Settings dialog, without Sciter (tests/js): which one
// the dialog opens on.

// The section shown first: the one the opener asked for (`params.section`)
// if the dialog has it, else Appearance; opened on its own (no parameters, to
// look at it) it shows Table
export function initialSection(params, sections) {
    if (!params) return "table";
    return sections.includes(params.section) ? params.section : "appearance";
}

// The font sizes of the log tables offered, in % of the normal font
export const fontSizes = [80, 90, 100, 110, 125, 150, 175, 200];

// The options of the font size: { value, label, initial }, the size the
// dialog opened with (100 when none) marked `initial`, shown in italics so the
// user sees where they started; a size not in the list (settings edited by hand) is added in its place
export function fontSizeOptions(initial) {
    const start = Number.isInteger(initial) && initial > 0 ? initial : 100; // settings keep an int
    const values = fontSizes.includes(start) ? fontSizes : [...fontSizes, start].sort((a, b) => a - b);
    return values.map(value => ({ value, initial: value === start, label: `${value}%` }));
}
