//! Sliders drawn like a switch (Sciter's own hslider can't be styled so): a
// rounded track with white knobs, filled with the accent as a switch that is
// on, marks under it. A Slider has one knob, the fill left of it and the value
// on its right; a RangeSlider has two, the fill between them, the value of the
// left knob above the track and of the right one under it, so they never
// cover each other. The values come from slider-value.js; this is the DOM
// side: building the parts, the mouse and the keys. Their look is `.slider`
// in style.css.
//
// new Slider(element, { min, max, step, value, marks, format, onChange })
// new RangeSlider(element, { min, max, step, value: [low, high], marks, format, onChange })
// marks are [{ value, label, className }], format(value) is the text of a
// value, onChange(value) is called when the user moves it (not by `value =`).
import { valueAt, fractionOf, keyedValue, nearestKnob, movedRange } from "slider-value.js";

function part(className, parent, tag = "div") {
    const element = document.createElement(tag);
    element.className = className;
    if (parent) parent.append(element);
    return element;
}

const percent = fraction => `${fraction * 100}%`;

// The parts: the track, the rail in it (the path of a knob's middle), the fill,
// the knobs and the marks; with `labelRows` a row for labels above the track
// and one under the marks
function build(element, range, marks, knobCount, labelRows) {
    element.classList.add("slider");
    const body = part("slider-body", element); // what a press moves
    const top = labelRows ? part("slider-labels", body) : null;
    const track = part("slider-track", body);
    const rail = part("slider-rail", track);
    const fill = part("slider-fill", rail);
    const knobs = [];
    for (let i = 0; i < knobCount; i++) knobs.push(part("slider-knob", rail));
    const markRow = part("slider-marks", body);
    for (const mark of marks) {
        const node = part(`slider-mark ${mark.className || ""}`, markRow);
        node.style.left = percent(fractionOf(mark.value, range));
        part("slider-tick", node);
        part("", node, "span").textContent = mark.label || "";
    }
    const bottom = labelRows ? part("slider-labels", body) : null;
    return { body, rail, fill, knobs, top, bottom };
}

// A press on `body` and the drag after it: onPress(value) and onMove(value),
// the value under the mouse on `rail`; focus() after the press
function trackPress(body, rail, range, focus, onPress, onMove) {
    let dragging = false;
    const valueUnder = clientX => {
        const rect = rail.getBoundingClientRect();
        return valueAt(rect.width > 0 ? (clientX - rect.left) / rect.width : 0, range);
    };
    body.on("mousedown", evt => {
        if (evt.button !== 0 && evt.button !== undefined) return false; // Sciter may give none
        dragging = true;
        onPress(valueUnder(evt.clientX));
        focus();
        return true; // no text selection
    });
    document.on("mousemove", evt => {
        if (!dragging) return;
        // Released outside the window: no mouseup came here
        if (!(evt.buttons & 1)) dragging = false;
        else onMove(valueUnder(evt.clientX));
    });
    document.on("mouseup", () => { dragging = false; });
}

export class Slider {
    constructor(element, { min, max, step, value = min, marks = [], format = String, onChange = () => {} }) {
        this.range = { min, max, step };
        this.format = format;
        this.onChange = onChange;
        element.setAttribute("tabindex", "0");
        // A press on the value on the right moves nothing: beyond the rail it would give the max
        const { body, rail, fill, knobs } = build(element, this.range, marks, 1, false);
        this.fill = fill;
        this.knob = knobs[0];
        this.text = part("slider-value", element, "span");
        this.value = value;

        const focus = () => { if (!element.state.focus) element.state.focus = true; };
        trackPress(body, rail, this.range, focus, v => this.change(v), v => this.change(v));
        element.on("keydown", evt => {
            const next = keyedValue(this.current, evt.code, this.range);
            if (next === null) return false;
            this.change(next);
            return true;
        });
    }

    get value() { return this.current; }

    // Sets the value as it is (one off the step or the range, from edited settings, too)
    set value(value) {
        this.current = value;
        const at = percent(fractionOf(value, this.range));
        this.fill.style.width = at;
        this.knob.style.left = at;
        this.text.textContent = this.format(value);
    }

    change(value) {
        if (value === this.current) return;
        this.value = value;
        this.onChange(value);
    }
}

export class RangeSlider {
    constructor(element, { min, max, step, value = [min, max], marks = [], format = String, onChange = () => {} }) {
        this.range = { min, max, step };
        this.format = format;
        this.onChange = onChange;
        element.classList.add("range");
        const { body, rail, fill, knobs, top, bottom } = build(element, this.range, marks, 2, true);
        this.fill = fill;
        this.knobs = knobs;
        // The value of the left knob above the track, of the right one under the marks
        this.labels = [part("slider-label", top, "span"), part("slider-label", bottom, "span")];
        knobs.forEach((knob, i) => {
            knob.setAttribute("tabindex", "0"); // each takes the keys in its turn
            knob.setAttribute("knob", String(i));
        });
        this.value = value;

        let grabbed = null; // the knob the press took; null: knobs at one place wait for a move
        const focus = () => {
            const knob = knobs[grabbed ?? 0];
            if (!knob.state.focus) knob.state.focus = true;
        };
        trackPress(body, rail, this.range, focus, v => {
            grabbed = nearestKnob(v, this.current);
            if (grabbed !== null) this.change(movedRange(this.current, grabbed, v));
        }, v => {
            if (grabbed === null) {
                grabbed = nearestKnob(v, this.current);
                if (grabbed === null) return;
                focus();
            }
            this.change(movedRange(this.current, grabbed, v));
        });
        element.on("keydown", ".slider-knob", (evt, knob) => {
            const i = parseInt(knob.getAttribute("knob"));
            const next = keyedValue(this.current[i], evt.code, this.range);
            if (next === null) return false;
            this.change(movedRange(this.current, i, next));
            return true;
        });
    }

    get value() { return this.current; }

    // Sets the knobs, [low, high]
    set value([low, high]) {
        this.current = [low, high];
        const at = [fractionOf(low, this.range), fractionOf(high, this.range)];
        this.fill.style.left = percent(at[0]);
        this.fill.style.width = percent(at[1] - at[0]);
        at.forEach((fraction, i) => {
            this.knobs[i].style.left = percent(fraction);
            const label = this.labels[i];
            label.style.left = percent(fraction);
            label.textContent = this.format(this.current[i]);
            // At an end of the track the label keeps inside it
            label.classList.toggle("start", fraction === 0);
            label.classList.toggle("end", fraction === 1);
        });
    }

    change([low, high]) {
        if (low === this.current[0] && high === this.current[1]) return;
        this.value = [low, high];
        this.onChange([low, high]);
    }
}
