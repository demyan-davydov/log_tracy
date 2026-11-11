//! LockGuard: holds a mutex for its scope.
module utils.lock_guard;

import core.sync.mutex : Mutex;

struct LockGuard
{
    private Mutex _mutex;

    this(Mutex mutex) nothrow @trusted @nogc
    {
        _mutex = mutex;
        _mutex.lock_nothrow!Mutex();
    }

    ~this() nothrow @trusted @nogc
    {
        _mutex.unlock_nothrow!Mutex();
    }
}
