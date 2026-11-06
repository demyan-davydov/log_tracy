//! Applies the color theme (theme-light.css / theme-dark.css) to the page of a
//! window: the main window and the dialogs share it. Sciter doesn't reload a
//! <style> whose `src` changes, so the theme's <style id="theme-style"> is
//! replaced by a new one. The `theme` attribute of <html> switches Sciter's
//! own widgets (select and its list, buttons, checkboxes, inputs) to the same
//! theme (the pages start with theme="light" and theme-light.css).
//! Sciter-only: not loaded by the tests.
import { $ } from "@sciter";

// @param theme - "light" | "dark"
export function applyTheme(theme) {
    const oldStyle = $("#theme-style");
    if (oldStyle) oldStyle.remove();

    const newStyle = document.createElement("style");
    newStyle.id = "theme-style";
    newStyle.setAttribute("src", theme === "dark" ? "theme-dark.css" : "theme-light.css");
    document.head.prepend(newStyle);
    document.attributes["theme"] = theme === "dark" ? "dark" : "light";
}
