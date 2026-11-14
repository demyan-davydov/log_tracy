//! Writes a test log of a format, size and content (formats/generator): the same options and
//! seed give the same file on every machine. Built and run by
//! `node scripts/build.mjs gen-log <file> --format dlt --size 1G ...` (the options: --help).
module gen_log;

import std.stdio : File, stderr, write, writefln;

import formats.generator.command_line : genLogUsage, parseGenCommand;
import formats.generator.generator;

int main(string[] args)
{
    import core.time : MonoTime;

    GenStats stats;
    try
    {
        const command = parseGenCommand(args);
        if (command.help)
        {
            write(genLogUsage);
            return 0;
        }
        const start = MonoTime.currTime;
        auto file = File(command.path, "wb");
        file.setvbuf(1 << 20);
        stats = generateLog(command.options, (const(ubyte)[] bytes) { file.rawWrite(bytes); });
        file.close();

        writefln("%s: %s records, %s bytes in %s ms", command.path, stats.records, stats.bytes,
            (MonoTime.currTime - start).total!"msecs");
        foreach (kind, n; stats.corrupted)
            if (n > 0)
                writefln("  broken by %s: %s", corruptionNames[kind], n);
        if (stats.truncated)
            writefln("  the last record cut");
        return 0;
    }
    catch (Exception e)
    {
        stderr.writefln("gen_log: %s (see --help)", e.msg);
        return 1;
    }
}
