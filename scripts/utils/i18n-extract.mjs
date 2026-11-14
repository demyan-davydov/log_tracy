// Brings the catalogs of resources/i18n/translations up to the texts of the code, as lupdate
// does: finds the tr / trc / trn / trParts / uiText (D) calls and the marked elements (data-tr) in
// resources/ (*.js, the scripts and markup of *.htm) and source/ (*.d), outside comments,
// adds new texts untranslated (""), moves the texts gone from the code to "obsolete" (and
// back when they return), sorts the keys. A call or mark whose text is not a literal is an
// error: it can't be found.
//   node scripts/utils/i18n-extract.mjs            update the catalogs
//   node scripts/utils/i18n-extract.mjs --check    only tell what is out of date (exit code 1)
// See resources/i18n/i18n.js for the calls and the catalog; tests: tests/js/i18n-*.test.mjs.
import { readFileSync, writeFileSync, readdirSync, realpathSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { pluralCategories } from "../../resources/i18n/plural.js";

const translationsDir = "resources/i18n/translations";
// Where the calls are defined, not made.
const implementations = new Set(["resources/i18n/i18n.js", "resources/i18n/dom.js", "source/utils/ui_text.d"]);

// The string literals a text may be: of JS (no substitutions in a template), and of D (with
// the postfix of its width; WYSIWYG strings are not: their escapes are not escapes).
const literals = {
    js: /\s*("(?:[^"\\\n]|\\[\s\S])*"|'(?:[^'\\\n]|\\[\s\S])*'|`(?:[^`\\$]|\\[\s\S]|\$(?!\{))*`)/y,
    d: /\s*("(?:[^"\\]|\\[\s\S])*")[cwd]?/y,
};
const comma = /\s*,/y;
const end = /\s*[,)]/y;
const call = /(?<![\w.$])(trn|trc|trParts|tr|uiText)\s*\(/g;

const escapes = { n: "\n", t: "\t", r: "\r", 0: "\0", b: "\b", f: "\f", v: "\v" };

// The text of a JS or D string literal, its escapes decoded.
function decode(quoted) {
    return quoted.slice(1, -1).replace(/\\(x[0-9a-fA-F]{2}|u\{[0-9a-fA-F]+\}|u[0-9a-fA-F]{4}|U[0-9a-fA-F]{8}|\r?\n|[\s\S])/g, (_, e) => {
        if (e[0] === "x" && e.length === 3 || e[0] === "u" && e.length === 5)
            return String.fromCharCode(parseInt(e.slice(1), 16));
        if (e[0] === "u" && e[1] === "{" || e[0] === "U" && e.length === 9)
            return String.fromCodePoint(parseInt(e.replace(/^[uU]\{?|\}$/g, ""), 16));
        if (e[0] === "\n" || e[0] === "\r")
            return ""; // a line continuation
        return escapes[e] ?? e;
    });
}

const blank = (text) => text.replace(/[^\n]/g, " ");

// The end of the string literal opened at `i` by its quote.
function stringEnd(source, i, language) {
    const quote = source[i];
    const raw = language === "d" && quote === "`";
    const multiline = quote === "`" || language === "d" && quote === '"';
    let j = i + 1;
    while (j < source.length) {
        const c = source[j];
        if (c === "\\" && !raw)
            j += 2;
        else if (c === quote)
            return j + 1;
        else if (c === "\n" && !multiline)
            return j; // unterminated: a quote of a regex, say
        else
            j++;
    }
    return j;
}

// The end of the nesting comment of D opened at `i` ("/+ /+ +/ +/").
function nestedCommentEnd(source, i) {
    let depth = 0, j = i;
    while (j < source.length) {
        if (source.startsWith("/+", j))
            depth++, j += 2;
        else if (source.startsWith("+/", j)) {
            j += 2;
            if (--depth === 0)
                return j;
        } else
            j++;
    }
    return j;
}

// `source` with its comments blanked: lines and positions stay. Strings are skipped so that
// "//" in a string starts no comment. A regex literal is not known: a quote in one ends at
// the end of its line.
function withoutComments(source, language) {
    let out = "", i = 0;
    while (i < source.length) {
        const c = source[i], two = source.slice(i, i + 2);
        let stop = -1;
        if (two === "//") {
            const e = source.indexOf("\n", i);
            stop = e < 0 ? source.length : e;
        } else if (two === "/*") {
            const e = source.indexOf("*/", i + 2);
            stop = e < 0 ? source.length : e + 2;
        } else if (two === "/+" && language === "d")
            stop = nestedCommentEnd(source, i);
        if (stop >= 0) {
            out += blank(source.slice(i, stop));
            i = stop;
        } else if (c === '"' || c === "'" || c === "`") {
            const e = stringEnd(source, i, language);
            out += source.slice(i, e);
            i = e;
        } else {
            out += c;
            i++;
        }
    }
    return out;
}

// The markup of a page: its scripts and comments blanked, lines and positions stay.
function markupOf(page) {
    return page.replace(/(<script\b[^>]*>)([\s\S]*?)(<\/script>)/gi, (_, open, body, close) => open + blank(body) + close)
        .replace(/<!--[\s\S]*?-->/g, blank);
}

const entities = { amp: "&", lt: "<", gt: ">", quot: "\"", apos: "'" };
const decodeEntities = (text) => text.replace(/&(amp|lt|gt|quot|apos|#\d+);/g, (_, e) =>
    e[0] === "#" ? String.fromCharCode(parseInt(e.slice(1), 10)) : entities[e]);

const mark = /(?<![\w-])data-tr(?:-title|-placeholder)?(?![\w-])/g;
// "text" or 'text' in markup; in JSX also {"text"}, {'text'}
const markValue = /\s*=\s*(?:"([^"]*)"|'([^']*)'|\{\s*"([^"\\]*)"\s*\}|\{\s*'([^'\\]*)'\s*\})/y;

const contextMark = /(?<![\w-])data-tr-context(?![\w-])/g;

// The literal of the mark value at `pos` of `code`, or null.
function markLiteral(code, pos, decode) {
    markValue.lastIndex = pos;
    const value = markValue.exec(code);
    if (!value)
        return null;
    const literal = value[1] ?? value[2] ?? value[3] ?? value[4];
    return decode ? decodeEntities(literal) : literal;
}

// The context of the element whose tag holds the mark at `pos` (data-tr-context="noun"), or null.
function markContext(code, pos, decode) {
    const start = code.lastIndexOf("<", pos);
    const end = code.indexOf(">", pos);
    const tag = code.slice(start, end < 0 ? code.length : end);
    contextMark.lastIndex = 0;
    const m = contextMark.exec(tag);
    return m ? markLiteral(tag, m.index + m[0].length, decode) : null;
}

// The texts of the elements marked in `code` (dom.js: data-tr="Filters", data-tr-title="...",
// with data-tr-context="noun" the key of trc for the text of data-tr), added to `texts`; a mark without a literal text
// to `errors`. `decode`: the entities of HTML.
function markedTexts(code, decode, texts, errors) {
    for (const m of code.matchAll(mark)) {
        const text = markLiteral(code, m.index + m[0].length, decode);
        if (text !== null) {
            const context = m[0] === "data-tr" ? markContext(code, m.index, decode) : null;
            texts.push({ key: context ? `${text}|${context}` : text, source: text, plural: false });
        } else
            errors.push({ line: code.slice(0, m.index).split("\n").length, call: code.slice(m.index, m.index + 40).split("\n")[0] });
    }
}

// D `code` (comments blanked) with its unittest blocks blanked too, and those of
// version (unittest): their texts are no texts of the program. Lines and positions stay.
function withoutUnittests(code) {
    let out = code;
    for (const m of code.matchAll(/\bunittest\b|\bversion\s*\(\s*unittest\s*\)/g)) {
        const open = code.indexOf("{", m.index + m[0].length);
        // Attributes may stand before the brace (version (unittest) private {)
        const between = open < 0 ? ";" : code.slice(m.index + m[0].length, open);
        if (!/^(\s*(private|public|package|protected|static|@\w+))*\s*$/.test(between))
            continue; // `version (unittest):` or something else: left as it is
        let depth = 0, i = open;
        for (; i < code.length; i++) {
            const c = code[i];
            if (c === '"' || c === "'" || c === "`") {
                i = stringEnd(code, i, "d") - 1;
                continue;
            }
            if (c === "{") depth++;
            else if (c === "}" && --depth === 0) break;
        }
        out = out.slice(0, m.index) + blank(out.slice(m.index, i + 1)) + out.slice(i + 1);
    }
    return out;
}

// The scripts of a page, the rest blanked: lines and positions stay.
function scriptsOf(page) {
    let out = "", last = 0;
    for (const m of page.matchAll(/(<script\b[^>]*>)([\s\S]*?)<\/script>/gi)) {
        const start = m.index + m[1].length;
        out += blank(page.slice(last, start)) + m[2];
        last = start + m[2].length;
    }
    return out + blank(page.slice(last));
}

// Reads the literal at `pos` of `source`: [text, the position after it] or null.
function readLiteral(source, pos, after, literal) {
    literal.lastIndex = pos;
    const m = literal.exec(source);
    if (!m)
        return null;
    after.lastIndex = literal.lastIndex;
    if (!after.exec(source))
        return null;
    return [decode(m[1]), after === comma ? comma.lastIndex : literal.lastIndex];
}

// The texts to translate in `source` of `language` ("js", "d", or "htm": a page, its scripts
// and its markup): of the calls, then of the marked elements (data-tr="...", see
// resources/i18n/dom.js). {key as in a catalog ("text|context" for trc), source (the english
// text), plural, other (the english plural of a trn)}; and the calls and marks whose text is
// not a literal: {line, call}. Comments are skipped.
export function extractTexts(source, language = "js") {
    const uncommented = withoutComments(language === "htm" ? scriptsOf(source) : source, language === "d" ? "d" : "js");
    const code = language === "d" ? withoutUnittests(uncommented) : uncommented;
    const literal = literals[language === "d" ? "d" : "js"];
    const texts = [], errors = [];
    for (const m of code.matchAll(call)) {
        const before = code.slice(Math.max(0, m.index - 9), m.index);
        if (/function\s+$/.test(before))
            continue;
        const pos = m.index + m[0].length;
        const name = m[1];
        let text = null;
        if (name === "tr" || name === "trParts" || name === "uiText") {
            const first = readLiteral(code, pos, end, literal);
            text = first && { key: first[0], source: first[0], plural: false };
        } else {
            const first = readLiteral(code, pos, comma, literal);
            const second = first && readLiteral(code, first[1], end, literal);
            if (second)
                text = name === "trc"
                    ? { key: `${second[0]}|${first[0]}`, source: second[0], plural: false }
                    : { key: first[0], source: first[0], plural: true, other: second[0] };
        }
        if (text)
            texts.push(text);
        else
            errors.push({ line: code.slice(0, m.index).split("\n").length, call: code.slice(m.index, pos + 30).split("\n")[0] });
    }
    markedTexts(code, false, texts, errors);
    if (language === "htm")
        markedTexts(markupOf(source), true, texts, errors);
    return { texts, errors };
}

const sorted = (keys) => [...keys].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
// Whether `entry` is forms of a plural text: {one: "...", few: "...", ...}.
const isForms = (entry) => typeof entry === "object" && entry !== null && !Array.isArray(entry)
    && Object.values(entry).every((form) => typeof form === "string");

// Whether `entry` may be in a catalog: a text, or forms of texts.
const isValid = (entry) => typeof entry === "string" || isForms(entry);

// Whether `entry` translates nothing: none, "", or forms all "".
const isEmpty = (entry) => entry === undefined || entry === ""
    || isForms(entry) && Object.values(entry).every((form) => form === "");

// Whether `entry` translates the text: a string, or every form of `locale`.
function isTranslated(entry, plural, locale) {
    if (isEmpty(entry))
        return false;
    if (!plural)
        return typeof entry === "string";
    return isForms(entry) && pluralCategories(locale).every((c) => !isEmpty(entry[c]));
}

// Whether two calls with one key are the same text.
const sameText = (a, b) => a.source === b.source && a.plural === b.plural && a.other === b.other;

// `catalog` brought up to `texts`: {catalog, added, obsoleted, untranslated} (keys).
export function mergeCatalog(catalog, texts) {
    const messages = catalog.messages ?? {};
    const obsolete = { ...catalog.obsolete };
    const byKey = new Map(texts.map((t) => [t.key, t]));
    const added = [], obsoleted = [], untranslated = [];
    const nextMessages = {};
    for (const key of sorted(byKey.keys())) {
        let entry = messages[key];
        if (entry === undefined && key in obsolete) {
            entry = obsolete[key];
            delete obsolete[key];
        }
        if (entry === undefined) {
            entry = "";
            added.push(key);
        }
        nextMessages[key] = entry;
        if (!isTranslated(entry, byKey.get(key).plural, catalog.locale))
            untranslated.push(key);
    }
    for (const key of Object.keys(messages))
        if (!byKey.has(key) && !isEmpty(messages[key])) {
            obsolete[key] = messages[key];
            obsoleted.push(key);
        }
    const nextObsolete = {};
    for (const key of sorted(Object.keys(obsolete)))
        nextObsolete[key] = obsolete[key];
    const { messages: _, obsolete: __, ...header } = catalog;
    return {
        catalog: { ...header, messages: nextMessages, obsolete: nextObsolete },
        added: sorted(added), obsoleted: sorted(obsoleted), untranslated,
    };
}

// Whether `text` marks a mnemonic letter: "&" before it, "&&" is a "&" (ui/app_menu.parseLabel).
// Only before a letter or a digit: "Search & Filter" is no mnemonic.
const hasMnemonic = (text) => /&[\p{L}\p{N}]/u.test(text.replace(/&&/g, ""));

const parametersOf = (...texts) => sorted(new Set(texts.flatMap((t) => t.match(/\{\w+\}/g) ?? []))).join();

// What is wrong with `catalog` against the `texts` of the code: one key used for different
// texts, missing texts, texts not in the code, entries that are no texts, translations whose
// parameters, mnemonic or plural forms don't fit the source.
export function checkCatalog(catalog, texts) {
    const problems = [];
    if (!catalog.locale)
        problems.push("no locale");
    if (!catalog.name)
        problems.push("no name");
    const messages = catalog.messages ?? {};
    const keys = new Map(), conflicts = new Set();
    for (const text of texts) {
        const first = keys.get(text.key);
        if (first) {
            if (!sameText(first, text) && !conflicts.has(text.key)) {
                conflicts.add(text.key);
                problems.push(`conflicting uses: ${text.key}`);
            }
            continue;
        }
        keys.set(text.key, text);
        const entry = messages[text.key];
        if (entry === undefined) {
            problems.push(`missing: ${text.key}`);
            continue;
        }
        if (!isValid(entry)) {
            problems.push(`bad entry: ${text.key}`);
            continue;
        }
        if (isEmpty(entry))
            continue;
        if (!text.plural) {
            if (typeof entry !== "string")
                problems.push(`not a plural: ${text.key}`);
            else if (parametersOf(entry) !== parametersOf(text.source))
                problems.push(`parameters differ: ${text.key}`);
            else if (hasMnemonic(text.source) && !hasMnemonic(entry))
                problems.push(`mnemonic lost: ${text.key}`);
            else if (!hasMnemonic(text.source) && hasMnemonic(entry))
                problems.push(`mnemonic added: ${text.key}`);
            continue;
        }
        if (!isForms(entry)) {
            problems.push(`a plural: ${text.key}`);
            continue;
        }
        const missing = pluralCategories(catalog.locale).filter((c) => isEmpty(entry[c]));
        if (missing.length) {
            problems.push(`missing forms ${missing.join(", ")}: ${text.key}`);
            continue;
        }
        const expected = parametersOf(text.key, text.other);
        for (const [form, translation] of Object.entries(entry))
            if (parametersOf(translation) !== expected)
                problems.push(`parameters differ: ${text.key} (${form})`);
    }
    for (const key of Object.keys(messages))
        if (!keys.has(key))
            problems.push(`not in the code: ${key}`);
    return problems;
}

function filesOf(dir, extension) {
    return readdirSync(dir, { recursive: true, withFileTypes: true })
        .filter((e) => e.isFile() && e.name.endsWith(extension))
        .map((e) => join(e.parentPath ?? e.path, e.name));
}

// The language of the texts of a source file, by its extension; null: no texts in it.
const languageOf = (path) => (path.endsWith(".js") ? "js" : path.endsWith(".htm") ? "htm" : path.endsWith(".d") ? "d" : null);

// The texts of the code under `root` (the scripts and pages of resources/, the D sources of
// source/) and the calls without a literal ({file, line, call}).
export function scanSources(root) {
    const texts = [], errors = [];
    const files = [...filesOf(join(root, "resources"), ".js"), ...filesOf(join(root, "resources"), ".htm"),
        ...filesOf(join(root, "source"), ".d")];
    for (const path of sorted(files)) {
        const file = relative(root, path).split("\\").join("/");
        if (implementations.has(file))
            continue;
        const found = extractTexts(readFileSync(path, "utf8"), languageOf(path));
        texts.push(...found.texts);
        errors.push(...found.errors.map((e) => ({ file, ...e })));
    }
    return { texts, errors };
}

// The catalogs under `root`: [{file, path, catalog}].
export function loadCatalogs(root) {
    const dir = join(root, translationsDir);
    return sorted(readdirSync(dir).filter((name) => name.endsWith(".json"))).map((name) => {
        const path = join(dir, name);
        return { file: `${translationsDir}/${name}`, path, catalog: JSON.parse(readFileSync(path, "utf8")) };
    });
}

function main(check) {
    const root = fileURLToPath(new URL("../..", import.meta.url));
    const { texts, errors } = scanSources(root);
    for (const e of errors)
        console.error(`${e.file}:${e.line}: not a literal text: ${e.call}`);
    let outOfDate = errors.length > 0;
    for (const { file, path, catalog } of loadCatalogs(root)) {
        const merged = mergeCatalog(catalog, texts);
        const problems = checkCatalog(merged.catalog, texts);
        for (const p of problems)
            console.error(`${file}: ${p}`);
        const changed = JSON.stringify(merged.catalog) !== JSON.stringify(catalog);
        outOfDate ||= problems.length > 0 || (check && changed);
        if (changed && !check)
            writeFileSync(path, JSON.stringify(merged.catalog, null, 2) + "\n");
        console.log(`${file}: ${Object.keys(merged.catalog.messages).length} texts, ` +
            `${merged.added.length} added, ${merged.obsoleted.length} obsolete, ` +
            `${merged.untranslated.length} to translate${check && changed ? " (out of date)" : ""}`);
    }
    process.exitCode = outOfDate ? 1 : 0;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === realpathSync(process.argv[1])) // links resolved
    main(process.argv.includes("--check"));
