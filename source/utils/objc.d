//! Calls of the Objective-C runtime from D (macOS): a class by name, a message with an exact
//! prototype.
module utils.objc;

version (OSX):

extern (C) void* objc_getClass(const char* name);
extern (C) void* sel_registerName(const char* name);
extern (C) void* objc_msgSend(void* self, void* op, ...);

/// Calls objc_msgSend through an exact prototype derived from the argument types.
R msg(R = void*, Args...)(void* obj, const(char)* sel, Args args)
{
    alias Fn = extern (C) R function(void*, void*, Args) @trusted;
    return (cast(Fn)&objc_msgSend)(obj, sel_registerName(sel), args);
}

/// The class named `name`, null if there is none.
void* cls(const(char)* name)
{
    return objc_getClass(name);
}
