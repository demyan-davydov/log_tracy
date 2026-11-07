//! Read-only memory mapped file that survives the loss of its storage.
//!
//! When the medium of a mapped file goes away (a USB disk is pulled, an I/O
//! error, the file is truncated), touching a page that is not in memory yet
//! raises a hardware fault instead of an error code: SIGBUS on POSIX,
//! EXCEPTION_IN_PAGE_ERROR on Windows. Unhandled, it kills the process.
//!
//! Every MappedFile registers its address range in a process-wide table. The
//! fault handler checks whether the faulting address belongs to one of them:
//!   * if it does, the file is marked lost and the failed page is replaced by
//!     a page of zeros, so the interrupted read completes (reading zeros) and
//!     the code can check lost() and stop using the file;
//!   * otherwise the fault is passed on, so real bugs still crash as before.
module utils.mapped_file;

import core.atomic : atomicLoad, atomicStore, cas, MemoryOrder;

//! Read-only mapping of a whole file. Not copyable: it owns the mapping.
struct MappedFile
{
    private const(ubyte)[] _data;
    private size_t _slot = noSlot;

    version (Windows)
    {
        import core.sys.windows.windows : HANDLE;

        private HANDLE _file;
        private HANDLE _mapping;
    }

    @disable this(this);

    //! @brief Maps the whole file `path` for reading.
    //! @throws Exception if the file can't be opened or mapped
    this(string path)
    {
        mapFile(path);
        if (_data.length > 0)
            _slot = registerRange(_data.ptr, _data.length);
    }

    ~this()
    {
        close();
    }

    //! @brief Unmaps the file. Idempotent; the destructor calls it as well.
    void close() nothrow @nogc
    {
        const bool wasLost = _slot != noSlot && isLostSlot(_slot);
        if (_slot != noSlot)
        {
            unregisterRange(_slot);
            _slot = noSlot;
        }
        unmapFile(wasLost);
        _data = null;
    }

    //! @return the content of the file; reads as zeros after the file is lost
    const(ubyte)[] data() const pure nothrow @nogc @property
    {
        return _data;
    }

    //! @return true once a read of the file failed: its storage is gone
    bool lost() const nothrow @nogc @property
    {
        return _slot != noSlot && isLostSlot(_slot);
    }

    version (Posix)
    {
        private void mapFile(string path)
        {
            import core.sys.posix.fcntl : open, O_RDONLY;
            import core.sys.posix.sys.mman : mmap, MAP_SHARED, MAP_FAILED, PROT_READ;
            import core.sys.posix.sys.stat : fstat, stat_t;
            import core.sys.posix.unistd : posixClose = close;
            import std.exception : errnoEnforce;
            import std.string : toStringz;

            const fd = open(path.toStringz, O_RDONLY);
            errnoEnforce(fd != -1, "Can't open " ~ path);
            scope (exit)
                posixClose(fd); // the mapping keeps its own reference

            stat_t st;
            errnoEnforce(fstat(fd, &st) == 0, "Can't stat " ~ path);
            const size = cast(size_t) st.st_size;
            if (size == 0)
                return; // nothing to map

            void* ptr = mmap(null, size, PROT_READ, MAP_SHARED, fd, 0);
            errnoEnforce(ptr != MAP_FAILED, "Can't map " ~ path);
            _data = (cast(const(ubyte)*) ptr)[0 .. size];
        }

        private void unmapFile(bool wasLost) nothrow @nogc
        {
            import core.sys.posix.sys.mman : munmap;

            // Pages replaced after a loss are part of the same range
            if (_data.length > 0)
                munmap(cast(void*) _data.ptr, _data.length);
        }
    }
    else version (Windows)
    {
        private void mapFile(string path)
        {
            import core.sys.windows.windows;
            import std.exception : enforce;
            import std.utf : toUTF16z;
            import std.windows.syserror : sysErrorString;

            string error(string what)
            {
                return what ~ " " ~ path ~ ": " ~ sysErrorString(GetLastError());
            }

            _file = CreateFileW(path.toUTF16z, GENERIC_READ,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, null,
                OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
            enforce(_file != INVALID_HANDLE_VALUE, error("Can't open"));

            LARGE_INTEGER size;
            enforce(GetFileSizeEx(_file, &size), error("Can't get the size of"));
            if (size.QuadPart == 0)
                return; // nothing to map (and CreateFileMapping rejects it)

            _mapping = CreateFileMappingW(_file, null, PAGE_READONLY, 0, 0, null);
            enforce(_mapping !is null, error("Can't map"));

            void* ptr = MapViewOfFile(_mapping, FILE_MAP_READ, 0, 0, 0);
            enforce(ptr !is null, error("Can't map a view of"));
            _data = (cast(const(ubyte)*) ptr)[0 .. cast(size_t) size.QuadPart];
        }

        private void unmapFile(bool wasLost) nothrow @nogc
        {
            import core.sys.windows.windows;

            if (_data.length > 0)
            {
                if (wasLost) // the view was replaced by reserved memory
                    VirtualFree(cast(void*) _data.ptr, 0, MEM_RELEASE);
                else
                    UnmapViewOfFile(cast(void*) _data.ptr);
            }
            if (_mapping !is null)
                CloseHandle(_mapping);
            if (_file !is null && _file != INVALID_HANDLE_VALUE)
                CloseHandle(_file);
            _mapping = null;
            _file = null;
        }
    }
    else
        static assert(0, "MappedFile: unsupported platform");
}

// ─── Registry of guarded ranges ────────────────────────────────────────────
// Read by the fault handler, which may run on any thread at any time: no
// locks and no allocations there, only atomics on a fixed table.

private enum size_t noSlot = size_t.max;
private enum size_t maxSlots = 64; // open documents at a time

private enum SlotState : int
{
    free,
    reserving, // being registered or unregistered
    active,
    remapping, // Windows: the view is being replaced after a loss
    lost,
}

private struct Slot
{
    shared size_t begin;
    shared size_t end;
    shared int state; // SlotState
}

private __gshared Slot[maxSlots] g_slots;
private __gshared size_t g_pageSize;

private size_t registerRange(const(void)* begin, size_t length)
{
    installFaultHandler();

    foreach (i, ref slot; g_slots)
    {
        if (!cas(&slot.state, cast(int) SlotState.free, cast(int) SlotState.reserving))
            continue;
        atomicStore(slot.begin, cast(size_t) begin);
        atomicStore(slot.end, cast(size_t) begin + length);
        atomicStore!(MemoryOrder.rel)(slot.state, cast(int) SlotState.active);
        return i;
    }
    throw new Exception("Too many mapped files");
}

private void unregisterRange(size_t i) nothrow @nogc
{
    atomicStore!(MemoryOrder.rel)(g_slots[i].state, cast(int) SlotState.reserving);
    atomicStore(g_slots[i].begin, 0);
    atomicStore(g_slots[i].end, 0);
    atomicStore!(MemoryOrder.rel)(g_slots[i].state, cast(int) SlotState.free);
}

private bool isLostSlot(size_t i) nothrow @nogc
{
    const state = atomicLoad!(MemoryOrder.acq)(g_slots[i].state);
    return state == SlotState.lost || state == SlotState.remapping;
}

//! @return the slot whose range contains `address`, or noSlot
private size_t findSlot(size_t address) nothrow @nogc
{
    foreach (i, ref slot; g_slots)
    {
        const state = atomicLoad!(MemoryOrder.acq)(slot.state);
        if (state == SlotState.free || state == SlotState.reserving)
            continue;
        if (address >= atomicLoad(slot.begin) && address < atomicLoad(slot.end))
            return i;
    }
    return noSlot;
}

private size_t pageOf(size_t address) nothrow @nogc
{
    return address & ~(g_pageSize - 1);
}

// ─── Fault handlers ────────────────────────────────────────────────────────

private __gshared bool g_handlerInstalled;

version (Posix)
{
    import core.sys.posix.signal : sigaction, sigaction_t, siginfo_t, sigemptyset,
        SA_SIGINFO, SIGBUS, SIG_DFL, SIG_IGN;

    private __gshared sigaction_t g_previousAction;

    private void installFaultHandler()
    {
        import core.sys.posix.unistd : sysconf, _SC_PAGESIZE;

        synchronized
        {
            if (g_handlerInstalled)
                return;
            g_pageSize = cast(size_t) sysconf(_SC_PAGESIZE);

            sigaction_t action;
            action.sa_sigaction = cast(typeof(action.sa_sigaction))&onSigBus;
            action.sa_flags = SA_SIGINFO;
            sigemptyset(&action.sa_mask);
            if (sigaction(SIGBUS, &action, &g_previousAction) != 0)
                throw new Exception("Can't install the SIGBUS handler");
            g_handlerInstalled = true;
        }
    }

    private extern (C) void onSigBus(int signal, siginfo_t* info, void* context) nothrow @nogc
    {
        import core.sys.posix.sys.mman : mmap, MAP_ANON, MAP_FAILED, MAP_FIXED, MAP_PRIVATE, PROT_READ;

        const address = cast(size_t) info.si_addr;
        const i = findSlot(address);
        if (i != noSlot)
        {
            // Replace the unreadable page with zeros: the faulting read is
            // restarted on return and succeeds
            void* page = cast(void*) pageOf(address);
            if (mmap(page, g_pageSize, PROT_READ, MAP_FIXED | MAP_PRIVATE | MAP_ANON, -1, 0) != MAP_FAILED)
            {
                atomicStore!(MemoryOrder.rel)(g_slots[i].state, cast(int) SlotState.lost);
                return;
            }
        }

        // Not ours (or the page could not be replaced): behave as without us
        if ((g_previousAction.sa_flags & SA_SIGINFO) && g_previousAction.sa_sigaction !is null)
        {
            (cast(void function(int, siginfo_t*, void*) nothrow @nogc) g_previousAction.sa_sigaction)(
                signal, info, context);
            return;
        }
        if (g_previousAction.sa_handler == SIG_DFL || g_previousAction.sa_handler == SIG_IGN)
        {
            // Restore the default action; returning re-raises the fault with it
            sigaction_t defaultAction;
            defaultAction.sa_handler = SIG_DFL;
            sigemptyset(&defaultAction.sa_mask);
            sigaction(SIGBUS, &defaultAction, null);
            return;
        }
        (cast(void function(int) nothrow @nogc) g_previousAction.sa_handler)(signal);
    }
}
else version (Windows)
{
    import core.sys.windows.windows;

    private void installFaultHandler()
    {
        synchronized
        {
            if (g_handlerInstalled)
                return;
            SYSTEM_INFO info;
            GetSystemInfo(&info);
            g_pageSize = info.dwPageSize;

            if (AddVectoredExceptionHandler(1, &onException) is null)
                throw new Exception("Can't install the exception handler");
            g_handlerInstalled = true;
        }
    }

    // A view of a mapped file can't have single pages replaced. After the
    // first failed read the whole view is unmapped and its address range
    // reserved instead; pages are committed (as zeros) one at a time when an
    // access violation hits them.
    private extern (Windows) LONG onException(EXCEPTION_POINTERS* pointers) nothrow @nogc
    {
        auto record = pointers.ExceptionRecord;
        const code = record.ExceptionCode;
        if ((code != EXCEPTION_IN_PAGE_ERROR && code != EXCEPTION_ACCESS_VIOLATION)
            || record.NumberParameters < 2)
            return EXCEPTION_CONTINUE_SEARCH;

        const address = cast(size_t) record.ExceptionInformation[1];
        const i = findSlot(address);
        if (i == noSlot)
            return EXCEPTION_CONTINUE_SEARCH;

        auto slot = &g_slots[i];
        void* begin = cast(void*) atomicLoad(slot.begin);

        if (code == EXCEPTION_IN_PAGE_ERROR
            && cas(&slot.state, cast(int) SlotState.active, cast(int) SlotState.remapping))
        {
            const length = atomicLoad(slot.end) - cast(size_t) begin;
            UnmapViewOfFile(begin);
            const reserved = VirtualAlloc(begin, length, MEM_RESERVE, PAGE_READONLY);
            atomicStore!(MemoryOrder.rel)(slot.state, cast(int) SlotState.lost);
            if (reserved is null)
                return EXCEPTION_CONTINUE_SEARCH; // the range was taken meanwhile
        }

        // Another thread may be replacing the view right now
        while (atomicLoad!(MemoryOrder.acq)(slot.state) == SlotState.remapping)
            SwitchToThread();
        if (atomicLoad!(MemoryOrder.acq)(slot.state) != SlotState.lost)
            return EXCEPTION_CONTINUE_SEARCH; // a real access violation

        if (VirtualAlloc(cast(void*) pageOf(address), g_pageSize, MEM_COMMIT, PAGE_READONLY) is null)
            return EXCEPTION_CONTINUE_SEARCH;
        return EXCEPTION_CONTINUE_EXECUTION;
    }
}

// =============================================================================
// Unit tests
// =============================================================================

version (Posix)
{
    @("MappedFile: maps the content of a file")
    unittest
    {
        import std.file : remove, tempDir, write;
        import std.path : buildPath;

        auto path = buildPath(tempDir(), "mapped_file_content.bin");
        write(path, "hello");
        scope (exit)
            remove(path);

        auto file = MappedFile(path);
        assert(cast(const(char)[]) file.data == "hello");
        assert(!file.lost);
    }

    @("MappedFile: an empty file maps to an empty range")
    unittest
    {
        import std.file : remove, tempDir, write;
        import std.path : buildPath;

        auto path = buildPath(tempDir(), "mapped_file_empty.bin");
        write(path, "");
        scope (exit)
            remove(path);

        auto file = MappedFile(path);
        assert(file.data.length == 0 && !file.lost);
    }

    @("MappedFile: a missing file throws")
    unittest
    {
        import std.exception : assertThrown;

        assertThrown(MappedFile("/nonexistent/mapped_file.bin"));
    }

    @("MappedFile: a read after the storage is gone reads zeros and marks the file lost")
    unittest
    {
        import core.sys.posix.unistd : truncate;
        import std.file : remove, tempDir, write;
        import std.path : buildPath;
        import std.string : toStringz;

        // Truncating a mapped file makes its pages beyond the new end raise
        // SIGBUS, the same fault as a pulled disk
        auto path = buildPath(tempDir(), "mapped_file_lost.bin");
        auto content = new ubyte[](1024 * 1024);
        content[] = 0xAB;
        write(path, content);
        scope (exit)
            remove(path);

        auto file = MappedFile(path);
        assert(truncate(path.toStringz, 0) == 0);

        // Without the handler this read kills the process
        const value = (cast(const(ubyte)*) file.data.ptr)[content.length / 2];
        assert(value == 0, "the lost page reads as zeros");
        assert(file.lost, "the file is marked lost");

        file.close(); // unmapping a lost file is fine
        assert(!file.lost);
    }
}
