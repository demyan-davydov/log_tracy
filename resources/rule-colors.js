// The color of a text on a rule's color (its chip in the Filters page); the
// rows of the log table take the colors of the rules from the backend. Pure,
// so it can be tested with node.
// Tests: tests/js/rule-colors.test.mjs.

// The text color that reads best on `color` (#rrggbb): black or white, the one
// of the higher contrast ratio by WCAG 2 (Sciter has no contrast-color())
export function contrastText(color) {
    const linear = c => c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
    const channel = i => linear(parseInt(color.substr(1 + 2 * i, 2), 16) / 255);
    const luminance = 0.2126 * channel(0) + 0.7152 * channel(1) + 0.0722 * channel(2);
    // (L + 0.05) / 0.05 against black, 1.05 / (L + 0.05) against white
    return (luminance + 0.05) ** 2 >= 1.05 * 0.05 ? "#000000" : "#ffffff";
}
