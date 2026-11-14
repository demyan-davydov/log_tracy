// What the File Info page of a document shows: its file, its size and how many
// records it has, the format it was opened with. Sciter-free; tests:
// tests/js/file-info.test.mjs.
import { tr, trn } from "./i18n/i18n.js";

// `n` with its digits grouped by three, by a no-break space: read the same in
// every language (Sciter draws no narrow one, U+202F)
export function groupDigits(n) {
    return String(n).replace(/\B(?=(\d{3})+$)/g, " ");
}

// A size of `bytes` for people: in bytes below a kilobyte, otherwise in the
// largest unit of 1024 it reaches, with one decimal
export function sizeText(bytes) {
    if (bytes < 1024)
        return trn("{count} byte", "{count} bytes", bytes, { count: groupDigits(bytes) });
    // Each a literal for scripts/utils/i18n-extract
    const units = [
        (size) => tr("{size} KB", { size }),
        (size) => tr("{size} MB", { size }),
        (size) => tr("{size} GB", { size }),
        (size) => tr("{size} TB", { size }),
    ];
    let value = bytes / 1024;
    let unit = 0;
    // By the value shown: 1023.96 KB is shown as 1.0 MB, not 1024.0 KB
    while (Number(value.toFixed(1)) >= 1024 && unit < units.length - 1) {
        value /= 1024;
        unit++;
    }
    return units[unit](value.toFixed(1));
}

// The rows of the page for `info` of backend.documentInfo ({name, path,
// format, bytes, records}, null if the document isn't open): [{label, value}].
// The name is not repeated: the tab of the document shows it, the path ends
// with it. `status`: of the main view (source/ui/main_view_fsm.d); while the
// file loads the records are those found so far, after a failed load those
// of the part loaded
export function fileInfoRows(info, status) {
    if (!info) return [];
    const count = groupDigits(info.records);
    const all = trn("{count} record", "{count} records", info.records, { count });
    const records = status === "loadingFile" ? tr("{records}, loading...", { records: all })
        : status === "loadFailed" ? tr("{records}, not loaded completely", { records: all })
        : all;
    return [
        { label: tr("Path"), value: info.path },
        {
            label: tr("Size"),
            value: `${sizeText(info.bytes)} · ${records}`,
        },
        { label: tr("Format"), value: info.format },
    ];
}
