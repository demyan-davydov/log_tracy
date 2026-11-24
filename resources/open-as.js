// "Open as": the choice of the format a log is opened in by hand, where it is told: File
// Info, the menu of a tab, the menu of a recent file. Sciter-free; tests: tests/js/open-as.test.mjs.
import { tr } from "./i18n/i18n.js";

// The items of the list: [{ format, label, current, detected }], detecting the format again
// first (`format` ""), then `formats` of backend.formats() as they come; `current` is the id of
// the one the log is open in ("" for none), `detected` the one detection picks for its file
// (backend.documentInfo, recentFiles; "" or none: no mark). The label of a format is its own name
export function openAsItems(formats, currentId, detectedId = "") {
    return [
        { format: "", label: tr("Detect automatically"), current: false, detected: false },
        ...formats.map(({ id, name }) => ({
            format: id, label: name, current: id === currentId, detected: detectedId !== "" && id === detectedId,
        })),
    ];
}
