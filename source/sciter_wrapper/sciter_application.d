module sciter_wrapper.sciter_application;

import sciter_wrapper.sciter_api;

import sciter.api;
import sciter.types;
import sciter.behavior;
import sciter.def;

import std.algorithm : map;
import std.utf : toUTF16z, toUTF16;
import std.array : array;

private __gshared SciterApplication _instance;

SciterApplication* sciterApplication() nothrow @nogc
{
    return &_instance;
}

private struct SciterApplication
{
    private const(wchar)[][] _argv;
    private HINSTANCE _hinstance;

    auto argv() const nothrow @nogc @property
    {
        return _argv;
    }

    auto hinstance() nothrow @nogc @property
    {
        return _hinstance;
    }

    private INT_PTR sciterExec(UINT cmd, UINT_PTR p1, UINT_PTR p2) nothrow @nogc
    {
        return sciterApi().SciterExec(cmd, p1, p2);
    }

    private INT_PTR appInit(UINT_PTR p1, UINT_PTR p2) nothrow @nogc
    {
        return sciterExec(SCITER_APP_CMD.SCITER_APP_INIT, p1, p2);
    }

    void start() nothrow @nogc
    {
        appInit(0, 0);
    }

    void start(const(char)[][] args) nothrow
    {
        const(wchar)[][] wargs = cast(const(wchar)[][]) args.map!(str => toUTF16(str)).array;

        start(wargs);
    }

    void start(const(wchar)[][] args) nothrow
    {
        const(wchar)*[] ptrArr = args.map!(str => str.ptr).array;

        appInit(cast(UINT_PTR) ptrArr.length, cast(UINT_PTR) ptrArr.ptr);
    }

    int runEventLoop() nothrow @nogc
    {
        return cast(int) sciterExec(SCITER_APP_CMD.SCITER_APP_LOOP, 0, 0);
    }

    bool requestQuit(int returnValue = 0) nothrow @nogc
    {
        return sciterExec(SCITER_APP_CMD.SCITER_APP_STOP, returnValue, 0) == 0;
    }

    void shutdown() nothrow @nogc
    {
        sciterExec(SCITER_APP_CMD.SCITER_APP_SHUTDOWN, 0, 0);
    }

    bool runIteration() nothrow @nogc
    {
        return cast(bool) sciterExec(SCITER_APP_CMD.SCITER_APP_LOOP_ITERATION, 0, 0);
    }

    bool runHeartbit() nothrow @nogc
    {
        return cast(bool) sciterExec(SCITER_APP_CMD.SCITER_APP_LOOP_HEARTBIT, 0, 0);
    }
}
