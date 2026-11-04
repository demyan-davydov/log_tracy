// Reordering a list by dragging one of its items along an axis, as the tabs
// and the columns of Settings are dragged: the item follows the mouse within
// the list, the items it passes slide aside to free its new place, on drop it
// slides into that place. Spans are the extents of the items along the axis,
// [{ start, end }] in their order. Kept free of Sciter: tests/js.

// The shift of the dragged item `from` kept within the list
export function clampShift(spans, from, shift) {
    const min = spans[0].start - spans[from].start;
    const max = spans[spans.length - 1].end - spans[from].end;
    return Math.max(min, Math.min(max, shift));
}

// Where item `from` shifted by `shift` lands, and the shift of each item
// that frees that place: { to, shifts } (0 for the dragged item). The item
// takes the place of every item whose middle its leading edge has passed;
// with equal extents the end of the list is exactly the middle of the last
// item, hence the non-strict comparison.
export function dragTarget(spans, from, shift) {
    const size = spans[from].end - spans[from].start;
    const start = spans[from].start + shift, end = spans[from].end + shift;
    let to = from;
    const shifts = spans.map((span, i) => {
        const middle = (span.start + span.end) / 2;
        if (i > from && end >= middle) { to++; return -size; }
        if (i < from && start <= middle) { to--; return size; }
        return 0;
    });
    return { to, shifts };
}

// The shift that puts item `from` into the place `to` freed for it
export function settleShift(spans, from, to) {
    if (to > from) return spans[to].end - spans[from].end;
    if (to < from) return spans[to].start - spans[from].start;
    return 0;
}

// A copy of `items` with item `from` moved to the place `to`
export function moveItem(items, from, to) {
    const result = items.slice();
    const [item] = result.splice(from, 1);
    result.splice(to, 0, item);
    return result;
}
