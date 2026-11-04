// When a recent file was worked with last, as the start screen says it.
// Sciter-free; tests: tests/js/recent-time.test.mjs.

const minuteMs = 60 * 1000;
const hourMs = 60 * minuteMs;
const dayMs = 24 * hourMs;
const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

const plural = (count, unit) => `${count} ${unit}${count === 1 ? "" : "s"}`;
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
        if (ago < minuteMs) return "Just now";
        if (ago < hourMs) return `${plural(Math.floor(ago / minuteMs), "minute")} ago`;
        if (ago < dayMs) return `${plural(Math.floor(ago / hourMs), "hour")} ago`;
    }
    const then = new Date(lastUsed);
    const today = new Date(now);
    if (ago >= 0) {
        const days = daysBetween(then, today);
        // Over 24 hours on the same day: the day of a daylight saving change is 25 hours long
        if (days === 0) return `${plural(Math.floor(ago / hourMs), "hour")} ago`;
        if (days === 1) return `Yesterday, ${timeOf(then)}`;
        if (days === 2) return `2 days ago, ${timeOf(then)}`;
    }
    const year = then.getFullYear() === today.getFullYear() ? "" : ` ${then.getFullYear()}`;
    return `${then.getDate()} ${months[then.getMonth()]}${year}, ${timeOf(then)}`;
}
