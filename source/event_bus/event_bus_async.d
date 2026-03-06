/**
 * Asynchronous Event Bus implementation in D.
 *
 * Thread-safe. publish() queues events; dispatch() processes them on the
 * calling thread.
 *
 * Extra feature: overridable messages.
 * If `isOverridable!T` is true, then publish(T) checks whether the back of
 * the dispatch queue already holds an event of the same type. If so, it
 * replaces that entry instead of appending a new one. Events in the middle
 * of the queue are never touched — only the tail is checked.
 *
 * Usage:
 *   // opt-in for a specific message type:
 *   template isOverridable(T : Progress) { enum isOverridable = true; }
 */
module event_bus.event_bus_async;

import event_bus.event_bus_helper;

import core.sync.mutex : Mutex;

public import event_bus.event_bus_interface;

// ─── isOverridable detection ─────────────────────────────────────────────

/**
 * Helper to detect whether an event type opts-in to tail-override behaviour.
 *
 * To opt in, define a nested enum inside your event struct:
 *
 *   struct ProgressEvent {
 *       enum isOverridable = true;
 *       int value;
 *   }
 *
 * This works across module boundaries without any template specialisation.
 */
private template _isOverridable(T)
{
    static if (__traits(hasMember, T, "isOverridable"))
        enum _isOverridable = T.isOverridable;
    else
        enum _isOverridable = false;
}

// ─── Type-erased event queue item ─────────────────────────────────────────

package final class EventItem
{
    TypeInfo ti;
    // Raw heap buffer holding a copy of the event value.
    ubyte[] data;
    // Type-aware destructor: called when the item is discarded.
    void function(void[]) destructor;

    static EventItem make(EventType)(auto ref const EventType event)
    {
        import std.conv : emplace;

        auto item = new EventItem();
        item.ti = typeid(EventType);

        // Allocate aligned storage large enough for EventType.
        // We use `new ubyte[N]` which gives GC-managed memory.
        enum sz = EventType.sizeof;
        auto buf = new ubyte[sz];
        // emplace copy-constructs EventType into the raw buffer.
        emplace(cast(EventType*) buf.ptr, cast(EventType) event);
        item.data = buf;

        item.destructor = (void[] d) { destroy(*cast(EventType*) d.ptr); };
        return item;
    }

    ~this()
    {
        if (destructor !is null && data.ptr !is null)
            destructor(cast(void[]) data);
    }

    const(void)* ptr() const
    {
        return data.ptr;
    }
}

// ─── EventBusAsync ────────────────────────────────────────────────────────

/**
 * Asynchronous event bus.
 * publish() enqueues; dispatch() dequeues and fires callbacks.
 */
final class EventBusAsync : SignalConsumer, SignalProducer
{
private:
    EventBusHelper _helper;
    Mutex _queueMutex;
    EventItem[] _queue; // FIFO; front = next to dispatch

public:
    alias SubscriptionToken = .SubscriptionToken;

    this()
    {
        _helper = EventBusHelper(new Mutex());
        _queueMutex = new Mutex();
    }

    // ── Subscription ────────────────────────────────────────────────────

    SubscriptionToken subscribe(EventType)(void delegate(const EventType) cb)
    {
        void delegate(const(void)*) raw = (const(void)* p) {
            cb(*cast(const EventType*) p);
        };
        return _helper.subscribe(typeid(EventType), raw);
    }

    SubscriptionToken subscribe(EventType)(void function(const EventType) cb)
    {
        return subscribe!EventType((const EventType e) { cb(e); });
    }

    override SubscriptionToken subscribeRaw(TypeInfo ti,
        void delegate(const(void)*) cb)
    {
        return _helper.subscribe(ti, cb);
    }

    override bool unsubscribe(SubscriptionToken token)
    {
        return _helper.unsubscribe(token);
    }

    void unsubscribeAll()
    {
        _helper.unsubscribeAll();
    }

    // ── Publishing ──────────────────────────────────────────────────────

    /**
     * Enqueue an event.
     *
     * If the event type defines `enum isOverridable = true;` as a member,
     * and the back of the dispatch queue holds an event of the same type,
     * the tail item is replaced rather than a new one appended.
     * Only the tail is inspected — events in the middle are never removed.
     */
    void publish(EventType)(auto ref const EventType event)
    {
        auto item = EventItem.make!EventType(event);

        _queueMutex.lock();
        scope (exit)
            _queueMutex.unlock();

        static if (_isOverridable!EventType)
        {
            if (_queue.length > 0 &&
                _queue[$ - 1].ti is typeid(EventType))
            {
                // Replace the tail item.
                destroy(_queue[$ - 1]);
                _queue[$ - 1] = item;
                return;
            }
        }

        _queue ~= item;
    }

    override void publishRaw(TypeInfo ti, const(void)* data)
    {
        // Raw publish — no overridable support (type not known statically).
        // Callers must use the typed publish() overload for proper ownership.
        auto item = new EventItem();
        item.ti = ti;
        item.data = cast(ubyte[])(cast(void*) data)[0 .. 0]; // zero-length sentinel
        item.destructor = null;

        _queueMutex.lock();
        scope (exit)
            _queueMutex.unlock();
        _queue ~= item;
    }

    // ── Dispatching ─────────────────────────────────────────────────────

    /**
     * Process all queued events.
     * Callbacks are called on the calling thread.
     *
     * If any subscriber throws, remaining subscribers (and remaining events)
     * still run. All exceptions are linked via Throwable.next and the head
     * is thrown after all events are processed.
     */
    void dispatch()
    {
        EventItem[] snapshot;
        {
            _queueMutex.lock();
            snapshot = _queue;
            _queue = null;
            _queueMutex.unlock();
        }

        Throwable head, tail;

        foreach (item; snapshot)
            _helper.callRegisteredCallbacks(item.ti, item.ptr, head, tail);

        if (head !is null)
            throw head;
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// EventBusAsync Tests (mirroring C++ tests)
// ═══════════════════════════════════════════════════════════════════════════

version (unittest)
{
    import std.stdio : writeln;
    import std.conv : to;

    private void expectChainedExceptions(void delegate() dg, size_t expectedCount)
    {
        bool caught = false;
        try
        {
            dg();
        }
        catch (Exception head)
        {
            caught = true;
            size_t count = 0;
            for (Throwable e = head; e !is null; e = e.next)
                count++;
            assert(count == expectedCount,
                "Expected " ~ expectedCount.to!string ~
                    " chained exceptions, got " ~ count.to!string);
        }
        assert(caught, "Expected an Exception but nothing was thrown");
    }
}

unittest  // PublishAndSubscribe (Async)
{
    writeln("[Async] PublishAndSubscribe");
    auto bus = new EventBusAsync();
    int intCalls = 0, strCalls = 0, intCalls2 = 0;

    auto t1 = bus.subscribe((const int v) { assert(v == 1); intCalls++; });
    auto t2 = bus.subscribe((const string s) { assert(s == "hello"); strCalls++; });
    //auto t3 = bus.subscribe((int v) { assert(v == 1); intCalls2++; });

    bus.publish(1);
    bus.publish("hello");
    bus.dispatch();

    assert(t1 != t2);
    assert(intCalls == 1);
    assert(strCalls == 1);
    //assert(intCalls2 == 1);

    bus.unsubscribe(t1);
    bus.unsubscribe(t2);
    //bus.unsubscribe(t3);
}

unittest  // ComplexStructs (Async)
{
    writeln("[Async] ComplexStructs");
    struct Complex
    {
        int a;
        string b;
        double c;
    }

    auto bus = new EventBusAsync();
    int calls = 0;

    bus.subscribe((const Complex e) {
        assert(e.a == 1);
        assert(e.b == "hello");
        assert(e.c == 3.14);
        calls++;
    });

    bus.publish(Complex(1, "hello", 3.14));
    bus.dispatch();
    assert(calls == 1);
}

unittest  // Unsubscribe (Async)
{
    writeln("[Async] Unsubscribe");
    auto bus = new EventBusAsync();
    int calls = 0;

    auto t = bus.subscribe((const int v) { calls++; });

    bus.publish(1);
    bus.dispatch();
    assert(calls == 1);

    assert(bus.unsubscribe(t) == true);
    bus.publish(1);
    bus.dispatch();
    assert(calls == 1);

    assert(bus.unsubscribe(t) == false);
}

unittest  // SubscribingFromCallback (Async)
{
    writeln("[Async] SubscribingFromCallback");
    auto bus = new EventBusAsync();
    int calls1 = 0, calls2 = 0;

    bus.subscribe((const int v) {
        calls1++;
        bus.subscribe((const int vv) { assert(vv == 2); calls2++; });
    });

    bus.publish(1);
    bus.dispatch();
    assert(calls1 == 1);
    assert(calls2 == 0);

    bus.publish(2);
    bus.dispatch();
    assert(calls1 == 2);
    assert(calls2 == 1);
}

unittest  // UnsubscribingFromCallback (Async)
{
    writeln("[Async] UnsubscribingFromCallback");
    auto bus = new EventBusAsync();
    int calls = 0;
    bool unsub = false;
    SubscriptionToken tok;

    tok = bus.subscribe((const int v) { calls++; unsub = bus.unsubscribe(tok); });

    bus.publish(1);
    bus.dispatch();
    assert(calls == 1);
    assert(unsub == true);

    bus.publish(2);
    assert(calls == 1);
}

unittest  // PostingFromCallback (Async)
{
    writeln("[Async] PostingFromCallback");
    auto bus = new EventBusAsync();
    int floats = 0, ints = 0;

    bus.subscribe((const float f) { floats++; });
    bus.subscribe((const int v) {
        ints++;
        bus.publish(2.0f); // goes into queue; processed in next dispatch
    });

    bus.publish(2);
    bus.dispatch();

    assert(floats == 0); // not yet dispatched
    assert(ints == 1);

    bus.dispatch();
    assert(floats == 1);
    assert(ints == 1);
}

unittest  // AccessFromDifferentThreads (Async)
{
    writeln("[Async] AccessFromDifferentThreads");
    import core.thread : Thread;

    auto bus = new EventBusAsync();
    int calls = 0;

    auto sub1 = new Thread({ bus.subscribe((const int v) { calls++; }); });
    auto pub1 = new Thread({ bus.publish(1); });

    bus.subscribe((const int v) { calls++; });

    sub1.start();
    pub1.start();
    sub1.join();
    pub1.join();

    bus.publish(1);
    bus.dispatch();

    assert(calls >= 2);
    assert(calls <= 4);
}

unittest  // ThrowingExceptionDoesNotPreventOtherSubscribers (Async)
{
    writeln("[Async] ChainedExceptions");
    auto bus = new EventBusAsync();
    int calls1 = 0, calls2 = 0;

    bus.subscribe((const int v) { calls1++; throw new Exception("oops1"); });
    bus.subscribe((const int v) { calls2++; throw new Exception("oops2"); });

    bus.publish(1);
    // Both exceptions are linked: head.next points to the second one.
    expectChainedExceptions({ bus.dispatch(); }, 2);

    assert(calls1 == 1);
    assert(calls2 == 1);
}

// ═══════════════════════════════════════════════════════════════════════════
// Overridable-message tests
// ═══════════════════════════════════════════════════════════════════════════

// ─── Define test event types with/without opt-in enum ──────────────────────

// isOverridable = true embedded as a struct member — works cross-module.
private struct ProgressEvent
{
    enum isOverridable = true;
    int value;
}

// OtherEvent keeps the default: no isOverridable member → false.
private struct OtherEvent
{
    int value;
}

unittest  // OverridableConsecutive
{
    writeln("[Async][Override] Consecutive overridable messages — only last survives");
    auto bus = new EventBusAsync();
    int calls = 0;
    int last = -1;

    bus.subscribe((const ProgressEvent e) { calls++; last = e.value; });

    bus.publish(ProgressEvent(1));
    bus.publish(ProgressEvent(2));
    bus.publish(ProgressEvent(3));
    bus.dispatch();

    // Three publishes but they kept overriding the back,
    // so only one event is dispatched with value 3.
    assert(calls == 1, "Expected 1 call, got " ~ calls.to!string);
    assert(last == 3, "Expected last value 3, got " ~ last.to!string);
}

unittest  // OverridableInterleaved
{
    writeln("[Async][Override] Interleaved messages — no mid-queue erasure");
    auto bus = new EventBusAsync();
    int pCalls = 0;
    int oCalls = 0;
    int lastP = -1;

    bus.subscribe((const ProgressEvent e) { pCalls++; lastP = e.value; });
    bus.subscribe((const OtherEvent e) { oCalls++; });

    bus.publish(ProgressEvent(1)); // queue: [P(1)]
    bus.publish(OtherEvent(99)); // queue: [P(1), O(99)]   — back is O, not P
    bus.publish(ProgressEvent(2)); // queue: [P(1), O(99), P(2)] — back is O, append
    bus.dispatch();

    // P(1) and P(2) both dispatched because they weren't consecutive at the tail
    assert(pCalls == 2, "Expected 2 Progress calls, got " ~ pCalls.to!string);
    assert(oCalls == 1, "Expected 1 Other call, got " ~ oCalls.to!string);
    assert(lastP == 2);
}

unittest  // NonOverridableConsecutive
{
    writeln("[Async][Override] Consecutive non-overridable messages — all survive");
    auto bus = new EventBusAsync();
    int calls = 0;

    bus.subscribe((const OtherEvent e) { calls++; });

    bus.publish(OtherEvent(1));
    bus.publish(OtherEvent(2));
    bus.publish(OtherEvent(3));
    bus.dispatch();

    assert(calls == 3, "Expected 3 calls, got " ~ calls.to!string);
}

unittest  // OverridableMultipleRunsReset
{
    writeln("[Async][Override] Each dispatch cycle is independent");
    auto bus = new EventBusAsync();
    int calls = 0;
    int last = -1;

    bus.subscribe((const ProgressEvent e) { calls++; last = e.value; });

    // First cycle: two consecutive → one survives
    bus.publish(ProgressEvent(10));
    bus.publish(ProgressEvent(20));
    bus.dispatch();

    assert(calls == 1 && last == 20);

    // Second cycle: single → one survives
    bus.publish(ProgressEvent(30));
    bus.dispatch();

    assert(calls == 2 && last == 30);
}
