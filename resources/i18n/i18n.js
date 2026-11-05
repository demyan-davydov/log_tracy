// The texts of the interface in the language of the user. The code writes the english text,
// which is the key of its translation and what is shown when there is none:
//   tr("Open File..."), tr("Found {count}", { count }),
//   trc("noun", "Filter")                    a context tells homonyms apart,
//   trn("{n} match", "{n} matches", n)       the plural form of the language; n goes in as {n}.
// The argument is always a string literal: scripts/i18n-extract finds the texts by it.
// A catalog is a file of resources/i18n/translations ({locale, name, messages}); the key of a
// text with a context is "text|context", a plural text is keyed by its singular and
// translated by the forms of its language ({one, few, many}); "" is not translated yet.
// Sciter-free; tests: tests/js/i18n.test.mjs.
import { pluralCategory } from "./plural.js";

// The locale of the pseudo translation (BCP 47 private use): every text is the english one
// accented and lengthened, to see on screen what is not translated and what gets cut.
export const pseudoLocale = "x-pseudo";

let catalog = null;

// Translate by `next` from now on; null: the english source.
export function setCatalog(next) {
    catalog = next;
}

// `text` with its {name} parameters put in from the own fields of `args`; an unknown one stays
// as written.
export function format(text, args) {
    if (!args || typeof args !== "object")
        return text;
    return text.replace(/\{(\w+)\}/g, (match, name) => (Object.prototype.hasOwnProperty.call(args, name) ? String(args[name]) : match));
}

const accented = {
    A: "Å", B: "Ɓ", C: "Ç", D: "Ð", E: "É", F: "Ƒ", G: "Ĝ", H: "Ĥ", I: "Î", J: "Ĵ", K: "Ķ", L: "Ļ", M: "Ṁ",
    N: "Ñ", O: "Ô", P: "Þ", Q: "Ǫ", R: "Ŕ", S: "Š", T: "Ţ", U: "Û", V: "Ṽ", W: "Ŵ", X: "Ẋ", Y: "Ý", Z: "Ž",
    a: "á", b: "ƀ", c: "ç", d: "ð", e: "é", f: "ƒ", g: "ĝ", h: "ĥ", i: "î", j: "ĵ", k: "ķ", l: "ļ", m: "ṁ",
    n: "ñ", o: "ô", p: "þ", q: "ǫ", r: "ŕ", s: "š", t: "ţ", u: "û", v: "ṽ", w: "ŵ", x: "ẋ", y: "ý", z: "ž",
};

// The pseudo translation of `text`: letters accented, padded by 30% of the visible text, in
// brackets. Parameters and the mnemonic letter (after "&") stay as they are.
export function pseudoize(text) {
    let visible = 0;
    const body = text.replace(/\{\w+\}|&.?|./gsu, (part) => {
        if (part.startsWith("{") && part.length > 1)
            return part;
        visible += part.length === 2 && part[0] === "&" ? 1 : part.length;
        return part[0] === "&" ? part : accented[part] ?? part;
    });
    return `[${body} ${"~".repeat(Math.max(1, Math.round(visible * 0.3)))}]`;
}

// The translation of the catalog under `key`, if there is one.
function translated(key) {
    const text = catalog?.messages?.[key];
    return typeof text === "string" && text !== "" ? text : null;
}

function translate(key, source, args) {
    if (catalog?.locale === pseudoLocale)
        return format(pseudoize(source), args);
    return format(translated(key) ?? source, args);
}

// The translation of `text`, its {name} parameters put in from `args`.
export const tr = (text, args) => translate(text, text, args);

// The translation of `text` in the sense `context` ("noun", "verb").
export const trc = (context, text, args) => translate(`${text}|${context}`, text, args);

// The plural form for `n` of the translation of `one` (english: `one` for 1, `other` otherwise);
// `n` goes in as {n}, other parameters from `args`.
export function trn(one, other, n, args) {
    const values = { ...args, n };
    const english = n === 1 ? one : other;
    if (catalog?.locale === pseudoLocale)
        return format(pseudoize(english), values);
    const forms = catalog?.messages?.[one];
    const form = forms && typeof forms === "object" ? forms[pluralCategory(catalog.locale, n)] : null;
    return format(typeof form === "string" && form !== "" ? form : english, values);
}
