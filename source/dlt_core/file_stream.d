module dlt_core.file_stream;

import dlt_core.stream;
import std.stdio : File, StdioException;

class FileStream : InputStream
{
    private File _file;

    this(string filename)
    {
        _file = File(filename, "rb");

        if (!_file.isOpen)
            throw new StdioException("Cannot open file: " ~ filename);
    }

    ~this()
    {
        _file.close();
    }

    override bool empty() const
    {
        return _file.eof;
    }

    override size_t position() const
    {
        return _file.tell();
    }

    override void seek(size_t offset)
    {
        _file.seek(offset);
    }

    override void[] pop(void[] buffer)
    {
        return cast(ubyte[]) _file.rawRead(cast(ubyte[]) buffer);
    }

    override void[] popOrThrow(void[] buffer)
    {
        if (_file.rawRead(cast(ubyte[]) buffer).length != buffer.length)
            throw new InputStreamException("Failed to read from file");
        return buffer;
    }

    override bool skip(size_t size)
    {
        _file.seek(_file.tell() + size);
        return true;
    }

    void close()
    {
        _file.close();
    }

    size_t size()
    {
        return _file.size;
    }
}
