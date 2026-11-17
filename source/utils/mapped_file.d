//! Read-only memory mapped file that survives the loss of its storage and grows in place
//! as the file is written (MappedFile.grow: room reserved after it; on Windows what is
//! written later is read into private memory there).
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

//! What MappedFile.grow found
enum Growth
{
    none, // the same size, or the file can't grow (no room reserved, lost)
    grew, // data() is longer: the bytes of before at the same place
    shrank, // the file is shorter than its data: what was cut reads as zeros when touched
}

//! @brief Read-only mapping of a whole file. Not copyable: it owns the mapping.
//! It may grow in place (grow()): room is reserved after the file, so data() gets longer
//! with the bytes of before at the same address. Read data() on any thread; grow() on one.
struct MappedFile
{
    private const(ubyte)* _ptr;
    private shared size_t _length; // of data(): published after its bytes are mapped
    private size_t _reserved; // the address space from _ptr the file may grow into; 0: it doesn't grow
    private size_t _slot = noSlot;

    version (Posix)
        private int _fd = -1; // kept open while the file may grow

    version (Windows)
    {
        import core.sys.windows.windows : HANDLE;

        private HANDLE _file;
        private HANDLE _mapping;
        // Of a file that grows: the bytes from _ptr mapped as a view of the file, whole 64K
        // pieces of it; the rest of data() is private memory the file is read into (a view
        // can't take the place of memory being read by other threads)
        private size_t _viewLength;
        private bool _readFailed; // a read of what was written failed: the file is lost
    }

    @disable this(this);

    //! @brief Maps the whole file `path` for reading.
    //! @throws Exception if the file can't be opened or mapped
    this(string path)
    {
        mapFile(path);
        if (_length > 0 || _reserved > 0)
            _slot = registerRange(_ptr, guardedLength);
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
        _ptr = null;
        atomicStore(_length, 0);
        _reserved = 0;
    }

    //! @return the content of the file; reads as zeros after the file is lost
    const(ubyte)[] data() const pure nothrow @nogc @property
    {
        return _ptr[0 .. atomicLoad!(MemoryOrder.acq)(_length)];
    }

    //! @brief Takes the bytes written to the file since it was mapped or last grown:
    //! data() gets longer, the bytes of before at the same place. One thread at a time.
    Growth grow() nothrow @nogc
    {
        version (Posix)
        {
            import core.sys.posix.sys.mman : mmap, MAP_FAILED, MAP_FIXED, MAP_SHARED, PROT_READ;
            import core.sys.posix.sys.stat : fstat, stat_t;

            if (_fd == -1 || lost)
                return Growth.none;
            stat_t st;
            if (fstat(_fd, &st) != 0)
                return Growth.none;
            const old = atomicLoad(_length); // this thread is its only writer
            size_t size = cast(size_t) st.st_size;
            if (size < old)
                return Growth.shrank;
            if (size > _reserved)
                size = _reserved; // grown past its room: it stops growing
            if (size == old)
                return Growth.none;
            // The pages mapped stay: the last one, partly past the old end, is a shared page
            // of the file and shows what was written into it. Only the pages after it are new
            const from = pageCeil(old);
            if (size > from && mmap(cast(void*)(_ptr + from), size - from, PROT_READ,
                    MAP_SHARED | MAP_FIXED, _fd, from) == MAP_FAILED)
                return Growth.none;
            extendRange(_slot, cast(size_t) _ptr + size); // before a reader may touch the bytes
            atomicStore!(MemoryOrder.rel)(_length, size);
            return Growth.grew;
        }
        else version (Windows)
        {
            import core.sys.windows.windows : GetFileSizeEx, LARGE_INTEGER;

            if (!_reserved || lost)
                return Growth.none;
            LARGE_INTEGER fileSize;
            if (!GetFileSizeEx(_file, &fileSize))
                return Growth.none;
            const old = atomicLoad(_length); // this thread is its only writer
            size_t size = cast(size_t) fileSize.QuadPart;
            if (size < old)
                return Growth.shrank;
            if (size > _reserved)
                size = _reserved; // grown past its room: it stops growing
            if (size - old > readPerGrow)
                size = old + readPerGrow; // the rest by the next ones: the window doesn't wait the disk
            if (size == old)
                return Growth.none;
            if (!readTo(size))
                _readFailed = true;
            return atomicLoad(_length) > old ? Growth.grew : Growth.none;
        }
        else
            return Growth.none;
    }

    //! @return true once a read of the file failed: its storage is gone
    bool lost() const nothrow @nogc @property
    {
        version (Windows)
            if (_readFailed)
                return true;
        return _slot != noSlot && isLostSlot(_slot);
    }

    //! The bytes from _ptr a read of which may fault (the fault handler guards them): the
    //! mapping of the file, not the private memory a file that grows is read into on Windows
    private size_t guardedLength() const nothrow @nogc
    {
        version (Windows)
            if (_reserved)
                return _viewLength;
        return atomicLoad(_length);
    }

    version (Posix)
    {
        private void mapFile(string path)
        {
            import core.sys.posix.fcntl : open, O_RDONLY;
            import core.sys.posix.sys.mman : mmap, munmap, MAP_ANON, MAP_FAILED, MAP_FIXED, MAP_PRIVATE,
                MAP_SHARED, PROT_NONE, PROT_READ;
            import core.sys.posix.sys.stat : fstat, stat_t;
            import core.sys.posix.unistd : posixClose = close;
            import std.exception : errnoEnforce;
            import std.string : toStringz;

            const fd = open(path.toStringz, O_RDONLY);
            errnoEnforce(fd != -1, "Can't open " ~ path);
            bool keep = false; // the file may grow: the descriptor stays open
            scope (exit)
                if (!keep)
                    posixClose(fd); // the mapping keeps its own reference

            stat_t st;
            errnoEnforce(fstat(fd, &st) == 0, "Can't stat " ~ path);
            const size = cast(size_t) st.st_size;

            // Room to grow into: addresses only, nothing is committed
            const reserve = roomFor(size);
            void* base = reserve ? mmap(null, reserve, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0) : MAP_FAILED;
            if (base != MAP_FAILED)
            {
                if (size > 0 && mmap(base, size, PROT_READ, MAP_SHARED | MAP_FIXED, fd, 0) == MAP_FAILED)
                {
                    munmap(base, reserve);
                    errnoEnforce(false, "Can't map " ~ path);
                }
                _ptr = cast(const(ubyte)*) base;
                atomicStore(_length, size);
                _reserved = reserve;
                _fd = fd;
                keep = true;
                return;
            }

            // No room (an address space limit): mapped as it is, it doesn't grow
            if (size == 0)
                return; // nothing to map
            void* ptr = mmap(null, size, PROT_READ, MAP_SHARED, fd, 0);
            errnoEnforce(ptr != MAP_FAILED, "Can't map " ~ path);
            _ptr = cast(const(ubyte)*) ptr;
            atomicStore(_length, size);
        }

        private void unmapFile(bool wasLost) nothrow @nogc
        {
            import core.sys.posix.sys.mman : munmap;
            import core.sys.posix.unistd : posixClose = close;

            // Pages replaced after a loss are part of the same range
            const length = _reserved ? _reserved : atomicLoad(_length);
            if (length > 0)
                munmap(cast(void*) _ptr, length);
            if (_fd != -1)
                posixClose(_fd);
            _fd = -1;
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
            if (mapToGrow(cast(size_t) size.QuadPart))
            {
                enforce(!_readFailed, error("Can't read"));
                return;
            }
            if (size.QuadPart == 0)
                return; // nothing to map (and CreateFileMapping rejects it)

            _mapping = CreateFileMappingW(_file, null, PAGE_READONLY, 0, 0, null);
            enforce(_mapping !is null, error("Can't map"));

            void* ptr = MapViewOfFile(_mapping, FILE_MAP_READ, 0, 0, 0);
            enforce(ptr !is null, error("Can't map a view of"));
            _ptr = cast(const(ubyte)*) ptr;
            atomicStore(_length, cast(size_t) size.QuadPart);
        }

        //! @brief Maps the file of `size` bytes so that it may grow, in placeholders of the
        //! address space (Windows 10 1803+): whole 64K pieces of it as a view, the rest
        //! read into private memory after it, room reserved for more
        //! @return false if it can't be (an older Windows, no room): nothing is mapped then
        private bool mapToGrow(size_t size)
        {
            import core.sys.windows.windows;

            const api = placeholders();
            const reserve = roomFor(size);
            if (api.virtualAlloc2 is null || api.mapViewOfFile3 is null || reserve == 0)
                return false;
            auto process = GetCurrentProcess();
            void* base = api.virtualAlloc2(process, null, reserve, MEM_RESERVE | memReservePlaceholder,
                PAGE_NOACCESS, null, 0);
            if (base is null)
                return false;
            const view = size & ~(allocationGranularity() - 1);
            auto rest = cast(void*)(cast(ubyte*) base + view);
            if (view > 0)
            {
                // The placeholder split in two: the view takes the first one
                if (!VirtualFree(base, view, MEM_RELEASE | memPreservePlaceholder))
                {
                    VirtualFree(base, 0, MEM_RELEASE);
                    return false;
                }
                _mapping = CreateFileMappingW(_file, null, PAGE_READONLY, 0, 0, null);
                if (_mapping is null || api.mapViewOfFile3(_mapping, process, base, 0, view,
                        memReplacePlaceholder, PAGE_READONLY, null, 0) is null)
                {
                    if (_mapping !is null)
                        CloseHandle(_mapping);
                    _mapping = null;
                    VirtualFree(base, 0, MEM_RELEASE);
                    VirtualFree(rest, 0, MEM_RELEASE);
                    return false;
                }
            }
            if (api.virtualAlloc2(process, rest, reserve - view, MEM_RESERVE | memReplacePlaceholder,
                    PAGE_READWRITE, null, 0) is null)
            {
                if (view > 0)
                    UnmapViewOfFile(base);
                VirtualFree(rest, 0, MEM_RELEASE);
                if (_mapping !is null)
                    CloseHandle(_mapping);
                _mapping = null;
                return false;
            }
            _ptr = cast(const(ubyte)*) base;
            _reserved = reserve;
            _viewLength = view;
            atomicStore(_length, view);
            if (!readTo(size))
                _readFailed = true;
            return true;
        }

        //! @brief Reads the file from the end of data() to `size` into the private memory
        //! after the view, committed as it goes; data() gets the bytes read
        //! @return false if a read failed (what was read before is kept)
        private bool readTo(size_t size) nothrow @nogc
        {
            import core.sys.windows.windows;

            size_t length = atomicLoad(_length);
            if (size <= length)
                return true;
            auto at = cast(void*)(_ptr + length);
            if (VirtualAlloc(at, size - length, MEM_COMMIT, PAGE_READWRITE) is null)
                return false;
            bool ok = true;
            while (length < size)
            {
                OVERLAPPED offset;
                offset.Offset = cast(DWORD) length;
                offset.OffsetHigh = cast(DWORD)(cast(ulong) length >> 32);
                const left = size - length;
                const want = cast(DWORD)(left < (1u << 30) ? left : (1u << 30));
                DWORD read;
                if (!ReadFile(_file, cast(void*)(_ptr + length), want, &read, &offset))
                {
                    ok = false;
                    break;
                }
                if (read == 0)
                    break; // shorter meanwhile: the next grow() tells it
                length += read;
            }
            atomicStore!(MemoryOrder.rel)(_length, length);
            return ok;
        }

        private void unmapFile(bool wasLost) nothrow @nogc
        {
            import core.sys.windows.windows;

            if (_reserved)
            {
                if (_viewLength > 0)
                {
                    if (wasLost) // the view was replaced by reserved memory
                        VirtualFree(cast(void*) _ptr, 0, MEM_RELEASE);
                    else
                        UnmapViewOfFile(cast(void*) _ptr);
                }
                VirtualFree(cast(void*)(_ptr + _viewLength), 0, MEM_RELEASE);
                _viewLength = 0;
                _readFailed = false;
            }
            else if (atomicLoad(_length) > 0)
            {
                if (wasLost) // the view was replaced by reserved memory
                    VirtualFree(cast(void*) _ptr, 0, MEM_RELEASE);
                else
                    UnmapViewOfFile(cast(void*) _ptr);
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

//! The address space reserved for a file of `size` bytes to grow into: a few times its size,
//! and 64 GiB more at least, in whole 64K pieces (a placeholder of Windows of another size
//! isn't made, and the file then doesn't grow); 0 where addresses are too few (a 32-bit build)
private size_t roomFor(size_t size) pure nothrow @nogc @safe
{
    static if (size_t.sizeof < 8)
        return 0;
    else
    {
        enum size_t least = 64UL << 30;
        enum size_t piece = 64 << 10; // the allocation granularity of Windows, whole pages anywhere
        const times = size <= size_t.max / 4 ? size * 4 : size_t.max - piece;
        const room = times > size + least ? times : size + least;
        return (room + piece - 1) & ~(piece - 1);
    }
}

private size_t pageSize() nothrow @nogc
{
    version (Posix)
    {
        import core.sys.posix.unistd : sysconf, _SC_PAGESIZE;

        return cast(size_t) sysconf(_SC_PAGESIZE);
    }
    else
    {
        import core.sys.windows.windows : GetSystemInfo, SYSTEM_INFO;

        SYSTEM_INFO info;
        GetSystemInfo(&info);
        return info.dwPageSize;
    }
}

version (Windows)
{
    import core.sys.windows.windows : HANDLE;

    //! The most a grow() reads at once into the private memory of a file that grows
    private enum size_t readPerGrow = 16 << 20;

    // Placeholders of the address space (Windows 10 1803+), not in the headers of druntime
    private enum uint memReservePlaceholder = 0x0004_0000;
    private enum uint memReplacePlaceholder = 0x0000_4000;
    private enum uint memPreservePlaceholder = 0x0000_0002;

    private alias VirtualAlloc2Fn = extern (Windows) void* function(HANDLE process, void* base, size_t size,
        uint type, uint protection, void* parameters, uint count) nothrow @nogc;
    private alias MapViewOfFile3Fn = extern (Windows) void* function(HANDLE mapping, HANDLE process, void* base,
        ulong offset, size_t size, uint type, uint protection, void* parameters, uint count) nothrow @nogc;

    private struct PlaceholderApi
    {
        VirtualAlloc2Fn virtualAlloc2;
        MapViewOfFile3Fn mapViewOfFile3;
    }

    //! The functions of placeholders, null where the system has none
    private PlaceholderApi placeholders() nothrow @nogc
    {
        import core.sys.windows.windows : GetModuleHandleW, GetProcAddress;

        __gshared PlaceholderApi api;
        __gshared bool looked;
        if (!looked)
        {
            if (auto module_ = GetModuleHandleW("kernelbase.dll"w.ptr))
            {
                api.virtualAlloc2 = cast(VirtualAlloc2Fn) GetProcAddress(module_, "VirtualAlloc2");
                api.mapViewOfFile3 = cast(MapViewOfFile3Fn) GetProcAddress(module_, "MapViewOfFile3");
            }
            looked = true;
        }
        return api;
    }

    private size_t allocationGranularity() nothrow @nogc
    {
        import core.sys.windows.windows : GetSystemInfo, SYSTEM_INFO;

        SYSTEM_INFO info;
        GetSystemInfo(&info);
        return info.dwAllocationGranularity;
    }
}

//! `length` rounded up to whole pages
private size_t pageCeil(size_t length) nothrow @nogc
{
    const page = pageSize();
    return (length + page - 1) & ~(page - 1);
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

//! The range of slot `i` ends at `end` now: a file grown in place
private void extendRange(size_t i, size_t end) nothrow @nogc
{
    if (i != noSlot)
        atomicStore!(MemoryOrder.rel)(g_slots[i].end, end);
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

version (unittest)
{
    private void append(string path, const(void)[] bytes)
    {
        import std.stdio : File;

        auto file = File(path, "ab");
        file.rawWrite(bytes);
    }

    //! Writes `bytes` over the file: std.file.write opens it shared with no one, which
    //! Windows refuses while the file is open here
    private void rewrite(string path, const(void)[] bytes)
    {
        import std.stdio : File;

        auto file = File(path, "wb");
        file.rawWrite(bytes);
    }
}

@("roomFor: whole 64K pieces, as the placeholders of Windows take them")
unittest
{
    static if (size_t.sizeof == 8)
        foreach (size; [0, 5, 65_535, 65_536, 1_000_003])
        {
            const room = roomFor(size);
            assert(room % 65_536 == 0 && room >= size + (64UL << 30));
        }
}

@("MappedFile.grow: takes the bytes written since, the bytes of before at the same place")
unittest
{
    import std.file : remove, tempDir, write;
    import std.path : buildPath;

    auto path = buildPath(tempDir(), "mapped_file_grow.bin");
    write(path, "hello");
    scope (exit)
        remove(path);

    auto file = MappedFile(path);
    const before = file.data;
    assert(file.grow() == Growth.none, "nothing written");

    append(path, " world");
    assert(file.grow() == Growth.grew);
    assert(cast(const(char)[]) file.data == "hello world");
    assert(file.data.ptr == before.ptr && cast(const(char)[]) before == "hello");

    // Past the pages mapped at first
    auto more = new ubyte[](3 * 65_536 + 7);
    more[] = 'x';
    append(path, more);
    assert(file.grow() == Growth.grew);
    assert(file.data.length == 11 + more.length && file.data.ptr == before.ptr);
    assert(file.data[$ - 1] == 'x' && file.data[11] == 'x');
    assert(!file.lost);
}

@("MappedFile.grow: an empty file that gets its first bytes")
unittest
{
    import std.file : remove, tempDir, write;
    import std.path : buildPath;

    auto path = buildPath(tempDir(), "mapped_file_grow_empty.bin");
    write(path, "");
    scope (exit)
        remove(path);

    auto file = MappedFile(path);
    assert(file.data.length == 0);
    append(path, "first");
    assert(file.grow() == Growth.grew);
    assert(cast(const(char)[]) file.data == "first");
}

@("MappedFile.grow: a file made shorter is told, its data stays as long")
unittest
{
    import std.file : remove, tempDir, write;
    import std.path : buildPath;

    // Small enough to be read, not mapped, on Windows: a mapped file can't be made
    // shorter there
    auto path = buildPath(tempDir(), "mapped_file_grow_shrank.bin");
    write(path, "hello world");
    scope (exit)
        remove(path);

    auto file = MappedFile(path);
    rewrite(path, "hello");
    assert(file.grow() == Growth.shrank);
    assert(file.data.length == 11);
}


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
