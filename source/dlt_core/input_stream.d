module dlt_core.input_stream;

/// Interface for a sequential read-only stream

class InputStreamException : Exception
{
    this(string msg)
    {
        super(msg);
    }
}

interface InputStream
{
    //! Returns true if the stream is empty
    bool empty() const;

    //! Returns the current position in the stream
    size_t position() const;

    //! Seeks to the specified position in the stream
    void seek(size_t offset);

    //! Pops the specified number of bytes into the buffer
    void[] pop(void[] buffer);

    //! Pops required buffer or throws an InputStreamException
    void[] popOrThrow(void[] buffer);

    //! Skips the specified number of bytes
    bool skip(size_t size);

    //! Pops the specified number of bytes into the buffer
    final bool pop(T)(ref T result)
    {
        import core.stdc.string : memcpy;

        ubyte[T.sizeof] tmp = void;
        void[] tmpBuf = tmp[];
        const auto receivedBuffer = pop(tmpBuf);
        if (receivedBuffer.length == T.sizeof)
        {
            memcpy(cast(void*)&result, tmp.ptr, T.sizeof);
            return true;
        }
        return false;
    }

    //! Pops the specified number of bytes into the buffer
    final T popOrThrow(T)(ref T result)
    {
        import core.stdc.string : memcpy;

        ubyte[T.sizeof] tmp = void;
        void[] tmpBuf = tmp[];
        popOrThrow(tmpBuf);
        memcpy(cast(void*)&result, tmp.ptr, T.sizeof);
        return result;
    }

    //! Pops the specified number of elements into the array
    final bool popArray(T)(T[] result)
    {
        void[] buffer = new void[T.sizeof * result.length];
        const auto receivedBuffer = pop(buffer);
        return receivedBuffer.length == T.sizeof * result.length;
    }

    //! Pops the specified number of elements into the array
    final T[] popArrayOrThrow(T)(T[] result)
    {
        void[] buffer = new void[T.sizeof * result.length];
        popOrThrow(buffer);
        return result;
    }
}
