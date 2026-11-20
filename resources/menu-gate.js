//! A context menu opens by the mouse only, never by the keyboard (the Menu key, Shift+F10): a menu is let open when a press of the
//! mouse came after the last key. The gate is pure; `watchMenuInput` arms the window's one by every press and closes it by every key,
//! both seen before anybody else hears them (the sinking phase), and `menuOpensByMouse` asks it in a "contextmenu" handler.

// A gate: `pressed` (a press of the mouse) arms it, `keyed` (a key) closes it, `take` says whether it was armed and closes it
export function menuGate() {
    let armed = false;
    return {
        pressed() { armed = true; },
        keyed() { armed = false; },
        take() {
            const was = armed;
            armed = false;
            return was;
        },
    };
}

let windowGate = null;

// The gate of the window hears the presses and the keys of `doc` from now on
export function watchMenuInput(doc) {
    windowGate = menuGate();
    doc.on("^mousedown", () => { windowGate.pressed(); });
    doc.on("^keydown", () => { windowGate.keyed(); });
}

// Whether the "contextmenu" being handled came of the mouse; false before `watchMenuInput`
export function menuOpensByMouse() {
    return windowGate !== null && windowGate.take();
}
