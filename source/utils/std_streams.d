//! The standard output streams of a program started without them: a Windows program
//! (`/SUBSYSTEM:WINDOWS`) run from Explorer or a shortcut has neither stdout nor stderr, and a
//! launcher elsewhere may start a program with them closed; std.stdio throws once the C library
//! fails a write to one, at whatever line its buffer filled. Such a stream is pointed at the null
//! device by this module's constructor, before any other one writes (a module that writes in
//! its constructor imports this one, which makes its constructor run first): what is written
//! there is dropped. A stream the program was given (a console, a file, the pipe of an MCP
//! client) stays as it is.
module utils.std_streams;

import std.stdio : File;

/// Whether stdout and stderr were checked, missing ones pointed at the null device: true once
/// this module's constructor has run
bool streamsChecked() nothrow @nogc => _checked;

private __gshared bool _checked;

/// Whether a standard stream is missing: the C library has no descriptor for it (-2 in a
/// Windows program without a console), or the system has no usable handle behind it.
bool streamMissing(int descriptor, bool systemHandleUsable) pure nothrow @nogc @safe
{
    return descriptor < 0 || !systemHandleUsable;
}

/// Whether a handle of Windows is usable, by what `GetFileType` gave and `GetLastError` after
/// it: FILE_TYPE_UNKNOWN (0) is a failure only with an error, else a handle of a kind it doesn't
/// name (a device, a redirector of another program), which works.
bool windowsHandleUsable(uint fileType, uint lastError) pure nothrow @nogc @safe
{
    enum fileTypeUnknown = 0, noError = 0;
    return fileType != fileTypeUnknown || lastError == noError;
}

@("streamMissing: a stream without a descriptor or a usable handle of the system is missing")
unittest
{
    assert(!streamMissing(1, true), "a console, a file or a pipe");
    assert(streamMissing(-2, false), "a Windows program without a console");
    assert(streamMissing(-2, true), "no descriptor of the C library");
    assert(streamMissing(1, false), "a handle the system doesn't take");
}

@("windowsHandleUsable: FILE_TYPE_UNKNOWN is a failure only with an error")
unittest
{
    enum fileTypeUnknown = 0, fileTypeDisk = 1, noError = 0, errorInvalidHandle = 6;
    assert(windowsHandleUsable(fileTypeDisk, noError));
    assert(windowsHandleUsable(fileTypeUnknown, noError), "a handle of a kind it doesn't name");
    assert(!windowsHandleUsable(fileTypeUnknown, errorInvalidHandle), "no handle, or a closed one");
}

version (Posix)
{
    @("silenceIfMissing: a stream whose descriptor was closed is pointed at /dev/null, writes go on")
    unittest
    {
        import core.sys.posix.unistd : close;
        import std.file : deleteme, remove;

        const path = deleteme ~ "_std_streams";
        auto stream = File(path, "w");
        scope (exit) remove(path);
        close(stream.fileno); // as a launcher that closed it: the C library still names it
        assert(silenceIfMissing(stream, 0), "a closed stream is missing");
        stream.writeln("dropped");
        stream.flush(); // threw before: a write to a closed descriptor
        assert(!silenceIfMissing(stream, 0), "the null device is usable");
    }
}

/// Points `stream` at the null device if it is missing (`stdHandle`: its STD_..._HANDLE of
/// Windows): whether it did.
private bool silenceIfMissing(ref File stream, uint stdHandle) nothrow
{
    version (Windows)
    {
        try
        {
            import core.sys.windows.windows : GetFileType, GetLastError, GetStdHandle,
                NO_ERROR, SetLastError;

            SetLastError(NO_ERROR); // GetFileType keeps it on a handle of an unknown kind
            const type = GetFileType(GetStdHandle(stdHandle));
            if (!streamMissing(stream.fileno, windowsHandleUsable(type, GetLastError())))
                return false;
            stream.reopen("NUL", "w");
            return true;
        }
        catch (Exception) // left as it is: nowhere to say it
            return false;
    }
    else version (Posix)
    {
        try
        {
            import core.stdc.errno : EBADF, errno;
            import core.sys.posix.fcntl : F_GETFD, fcntl;

            const descriptor = stream.fileno;
            const closed = descriptor >= 0 && fcntl(descriptor, F_GETFD) == -1 && errno == EBADF;
            if (!streamMissing(descriptor, !closed))
                return false;
            stream.reopen("/dev/null", "w");
            return true;
        }
        catch (Exception) // left as it is: nowhere to say it
            return false;
    }
    else
        return false;
}

// Before the constructors of the modules that import this one: stdout and stderr, each one
// missing, pointed at the null device
shared static this()
{
    import std.stdio : stderr, stdout;

    enum uint stdOutputHandle = cast(uint) -11, stdErrorHandle = cast(uint) -12; // STD_OUTPUT_HANDLE, STD_ERROR_HANDLE of Windows
    silenceIfMissing(stdout, stdOutputHandle);
    silenceIfMissing(stderr, stdErrorHandle);
    _checked = true;
}
