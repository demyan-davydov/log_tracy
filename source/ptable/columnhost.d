//! The columns the tables of one list of columns share (`ColumnHost`): the definitions, the layout (widths, visibility,
//! pinning, the horizontal scroll), the width of the room of the columns and their places in it, and the fit of the widths
//! to the rows the tables show (`settle`). The tables (`ColumnClient`) only lay out their rows and tell what they need: the
//! widths are decided here, once for all of them, so two tables never argue over a width. Invariants: the clients of a host
//! show one list of columns (tables that need other columns have a host of their own), and the room of the columns is the
//! same for all of them (the least the clients have: a wider one leaves its edge empty, none cuts a column). Pure: no Sciter,
//! no log. See docs/stories/painted-table.md.
module ptable.columnhost;

import ptable.layout : ColumnDef, ColumnLayout, LayoutChange, LayoutListener, Placements, placeColumns;
import ptable.listeners : Listeners;

import std.algorithm.comparison : max, min;

/// A table of a host: lays out its rows on the screen by the widths of the host and tells what they need
interface ColumnClient
{
    /// The rows on the screen laid out again by the widths of the host now; `needs[i]` (the column `i` of the host) grows to what
    /// the rows and the title ask of it. Called by `ColumnHost.settle` only, never calls it back.
    void measure(double[] needs);
}

final class ColumnHost
{
    enum maxRounds = 16; /// a safeguard of `settle`: the widths only widen in it and are bounded

    private struct Client
    {
        ColumnClient client;
        double width; // the room of the columns it has, NaN: not told yet
    }

    private ColumnLayout _layout;
    private ColumnDef[] _columns;
    private size_t[string] _index; // the index of a column by its id
    private double[] _least; // the least width of each column
    private Client[] _clients;
    private double[] _fits; // the widths `settle` fits, by the index of the column
    private double[] _needs; // what the clients told in a round of `settle`, kept to allocate once
    private bool _settling;
    private size_t _rounds;
    private Listeners!LayoutChange _listeners;
    private size_t _layoutHandle;
    private Placements _placed;
    private uint _placedRevision;
    private double _placedWidth = -1, _placedOrigin = 0;
    private bool _placedValid;

    /// A host of the widths of `layout` (a layout of its own by default)
    this(ColumnLayout layout = null)
    {
        _layout = layout !is null ? layout : new ColumnLayout;
        _layoutHandle = _layout.subscribe((const LayoutChange change) { _listeners.tell(change); });
    }

    /// The widths, visibility, pinning and scroll of the columns
    inout(ColumnLayout) layout() inout { return _layout; }

    /// The columns of the clients, in their order
    const(ColumnDef)[] columns() const { return _columns; }

    /// The columns are `columns` now (the clients read theirs again: another format): the same ids keep everything
    void setColumns(const(ColumnDef)[] columns)
    {
        if (columns == _columns)
            return;
        _columns = columns.dup;
        _index = null;
        _least.length = _fits.length = _columns.length;
        foreach (i, ref column; _columns)
        {
            _index[column.id] = i;
            _least[i] = column.minWidth;
            _fits[i] = _layout.fitWidth(column.id); // the layout keeps them by id: a column seen before keeps its width
        }
        _placedValid = false;
    }

    /// The index of the column `id`, `size_t.max` if the host has none
    size_t indexOf(string id) const
    {
        if (auto found = id in _index)
            return *found;
        return size_t.max;
    }

    /// The least widths of the columns (what `settle` starts from to narrow them): the least width of each column
    const(double)[] least() const
    {
        return _least;
    }

    /// The widths the columns are fit to now (what `settle` starts from to only widen them)
    const(double)[] fits() const
    {
        return _fits;
    }

    /// The rounds the last `settle` took
    size_t rounds() const { return _rounds; }

    /// `client` shows the columns of the host from now on; its room is told by `resize`
    void attach(ColumnClient client)
    {
        assert(find(client) == size_t.max, "a client attached twice");
        _clients ~= Client(client, double.nan);
    }

    /// `client` no longer shows them: what it needed and the room it had are forgotten, the others settle without it
    void detach(ColumnClient client)
    {
        const at = find(client);
        if (at == size_t.max)
            return;
        const room = width;
        _clients = _clients[0 .. at] ~ _clients[at + 1 .. $];
        toldRoom(room);
        if (_clients.length)
            settle(_least);
    }

    /// The room of the columns `client` has is `width` now
    void resize(ColumnClient client, double width)
    {
        const at = find(client);
        assert(at != size_t.max, "the room of a client not attached");
        const room = this.width;
        _clients[at].width = width;
        toldRoom(room);
    }

    /// The room of the columns of every client: the least the clients told, 0 if none did
    double width() const
    {
        double least = double.infinity;
        foreach (ref c; _clients)
            if (c.width == c.width) // told
                least = min(least, c.width);
        return least == double.infinity ? 0 : least;
    }

    /// Where the columns stand in the room of the host whose left edge is `originX` from a table's: made again only when the layout,
    /// the room or the columns changed
    ref const(Placements) places(double originX = 0)
    {
        const room = width;
        if (!_placedValid || _placedRevision != _layout.revision || _placedWidth != room || _placedOrigin != originX)
        {
            _placed = placeColumns(_columns, _layout, room, originX);
            _placedRevision = _layout.revision;
            _placedWidth = room;
            _placedOrigin = originX;
            _placedValid = true;
        }
        return _placed;
    }

    /// Settles the widths from `start` (`least` to narrow them, `fits` to only widen them): every client lays out its rows by the widths
    /// now and tells what they need, a column takes the most of `start` and the needs; while that changed a width, the clients lay out
    /// again by the new widths and the columns only widen. The change is told once, at the end (`LayoutChange.Kind.fit`); nothing is
    /// told, nor are the places made again, when the widths came out as they were.
    void settle(const(double)[] start)
    {
        assert(!_settling, "a client settled the host from its measure");
        assert(start.length == _columns.length, "a start of other columns");
        _settling = true;
        scope (exit)
            _settling = false;
        _needs.length = _columns.length;
        _rounds = 0;
        _layout.fitting({
            if (start.ptr !is _fits.ptr) // `fits` itself: nothing to copy (and a copy onto itself is not allowed)
                _fits[] = start[];
            while (_rounds < maxRounds)
            {
                ++_rounds;
                _needs[] = 0;
                foreach (ref c; _clients)
                    c.client.measure(_needs);
                foreach (i, need; _needs)
                    _fits[i] = max(_fits[i], need);
                if (!writeFits())
                    break;
            }
        });
    }

    // Gives the layout the widths of `_fits`; true if one changed
    private bool writeFits()
    {
        bool changed;
        foreach (i, ref column; _columns)
            if (_layout.fitWidth(column.id) != _fits[i])
            {
                _layout.setFit(column.id, _fits[i]);
                changed = true;
            }
        return changed;
    }

    private size_t find(ColumnClient client) const
    {
        foreach (i, ref c; _clients)
            if (c.client is client)
                return i;
        return size_t.max;
    }

    // The room was `before`: told if it is another now
    private void toldRoom(double before)
    {
        if (width != before)
            _listeners.tell(LayoutChange(LayoutChange.Kind.room, ""));
    }

    /// Calls `listener` after every change of the layout and of the room of the columns (`LayoutChange.Kind.room`); the handle is
    /// for `unsubscribe`
    size_t subscribe(LayoutListener listener)
    {
        return _listeners.add(listener);
    }

    void unsubscribe(size_t handle)
    {
        _listeners.remove(handle);
    }
}

version (unittest)
{
    // A client whose rows need what `needOf` says for the widths of the host now
    private final class FakeClient : ColumnClient
    {
        ColumnHost host;
        double[] delegate(ColumnHost host) needOf;
        size_t measures;

        this(ColumnHost host, double[] delegate(ColumnHost host) needOf)
        {
            this.host = host;
            this.needOf = needOf;
        }

        void measure(double[] needs)
        {
            ++measures;
            foreach (i, need; needOf(host))
                needs[i] = max(needs[i], need);
        }
    }

    private FakeClient needing(ColumnHost host, double[] fixed...)
    {
        auto copy = fixed.dup;
        return new FakeClient(host, (ColumnHost) => copy);
    }

    private ColumnHost hostOf(ColumnDef[] columns...)
    {
        auto host = new ColumnHost;
        host.setColumns(columns.dup);
        return host;
    }

    private LayoutChange[] toldBy(ColumnHost host, void delegate() act)
    {
        LayoutChange[] told;
        const handle = host.subscribe((const LayoutChange c) { told ~= c; });
        act();
        host.unsubscribe(handle);
        return told;
    }
}

@("ColumnHost: the columns are found by id; the same ids keep the widths, other ones are new columns")
unittest
{
    auto host = hostOf(ColumnDef("a", "A", 20), ColumnDef("b", "B", 30));
    assert(host.indexOf("b") == 1 && host.indexOf("c") == size_t.max);
    assert(host.least == [20, 30], "the least widths are those of the columns");
    auto client = needing(host, 50, 60);
    host.attach(client);
    host.settle(host.least);
    host.setColumns([ColumnDef("a", "A", 20), ColumnDef("b", "B", 30)]);
    assert(host.fits == [50, 60], "the same columns: nothing is forgotten");
    host.setColumns([ColumnDef("b", "B", 30), ColumnDef("c", "C", 10)]);
    assert(host.indexOf("b") == 0 && host.indexOf("c") == 1 && host.fits.length == 2);
}

@("ColumnHost: a column is as wide as the client that needs it most, and the change is told once")
unittest
{
    auto host = hostOf(ColumnDef("level", "L", 24), ColumnDef("text", "T", 24));
    auto main = needing(host, 60, 300);
    auto search = needing(host, 50, 400);
    host.attach(main);
    host.attach(search);
    const told = toldBy(host, { host.settle(host.least); });
    assert(host.fits == [60, 400], "the most any client needs");
    assert(host.layout.width("level") == 60 && host.layout.width("text") == 400);
    assert(told.length == 1 && told[0].kind == LayoutChange.Kind.fit, "one notice, of the fit");
    const again = toldBy(host, { host.settle(host.fits); });
    assert(again.length == 0, "nothing changed: nothing is told");
}

@("ColumnHost: the widths settle when what the rows need depends on them, in a few rounds")
unittest
{
    auto host = hostOf(ColumnDef("a", "A", 10), ColumnDef("b", "B", 10));
    // a wider `a` brings other rows into the window, which need `b` wider, up to a bound
    auto chained = new FakeClient(host, (ColumnHost h) => [80.0, min(200.0, h.layout.width("a") * 2)]);
    auto other = needing(host, 100, 0);
    host.attach(chained);
    host.attach(other);
    host.settle(host.least);
    assert(host.fits == [100, 200], "a by the other client, b by the a it made");
    assert(host.rounds > 1 && host.rounds < ColumnHost.maxRounds, "it came to rest, not to the safeguard");
}

@("ColumnHost: settling from the least widths narrows, from the fits only widens")
unittest
{
    auto host = hostOf(ColumnDef("a", "A", 20));
    double need = 90;
    auto client = new FakeClient(host, (ColumnHost) => [need]);
    host.attach(client);
    host.settle(host.least);
    need = 40;
    host.settle(host.fits);
    assert(host.fits == [90], "from the fits: a narrower need does not narrow");
    host.settle(host.least);
    assert(host.fits == [40], "from the least: it narrows to the need");
    need = 0;
    host.settle(host.least);
    assert(host.fits == [20], "nothing measured: the least width");
}

@("ColumnHost: a detached client's needs are gone and the others settle without it at once")
unittest
{
    auto host = hostOf(ColumnDef("level", "L", 24));
    auto main = needing(host, 50);
    auto search = needing(host, 60);
    host.attach(main);
    host.attach(search);
    host.settle(host.least);
    assert(host.fits == [60]);
    const measured = search.measures;
    const told = toldBy(host, { host.detach(search); });
    assert(host.fits == [50] && host.layout.width("level") == 50, "the column narrows to what is left");
    assert(told.length == 1 && told[0].kind == LayoutChange.Kind.fit);
    assert(search.measures == measured, "a detached client is not asked");
}

@("ColumnHost: the room of the columns is the least the clients told, and the places are made for it")
unittest
{
    auto host = hostOf(ColumnDef("a", "A", 40), ColumnDef("text", "T", 50, true));
    auto main = needing(host, 0, 0);
    auto search = needing(host, 0, 0);
    host.attach(main);
    host.attach(search);
    assert(host.width == 0, "nobody told a room yet");
    host.resize(main, 300);
    assert(host.width == 300, "a client that did not tell its room is not counted");
    const told = toldBy(host, { host.resize(search, 280); });
    assert(host.width == 280 && told.length == 1 && told[0].kind == LayoutChange.Kind.room);
    assert(toldBy(host, { host.resize(main, 290); }).length == 0, "the least did not change: nothing told");
    auto p = &host.places(10);
    assert(p.columns.length == 2 && p.columns[0].x == 10 && p.columns[1].width == 240, "the flex column takes the rest of the least room");
    assert(&host.places(10) is p && host.places(10).columns.ptr is p.columns.ptr, "kept while nothing changed");
    host.detach(search);
    assert(host.width == 290, "the narrow one is gone");
    assert(host.places(10).columns[1].width == 250);
}

@("ColumnHost: the layout's changes are told to its listeners")
unittest
{
    auto host = hostOf(ColumnDef("a", "A", 40));
    const told = toldBy(host, { host.layout.setVisible("a", false); });
    assert(told.length == 1 && told[0].kind == LayoutChange.Kind.visibility);
}
