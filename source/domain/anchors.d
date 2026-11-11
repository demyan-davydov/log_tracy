//! The anchors of a document: the messages the user pinned, listed in both views
//! whatever the filters and the search, at most MaxAnchors.
module domain.anchors;

import std.conv : to;

// Store DLT document anchors in a hash set
// Anchors are used to mark messages that should be displayed in the main/search view
// Anchors are stored as a hash set of message indexes
struct Anchors
{
    enum MaxAnchors = 16;
    private void[0][size_t] _anchors; // hash set

    this(const(Anchors) other)
    {
        _anchors = cast(typeof(_anchors)) other._anchors.dup;
    }

    void opAssign(const(Anchors) other)
    {
        _anchors = cast(typeof(_anchors)) other._anchors.dup;
    }

    size_t[] exportAnchors() const pure nothrow @property
    {
        return _anchors.keys;
    }

    void importAnchors(const(size_t[]) anchors)
    {
        if (anchors.length > MaxAnchors)
            throw new Exception(
                "Invalid anchors length: " ~ anchors.length.to!string ~ ", max: " ~ MaxAnchors
                    .to!string);
        foreach (offset; anchors)
            _anchors[offset] = void[0].init;

        _anchors.rehash();
    }

    size_t length() const pure @nogc nothrow @property
    {
        return _anchors.length;
    }

    bool has(size_t msgIndex) const pure @nogc nothrow
    {
        return (msgIndex in _anchors) !is null;
    }

    bool set(size_t msgIndex, bool value)
    {
        if (!value)
        {
            _anchors.remove(msgIndex);
        }
        else
        {
            auto valueRef = (msgIndex in _anchors);
            if (valueRef is null)
            {
                if (_anchors.length == MaxAnchors)
                    return false;

                _anchors[msgIndex] = void[0].init;
            }
        }

        return true;
    }
}
