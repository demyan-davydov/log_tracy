module dlt_core.stream;

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
        void[] resultBuffer = (cast(void*)&result)[0 .. T.sizeof];
        const auto receivedBuffer = pop(resultBuffer);
        return receivedBuffer.length == T.sizeof;
    }

    //! Pops the specified number of bytes into the buffer
    final T popOrThrow(T)(ref T result)
    {
        void[] resultBuffer = (cast(void*)&result)[0 .. T.sizeof];
        popOrThrow(resultBuffer);
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
