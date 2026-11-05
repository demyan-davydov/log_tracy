// The match colors (match-colors.css, --match-color-N in the themes): each
// search chip has one, and the matches it finds will be shown in it. An element
// of color n gets the class matchColorClass(n).
// Tests: tests/js/match-colors.test.mjs.

// The number of match colors: match-colors.css and both themes define as many
export const matchColorCount = 16;

// @returns the class of match color `n` (any integer: the colors repeat)
export function matchColorClass(n) {
    return `match-color-${((n % matchColorCount) + matchColorCount) % matchColorCount}`;
}
