// What the debug channel (ui/debug_channel, builds with --debug-channel only) evaluates for a request
// {"eval": code}: this function expression, called with the code. It answers, as JSON text, what
// the code gave: {value} made plain JSON or {thrown} (the response line is made of it by
// ui/debug_protocol). Not served to the window and not a module: SciterEval runs it in the
// global scope of the window, where the code sees what the modules put on globalThis.
(function debugEval(code) {
    const maxDepth = 4, maxItems = 100, maxText = 200;
    const cut = text => (text.length > maxText ? text.slice(0, maxText) + "…" : text);
    const isElement = value => typeof Element !== "undefined" && value instanceof Element;

    // An element as a summary instead of "[object Element]": what tells which one it is, and
    // where it is in the window
    function elementSummary(element) {
        const summary = { tag: String(element.tagName).toLowerCase() };
        if (element.id) summary.id = element.id;
        if (element.className) summary.class = element.className;
        const text = String(element.innerText ?? "").trim();
        if (text) summary.text = cut(text);
        try {
            summary.box = element.state.box("xywh", "border", "window");
        } catch {
            // not laid out
        }
        return summary;
    }

    const isList = value => Array.isArray(value)
        || (typeof value.length === "number" && typeof value[Symbol.iterator] === "function");

    // The value as plain JSON; `path`: the objects it is inside of, for cycles
    function plain(value, depth, path) {
        if (value === undefined) return null;
        if (value === null || typeof value === "boolean" || typeof value === "string") return value;
        if (typeof value === "number") return Number.isFinite(value) ? value : String(value);
        if (typeof value === "function") return `function ${value.name}`;
        if (typeof value !== "object") return String(value); // bigint, symbol
        if (isElement(value)) return elementSummary(value);
        if (typeof value.then === "function") return "[promise]";
        if (value instanceof Error) return { error: String(value) };
        if (path.includes(value)) return "[circular]";
        if (depth >= maxDepth) return isList(value) ? "[array]" : "[object]";
        path.push(value);
        try {
            if (isList(value)) {
                const items = Array.from(value);
                const result = items.slice(0, maxItems).map(item => plain(item, depth + 1, path));
                if (items.length > maxItems) result.push(`… ${items.length - maxItems} more`);
                return result;
            }
            const result = {};
            const keys = Object.keys(value);
            for (const key of keys.slice(0, maxItems)) result[key] = plain(value[key], depth + 1, path);
            if (keys.length > maxItems) result["…"] = `${keys.length - maxItems} more`;
            return result;
        } finally {
            path.pop();
        }
    }

    // The frames of the code that threw `e`, one a line: those of this wrapper (from debugEval
    // on, and eval itself just before it in Sciter: "at eval (native)") cut, the message that
    // V8 repeats on the first line too
    function codeFrames(e, message) {
        if (typeof e?.stack !== "string") return [];
        const lines = e.stack.split("\n").map(line => line.trim()).filter(line => line);
        let end = lines.findIndex(line => /^at debugEval\b/.test(line));
        if (end < 0) end = lines.length;
        if (end > 0 && lines[end - 1] === "at eval (native)") end--;
        const start = lines[0] === message ? 1 : 0;
        return lines.slice(start, end);
    }

    try {
        const value = (0, eval)(code); // indirect: the global scope, not this function's
        return JSON.stringify({ value: plain(value, 0, []) });
    } catch (e) {
        const message = String(e);
        const frames = codeFrames(e, message).map(frame => `\n    ${frame}`).join("");
        return JSON.stringify({ thrown: message + frames });
    }
})
