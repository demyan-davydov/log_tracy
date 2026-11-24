// The items of the "Open as" list as markup, for the three menus that have it: the Format row
// of File Info (document-pane.js), the menu of a tab and the menu of a recent file (script.js).
// What the list holds is open-as.js.
import { tr } from "i18n/i18n.js";
import { openAsItems } from "open-as.js";

// The <li> of every item for `formats` (backend.formats()), the one the log is open in current,
// the one detection picks marked at the right ("auto-detected", in the grey of a shortcut);
// `docId`: the tab's, for the menu of a tab (its click reads it)
export function openAsListItems(formats, currentId, detectedId, docId = "") {
    return openAsItems(formats, currentId, detectedId).map(({ format, label, current, detected }) =>
        <li command="open-as-format" class={current ? "format-current" : ""} format={format} docid={docId}>
            {label}{detected ? <span class="format-note">{tr("auto-detected")}</span> : []}
        </li>);
}

// The text of the button that opens the list: a small triangle after the label, as text
export const openAsButtonText = label => `${label} \u25BE`;
