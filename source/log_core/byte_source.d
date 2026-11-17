//! ByteSource: where the bytes of a log come from.
module log_core.byte_source;

import utils.mapped_file : Growth, MappedFile;

import core.time : MonoTime, seconds;

//! Where the bytes of a log come from: a file now, later a growing file or a
//! stream spooled to disk. Records are addressed by their offset in data().
interface ByteSource
{
    //! All bytes available so far. The slice stays valid until close(). A
    //! source that isn't complete may give more later: a longer slice with
    //! the same bytes at the same place, so what was read stays readable.
    const(ubyte)[] data() const pure nothrow @nogc;

    //! true if no more bytes are waited for now: a record cut by the end of
    //! data() is let out (LogFormat.scanRecords, final_). false for a source
    //! being written (a growing file, a stream): such a record is waited for.
    //! A source may be complete for a while and get more bytes later (a file
    //! written again after a pause, see PolledSource): it is not complete
    //! then, and what was taken stays as it was taken.
    //! A reader asks complete() first, then data(): the other way round, bytes
    //! that came in between would make it take the end of the data it holds
    //! for the end of the source.
    bool complete() const nothrow @nogc;

    //! true once the bytes can't be read any more (e.g. the disk of the file
    //! was removed); data() reads as zeros from then on
    bool lost() const nothrow @nogc;

    //! Releases the bytes. Idempotent; data() is empty afterwards.
    void close() nothrow @nogc;
}

//! @brief A source that learns of its new bytes when asked: a file being written. Its
//! holder polls it now and then, from one thread, while nothing reads complete() or scans
//! its data (data() may be read meanwhile: it only gets longer)
interface PolledSource
{
    //! Takes the bytes written since the last poll; tells it complete once no byte came
    //! for a while. `now` is the time of the poll
    void poll(MonoTime now);

    //! The source got shorter than its data (a file truncated: rotated by copying it
    //! and emptying it). Its data can't be trusted past the new end: its holder opens it
    //! anew
    bool truncated() const nothrow @nogc;
}

//! @brief A file mapped into memory, which grows as the file is written (PolledSource):
//! complete once it didn't grow for quietPeriod
final class FileSource : ByteSource, PolledSource
{
    //! A file that didn't grow that long is taken as complete: its last record is let out
    enum quietPeriod = 1.seconds;

    private MappedFile _file;
    private shared bool _complete; // read by the indexing thread
    private bool _truncated;
    private MonoTime _grewAt; // when the file was opened or last grew

    //! @throws Exception if the file can't be opened
    this(string path, MonoTime now = MonoTime.currTime)
    {
        _file = MappedFile(path);
        _grewAt = now;
    }

    ~this()
    {
        _file.close();
    }

    override const(ubyte)[] data() const pure nothrow @nogc
    {
        return _file.data;
    }

    override bool complete() const nothrow @nogc
    {
        import core.atomic : atomicLoad;

        return atomicLoad(_complete);
    }

    override void poll(MonoTime now)
    {
        import core.atomic : atomicStore;

        final switch (_file.grow())
        {
        case Growth.grew:
            atomicStore(_complete, false);
            _grewAt = now;
            break;
        case Growth.shrank:
            _truncated = true;
            break;
        case Growth.none:
            if (now - _grewAt >= quietPeriod)
                atomicStore(_complete, true);
            break;
        }
    }

    override bool truncated() const nothrow @nogc
    {
        return _truncated;
    }

    override bool lost() const nothrow @nogc
    {
        return _file.lost;
    }

    override void close() nothrow @nogc
    {
        _file.close();
    }
}

@("FileSource.poll: complete once the file didn't grow for a while, not after it grew")
unittest
{
    import core.time : msecs;
    import std.file : remove, tempDir, write;
    import std.path : buildPath;
    import std.stdio : File;

    const path = buildPath(tempDir(), "byte_source_poll.txt");
    write(path, "one\ntw");
    scope (exit)
        remove(path);

    const t0 = MonoTime.currTime;
    auto source = new FileSource(path, t0);
    scope (exit)
        source.close();
    assert(!source.complete, "it may be being written");
    source.poll(t0 + 500.msecs);
    assert(!source.complete);
    source.poll(t0 + FileSource.quietPeriod);
    assert(source.complete, "quiet for a while");

    File(path, "ab").rawWrite("o\n");
    source.poll(t0 + 2 * FileSource.quietPeriod);
    assert(!source.complete, "written again");
    assert(cast(const(char)[]) source.data == "one\ntwo\n");
    source.poll(t0 + 3 * FileSource.quietPeriod);
    assert(source.complete);
    assert(!source.truncated);
}

@("FileSource.poll: a file made shorter is truncated")
unittest
{
    import core.time : msecs;
    import std.file : remove, tempDir, write;
    import std.path : buildPath;

    const path = buildPath(tempDir(), "byte_source_truncated.txt");
    write(path, "one\ntwo\n");
    scope (exit)
        remove(path);

    const t0 = MonoTime.currTime;
    auto source = new FileSource(path, t0);
    scope (exit)
        source.close();
    write(path, ""); // emptied, as a rotation by copying does
    source.poll(t0 + 10.msecs);
    assert(source.truncated);
}

@("FileSource: maps the content of a file")
unittest
{
    import std.file : write, remove, tempDir;
    import std.path : buildPath;

    const path = buildPath(tempDir(), "byte_source_test.bin");
    write(path, cast(const(ubyte)[]) "content");
    scope (exit)
        remove(path);

    auto source = new FileSource(path);
    assert(source.data == cast(const(ubyte)[]) "content");
    assert(!source.lost);

    source.close();
    assert(source.data.length == 0);
    source.close(); // idempotent
}
