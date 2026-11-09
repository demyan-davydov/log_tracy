// The sections of the Settings dialog, without Sciter (tests/js): which one
// the dialog opens on.

// The section shown first: the one the opener asked for (`params.section`)
// if the dialog has it, else Appearance; opened on its own (no parameters, to
// look at it) it shows Columns
export function initialSection(params, sections) {
    if (!params) return "columns";
    return sections.includes(params.section) ? params.section : "appearance";
}
