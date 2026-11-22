import test from "node:test";
import assert from "node:assert/strict";
import { ColumnTip, hintsOf, tipDelayMs } from "../../resources/column-tip.js";

// A tip with fake timers; `seen` is what it did, `fire()` runs the timer pending
function make({ hints = { sid: "Session ID" }, active = () => true } = {}) {
    const seen = [];
    let pending = null;
    const timers = {
        set: (fn, ms) => { pending = { fn, ms }; return pending; },
        clear: id => { if (pending === id) pending = null; },
    };
    const tip = new ColumnTip({
        hintOf: column => hints[column],
        show: (rect, text) => seen.push(`show ${text} ${rect.join(",")}`),
        hide: () => seen.push("hide"),
        active,
        timers,
    });
    const fire = () => { const p = pending; pending = null; p?.fn(); return p?.ms; };
    return { tip, seen, fire, waiting: () => pending !== null };
}

const rect = [10, 0, 40, 21];
const title = (type, column = "sid") => ({ type, kind: "header", column, rect });

test("a title with a hint shows it under the title after the delay; one with none shows nothing", () => {
    const { tip, seen, fire } = make();
    tip.pointer(title("enter"));
    assert.deepEqual(seen, [], "not at once");
    assert.equal(fire(), tipDelayMs);
    assert.deepEqual(seen, ["show Session ID 10,0,40,21"]);
    const other = make();
    other.tip.pointer(title("enter", "time"));
    assert.equal(other.waiting(), false);
});

test("the mouse leaving the title before the delay shows nothing, after it hides the tip", () => {
    const { tip, seen, fire, waiting } = make();
    tip.pointer(title("enter"));
    tip.pointer(title("leave"));
    assert.equal(waiting(), false);
    tip.pointer(title("enter"));
    fire();
    tip.pointer(title("leave"));
    assert.deepEqual(seen, ["show Session ID 10,0,40,21", "hide"]);
});

test("the cells have no tip", () => {
    const { tip, waiting } = make();
    tip.pointer({ type: "enter", kind: "cell", column: "sid", row: 1, rect });
    assert.equal(waiting(), false);
});

test("a press hides the tip, and it does not come back until the mouse leaves the title", () => {
    const { tip, seen, fire, waiting } = make();
    tip.pointer(title("enter"));
    fire();
    for (const type of ["down", "leave", "up", "click", "enter"])
        tip.pointer(title(type));
    assert.deepEqual(seen, ["show Session ID 10,0,40,21", "hide"]);
    assert.equal(waiting(), false, "the enter after the release");
    tip.pointer(title("leave"));
    tip.pointer(title("enter"));
    fire();
    assert.equal(seen.at(-1), "show Session ID 10,0,40,21");
});

test("a press before the delay cancels the wait; a cancel of the press ends it as a release does", () => {
    const { tip, seen, waiting } = make();
    tip.pointer(title("enter"));
    tip.pointer(title("down"));
    assert.equal(waiting(), false);
    tip.pointer(title("leave"));
    tip.pointer(title("cancel"));
    tip.pointer(title("enter"));
    assert.equal(waiting(), false, "still the title pressed");
    assert.deepEqual(seen, [], "nothing was shown: nothing to hide");
});

test("a dismissal (a scroll, a right click, the window or the table gone) hides the tip and drops the wait", () => {
    const { tip, seen, fire, waiting } = make();
    tip.pointer(title("enter"));
    tip.dismiss();
    assert.equal(waiting(), false);
    tip.pointer(title("leave"));
    tip.pointer(title("enter"));
    fire();
    tip.dismiss();
    tip.dismiss();
    assert.deepEqual(seen, ["show Session ID 10,0,40,21", "hide"], "hidden once");
});

test("no tip in a window that is not active when the delay ends", () => {
    const { tip, seen, fire } = make({ active: () => false });
    tip.pointer(title("enter"));
    fire();
    assert.deepEqual(seen, []);
});

test("a title with no rect has nowhere to show a tip", () => {
    const { tip, waiting } = make();
    tip.pointer({ type: "enter", kind: "header", column: "sid" });
    assert.equal(waiting(), false);
});

test("the hints of the columns of a document: by id, only the columns that have one; none while the columns are not known yet", () => {
    const hints = hintsOf([{ id: "sid", hint: "Session ID" }, { id: "time" }]);
    assert.equal(hints.get("sid"), "Session ID");
    assert.equal(hints.has("time"), false);
    assert.equal(hintsOf([]), null, "asked again later");
});
