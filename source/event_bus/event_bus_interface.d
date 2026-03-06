module event_bus.event_bus_interface;

alias SubscriptionToken = size_t;

// ─── SignalConsumer interface ──────────────────────────────────────────────

interface SignalConsumer
{
    /**
     * Subscribe to events of type EventType.
     * The callback receives a const ref to the event.
     *
     * Compile-time enforcement:
     *  - pointer receivers are silently ignored (pointer to event type means
     *    a different type from the runtime's perspective)
     *  - the callback takes the event by value or const ref
     */
    SubscriptionToken subscribeRaw(TypeInfo ti, void delegate(const(void)*) cb);
    bool unsubscribe(SubscriptionToken token);
}

// ─── SignalProducer interface ──────────────────────────────────────────────

interface SignalProducer
{
    void publishRaw(TypeInfo ti, const(void)* data);
}
