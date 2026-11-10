module log_core.byte_source;

import utils.mapped_file : MappedFile;

//! Where the bytes of a log come from: a file now, later a growing file or a
//! stream spooled to disk. Records are addressed by their offset in data().
interface ByteSource
{
    //! All bytes available so far. The slice stays valid until close(). A
    //! source that isn't complete may give more later: a longer slice with
    //! the same bytes at the same place, so what was read stays readable.
    const(ubyte)[] data() const pure nothrow @nogc;

    //! true if no more bytes will come: the last bytes are a whole record or
    //! garbage. false for a source being written (a growing file, a stream):
    //! a record cut by the end of data() is waited for
    bool complete() const nothrow @nogc;

    //! true once the bytes can't be read any more (e.g. the disk of the file
    //! was removed); data() reads as zeros from then on
    bool lost() const nothrow @nogc;

    //! Releases the bytes. Idempotent; data() is empty afterwards.
    void close() nothrow @nogc;
}

//! A file mapped into memory
final class FileSource : ByteSource
{
    private MappedFile _file;

    //! @throws Exception if the file can't be opened
    this(string path)
    {
        _file = MappedFile(path);
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
        return true; // the file as it was mapped
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
