//! A finite state machine over state structs, events dispatched to their handlers at compile time.
module utils.fsm;

import std.meta : AliasSeq, NoDuplicates, anySatisfy, staticIndexOf;

/// The result of an event handler: either a transition to a state or "stay".
/// One type for both, so that the ternary operator works:
///     return cond ? To!Focused : NoTransition;
struct Transition
{
    private const(void)* m_target; // the unique tag of the state type, null = no transition

    bool isActive() const pure nothrow @nogc @safe
    {
        return m_target !is null;
    }
}

/// A transition to the state TState.
Transition To(TState)() pure nothrow @nogc @safe
{
    return Transition(&StateTag!TState.value);
}

/// No transition.
enum Transition NoTransition = Transition.init;

// A unique address per state type: an identifier without TypeInfo or hashes.
private struct StateTag(TState)
{
    static immutable ubyte value;
}

/// A finite state machine.
///   TContext: the shared data, passed by ref to every handler.
///   TStates:  the state structs; the first one is the initial state.
///
/// A state may (optionally) have:
///   void onEnter(ref TContext ctx);
///   void onExit(ref TContext ctx);
///   Transition on(in TEvent e, ref TContext ctx);   // or void => no transition
///
/// An event the current state doesn't handle is ignored.
/// An event no state handles is a compile error.
struct Fsm(TContext, TStates...)
{
    static assert(TStates.length > 0, "Fsm requires at least one state");
    static assert(is(NoDuplicates!TStates == TStates), "Fsm states must be unique");

    private TContext m_context;
    private TStates m_states; // all states live inside the machine, no heap
    private size_t m_currentStateId;
    private bool m_started;
    private bool m_processing;

public:
    this(TContext context)
    {
        m_context = context;
    }

    /// For the unittests of this module only: the context is the machine's own
    /// memory; it acts outside through the objects passed in the context.
    private ref const(TContext) context() const return
    {
        return m_context;
    }

    bool isStarted() const
    {
        return m_started;
    }

    /// Enters the initial state (calls its onEnter).
    void start()
    {
        assert(!m_started, "Fsm is already started");
        m_started = true;
        m_currentStateId = 0;
        callEnter(m_currentStateId);
    }

    /// Exits the current state (calls its onExit).
    void stop()
    {
        assert(m_started, "Fsm is not started");
        callExit(m_currentStateId);
        m_started = false;
    }

    /// For the unittests of this module only: outside code must not depend on
    /// which state is current, it sees only the output of the machine.
    private bool isIn(TState)() const
    {
        enum id = staticIndexOf!(TState, TStates);
        static assert(id >= 0, TState.stringof ~ " is not a state of this Fsm");
        return m_currentStateId == id;
    }

    /// For the unittests of this module only: reads the fields of a state.
    /// The reference is const: states change only in their event handlers.
    private ref const(TState) state(TState)() const return
    {
        enum id = staticIndexOf!(TState, TStates);
        static assert(id >= 0, TState.stringof ~ " is not a state of this Fsm");
        return m_states[id];
    }

    void process(TEvent)(in TEvent e)
    {
        static assert(anySatisfy!(HandlesEvent!TEvent, TStates),
            "No state of this Fsm handles event " ~ TEvent.stringof);

        assert(m_started, "Fsm is not started");
        assert(!m_processing, "Recursive Fsm.process() call from a handler is not supported");

        m_processing = true;
        scope (exit) m_processing = false;

        Transition t;
    
        stateSwitch: switch (m_currentStateId)
        {
            static foreach (i, TState; TStates)
            {
            case i:
                static if (canHandle!(TState, TEvent))
                {
                    alias R = typeof(m_states[i].on(e, m_context));
                    static if (is(R == void))
                        m_states[i].on(e, m_context);
                    else static if (is(R : Transition))
                        t = m_states[i].on(e, m_context);
                    else
                        static assert(0, TState.stringof ~ ".on(" ~ TEvent.stringof
                            ~ ") must return void or Transition, not " ~ R.stringof);
                }
                break stateSwitch;
            }
        default:
            assert(0, "invalid Fsm state id");
        }

        if (t.isActive)
            transit(stateIdOf(t));
    }

private:
    template HandlesEvent(TEvent)
    {
        enum HandlesEvent(TState) = canHandle!(TState, TEvent);
    }

    enum canHandle(TState, TEvent) = __traits(compiles,
        (ref TState s, ref TContext c, in TEvent e) { s.on(e, c); });

    void transit(size_t target)
    {
        // A transition to the same state calls onExit + onEnter too.
        callExit(m_currentStateId);
        m_currentStateId = target;
        callEnter(m_currentStateId);
    }

    static size_t stateIdOf(Transition t)
    {
        static foreach (i, TState; TStates)
        {
            if (t.m_target is &StateTag!TState.value)
                return i;
        }
        assert(0, "Transition target is not a state of this Fsm");
    }

    void callEnter(size_t id)
    {
        callHook!"onEnter"(id);
    }

    void callExit(size_t id)
    {
        callHook!"onExit"(id);
    }

    void callHook(string name)(size_t id)
    {
    hookSwitch:
        switch (id)
        {
            static foreach (i, TState; TStates)
            {
            case i:
                static if (__traits(hasMember, TState, name))
                    __traits(getMember, m_states[i], name)(m_context);
                break hookSwitch;
            }
        default:
            assert(0, "invalid Fsm state id");
        }
    }
}

version (unittest) private
{
    struct Context
    {
        bool isActive;
        string log;
    }

    struct MouseClickEvent { int x; int y; }
    struct MouseDoubleClickEvent { int x; int y; }
    struct KeyEvent { char key; }

    struct InitState
    {
        void onEnter(ref Context c) { c.log ~= "+I"; }
        void onExit(ref Context c) { c.log ~= "-I"; }

        Transition on(in MouseClickEvent e, ref Context c)
        {
            c.isActive = !c.isActive;
            return To!Focused;
        }

        Transition on(in MouseDoubleClickEvent e, ref Context c)
        {
            return c.isActive ? To!Focused : NoTransition;
        }
    }

    struct Focused
    {
        int keys;

        void onEnter(ref Context c) { c.log ~= "+F"; }
        // no onExit, which is fine

        void on(in KeyEvent e, ref Context c) { ++keys; } // void => no transition

        Transition on(in MouseDoubleClickEvent e, ref Context c)
        {
            return To!InitState;
        }
    }
}

unittest
{
    Fsm!(Context, InitState, Focused) fsm;
    fsm.start();
    assert(fsm.isIn!InitState);

    fsm.process(MouseDoubleClickEvent(1, 2)); // isActive == false -> stays
    assert(fsm.isIn!InitState);

    fsm.process(KeyEvent('a'));               // InitState doesn't handle it -> ignored
    assert(fsm.isIn!InitState);

    fsm.process(MouseClickEvent(1, 2));
    assert(fsm.isIn!Focused);
    assert(fsm.context.isActive);

    fsm.process(KeyEvent('a'));
    fsm.process(KeyEvent('b'));
    assert(fsm.state!Focused.keys == 2);

    fsm.process(MouseDoubleClickEvent(1, 2));
    assert(fsm.isIn!InitState);

    assert(fsm.context.log == "+I-I+F+I", fsm.context.log);

    static assert(!__traits(compiles, fsm.process(42)));      // no state handles int
    static assert(!__traits(compiles, fsm.isIn!Context));     // not a state
    static assert(!__traits(compiles, fsm.state!Focused.keys = 0)); // a state is read-only
}
