//! What the code reads of an element of Sciter's DOM by its handle, the thin calls over the C API that need no wrapper class.
module sciter.element;

import sciter.api : sciterApi;
import sciter.capi.api;
import sciter.capi.dom : SCDOM_OK;
import sciter.capi.types;

/// The value of the attribute `name` of the element `he`, as UTF-8; null when the element has no such attribute
string attributeOf(HELEMENT he, const(char)[] name)
{
    import std.string : toStringz;
    import std.utf : toUTF8;

    static struct Received
    {
        const(wchar)[] text;
        bool got;
    }

    extern (C) static void receive(LPCWSTR str, UINT length, void* param) nothrow
    {
        auto into = cast(Received*) param;
        into.text = str[0 .. length].idup;
        into.got = true;
    }

    Received received;
    // the binding declares the receiver as a pointer to the type of the function pointer (the C header's `LPCWSTR_RECEIVER*`, a
    // function type there): the address of the function is what Sciter calls
    auto receiver = cast(LPCWSTR_RECEIVER*) &receive;
    if (sciterApi().SciterGetAttributeByNameCB(he, name.toStringz, receiver, &received) != SCDOM_OK || !received.got)
        return null;
    return received.text.toUTF8;
}
