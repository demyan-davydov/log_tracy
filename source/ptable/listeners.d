//! The list of listeners of one kind of change, in the order they came: a model, a layout or a look tells
//! its listeners through it. One thread. A listener may unsubscribe (itself or another) or subscribe while
//! the list is being told: a listener removed is not called afterwards, one added is called from the next
//! change on.
module ptable.listeners;

/// The listeners of `Change`s
struct Listeners(Change)
{
    alias Listener = void delegate(const Change change);

    private struct Entry
    {
        size_t handle;
        Listener listener; // null: removed while the list was being told
    }

    private Entry[] _entries;
    private size_t _next;
    private size_t _telling;
    private bool _removedWhileTelling;

    /// Adds a listener to the end; the handle is for `remove`
    size_t add(Listener listener)
    {
        _entries ~= Entry(_next, listener);
        return _next++;
    }

    /// Removes the listener of `handle`; false if there is none
    bool remove(size_t handle)
    {
        foreach (i, ref entry; _entries)
        {
            if (entry.listener is null || entry.handle != handle)
                continue;
            if (_telling == 0)
                _entries = _entries[0 .. i] ~ _entries[i + 1 .. $];
            else
            {
                entry.listener = null;
                _removedWhileTelling = true;
            }
            return true;
        }
        return false;
    }

    /// Removes every listener
    void clear()
    {
        foreach (ref entry; _entries)
            entry.listener = null;
        _removedWhileTelling = _entries.length != 0;
        if (_telling == 0)
            compact();
    }

    /// The listeners now
    size_t length() const
    {
        size_t n;
        foreach (ref entry; _entries)
            n += entry.listener !is null;
        return n;
    }

    /// Tells `change` to the listeners, in the order they were added
    void tell(const Change change)
    {
        const count = _entries.length; // the ones added meanwhile wait
        ++_telling;
        scope (exit)
        {
            if (--_telling == 0 && _removedWhileTelling)
                compact();
        }
        foreach (i; 0 .. count)
        {
            const listener = _entries[i].listener;
            if (listener !is null)
                listener(change);
        }
    }

    private void compact()
    {
        size_t kept;
        foreach (ref entry; _entries)
            if (entry.listener !is null)
                _entries[kept++] = entry;
        _entries = _entries[0 .. kept];
        _removedWhileTelling = false;
    }
}

@("Listeners: told in the order they were added, until removed")
unittest
{
    Listeners!int listeners;
    int[] seen;
    const a = listeners.add((const int c) { seen ~= c; });
    listeners.add((const int c) { seen ~= c * 10; });
    listeners.tell(1);
    assert(seen == [1, 10]);
    assert(listeners.remove(a) && !listeners.remove(a));
    listeners.tell(2);
    assert(seen == [1, 10, 20] && listeners.length == 1);
}

@("Listeners: a listener removing another one or itself while it is told, and one added meanwhile")
unittest
{
    Listeners!int listeners;
    int[] seen;
    size_t second, third;
    listeners.add((const int c) {
        seen ~= 1;
        listeners.remove(second); // the next one is not called
        listeners.add((const int d) { seen ~= 99; }); // from the next change on
    });
    second = listeners.add((const int c) { seen ~= 2; });
    third = listeners.add((const int c) { seen ~= 3; listeners.remove(third); });
    listeners.tell(0);
    assert(seen == [1, 3]);
    seen = null;
    listeners.tell(0);
    assert(seen == [1, 99], "the first one, and the one it added; the removed ones are gone");
    assert(listeners.length == 3);
}

@("Listeners: clear removes all, also while telling")
unittest
{
    Listeners!int listeners;
    int calls;
    listeners.add((const int c) { ++calls; listeners.clear(); });
    listeners.add((const int c) { ++calls; });
    listeners.tell(0);
    assert(calls == 1 && listeners.length == 0);
}
