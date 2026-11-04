/**
 * Synchronous Event Bus implementation in D.
 *
 * Thread-safe. Subscribers are called synchronously on the thread that
 * calls publish(). Implements ISP: separate consumer/producer interfaces.
 *
 * Notable design choices:
 * - COW (Copy-On-Write) subscriber lists via reference-counting
 * - Multiple subscriber exceptions are chained via Throwable.next (D idiom)
 * - @nogc callbacks are supported; internal bookkeeping uses the GC
 */
module utils.event_bus.event_bus_sync;

import utils.event_bus.event_bus_helper;

import core.sync.mutex : Mutex;

public import utils.event_bus.event_bus_interface;

// ─── EventBusSync ─────────────────────────────────────────────────────────

/**
 * Synchronous event bus.
 * publish() immediately dispatches callbacks on the calling thread.
 *
 * If any subscriber throws, remaining subscribers still run. Afterwards,
 * all exceptions are thrown as a chain linked via Throwable.next.
 * The first exception in the chain is thrown; subsequent ones are
 * accessible via the .next field.
 */
final class EventBusSync : SignalConsumer, SignalProducer
{
private:
    EventBusHelper _helper;

public:
    alias SubscriptionToken = .SubscriptionToken;

    this()
    {
        _helper = EventBusHelper(new Mutex());
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

    /**
     * Dispatch an event synchronously.
     * All subscribers are called before this returns.
     * Subscriber exceptions are thrown as a Throwable chain (head.next…).
     */
    override void publishRaw(EventOps ops, scope const(void)* data)
    {
        Throwable head, tail;
        _helper.callRegisteredCallbacks(ops.ti, data, head, tail);
        if (head !is null)
            throw head;
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// EventBusSync Tests
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

unittest  // PublishAndSubscribe (Sync)
{
    writeln("[Sync] PublishAndSubscribe");
    auto bus = new EventBusSync();

    int intCalls = 0, strCalls = 0;

    auto t1 = bus.subscribe((const int v) { assert(v == 1); intCalls++; });
    auto t2 = bus.subscribe((const string s) { assert(s == "hello"); strCalls++; });

    bus.publish(1);
    bus.publish("hello");

    assert(t1 != t2);
    assert(intCalls == 1);
    assert(strCalls == 1);

    bus.unsubscribe(t1);
    bus.unsubscribe(t2);
}

unittest  // PublishAndSubscribeForComplexStructs (Sync)
{
    writeln("[Sync] ComplexStructs");

    struct Complex
    {
        int a;
        string b;
        double c;
    }

    auto bus = new EventBusSync();
    int calls = 0;

    bus.subscribe((const Complex e) {
        assert(e.a == 1);
        assert(e.b == "hello");
        assert(e.c == 3.14);
        calls++;
    });

    bus.publish(Complex(1, "hello", 3.14));
    assert(calls == 1);
}

unittest  // Unsubscribe (Sync)
{
    writeln("[Sync] Unsubscribe");
    auto bus = new EventBusSync();
    int calls = 0;

    auto t = bus.subscribe((const int v) { calls++; });

    bus.publish(1);
    assert(calls == 1);

    assert(bus.unsubscribe(t) == true);
    bus.publish(1);
    assert(calls == 1);

    assert(bus.unsubscribe(t) == false); // already gone
}

unittest  // SubscribingFromCallback (Sync)
{
    writeln("[Sync] SubscribingFromCallback");
    auto bus = new EventBusSync();
    int calls1 = 0, calls2 = 0;

    bus.subscribe((const int v) {
        calls1++;
        bus.subscribe((const int vv) { assert(vv == 2); calls2++; });
    });

    bus.publish(1);
    assert(calls1 == 1);
    assert(calls2 == 0); // newly added; not yet called

    bus.publish(2);
    assert(calls1 == 2);
    assert(calls2 == 1);
}

unittest  // UnsubscribingFromCallback (Sync)
{
    writeln("[Sync] UnsubscribingFromCallback");
    auto bus = new EventBusSync();
    int calls = 0;
    bool unsub = false;
    SubscriptionToken tok;

    tok = bus.subscribe((const int v) { calls++; unsub = bus.unsubscribe(tok); });

    bus.publish(1);
    assert(calls == 1);
    assert(unsub == true);

    bus.publish(2);
    assert(calls == 1); // already unsubscribed
}

unittest  // PostingFromCallback (Sync)
{
    writeln("[Sync] PostingFromCallback");
    auto bus = new EventBusSync();
    int floats = 0, ints = 0;

    bus.subscribe((const float v) { floats++; });
    bus.subscribe((const int v) { ints++; bus.publish(2.0f); });

    bus.publish(2);

    assert(floats == 1);
    assert(ints == 1);
}

unittest  // AccessFromDifferentThreads (Sync)
{
    writeln("[Sync] AccessFromDifferentThreads");
    import core.thread : Thread;

    auto bus = new EventBusSync();
    int calls = 0;

    auto sub1 = new Thread({ bus.subscribe((const int v) { calls++; }); });
    auto pub1 = new Thread({ bus.publish(1); });

    bus.subscribe((const int v) { calls++; });

    sub1.start();
    pub1.start();
    sub1.join();
    pub1.join();

    bus.publish(1);

    assert(calls >= 2);
    assert(calls <= 4);
}

unittest  // ThrowingExceptionDoesNotPreventOtherSubscribers (Sync)
{
    writeln("[Sync] ChainedExceptions");
    auto bus = new EventBusSync();
    int calls1 = 0, calls2 = 0;

    bus.subscribe((const int v) { calls1++; throw new Exception("oops1"); });
    bus.subscribe((const int v) { calls2++; throw new Exception("oops2"); });

    // Both subscribers run; both exceptions are chained via Throwable.next.
    // The head exception is thrown; the second is accessible via head.next.
    expectChainedExceptions({ bus.publish(1); }, 2);

    assert(calls1 == 1);
    assert(calls2 == 1);
}
