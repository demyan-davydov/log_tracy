//! The debug channel of debug builds: with SCITER_DEBUG_PORT=<port> a server on 127.0.0.1
//! answers the requests of ui/debug_protocol (code to run in the window, a shot of it), for
//! agents and scripts looking inside the running app (scripts/app.mjs). A release build has no
//! server and only says that the variable is ignored.
//!
//! Kept apart from the rest of the app: main() starts and stops it, nothing else knows of it.
//! A request is run on the window's thread through postToWindowThread (sciter/window), between
//! the events of the loop; the server's thread waits for its result.
module ui.debug_channel;

import sciter.capi.types : HWINDOW;
import std.stdio : writeln;

/// The channel main() starts: does nothing in a release build or without SCITER_DEBUG_PORT
struct DebugChannel
{
    debug private Server _server;

    /// Stops answering: call it before the window is destroyed
    void stop()
    {
        debug if (_server !is null)
        {
            _server.stop();
            _server = null;
        }
    }
}

/// The channel to the window `hwnd`, when SCITER_DEBUG_PORT is set (0: any free port, written
/// to the output). Debug builds only.
DebugChannel startDebugChannel(HWINDOW hwnd)
{
    import std.process : environment;

    DebugChannel channel;
    const setting = environment.get("SCITER_DEBUG_PORT", "");
    if (!setting.length)
        return channel;
    debug
    {
        import ui.debug_protocol : parsePort;

        ushort port;
        if (!parsePort(setting, port))
        {
            writeln("SCITER_DEBUG_PORT is no port number: ", setting);
            return channel;
        }
        try
            channel._server = new Server(hwnd, port);
        catch (Exception e)
            writeln("Can't start the debug channel: ", e.msg);
    }
    else
        writeln("SCITER_DEBUG_PORT is ignored: the debug channel is in debug builds only");
    return channel;
}

debug:

import core.sync.event : Event;
import core.time : Duration, seconds;
import sciter.api : sciterApi;
import sciter.capi.types : UINT;
import sciter.value : SciterValue;
import sciter.window : postToWindowThread;
import std.socket : InternetAddress, Socket, SocketOption, SocketOptionLevel, SocketShutdown, TcpSocket;
import ui.debug_protocol;

// How long a request waits for the window's thread: it is busy (a long call, a native dialog)
private enum Duration windowTimeout = 30.seconds;

private final class Server
{
    private HWINDOW _hwnd;
    private TcpSocket _listener;
    private shared bool _stopped;

    this(HWINDOW hwnd, ushort port)
    {
        import core.thread : Thread;

        _hwnd = hwnd;
        _listener = new TcpSocket();
        _listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
        _listener.bind(new InternetAddress("127.0.0.1", port));
        _listener.listen(1);
        // scripts/app.mjs reads the port from this line (port 0 is any free one)
        writeln("Debug channel: listening on 127.0.0.1:", _listener.localAddress.toPortString);
        auto thread = new Thread(&serve);
        thread.isDaemon = true; // the app exits whatever a client does
        thread.start();
    }

    void stop()
    {
        import core.atomic : atomicStore;

        atomicStore(_stopped, true);
        try
        {
            _listener.shutdown(SocketShutdown.BOTH); // wakes the thread in accept()
            _listener.close();
        }
        catch (Exception)
        {
        }
    }

    private bool stopped() const
    {
        import core.atomic : atomicLoad;

        return atomicLoad(_stopped);
    }

    // The server's thread: one client at a time, its requests one by one
    private void serve()
    {
        while (!stopped)
        {
            try
            {
                auto client = _listener.accept();
                scope (exit)
                    client.close();
                talk(client);
            }
            catch (Exception e)
            {
                if (stopped)
                    return;
                writeln("Debug channel: ", e.msg);
            }
        }
    }

    private void talk(Socket client)
    {
        LineReader reader;
        char[4096] buffer;
        while (!stopped)
        {
            const received = client.receive(buffer[]);
            if (received == 0 || received == Socket.ERROR)
                return; // the client is gone
            reader.put(buffer[0 .. received]);
            string line;
            while (reader.next(line))
            {
                const response = answer(line) ~ "\n";
                for (size_t sent = 0; sent < response.length;)
                {
                    const n = client.send(response[sent .. $]);
                    if (n == Socket.ERROR)
                        return;
                    sent += n;
                }
            }
        }
    }

    // The response line of a request: what the protocol makes of the run on the window
    private string answer(string line)
    {
        DebugRequest request;
        string error;
        if (!parseRequest(line, request, error))
            return errorLine(error);
        final switch (request.kind)
        {
        case RequestKind.eval:
            return evalResponse(runOnWindow(evalScript(request.text)));
        case RequestKind.shot:
            return shotResponse(runOnWindow(shotScript), request.text, (string path, const(ubyte)[] image) {
                import std.file : mkdirRecurse, write;
                import std.path : dirName;

                mkdirRecurse(path.dirName);
                write(path, image);
            });
        }
    }

    // Runs `script` on the window's thread and waits for what it gave
    private WindowRun runOnWindow(string script)
    {
        import std.conv : to;

        auto run = new ScriptRun(_hwnd, script);
        postToWindowThread(_hwnd, &run.evaluate);
        if (!run.finished.wait(windowTimeout))
            return WindowRun("the window didn't run the request in "
                ~ windowTimeout.total!"seconds".to!string ~ " s");
        return run.result;
    }
}

// A script run on the window's thread, its value read there: the SciterValue doesn't leave the
// thread. On the heap: the server may give up waiting before it runs.
private final class ScriptRun
{
    private HWINDOW _hwnd;
    private immutable(wchar)[] _script;
    Event finished;
    WindowRun result; /// set on the window's thread before `finished`

    this(HWINDOW hwnd, string script)
    {
        import std.utf : toUTF16;

        _hwnd = hwnd;
        _script = script.toUTF16;
        finished.initialize(true, false);
    }

    // On the window's thread
    void evaluate() nothrow
    {
        try
        {
            import std.utf : toUTF8;

            SciterValue value;
            if (!sciterApi().SciterEval(_hwnd, _script.ptr, cast(UINT) _script.length, value.raw))
                result.error = "SciterEval failed (no document loaded?)";
            else
            {
                const(wchar)[] wide;
                const(ubyte)[] data;
                if (value.view.tryGet(wide))
                {
                    result.isText = true;
                    result.text = wide.toUTF8;
                }
                else if (value.view.tryGet(data))
                    result.bytes = data.dup; // the value's own bytes go with it
            }
        }
        catch (Exception e)
            result.error = e.msg;
        finished.setIfInitialized();
    }
}
