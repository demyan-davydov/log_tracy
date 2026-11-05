// Which plural form a count takes in a language: the categories of CLDR ("one", "few",
// "many", "other"). Sciter has no Intl.PluralRules, so the rules of the languages we
// translate to are here; a language without rules counts as english.
// Sciter-free; tests: tests/js/plural.test.mjs.

const english = {
    categories: ["one", "other"],
    of: (n) => (n === 1 ? "one" : "other"),
};

const rules = {
    en: english,
    // A fraction takes the form of few: "1,5 совпадения", so translations need no "other".
    ru: {
        categories: ["one", "few", "many"],
        of(n) {
            if (!Number.isInteger(n))
                return "few";
            const last = Math.abs(n) % 10, lastTwo = Math.abs(n) % 100;
            if (last === 1 && lastTwo !== 11)
                return "one";
            if (last >= 2 && last <= 4 && (lastTwo < 12 || lastTwo > 14))
                return "few";
            return "many";
        },
    },
};

// The rules of the language of a BCP 47 tag ("ru-KZ": ru), or of a POSIX locale ("ru_RU.UTF-8").
const rulesOf = (locale) => rules[String(locale).split(/[-_.]/)[0].toLowerCase()] ?? english;

// The category of the form `n` takes in `locale`.
export const pluralCategory = (locale, n) => rulesOf(locale).of(n);

// The forms a translation to `locale` must have.
export const pluralCategories = (locale) => rulesOf(locale).categories;
