//! Small pure geometry for the scripts: tests/js/geometry.test.mjs.

// Whether the point (x, y) is in `rect` = [x, y, w, h] (the edges that are right and below are outside)
export function pointInRect(x, y, [left, top, width, height]) {
    return x >= left && y >= top && x < left + width && y < top + height;
}
