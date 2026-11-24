// The filter of a file dialog ("Name (*.a;*.b)|*.a;*.b|..." as Sciter takes it) from the types
// of files it offers: [name, patterns], the name in the language of the interface (tr() by
// the caller: a literal for scripts/utils/i18n-extract), the patterns as they are.
// Sciter-free; tests: tests/js/file-types.test.mjs.
import { tr } from "./i18n/i18n.js";

// The filter of the types [[name, patterns], ...]
// (a | in a name, of a translation, would shift the pairs: it is a /)
export const fileFilter = (types) => types
    .map(([name, patterns]) => `${name.replace(/\s*\|\s*/g, " / ")} (${patterns})|${patterns}`).join("|");

// The type that ends a filter: any file
export const allFiles = () => [tr("All Files"), "*.*"];

// The filter of the dialog that opens a log. A log has any name (`.bin`, `.out`, `.gz` to be
// unpacked, none), so the types here only help to find it. macOS: none, its panel takes the
// patterns of every type for the only extensions that can be chosen, "All Files" doesn't lift it
// (the dialog of a FIBEX keeps its filter: it is XML)
export function logFileFilter(mac) {
    if (mac) return "";
    return fileFilter([[tr("Log Files"), "*.dlt;*.log;*.txt"], [tr("DLT Files"), "*.dlt"],
        [tr("Text Logs"), "*.log;*.txt"], allFiles()]);
}
