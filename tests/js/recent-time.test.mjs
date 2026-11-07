// When a recent file was used last, see resources/recent-time.js.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { lastUsedText } from "../../resources/recent-time.js";

// Local times, so the tests don't depend on the time zone
const at = (y, m, d, h = 0, min = 0, s = 0) => new Date(y, m - 1, d, h, min, s).getTime();
const now = at(2026, 11, 4, 15, 30);

test("less than a minute ago is just now", () => {
    assert.equal(lastUsedText(now, now), "Just now");
    assert.equal(lastUsedText(at(2026, 11, 4, 15, 29, 1), now), "Just now");
});

test("less than an hour ago counts minutes", () => {
    assert.equal(lastUsedText(at(2026, 11, 4, 15, 29), now), "1 minute ago");
    assert.equal(lastUsedText(at(2026, 11, 4, 14, 31), now), "59 minutes ago");
});

test("less than 24 hours ago counts hours, even across midnight", () => {
    assert.equal(lastUsedText(at(2026, 11, 4, 14, 30), now), "1 hour ago");
    assert.equal(lastUsedText(at(2026, 11, 4, 12, 0), now), "3 hours ago");
    assert.equal(lastUsedText(at(2026, 11, 3, 15, 31), now), "23 hours ago");
});

test("yesterday and the day before show the time", () => {
    assert.equal(lastUsedText(at(2026, 11, 3, 9, 5), now), "Yesterday, 09:05");
    assert.equal(lastUsedText(at(2026, 11, 2, 23, 59), now), "2 days ago, 23:59");
    assert.equal(lastUsedText(at(2026, 11, 2, 0, 0), now), "2 days ago, 00:00");
});

test("earlier dates show the day, the year only when it is not this one", () => {
    assert.equal(lastUsedText(at(2026, 11, 1, 23, 59), now), "1 Nov, 23:59");
    assert.equal(lastUsedText(at(2026, 1, 15, 8, 0), now), "15 Jan, 08:00");
    assert.equal(lastUsedText(at(2025, 12, 31, 18, 45), now), "31 Dec 2025, 18:45");
});

test("a time after now (the clock was set back) is shown as a date", () => {
    assert.equal(lastUsedText(at(2026, 11, 4, 16, 0), now), "4 Nov, 16:00");
    assert.equal(lastUsedText(at(2027, 2, 1, 10, 0), now), "1 Feb 2027, 10:00");
});

test("in russian: the plural forms, the words and the months of the catalog", async () => {
    const { setCatalog } = await import("../../resources/i18n/i18n.js");
    setCatalog({ locale: "ru", messages: {
        "Just now": "Только что",
        "{n} minute ago": { one: "{n} минуту назад", few: "{n} минуты назад", many: "{n} минут назад" },
        "{n} hour ago": { one: "{n} час назад", few: "{n} часа назад", many: "{n} часов назад" },
        "Yesterday, {time}": "Вчера, {time}",
        "2 days ago, {time}": "Позавчера, {time}",
        "Nov|month": "ноя",
        "{day} {month}, {time}": "{day} {month}, {time}",
        "{day} {month} {year}, {time}": "{day} {month} {year}, {time}",
    } });
    try {
        assert.equal(lastUsedText(now, now), "Только что");
        assert.equal(lastUsedText(at(2026, 11, 4, 15, 9), now), "21 минуту назад");
        assert.equal(lastUsedText(at(2026, 11, 4, 12, 0), now), "3 часа назад");
        assert.equal(lastUsedText(at(2026, 11, 3, 9, 5), now), "Вчера, 09:05");
        assert.equal(lastUsedText(at(2026, 11, 2, 9, 5), now), "Позавчера, 09:05");
        assert.equal(lastUsedText(at(2026, 11, 1, 23, 59), now), "1 ноя, 23:59");
        assert.equal(lastUsedText(at(2025, 11, 1, 23, 59), now), "1 ноя 2025, 23:59");
        assert.equal(lastUsedText(at(2026, 1, 15, 8, 0), now), "15 Jan, 08:00", "a month not translated: english");
    } finally {
        setCatalog(null);
    }
});
