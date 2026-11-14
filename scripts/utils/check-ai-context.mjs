// Finds what the shared context of the repository (.ai/, AGENTS.md, CLAUDE.md, .claude/) names
// in backquotes and the code no longer has: a path that isn't there, an identifier or a command
// line option no file of the code has. Deterministic, no model; run by `build.mjs test`.
// A name that is right though the code doesn't have it (a file the program writes, an API of
// Sciter): `allowed` below. Tests: tests/js/check-ai-context.test.mjs.
import { spawnSync } from "node:child_process";
import { readFileSync, realpathSync } from "node:fs";
import { basename } from "node:path";
import { fileURLToPath } from "node:url";

/// Names the code doesn't have that are still right, each with why.
export const allowed = new Map([
    ["settings.json", "written by the program next to it"],
    ["--no-ff", "an option of git"],
    ["--compiler=ldc2", "an option of dub"],
    ["MouseEvent", "an API of the platform"],
    ["getComputedStyle", "an API of the platform"],
    ["CGEvent", "an API of the platform"],
    [".edit.selectRange/selectionStart/insertText", "an API of Sciter"],
]);

/// Paths outside the repository, by their start: local logs, what a build writes, the folders
/// of the Sciter SDK.
export const outsidePaths = ["test_data", "build/", "samples.sciter", "docs/md", "bin/"];

/// The spans in backquotes of a markdown text, with their line (from 1); fenced blocks are left
/// out, a span of several backquotes ends at as many.
export function codeSpans(text) {
    const spans = [];
    let fenced = false;
    text.split("\n").forEach((line, i) => {
        if (/^\s*(```|~~~)/.test(line)) {
            fenced = !fenced;
            return;
        }
        if (fenced) return;
        for (const match of line.matchAll(/(`+)(.+?)\1(?!`)/g)) spans.push({ line: i + 1, span: match[2].trim() });
    });
    return spans;
}

const pathPattern = /^\.?[\w-]+(\.[\w-]+)*(\/\.?[\w-]+(\.[\w-]+)*)*\/?(:\d+)?$/;
const fileExtensions = /\.(d|mjs|js|md|htm|html|css|json|sdl|py|sh|rc)$/;

/// What a span names: "path", "identifier", "option", or null for anything else (a command,
/// an expression, a plain word, a pattern) the check leaves alone.
export function classify(span) {
    if (/^--[a-z][\w-]*(=\S*)?$/.test(span)) return "option";
    if (/[\s"'[\]=<>*$]|:\/\//.test(span)) return null;
    if (pathPattern.test(span) && (span.includes("/") || fileExtensions.test(span.replace(/:\d+$/, "")))) return "path";
    if (/^[A-Za-z_]\w*(\.[A-Za-z_]\w*)*(\(\))?$/.test(span)) {
        const name = span.replace(/\(\)$/, "");
        const camel = name.split(".").some((part) => /^[A-Za-z][a-z0-9]*[A-Z]/.test(part) || /^[A-Z][a-z]/.test(part));
        if ((camel || name.includes(".") || span.endsWith("()")) && !name.includes("_")) return "identifier";
    }
    return null;
}

function hasPath(path, code) {
    if (!path.includes("/") && code.basenames.has(path)) return true;
    const candidates = [path, `source/${path}`, `source/${path}.d`, `resources/${path}`, `resources/${path}.js`];
    return candidates.some((candidate) => code.files.has(candidate) || code.dirs.has(candidate));
}

/// What staleReason looks a span up in: the files of the repository (relative paths) and the
/// text of the code.
export function indexCode(files, codeText) {
    const dirs = new Set();
    for (const file of files) {
        const parts = file.split("/");
        for (let i = 1; i < parts.length; i++) dirs.add(parts.slice(0, i).join("/"));
    }
    return { files: new Set(files), dirs, basenames: new Set(files.map((file) => basename(file))),
        words: new Set(codeText.match(/[A-Za-z_]\w*/g) ?? []), text: codeText };
}

/// Why a span is stale, or null when the code has it (or it isn't a name the check knows).
export function staleReason(span, code) {
    if (allowed.has(span)) return null;
    const kind = classify(span);
    if (kind === "path") {
        const path = span.replace(/:\d+$/, "").replace(/\/$/, "");
        if (outsidePaths.some((start) => `${path}/`.startsWith(start))) return null;
        if (hasPath(path, code)) return null;
        // a member of a module: ui/filter_commands.DocumentFilters
        const member = /^(.+\/[\w-]+)\.([A-Za-z_]\w*)$/.exec(path);
        if (member && !fileExtensions.test(path)) {
            if (!hasPath(member[1], code)) return `no file or folder ${member[1]}`;
            return code.words.has(member[2]) ? null : `${member[2]} is not in the code`;
        }
        return `no file or folder ${path}`;
    }
    if (kind === "identifier") {
        const last = span.replace(/\(\)$/, "").split(".").at(-1);
        return code.words.has(last) ? null : `${last} is not in the code`;
    }
    if (kind === "option") {
        const name = span.replace(/=.*$/, "");
        const bare = name.slice(2);
        // the whole option (not the start of a longer one), or its name quoted as getopt takes it
        const whole = new RegExp(`${name.replace(/[-]/g, "\\-")}(?![\\w-])`);
        if (whole.test(code.text) || code.text.includes(`"${bare}"`) || code.text.includes(`'${bare}'`)) return null;
        return `${name} is not in the code`;
    }
    return null;
}

/// The files of the shared context and of the code: tracked or new, not ignored; null outside
/// a checkout of git (a copy of the sources) or without git.
function repositoryFiles() {
    const listed = spawnSync("git", ["ls-files", "--cached", "--others", "--exclude-standard"], { encoding: "utf8" });
    if (listed.error || listed.status !== 0) return null;
    return listed.stdout.split("\n").filter((file) => file !== "");
}

export const isContext = (file) => file === "AGENTS.md" || file === "CLAUDE.md" || /^(\.ai|\.claude)\/.*\.md$/.test(file);
// the check's own files name stale names on purpose
const isCode = (file) => (file === "dub.sdl" || /^(source|resources|scripts|tests)\/.*\.(d|mjs|js|htm|html|css)$/.test(file))
    && !file.includes("check-ai-context");

/// The stale names of the shared context: `{ file, line, span, reason }`, run in the root; null
/// when there is no git to list the files.
export function checkContext() {
    const files = repositoryFiles();
    if (files === null) return null;
    const readable = (file) => { try { return readFileSync(file, "utf8"); } catch { return ""; } };
    const code = indexCode(files, files.filter(isCode).map(readable).join("\n"));
    const stale = [];
    for (const file of files.filter(isContext)) {
        for (const { line, span } of codeSpans(readable(file))) {
            const reason = staleReason(span, code);
            if (reason !== null) stale.push({ file, line, span, reason });
        }
    }
    return stale;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === realpathSync(process.argv[1])) {
    process.chdir(fileURLToPath(new URL("../..", import.meta.url))); // the project root
    const stale = checkContext();
    if (stale === null) {
        console.log("Not checked: no git checkout to list the files of.");
        process.exit(0);
    }
    for (const { file, line, span, reason } of stale) console.log(`${file}:${line}: \`${span}\`: ${reason}`);
    console.log(stale.length === 0 ? "The context of .ai/ names nothing the code lacks."
        : `${stale.length} stale names: fix them, or add a right one to "allowed" of scripts/utils/check-ai-context.mjs.`);
    process.exitCode = stale.length === 0 ? 0 : 1;
}
