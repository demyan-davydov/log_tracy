// Dragging an item of a strip to another place, as the tabs and the columns of
// Settings are dragged: the DOM side of drag-order.js. The item follows the
// mouse within the strip, the items it passes slide aside, a marker shows where
// it will land; on drop it slides into that place. The caller keeps the state of
// the drag (adding what its strip needs to it) and decides what a drop means.
// The drag: { items, rects, spans, from, to, startX, dx, markerOrigin, active,
//             settling }; items get the classes dragging, shifting and settling.
import { clampShift, dragTarget, settleShift } from "drag-order.js";

export const DRAG_THRESHOLD = 4; // px of mouse movement before a press becomes a drag
export const SETTLE_MS = 160;    // a bit longer than the .settling transition

// Moves an item along the strip by `dx` px (0: back in its place)
export function setShift(item, dx) {
    item.style.transform = dx ? `translate(${dx}px, 0)` : "";
}

// The drag of a press on item `from` of `items`: it stays a press until the
// mouse moves far enough
export function pressItem(items, from, clientX) {
    const rects = items.map(item => item.getBoundingClientRect());
    return {
        items, rects, from, to: from,
        spans: rects.map(r => ({ start: r.left, end: r.right })), // see drag-order.js
        startX: clientX, dx: 0, markerOrigin: null,
        active: false, settling: false
    };
}

// The mouse moved to `clientX`: the item follows it within the strip, the items
// it passes slide aside. `onStart(d)` is called once, when the press becomes a
// drag (the marker is put in then). Returns: true if the place it lands on was
// computed again (the marker is to be shown there)
export function dragTo(d, clientX, onStart) {
    if (d.settling) return false;
    const dx = clientX - d.startX;
    const dragged = d.items[d.from];
    if (!d.active) {
        if (Math.abs(dx) < DRAG_THRESHOLD) return false;
        d.active = true;
        dragged.classList.add("dragging");
        for (const item of d.items) if (item !== dragged) item.classList.add("shifting");
        onStart(d);
    }
    d.dx = clampShift(d.spans, d.from, dx);
    setShift(dragged, d.dx);
    // The item takes the place of every item whose middle its leading edge has passed
    const { to, shifts } = dragTarget(d.spans, d.from, d.dx);
    d.items.forEach((item, i) => { if (i !== d.from) setShift(item, shifts[i]); });
    d.to = to;
    return true;
}

// The button was released: the item slides into the place it lands on, then
// `onSettled(d)` is called. Returns: false for a plain press (no drag), nothing
// slides then
export function drop(d, onSettled) {
    if (!d.active) return false;
    const dragged = d.items[d.from];
    d.settling = true;
    dragged.classList.add("settling");
    setShift(dragged, settleShift(d.spans, d.from, d.to));
    setTimeout(() => onSettled(d), SETTLE_MS);
    return true;
}

// Shows `marker` on the place the item lands on, hidden while it would stay
// where it was. `place(origin)` sets its position: `origin` is where left and
// top 0 put it, {left, top, width}, calibrated on the first show (absolute
// offsets are inside the border)
export function showDropMarker(marker, d, place) {
    if (!marker) return;
    if (d.to === d.from) {
        marker.style.display = "none";
        return;
    }
    marker.style.display = "block";
    if (!d.markerOrigin) {
        marker.style.left = "0px";
        marker.style.top = "0px";
        const r = marker.getBoundingClientRect();
        d.markerOrigin = { left: r.left, top: r.top, width: r.right - r.left };
    }
    place(d.markerOrigin);
}
