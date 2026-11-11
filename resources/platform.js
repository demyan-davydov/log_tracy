// The services of the platform the scripts use, through Sciter: the file and
// modal dialogs, the parameters and the result of a dialog, the window, the
// clipboard, the OS. One place for them, as backend.js is for the backend;
// the other scripts render the DOM and call these. Sciter-only: not loaded by
// the tests.
import * as env from "@env";

// ── The OS ───────────────────────────────────────────────────────────────────

// macOS: Cmd instead of Ctrl, Ctrl+click as a right click
export const isMac = () => env.PLATFORM === "OSX";

// The language of the user in the system and its country: two letters each ("ru", "KZ")
export const systemLanguage = () => ({ language: env.language() || "", country: env.country() || "" });

// ── Dialogs ──────────────────────────────────────────────────────────────────

// The path of the file to open, null if cancelled
// @param filter - "Name (*.ext)|*.ext|..." as Sciter takes it
export const chooseFileToOpen = filter => Window.this.selectFile({ mode: "open", filter }) || null;

// The path to save to, null if cancelled
// @param options - { caption, extension, filter, path (offered, without its extension) }
export const chooseFileToSave = options => Window.this.selectFile({ ...options, mode: "save" }) || null;

// Opens the page `url` as a modal dialog in the middle of the window (alignment
// -5: the centre of the parent; 1..9 would align it on the screen): what it
// closes with (closeDialog), null if cancelled
export const showModal = (url, parameters) => Window.this.modal({ url, alignment: -5, parameters });

// In a dialog: the parameters it was opened with, undefined if opened on its own
export const dialogParameters = () => Window.this.parameters;

// In a dialog: closes it with `result` (null: cancelled)
export const closeDialog = result => Window.this.close(result);

// In a dialog: its title
export const setDialogTitle = title => { Window.this.caption = title; };

// ── The window ───────────────────────────────────────────────────────────────

// The frame of the window on the screen: { left, top, width, height } in
// physical pixels; null while the window isn't shown normally (minimized,
// maximized, full screen: its frame then is not the one to restore)
export function windowFrame() {
    if (Window.this.state !== Window.WINDOW_SHOWN) return null;
    const [left, top, width, height] = Window.this.box("xywh", "border", "screen", true);
    return { left, top, width, height };
}

// True while the window is minimized
export const windowMinimized = () => Window.this.state === Window.WINDOW_MINIMIZED;

// The work areas of the monitors (without the taskbar, the Dock):
// [{ left, top, width, height }] in physical pixels, as windowFrame()
export function workAreas() {
    const areas = [];
    for (let i = 0; i < Window.screens; i++) {
        const [left, top, width, height] = Window.screenBox(i, "workarea", "xywh");
        areas.push({ left, top, width, height });
    }
    return areas;
}

// Moves the window to `frame` as windowFrame() gives it
export const moveWindow = frame => Window.this.move(frame.left, frame.top, frame.width, frame.height);

// Closes the window, as its close button does (closerequest, then close)
export const closeWindow = () => Window.this.close();

// Minimizes the window
export const minimizeWindow = () => { Window.this.state = Window.WINDOW_MINIMIZED; };

// The window is about to close: the last moment the script and the DOM are
// fully alive (not the BEHAVIOR_DETACH of the backend, see main_window.d)
export const onWindowCloseRequest = handler => Window.this.on("closerequest", handler);

// The user finished moving or resizing the window
export const onWindowFrameChanged = handler => Window.this.on("replacementend", handler);

// The window closes
export const onWindowClose = handler => Window.this.on("close", handler);

// ── The clipboard ────────────────────────────────────────────────────────────

export const copyText = text => Clipboard.writeText(text);
// The text on the clipboard, "" if none (Sciter ends it with NUL characters)
export const clipboardText = () => (Clipboard.readText() ?? "").replace(/\0+$/, "");
