module log_core.text_parsing;

//! Small parsers for the headers of text log lines. Each one reads from the
//! front of `s` and moves it past what it read; on failure `s` may be moved
//! partly, the caller gives up on the line then. No allocation.

//! Reads up to `maxDigits` (at most 9) decimal digits
//! @returns the number of digits read
private size_t readDigitRun(ref const(char)[] s, size_t maxDigits, out uint value) pure nothrow @nogc @safe
{
    size_t n = 0;
    uint result = 0;
    while (n < s.length && n < maxDigits && s[n] >= '0' && s[n] <= '9')
    {
        result = result * 10 + (s[n] - '0');
        ++n;
    }
    value = result;
    s = s[n .. $];
    return n;
}

//! Reads exactly `digits` decimal digits (at most 9)
bool readDigits(ref const(char)[] s, size_t digits, out uint value) pure nothrow @nogc @safe
{
    return readDigitRun(s, digits, value) == digits;
}

//! Reads 1 to 9 decimal digits
bool readNumber(ref const(char)[] s, out uint value) pure nothrow @nogc @safe
{
    return readDigitRun(s, 9, value) > 0;
}

//! Reads the character `c`
bool readChar(ref const(char)[] s, char c) pure nothrow @nogc @safe
{
    if (s.length == 0 || s[0] != c)
        return false;
    s = s[1 .. $];
    return true;
}

//! Skips spaces; @returns false if there was none
bool skipSpaces(ref const(char)[] s) pure nothrow @nogc @safe
{
    size_t n = 0;
    while (n < s.length && s[n] == ' ')
        ++n;
    s = s[n .. $];
    return n > 0;
}

//! Reads a fraction of a second after the separator: 1 to 9 digits
//! @returns nanoseconds
bool readFraction(ref const(char)[] s, out uint nanoseconds) pure nothrow @nogc @safe
{
    uint value;
    const n = readDigitRun(s, 9, value);
    if (n == 0)
        return false;
    foreach (_; n .. 9)
        value *= 10;
    nanoseconds = value;
    return true;
}

//! Reads "HH:MM:SS" and an optional ".fraction"
//! @returns nanoseconds since midnight
bool readTimeOfDay(ref const(char)[] s, out long nanoseconds) pure nothrow @nogc @safe
{
    uint hours, minutes, seconds, fraction;
    if (!readDigits(s, 2, hours) || !readChar(s, ':') || !readDigits(s, 2, minutes)
        || !readChar(s, ':') || !readDigits(s, 2, seconds))
        return false;
    if (hours > 23 || minutes > 59 || seconds > 60) // 60: a leap second
        return false;
    if (s.length && (s[0] == '.' || s[0] == ','))
    {
        s = s[1 .. $];
        if (!readFraction(s, fraction))
            return false;
    }
    nanoseconds = ((hours * 60L + minutes) * 60 + seconds) * 1_000_000_000L + fraction;
    return true;
}

//! Days since 1970-01-01 of a date of the proleptic Gregorian calendar
//! (H. Hinnant's days_from_civil). Not std.datetime's Date.dayOfGregorianCal:
//! the Date constructor throws, and the callers are nothrow @nogc.
long daysFromCivil(int year, uint month, uint day) pure nothrow @nogc @safe
{
    year -= month <= 2;
    const long era = (year >= 0 ? year : year - 399) / 400;
    const uint yoe = cast(uint)(year - era * 400);
    const uint doy = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1;
    const uint doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146_097 + doe - 719_468;
}

//! @returns true if the date exists
bool isValidDate(int year, uint month, uint day) pure nothrow @nogc @safe
{
    import std.datetime.date : valid;

    return month <= 12 && day <= 31 && valid!"days"(year, month, day);
}

//! Nanoseconds since the epoch of a date and a time of day, as if in UTC
long toEpochNs(int year, uint month, uint day, long timeOfDayNs) pure nothrow @nogc @safe
{
    return daysFromCivil(year, month, day) * 86_400_000_000_000L + timeOfDayNs;
}

//! The year of LocalNoYear times: a leap year, so that Feb 29 exists
enum int noYear = 2000;

@("text parsing: numbers, fractions and times")
unittest
{
    const(char)[] s = "0042x";
    uint v;
    assert(readDigits(s, 4, v) && v == 42 && s == "x");
    s = "12a";
    assert(!readDigits(s, 3, v));
    s = "12345 rest";
    assert(readNumber(s, v) && v == 12345 && s == " rest");
    s = "123";
    assert(readFraction(s, v) && v == 123_000_000);

    long ns;
    s = "14:22:01.123456 x";
    assert(readTimeOfDay(s, ns) && s == " x");
    assert(ns == ((14 * 60 + 22) * 60 + 1) * 1_000_000_000L + 123_456_000);
    s = "14:22:01,5";
    assert(readTimeOfDay(s, ns) && ns % 1_000_000_000 == 500_000_000);
    s = "25:00:00";
    assert(!readTimeOfDay(s, ns));
}

@("text parsing: dates")
unittest
{
    assert(daysFromCivil(1970, 1, 1) == 0);
    assert(daysFromCivil(2000, 3, 1) == 11_017);
    assert(toEpochNs(2026, 11, 3, 0) / 1_000_000_000 == 1_793_664_000);
    assert(isValidDate(2000, 2, 29));
    assert(!isValidDate(2001, 2, 29));
    assert(!isValidDate(2026, 4, 31));
    assert(!isValidDate(2026, 13, 1));
}
