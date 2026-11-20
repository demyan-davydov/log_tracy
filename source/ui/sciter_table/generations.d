//! A cache of two generations, Sciter-free: what was made for a key (a text layout, a width) is kept in the current generation; a
//! hit in the older one moves it to the current; a new key that finds the current at half of `limit`, or both at `limit`, lets the
//! older go whole (its values released) and the current becomes the older. Keys used frame after frame (more than half the limit,
//! up to what else passes through between two uses) are made once, and no more than `limit` are kept. The keys and the maps are in memory of the allocator given (the texts of the keys in an arena of
//! their generation), the garbage collector is not asked for a lookup. Used by `SciterTextCache` and `SciterMeasurer`
//! (ui/sciter_table/host).
module ui.sciter_table.generations;

import ptable.memory : Arena, HashMap, mallocAllocator;
import std.experimental.allocator : RCIAllocator;

/// `K` is a struct with a `text` member (`const(wchar)[]`): the text is copied into the memory of the generation that keeps it
final class Generations(K, V)
{
    alias Release = void delegate(ref V value) nothrow;

    private static struct Generation
    {
        Arena arena;
        HashMap!(K, V) map;

        this(RCIAllocator allocator)
        {
            arena = Arena(allocator);
            map = HashMap!(K, V)(allocator);
        }
    }

    private Generation[2] _generations;
    private size_t _current;
    private Release _release;
    private V _loose; // the value `keep` had no memory for: the caller uses it until the next `keep`, which releases it
    private bool _hasLoose;
    size_t limit; /// keys both generations keep together

    /// `release`: called for each value that goes (null: nothing to release)
    this(size_t limit, Release release = null, RCIAllocator allocator = mallocAllocator())
    {
        this.limit = limit;
        _release = release;
        _generations[0] = Generation(allocator);
        _generations[1] = Generation(allocator);
    }

    /// The value kept for `key`, null if none: valid until the next `find` or `keep`
    V* find(K key)
    {
        auto now = &_generations[_current];
        if (auto found = key in now.map)
            return found;
        auto before = &_generations[1 - _current];
        if (auto old = key in before.map)
        {
            if (!put(*now, key, *old))
                return key in before.map; // no memory to move it: it stays in the older
            before.map.remove(key);
            return key in now.map;
        }
        return null;
    }

    /// Keeps `value` for `key` (not kept yet), its text copied. False if there is no memory to keep it: the value is then the
    /// cache's still, valid until the next `keep` or `clear`, which release it
    bool keep(K key, V value)
    {
        releaseLoose();
        // A new key rotates when the current keeps half the limit (the older then holds what was used since the rotation before, to
        // be moved back by a hit), or both together the limit: a move doesn't change how many are kept, so they stay bounded. The
        // current alone at the limit (the older empty: a working set as big as the limit) leaves an older at the limit: that goes too.
        if (_generations[_current].map.length >= limit / 2 || length >= limit)
            rotate();
        if (length >= limit)
            rotate();
        if (put(_generations[_current], key, value))
            return true;
        _loose = value;
        _hasLoose = true;
        return false;
    }

    /// How many keys are kept
    size_t length() const
    {
        return _generations[0].map.length + _generations[1].map.length;
    }

    /// Lets go of everything, each value released
    void clear()
    {
        releaseLoose();
        drop(_generations[0]);
        drop(_generations[1]);
    }

    private void releaseLoose()
    {
        if (_hasLoose && _release !is null)
            _release(_loose);
        _loose = V.init;
        _hasLoose = false;
    }

    // The older generation goes, the current becomes the older
    private void rotate()
    {
        drop(_generations[1 - _current]);
        _current = 1 - _current;
    }

    private void drop(ref Generation g)
    {
        if (_release !is null)
            foreach (ref const K key, ref V value; g.map)
                _release(value);
        g.map.clear();
        g.arena.reset();
    }

    // False if there is no memory for the copy of the text or the room of the map (nothing is kept then)
    private static bool put(ref Generation g, K key, V value)
    {
        const text = g.arena.copy(key.text);
        if (text.length != key.text.length)
            return false;
        key.text = text;
        return g.map.set(key, value);
    }
}

version (unittest)
{
    private struct Key
    {
        uint font;
        const(wchar)[] text;
    }

    private alias Cache = Generations!(Key, int);

    private Key key(size_t i)
    {
        import std.conv : to;

        return Key(0, i.to!wstring);
    }

    // Finds `k`, or makes and keeps it; true if it was made
    private bool use(Cache cache, Key k, int value = 0)
    {
        if (cache.find(k) !is null)
            return false;
        cache.keep(k, value);
        return true;
    }
}

@("Generations: a working set bigger than half the limit, used frame after frame, is made once")
unittest
{
    auto cache = new Cache(100);
    size_t made;
    foreach (frame; 0 .. 5)
        foreach (i; 0 .. 60)
            made += use(cache, key(i));
    assert(made == 60, "made again");
}

@("Generations: the keys used every frame stay kept through a stream of keys used once")
unittest
{
    auto cache = new Cache(100);
    size_t fresh = 1000;
    foreach (frame; 0 .. 20)
    {
        foreach (i; 0 .. 30)
            assert(!use(cache, key(i)) || frame == 0, "a key of every frame made again");
        foreach (i; 0 .. 20)
            use(cache, key(fresh++));
        assert(cache.length <= 100);
    }
}

@("Generations: the keys stay bounded by the limit while the keys found move to the current generation")
unittest
{
    auto cache = new Cache(100);
    size_t next;
    foreach (cycle; 0 .. 30) // ten new keys a cycle, then every key so far used again: moves must not grow it past the limit
    {
        foreach (i; 0 .. 10)
            use(cache, key(next++));
        foreach (i; 0 .. next)
            cache.find(key(i));
        assert(cache.length <= 100, "more than the limit kept");
    }
}

@("Generations: a value found in the older generation keeps its value, a key is found by font and text")
unittest
{
    auto cache = new Cache(4);
    cache.keep(Key(1, "a"w), 7);
    foreach (i; 0 .. 3)
        cache.keep(key(i), 0); // "a" now in the older generation or still kept
    auto found = cache.find(Key(1, "a"w));
    assert(found !is null && *found == 7);
    assert(cache.find(Key(2, "a"w)) is null, "another font");
}

@("Generations: the text of a key is copied: the caller's buffer may change")
unittest
{
    auto cache = new Cache(10);
    wchar[] buffer = "abc"w.dup;
    cache.keep(Key(0, buffer), 5);
    buffer[0] = 'x';
    assert(cache.find(Key(0, "abc"w)) !is null);
    assert(cache.find(Key(0, "xbc"w)) is null);
}

@("Generations: what goes is released once, clear releases the rest, the keys are bounded by the limit")
unittest
{
    bool[int] released;
    auto cache = new Cache(10, (ref int v) nothrow {
        assert(v !in released, "released twice");
        released[v] = true;
    });
    foreach (i; 0 .. 35)
    {
        use(cache, key(i), cast(int) i);
        assert(cache.length <= 10);
    }
    assert(released.length + cache.length == 35, "every value that went is released");
    cache.clear();
    assert(cache.length == 0 && released.length == 35);
}

@("Generations: a hit in the older generation that can't be moved for want of memory stays there, kept and not released")
unittest
{
    import std.array : replicate;
    import std.experimental.allocator : allocatorObject;
    import std.experimental.allocator.mallocator : Mallocator;

    static struct Failing // gives memory until told not to
    {
        bool fail;
        enum uint alignment = Mallocator.alignment;
        void[] allocate(size_t n) pure nothrow @nogc @trusted { return fail ? null : Mallocator.instance.allocate(n); }
        bool deallocate(void[] b) pure nothrow @nogc @trusted { return Mallocator.instance.deallocate(b); }
    }

    Failing failing;
    size_t released;
    auto cache = new Cache(2, (ref int v) nothrow { ++released; }, allocatorObject(&failing));
    const big = "w"w.replicate(40_000); // 80 KB: more than a block of an arena, its copy asks for memory
    cache.keep(Key(0, big), 7);
    cache.keep(key(1), 1); // the first generation is the older now
    failing.fail = true;
    auto found = cache.find(Key(0, big));
    assert(found !is null && *found == 7, "the value lost on its way to the current generation");
    assert(released == 0);
    failing.fail = false;
    cache.clear();
    assert(released == 2, "each value released once");
}

@("Generations: a value that can't be kept for want of memory stays valid until the next keep, then is released once")
unittest
{
    import std.array : replicate;
    import std.experimental.allocator : allocatorObject;
    import std.experimental.allocator.mallocator : Mallocator;

    static struct Failing // gives memory until told not to
    {
        bool fail;
        enum uint alignment = Mallocator.alignment;
        void[] allocate(size_t n) pure nothrow @nogc @trusted { return fail ? null : Mallocator.instance.allocate(n); }
        bool deallocate(void[] b) pure nothrow @nogc @trusted { return Mallocator.instance.deallocate(b); }
    }

    Failing failing;
    int[] released;
    auto cache = new Cache(100, (ref int v) nothrow { released ~= v; }, allocatorObject(&failing));
    const big = "w"w.replicate(40_000); // 80 KB: more than a block of an arena, its copy asks for memory
    failing.fail = true;
    assert(!cache.keep(Key(0, big), 7), "kept with no memory for its text");
    assert(cache.length == 0 && cache.find(Key(0, big)) is null);
    assert(released.length == 0, "released while the caller still uses it");
    failing.fail = false;
    assert(cache.keep(key(1), 1));
    assert(released == [7], "the value not kept is released by the next keep");
    failing.fail = true;
    assert(!cache.keep(Key(0, big), 8));
    failing.fail = false;
    cache.clear();
    assert(released == [7, 8, 1], "clear releases the value not kept too, each once");
}
