//! A slider drawn like a switch (Sciter's own hslider can't be styled so): a
// rounded track with a white knob, the part left of the knob filled with the
// accent, marks under it, the value on its right. The
// values come from slider-value.js; this is the DOM side: building the parts,
// the mouse and the keys. Its look is `.slider` in style.css.
//
// new Slider(element, { min, max, step, value, marks, format, onChange }):
// marks are [{ value, label, className }], format(value) is the text on the
// right, onChange(value) is called when the user moves it (not by `value =`).
import { valueAt, fractionOf, keyedValue } from "slider-value.js";

function part(className, parent) {
    const element = document.createElement("div");
    element.className = className;
    if (parent) parent.append(element);
    return element;
}

export class Slider {
    constructor(element, { min, max, step, value = min, marks = [], format = String, onChange = () => {} }) {
        this.element = element;
        this.range = { min, max, step };
        this.format = format;
        this.onChange = onChange;
        this.dragging = false;

        element.classList.add("slider");
        element.setAttribute("tabindex", "0");
        const body = part("slider-body", element); // the track and the marks: what a press moves
        const track = part("slider-track", body);
        this.rail = part("slider-rail", track); // the path of the knob's middle
        this.fill = part("slider-fill", this.rail);
        this.knob = part("slider-knob", this.rail);
        const markRow = part("slider-marks", body);
        for (const mark of marks) {
            const node = part(`slider-mark ${mark.className || ""}`, markRow);
            node.style.left = `${fractionOf(mark.value, this.range) * 100}%`;
            part("slider-tick", node);
            const label = document.createElement("span");
            label.textContent = mark.label;
            node.append(label);
        }
        this.text = document.createElement("span");
        this.text.className = "slider-value";
        element.append(this.text);

        this.value = value;

        // A press on the value on the right moves nothing: beyond the rail it would give the max
        body.on("mousedown", evt => {
            if (evt.button !== 0 && evt.button !== undefined) return false; // Sciter may give none
            this.dragging = true;
            if (!element.state.focus) element.state.focus = true;
            this.moveTo(evt.clientX);
            return true; // no text selection
        });
        document.on("mousemove", evt => {
            if (!this.dragging) return;
            // Released outside the window: no mouseup came here
            if (!(evt.buttons & 1)) this.dragging = false;
            else this.moveTo(evt.clientX);
        });
        document.on("mouseup", () => { this.dragging = false; });
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
        const at = `${fractionOf(value, this.range) * 100}%`;
        this.fill.style.width = at;
        this.knob.style.left = at;
        this.text.textContent = this.format(value);
    }

    moveTo(clientX) {
        const rect = this.rail.getBoundingClientRect();
        this.change(valueAt(rect.width > 0 ? (clientX - rect.left) / rect.width : 0, this.range));
    }

    change(value) {
        if (value === this.current) return;
        this.value = value;
        this.onChange(value);
    }
}
