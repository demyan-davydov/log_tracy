// The sections of the Settings dialog, without Sciter (tests/js): which one
// the dialog opens on.

// The section shown first: the one the opener asked for (`params.section`)
// if the dialog has it, else Appearance; opened on its own (no parameters, to
// look at it) it shows Table
export function initialSection(params, sections) {
    if (!params) return "table";
    return sections.includes(params.section) ? params.section : "appearance";
}

// The font size of the log tables, in % of the normal font: a slider of this range
export const fontSizeRange = { min: 80, max: 200, step: 5 };

// The size the dialog starts with: the setting, 100 when it has none or an
// impossible one (settings keep an int)
export function startFontSize(setting) {
    return Number.isInteger(setting) && setting > 0 ? setting : 100;
}

// The marks of the slider: { value, label, className }, one at every step:
// "major" every 20% with its label, "ten" every 10%, "step" between; the
// normal size is also "normal", the size the dialog opened with "initial" so
// the user sees where they started. A start off the step (settings edited by
// hand) gets a mark of its own without a label
export function fontSizeMarks(setting) {
    const start = startFontSize(setting);
    const { min, max, step } = fontSizeRange;
    const marks = [];
    for (let value = min; value <= max; value += step) {
        const kind = value % 20 === 0 ? "major" : value % 10 === 0 ? "ten" : "step";
        marks.push({
            value, label: kind === "major" ? `${value}%` : "",
            className: [kind, value === 100 ? "normal" : "", value === start ? "initial" : ""].filter(Boolean).join(" "),
        });
    }
    if (!marks.some(m => m.value === start)) marks.push({ value: start, label: "", className: "initial" });
    return marks;
}
