//! One running copy of a program per lock file.
//!
//! The first copy takes an exclusive lock on the file and writes its process id into it; a
//! copy started after it fails to take the lock, reads that id and can bring the windows of
//! the first copy forward before it exits. The lock belongs to the open file: the system
//! drops it when the process ends, even when it crashes, so a file left behind locks nothing.
//!
//! The lock: `flock` on POSIX (per open file, so two locks of one process conflict too),
//! `LockFileEx` on Windows on a byte past the id, which the other copy still reads. A lock
//! that fails for another reason (a file system without locks) is an error, not another copy.
//! Bringing forward: `NSRunningApplication` on macOS, the top-level windows of the process
//! on Windows; on Linux nothing is done (it depends on X11 or Wayland and its compositor).
module utils.single_instance;

/// The claim of this process on a lock file, held from construction to `release` or the
/// destructor.
final class SingleInstance
{
    private LockFile _file;
    private bool _first;
    private int _firstPid;

    /// Opens (creates) the lock file at `path` and tries to lock it. Throws when the file
    /// can't be opened or locked at all: whether another copy runs is then unknown.
    this(string path)
    {
        _file = LockFile.open(path);
        scope (failure) _file.close();
        _first = _file.tryLock(path);
        if (_first)
        {
            import std.conv : to;
            import std.process : thisProcessID;

            _file.rewrite(thisProcessID.to!string);
        }
        else
            _firstPid = readFirstPid();
    }

    ~this()
    {
        release();
    }

    /// Whether this process holds the lock: no other copy runs.
    bool isFirst() const => _first;

    /// The process id the first copy wrote into the file, 0 if this process is the first or
    /// none was written yet.
    int firstPid() const => _firstPid;

    /// Brings the windows of the first copy forward, as far as the system lets a process do
    /// that for another one. Does nothing if this process is the first.
    void activateFirst()
    {
        if (!_first && _firstPid > 0)
            activateProcess(_firstPid);
    }

    // The first copy writes its id right after it took the lock: wait for it a little
    private int readFirstPid()
    {
        import core.thread : Thread;
        import core.time : msecs;

        foreach (attempt; 0 .. 10)
        {
            if (auto pid = parsePid(_file.readAll()))
                return pid;
            Thread.sleep(20.msecs);
        }
        return 0;
    }

    /// Gives the lock up (the file stays). Called again, does nothing.
    void release() nothrow @nogc
    {
        _file.close();
        _first = false;
    }
}

/// The process id written in a lock file, 0 when there is none (the first copy hasn't written
/// it yet, or the file holds something else).
private int parsePid(const(char)[] text) pure nothrow @safe
{
    import std.ascii : isDigit;
    import std.string : strip;

    auto s = text.strip;
    if (s.length == 0 || s.length > 9)
        return 0;
    int pid;
    foreach (c; s)
    {
        if (!c.isDigit)
            return 0;
        pid = pid * 10 + (c - '0');
    }
    return pid;
}

@("lockBusy: only the error of a lock held elsewhere means another copy")
unittest
{
    version (Posix)
    {
        import core.stdc.errno : EBADF, ENOLCK, EWOULDBLOCK;

        assert(lockBusy(EWOULDBLOCK));
        assert(!lockBusy(ENOLCK)); // a file system without locks
        assert(!lockBusy(EBADF));
    }
    else version (Windows)
    {
        assert(lockBusy(ERROR_LOCK_VIOLATION));
        assert(!lockBusy(ERROR_INVALID_PARAMETER));
        assert(!lockBusy(ERROR_NOT_SUPPORTED));
    }
}

@("parsePid: an id, or 0 for what is not one")
unittest
{
    assert(parsePid("1234") == 1234);
    assert(parsePid(" 42\n") == 42);
    assert(parsePid("") == 0);
    assert(parsePid("12a") == 0);
    assert(parsePid("4000000000") == 0);
}

version (Posix)
{
    private extern (C) int flock(int fd, int operation) nothrow @nogc;
    private enum LOCK_EX = 2, LOCK_NB = 4;

    /// Whether a failed `flock` failed because another open file holds the lock.
    private bool lockBusy(int error) pure nothrow @nogc @safe
    {
        import core.stdc.errno : EWOULDBLOCK;

        return error == EWOULDBLOCK;
    }

    /// The open lock file: a descriptor.
    private struct LockFile
    {
        import core.sys.posix.fcntl : FD_CLOEXEC, F_SETFD, O_CREAT, O_RDWR, fcntl,
            posixOpen = open;
        import core.sys.posix.unistd : posixClose = close, ftruncate, pread, pwrite;

        private int _fd = -1;

        static LockFile open(string path)
        {
            import std.conv : octal;
            import std.exception : errnoEnforce;
            import std.string : toStringz;

            LockFile f;
            f._fd = posixOpen(path.toStringz, O_RDWR | O_CREAT, octal!644);
            errnoEnforce(f._fd >= 0, "can't open " ~ path);
            fcntl(f._fd, F_SETFD, FD_CLOEXEC); // a started process doesn't inherit the lock
            return f;
        }

        /// Takes the lock: true, or false when another open file holds it. Throws otherwise.
        bool tryLock(string path)
        {
            import core.stdc.errno : errno;
            import std.exception : ErrnoException;

            if (flock(_fd, LOCK_EX | LOCK_NB) == 0)
                return true;
            if (lockBusy(errno))
                return false;
            throw new ErrnoException("can't lock " ~ path);
        }

        void rewrite(const(char)[] text) nothrow @nogc
        {
            ftruncate(_fd, 0);
            pwrite(_fd, text.ptr, text.length, 0);
        }

        char[] readAll() nothrow
        {
            char[32] buf;
            auto n = pread(_fd, buf.ptr, buf.length, 0);
            return n > 0 ? buf[0 .. n].dup : null;
        }

        void close() nothrow @nogc
        {
            if (_fd >= 0)
                posixClose(_fd); // drops the lock
            _fd = -1;
        }
    }
}
else version (Windows)
{
    import core.sys.windows.windows;

    /// Whether a failed `LockFileEx` failed because another handle holds the lock.
    private bool lockBusy(DWORD error) pure nothrow @nogc @safe
        => error == ERROR_LOCK_VIOLATION;

    /// The open lock file: a handle.
    private struct LockFile
    {
        private HANDLE _h = INVALID_HANDLE_VALUE;

        static LockFile open(string path)
        {
            import std.exception : enforce;
            import std.utf : toUTF16z;

            LockFile f;
            // Shared, so the other copy opens it to read the id
            f._h = CreateFileW(path.toUTF16z, GENERIC_READ | GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, null, OPEN_ALWAYS,
                FILE_ATTRIBUTE_NORMAL, null);
            enforce(f._h != INVALID_HANDLE_VALUE, "can't open " ~ path);
            return f;
        }

        // A locked range can't be read by another handle: the lock is on a byte at 1 MB, far
        // past the id, beyond the end of the file (allowed), within what any file system holds
        private static OVERLAPPED lockedByte() nothrow @nogc
        {
            OVERLAPPED o;
            o.Offset = 1 << 20;
            return o;
        }

        /// Takes the lock: true, or false when another handle holds it. Throws otherwise.
        bool tryLock(string path)
        {
            import std.windows.syserror : WindowsException;

            auto o = lockedByte();
            if (LockFileEx(_h, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &o))
                return true;
            auto error = GetLastError();
            if (lockBusy(error))
                return false;
            throw new WindowsException(error, "can't lock " ~ path);
        }

        void rewrite(const(char)[] text) nothrow @nogc
        {
            DWORD written;
            SetFilePointer(_h, 0, null, FILE_BEGIN);
            WriteFile(_h, text.ptr, cast(DWORD) text.length, &written, null);
            SetEndOfFile(_h);
        }

        char[] readAll() nothrow
        {
            char[32] buf;
            DWORD n;
            SetFilePointer(_h, 0, null, FILE_BEGIN);
            if (!ReadFile(_h, buf.ptr, buf.length, &n, null))
                return null;
            return buf[0 .. n].dup;
        }

        void close() nothrow @nogc
        {
            if (_h != INVALID_HANDLE_VALUE)
                CloseHandle(_h); // drops the lock
            _h = INVALID_HANDLE_VALUE;
        }
    }
}

version (OSX)
{
    private void activateProcess(int pid)
    {
        import utils.objc : cls, msg;

        auto app = msg(cls("NSRunningApplication"), "runningApplicationWithProcessIdentifier:", pid);
        if (app is null)
            return;
        enum NSApplicationActivateAllWindows = 1UL << 0;
        enum NSApplicationActivateIgnoringOtherApps = 1UL << 1; // deprecated in macOS 14, still asked
        msg!byte(app, "activateWithOptions:",
            NSApplicationActivateAllWindows | NSApplicationActivateIgnoringOtherApps);
    }
}
else version (Windows)
{
    private void activateProcess(int pid)
    {
        static struct Search
        {
            DWORD pid;
            HWND found;
        }

        static extern (Windows) BOOL visit(HWND hwnd, LPARAM param) nothrow
        {
            auto search = cast(Search*) param;
            DWORD owner;
            GetWindowThreadProcessId(hwnd, &owner);
            if (owner != search.pid || !IsWindowVisible(hwnd) || GetWindow(hwnd, GW_OWNER)
                || (GetWindowLongW(hwnd, GWL_EXSTYLE) & WS_EX_TOOLWINDOW))
                return TRUE;
            search.found = hwnd;
            // The main window: a visible top-level one without an owner, not a popup
            return FALSE;
        }

        Search search = {pid: cast(DWORD) pid};
        EnumWindows(&visit, cast(LPARAM)&search);
        if (search.found is null)
            return;
        if (IsIconic(search.found))
            ShowWindow(search.found, SW_RESTORE);
        // Allowed: the process the user has just started may give the foreground away
        SetForegroundWindow(search.found);
    }
}
else
{
    private void activateProcess(int pid)
    {
        // Linux: see the module comment
    }
}

version (unittest)
{
    /// A folder of its own for a test's lock file, removed by `removeTestDir`.
    private string testLockPath(string name)
    {
        import std.file : mkdirRecurse;
        import std.path : buildPath;

        mkdirRecurse(testDir(name));
        return buildPath(testDir(name), "settings.lock");
    }

    private void removeTestDir(string name)
    {
        import std.file : exists, rmdirRecurse;

        if (exists(testDir(name)))
            rmdirRecurse(testDir(name));
    }

    private string testDir(string name)
    {
        import std.conv : to;
        import std.file : tempDir;
        import std.path : buildPath;
        import std.process : thisProcessID;

        return buildPath(tempDir, "dlt_explorer_single_instance_" ~ thisProcessID.to!string ~ "_" ~ name);
    }
}

@("SingleInstance: the first copy holds the lock, the second sees its process id")
unittest
{
    import std.process : thisProcessID;

    scope (exit) removeTestDir("two");
    auto first = new SingleInstance(testLockPath("two"));
    scope (exit) first.release();
    assert(first.isFirst);
    assert(first.firstPid == 0);

    auto second = new SingleInstance(testLockPath("two"));
    scope (exit) second.release();
    assert(!second.isFirst);
    assert(second.firstPid == thisProcessID);
}

@("SingleInstance: after the first copy is gone, the next one is first")
unittest
{
    scope (exit) removeTestDir("after");
    auto first = new SingleInstance(testLockPath("after"));
    assert(first.isFirst);
    first.release();
    first.release(); // again: nothing

    auto next = new SingleInstance(testLockPath("after"));
    scope (exit) next.release();
    assert(next.isFirst);
}

@("SingleInstance: a file left behind with an id in it locks nothing and is rewritten")
unittest
{
    import std.file : read, write;
    import std.process : thisProcessID;
    import std.conv : to;

    scope (exit) removeTestDir("stale");
    auto path = testLockPath("stale");
    write(path, "4000000000 and more text of an old copy");

    auto first = new SingleInstance(path);
    scope (exit) first.release();
    assert(first.isFirst);

    auto second = new SingleInstance(path);
    scope (exit) second.release();
    assert(second.firstPid == thisProcessID);
    assert(cast(string) read(path) == thisProcessID.to!string);
}
