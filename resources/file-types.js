// The filter of a file dialog ("Name (*.a;*.b)|*.a;*.b|..." as Sciter takes it) from the types
// of files it offers: [name, patterns], the name in the language of the interface (tr() by
// the caller: a literal for scripts/i18n-extract), the patterns as they are.
// Sciter-free; tests: tests/js/file-types.test.mjs.
import { tr } from "./i18n/i18n.js";

// The filter of the types [[name, patterns], ...]
// (a | in a name, of a translation, would shift the pairs: it is a /)
export const fileFilter = (types) => types
    .map(([name, patterns]) => `${name.replace(/\s*\|\s*/g, " / ")} (${patterns})|${patterns}`).join("|");

// The type that ends a filter: any file
export const allFiles = () => [tr("All Files"), "*.*"];
