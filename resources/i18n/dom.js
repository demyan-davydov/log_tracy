// The texts of the elements built once (the static markup of a page, the JSX skeleton of a
// panel) in the language of the interface, again whenever it changes. An element is marked
// with the english source of what to translate:
//   <header data-tr="Filters" />               its text
//   <button data-tr-title="New Tab">+</button> its title (data-tr-placeholder: its placeholder)
// The source is a literal: scripts/i18n-extract finds the texts by it. Texts rendered anew
// call tr() themselves instead. An element marked with data-tr has its text replaced: mark
// one that holds only text (a <span> of its own inside, not a header with an icon in it).
// Free of Sciter but for the DOM (querySelectorAll, attributes, textContent); tests:
// tests/js/i18n-dom.test.mjs.
import { tr } from "./i18n.js";

const attributes = [["data-tr-title", "title"], ["data-tr-placeholder", "placeholder"]];

// Translates the marked elements of `root` (an element or the document).
export function translateTree(root) {
    for (const element of root.querySelectorAll("[data-tr]"))
        element.textContent = tr(element.getAttribute("data-tr"));
    for (const [mark, attribute] of attributes)
        for (const element of root.querySelectorAll(`[${mark}]`))
            element.setAttribute(attribute, tr(element.getAttribute(mark)));
}
