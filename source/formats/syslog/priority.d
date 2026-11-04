module formats.syslog.priority;

//! The syslog priority shared by the formats that carry it (syslog, the
//! kernel log): "<priority>" = facility * 8 + severity, RFC 5424.

import log_core.log_level : LogLevel;

//! @returns the level of a syslog severity 0..7 (emerg .. debug)
LogLevel severityLevel(uint severity) pure nothrow @nogc @safe
{
    static immutable LogLevel[8] levels = [
        LogLevel.Fatal, LogLevel.Fatal, LogLevel.Fatal, // emerg, alert, crit
        LogLevel.Error, LogLevel.Warn, // err, warning
        LogLevel.Info, LogLevel.Info, LogLevel.Debug // notice, info, debug
    ];
    return severity < levels.length ? levels[severity] : LogLevel.None;
}

//! @returns the level of a severity name as dmesg -x prints it ("err", "warn"...)
bool severityByName(const(char)[] name, out LogLevel level) pure nothrow @nogc @safe
{
    static immutable string[8] names = ["emerg", "alert", "crit", "err", "warn", "notice", "info", "debug"];
    foreach (i, n; names)
    {
        if (name == n)
        {
            level = severityLevel(cast(uint) i);
            return true;
        }
    }
    return false;
}

//! Facility names (RFC 5424) by number
private static immutable string[24] facilityNames = [
    "kern", "user", "mail", "daemon", "auth", "syslog", "lpr", "news",
    "uucp", "cron", "authpriv", "ftp", "ntp", "audit", "alert", "clock",
    "local0", "local1", "local2", "local3", "local4", "local5", "local6", "local7"
];

//! @brief Reads an optional "<priority>" prefix
//! @param present - there was one; level and facility are set then
//! @returns false if it starts like one but is not valid
bool readPriority(ref const(char)[] s, out bool present, out LogLevel level, out string facility) pure nothrow @nogc @safe
{
    import log_core.text.text_parsing : readChar, readNumber;

    if (s.length == 0 || s[0] != '<')
        return true; // no prefix
    const(char)[] rest = s[1 .. $];
    uint value;
    if (!readNumber(rest, value) || !readChar(rest, '>') || !splitPriority(value, level, facility))
        return false;
    present = true;
    s = rest;
    return true;
}

//! @brief Splits a priority number into the level and the facility
//! @returns false if it is out of range (facility 0..23)
bool splitPriority(uint value, out LogLevel level, out string facility) pure nothrow @nogc @safe
{
    if (value >= facilityNames.length * 8)
        return false;
    level = severityLevel(value & 7);
    facility = facilityNames[value >> 3];
    return true;
}

@("syslog priority: severities, names and the prefix")
unittest
{
    const LogLevel[8] expected = [
        LogLevel.Fatal, LogLevel.Fatal, LogLevel.Fatal, LogLevel.Error,
        LogLevel.Warn, LogLevel.Info, LogLevel.Info, LogLevel.Debug
    ];
    foreach (severity, level; expected)
        assert(severityLevel(cast(uint) severity) == level);

    LogLevel level;
    assert(severityByName("warn", level) && level == LogLevel.Warn);
    assert(severityByName("emerg", level) && level == LogLevel.Fatal);
    assert(!severityByName("warning", level), "dmesg -x names");

    const(char)[] s = "<30>rest";
    bool present;
    string facility;
    assert(readPriority(s, present, level, facility) && s == "rest");
    assert(present && level == LogLevel.Info && facility == "daemon");

    s = "<134>x";
    assert(readPriority(s, present, level, facility) && facility == "local0");

    s = "no prefix";
    assert(readPriority(s, present, level, facility) && !present && s == "no prefix");

    foreach (bad; ["<192>x", "<x>", "<30"])
    {
        s = bad;
        assert(!readPriority(s, present, level, facility), bad);
    }
}
