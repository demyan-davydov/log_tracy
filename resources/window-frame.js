// The frame of the window restored from the settings: the saved frame, unless
// it is missing or would leave the window out of reach (on a monitor no longer
// there). Frames and work areas are { left, top, width, height } in physical
// pixels of the desktop. Kept free of Sciter: tests/js.

// The strip at the top of the frame the window is dragged by, and how much of
// it a monitor must show to restore the frame
const titleBarHeight = 40;
const minVisibleWidth = 100;
const minVisibleHeight = 20;

// The frame to move the window to, null to leave it as the markup makes it.
// `workAreas`: the work areas of the monitors.
export function restorableFrame(frame, workAreas) {
    if (!frame || !(frame.width > 0) || !(frame.height > 0)) return null;
    const titleBar = { left: frame.left, top: frame.top, width: frame.width, height: titleBarHeight };
    const reachable = workAreas.some(area => {
        const width = overlap(titleBar.left, titleBar.width, area.left, area.width);
        const height = overlap(titleBar.top, titleBar.height, area.top, area.height);
        return width >= minVisibleWidth && height >= minVisibleHeight;
    });
    return reachable ? frame : null;
}

// How long the segments [a, a + aLength) and [b, b + bLength) overlap
function overlap(a, aLength, b, bLength) {
    return Math.max(0, Math.min(a + aLength, b + bLength) - Math.max(a, b));
}
