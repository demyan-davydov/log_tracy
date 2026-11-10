//! The text records of the log generator: a line each, ended by "\n". Not in the program:
//! only in unittests and with -d-version=LogGenerator.
module formats.generator.text;

version (unittest)
    version = LogGeneratorCode;
else version (LogGenerator)
    version = LogGeneratorCode;

version (LogGeneratorCode):

import formats.generator.content : RecordContent, Rng;

//! @returns a plain text record of `r`: its text and a line break
ubyte[] plainTextRecord(in RecordContent r)
{
    return cast(ubyte[])(r.text ~ '\n');
}

//! @returns a line of bytes no text has (control characters, bytes that are not UTF-8), but
//! no zero: a zero in the first bytes makes the data binary for the detection
ubyte[] junkLine(ref Rng rng)
{
    static immutable ubyte[] junk = [0x01, 0x02, 0x07, 0x08, 0x1B, 0x7F, 0xFE, 0xFF, 0xC0, 0x80];
    auto line = new ubyte[rng.between(1, 80) + 1];
    foreach (ref b; line[0 .. $ - 1])
        b = junk[rng.below(junk.length)];
    line[$ - 1] = '\n';
    return line;
}

//! @returns an ASCII line longer than one record holds (`maxRecordLength`), shorter than
//! two: the reader cuts it into two records
ubyte[] longLine(ref Rng rng, size_t maxRecordLength)
{
    auto line = new ubyte[rng.between(maxRecordLength + 1, 2 * maxRecordLength - 1) + 1];
    foreach (i, ref b; line[0 .. $ - 1])
        b = cast(ubyte)('a' + i % 26);
    line[$ - 1] = '\n';
    return line;
}
