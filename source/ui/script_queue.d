//! The calls of the script the log tables have to make (a row chosen, a cell clicked, a copy): a table never calls the
//! script itself, since the event that gives rise to a call may come from inside a call of the script (`table.call`).
//! It queues the call here and the window sends what was queued from its idle loop (`MainWindow.onIdle`), as it does
//! the calls of the session (`AppSession.takeScriptCalls`). Free of Sciter.
module ui.script_queue;

/// A call of a global function of the script with one text: name(text)
struct QueuedCall
{
    string name;
    wstring text;
}

/// The calls queued since they were last taken, in order
final class ScriptQueue
{
    private QueuedCall[] _calls;

    /// Queues name(text); `text` is copied
    void put(string name, const(wchar)[] text)
    {
        _calls ~= QueuedCall(name, text.idup);
    }

    /// The calls queued since the last time, in the order they came; the queue is empty after
    QueuedCall[] take()
    {
        auto calls = _calls;
        _calls = null;
        return calls;
    }
}

@("ScriptQueue: the calls are taken in the order they came, and only once")
unittest
{
    auto queue = new ScriptQueue;
    queue.put("logTableRowChosen", `{"row":1}`w);
    queue.put("logTableCopy", "text"w);
    assert(queue.take() == [QueuedCall("logTableRowChosen", `{"row":1}`w), QueuedCall("logTableCopy", "text"w)]);
    assert(queue.take().length == 0, "taken once");
}

@("ScriptQueue: a call keeps its own copy of the text it was given")
unittest
{
    auto queue = new ScriptQueue;
    auto text = "copied"w.dup;
    queue.put("logTableCopy", text);
    text[] = 'x';
    assert(queue.take() == [QueuedCall("logTableCopy", "copied"w)]);
}
