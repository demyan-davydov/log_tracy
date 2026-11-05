// When a recent file was worked with last, as the start screen says it, in the language of
// the interface. Sciter-free; tests: tests/js/recent-time.test.mjs.
import { tr, trc, trn } from "./i18n/i18n.js";

const minuteMs = 60 * 1000;
const hourMs = 60 * minuteMs;
const dayMs = 24 * hourMs;
// The short names of the months, in the language now; each a literal for scripts/i18n-extract
const monthNames = [
    () => trc("month", "Jan"), () => trc("month", "Feb"), () => trc("month", "Mar"),
    () => trc("month", "Apr"), () => trc("month", "May"), () => trc("month", "Jun"),
    () => trc("month", "Jul"), () => trc("month", "Aug"), () => trc("month", "Sep"),
    () => trc("month", "Oct"), () => trc("month", "Nov"), () => trc("month", "Dec"),
];
const monthName = (month) => monthNames[month]();

const minutesAgo = (n) => trn("{n} minute ago", "{n} minutes ago", n);
const hoursAgo = (n) => trn("{n} hour ago", "{n} hours ago", n);
const twoDigits = (n) => String(n).padStart(2, "0");
const timeOf = (date) => `${twoDigits(date.getHours())}:${twoDigits(date.getMinutes())}`;

// Calendar days from `then` to `now`, in local time. Rounded: a day of a
// daylight saving change is 23 or 25 hours long.
function daysBetween(then, now) {
    const midnight = (date) => new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
    return Math.round((midnight(now) - midnight(then)) / dayMs);
}

// `lastUsed` and `now` are ms since the Unix epoch; the text is in local time:
// "Just now", "N minutes ago", "N hours ago" within 24 hours, then
// "Yesterday, 14:05", "2 days ago, 14:05", "3 Nov, 14:05", "3 Nov 2025, 14:05".
// A time after now (the clock was set back) is shown as a date.
export function lastUsedText(lastUsed, now) {
    const ago = now - lastUsed;
    if (ago >= 0) {
        if (ago < minuteMs) return tr("Just now");
        if (ago < hourMs) return minutesAgo(Math.floor(ago / minuteMs));
        if (ago < dayMs) return hoursAgo(Math.floor(ago / hourMs));
    }
    const then = new Date(lastUsed);
    const today = new Date(now);
    if (ago >= 0) {
        const days = daysBetween(then, today);
        // Over 24 hours on the same day: the day of a daylight saving change is 25 hours long
        if (days === 0) return hoursAgo(Math.floor(ago / hourMs));
        if (days === 1) return tr("Yesterday, {time}", { time: timeOf(then) });
        if (days === 2) return tr("2 days ago, {time}", { time: timeOf(then) });
    }
    const date = { day: then.getDate(), month: monthName(then.getMonth()), year: then.getFullYear(), time: timeOf(then) };
    return then.getFullYear() === today.getFullYear()
        ? tr("{day} {month}, {time}", date)
        : tr("{day} {month} {year}, {time}", date);
}
