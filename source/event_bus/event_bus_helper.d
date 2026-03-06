/**
 * EventBusHelper — shared COW subscriber list management.
 *
 * CallbackList is a module-private class (not nested inside a struct,
 * which D does not support). EventBusHelper is a value-type struct whose
 * members are heap-allocated, so it can be embedded in bus classes without
 * manual heap boxing.
 */
module event_bus.event_bus_helper;

import event_bus.event_bus_interface;

import core.sync.mutex : Mutex;
import std.algorithm : remove, countUntil;

// ─── Module-private callback list (reference type) ─────────────────────────

private final class CallbackList
{
    RawCallbackItem[] items;
    int refCount = 1; // manual ref-counting — no GC cycle

    this()
    {
    }

    this(RawCallbackItem[] src)
    {
        items = src.dup;
    }

    void addRef()
    {
        ++refCount;
    }

    void release()
    {
        --refCount;
    }

    bool shared_() const
    {
        return refCount > 1;
    }
}

// ─── Raw callback item ─────────────────────────────────────────────────────

struct RawCallbackItem
{
    void delegate(const(void)*) callback;
    SubscriptionToken token;
}

// ─── EventBusHelper (COW subscriber lists) ────────────────────────────────

/**
 * Value-type struct that manages per-type subscriber lists.
 *
 * Thread-safe via a lazily initialised Mutex. The Mutex is heap-allocated
 * on first use, so the struct can be embedded as a class field without an
 * explicit constructor call.
 *
 * IMPORTANT: do NOT copy this struct after first use — the Mutex cannot be
 * meaningfully duplicated. Use @disable this(this) if stricter enforcement
 * is desired.
 */
struct EventBusHelper
{
private:
    Mutex _mutex;
    CallbackList[TypeInfo] _subscribers;
    SubscriptionToken _nextToken = 0;

public:
    this(Mutex mutex)
    {
        _mutex = mutex;
    }

public:
    @disable this(this); // prevent accidental copy

    SubscriptionToken subscribe(TypeInfo ti, void delegate(const(void)*) cb)
    {
        _mutex.lock();
        scope (exit)
            _mutex.unlock();

        auto token = _nextToken++;
        auto list = ti in _subscribers;
        if (list is null)
        {
            auto newList = new CallbackList();
            newList.items ~= RawCallbackItem(cb, token);
            _subscribers[ti] = newList;
        }
        else
        {
            if ((*list).shared_())
            {
                // COW: someone is dispatching — make a private copy
                auto copy = new CallbackList((*list).items);
                (*list).release();
                *list = copy;
            }
            (*list).items ~= RawCallbackItem(cb, token);
        }
        return token;
    }

    bool unsubscribe(SubscriptionToken token)
    {
        _mutex.lock();
        scope (exit)
            _mutex.unlock();

        foreach (ti, ref list; _subscribers)
        {
            if (list is null)
                continue;
            auto idx = list.items.countUntil!(x => x.token == token);
            if (idx < 0)
                continue;

            if (list.shared_())
            {
                // COW
                auto copy = new CallbackList(list.items);
                list.release();
                list = copy;
            }
            list.items = list.items.remove(idx);
            return true;
        }
        return false;
    }

    void unsubscribeAll()
    {
        _mutex.lock();
        scope (exit)
            _mutex.unlock();
        _subscribers.clear();
    }

    /**
     * Call all registered callbacks for the given TypeInfo.
     *
     * Exceptions thrown by subscribers are chained via Throwable.next
     * (the D-idiomatic way to collect multiple exceptions). The caller
     * receives the head of the chain and is responsible for throwing it.
     *
     * Params:
     *   ti        = TypeInfo of the event type.
     *   eventData = Pointer to the event data.
     *   head      = First exception in the chain (null if none yet).
     *   tail      = Last exception in the chain (null if none yet).
     *               Updated as new exceptions are appended.
     */
    void callRegisteredCallbacks(TypeInfo ti, const(void)* eventData,
        ref Throwable head, ref Throwable tail)
    {
        CallbackList snapshot;
        {
            _mutex.lock();
            scope (exit)
                _mutex.unlock();
            auto list = ti in _subscribers;
            if (list is null)
                return;
            snapshot = *list;
            snapshot.addRef(); // keep alive while dispatching
        }

        scope (exit)
        {
            _mutex.lock();
            snapshot.release();
            _mutex.unlock();
        }

        foreach (ref item; snapshot.items)
        {
            try
            {
                item.callback(eventData);
            }
            catch (Exception e)
            {
                // Chain via Throwable.next — the idiomatic D approach.
                if (head is null)
                    head = tail = e;
                else
                {
                    tail.next = e;
                    tail = e;
                }
            }
        }
    }
}
