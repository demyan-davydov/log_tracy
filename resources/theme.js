//! Applies the color theme to the page of a window: the main window and the
//! dialogs share it. Every page loads both theme-light.css and theme-dark.css;
//! the dark one applies under <html theme="dark">, so the `theme` attribute
//! alone switches our colors and Sciter's own widgets (select and its list,
//! buttons, checkboxes, inputs). The pages start with theme="light".
//! Not a <style> replaced at run time: it loads asynchronously, and the styles
//! computed meanwhile (the <body> of a dialog) keep no theme until a click.
//! Sciter-only: not loaded by the tests.

// @param theme - "light" | "dark"
export function applyTheme(theme) {
    document.attributes["theme"] = theme === "dark" ? "dark" : "light";
}
