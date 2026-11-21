//! Whether a table follows the end of its rows as they grow, as a terminal does: the decision, free of the table. Following is turned on only
//! by a command (the user asked for it: the badge of the scroll bar); while it is on the table puts the end in view again at every pass, and a
//! move by anything but the table's own following (the wheel, a bar, the keys, a jump) that leaves the end out of view turns it off, as a new
//! list does. Where the rows stand never turns it on. See docs/stories/painted-table.md and rule 30 of .ai/rules/ux.md.
module ptable.endfollow;

/// What the table is to do after a pass of the follow
enum EndStep
{
    none, /// nothing
    stick, /// the end is out of view while following: scroll to it
    changed, /// the mode changed (it is `following` now)
}

struct EndFollow
{
    bool following; /// set by the command, cleared by `step`

    /// One pass. `foreignMove`: the rows moved since the table last stood where it put them (not by its own following); `atEnd`: the last row is in
    /// view, whole, at the end; `newList`: the rows are other ones now
    EndStep step(bool foreignMove, bool atEnd, bool newList)
    {
        if (!following)
            return EndStep.none;
        if (newList || (foreignMove && !atEnd))
        {
            following = false;
            return EndStep.changed;
        }
        return atEnd ? EndStep.none : EndStep.stick;
    }
}

@("EndFollow: following comes only by the command: a move of another's to the end or a short new list does not turn it on")
unittest
{
    EndFollow follow;
    assert(follow.step(true, true, false) == EndStep.none && !follow.following, "the wheel down to the end");
    assert(follow.step(false, true, true) == EndStep.none && !follow.following, "a new list that fits the window (a file being loaded)");
    follow.following = true; // the command
    assert(follow.step(false, true, false) == EndStep.none && follow.following, "at the end: nothing to do");
}

@("EndFollow: while following, a growth sticks to the end, a move of another's at the end keeps it, one away from the end turns it off")
unittest
{
    EndFollow follow;
    follow.following = true;
    assert(follow.step(false, false, false) == EndStep.stick && follow.following, "the list grew: the end is out of view");
    assert(follow.step(true, true, false) == EndStep.none && follow.following, "the wheel down at the end");
    assert(follow.step(true, false, false) == EndStep.changed && !follow.following, "up from the end");
    assert(follow.step(false, false, false) == EndStep.none && !follow.following, "not following: the rows stay");
}

@("EndFollow: a new list turns following off")
unittest
{
    EndFollow follow;
    follow.following = true;
    assert(follow.step(false, true, true) == EndStep.changed && !follow.following);
    assert(follow.step(false, true, true) == EndStep.none, "off already: told of nothing");
}
