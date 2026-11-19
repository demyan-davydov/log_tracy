//! Whether a table follows the end of its rows as they grow, as a terminal does: the decision, free of the table. The mode is derived from where
//! the rows stand, never set by the one who scrolls: when the position moved by anything but the table's own following (the wheel, a bar, the
//! keys, a jump) the mode becomes whether the last row is in view; while it is on and nothing else moved, the table has to put the end in view
//! again. A new list starts over. See docs/stories/painted-table.md and rule 30 of .ai/rules/ux.md.
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
    bool following;

    /// One pass. `foreignMove`: the rows moved since the table last stood where it put them (not by its own following); `atEnd`: the last row is in
    /// view, whole, at the end; `newList`: the rows are other ones now (the mode starts over and is read at once: a list that does not fill the window
    /// has its end in view)
    EndStep step(bool foreignMove, bool atEnd, bool newList)
    {
        const was = following;
        if (foreignMove || newList) // a new list is read at once as if the rows were moved: whether its end is in view
        {
            following = atEnd;
            return was != following ? EndStep.changed : EndStep.none;
        }
        return following && !atEnd ? EndStep.stick : EndStep.none;
    }
}

@("EndFollow: a move that is not its own to the end turns following on, a move up turns it off")
unittest
{
    EndFollow follow;
    assert(follow.step(true, true, false) == EndStep.changed && follow.following);
    assert(follow.step(true, true, false) == EndStep.none && follow.following, "the same again: nothing changed");
    assert(follow.step(true, false, false) == EndStep.changed && !follow.following, "up from the end");
    assert(follow.step(true, false, false) == EndStep.none && !follow.following);
}

@("EndFollow: with no move of another's the mode stays: following asks to stick when the end is out of view, else nothing")
unittest
{
    EndFollow follow;
    follow.step(true, true, false);
    assert(follow.step(false, true, false) == EndStep.none, "at the end: nothing to do");
    assert(follow.step(false, false, false) == EndStep.stick && follow.following, "the list grew: the end is out of view");
    follow.step(true, false, false); // up
    assert(follow.step(false, false, false) == EndStep.none && !follow.following, "not following: the rows stay");
}

@("EndFollow: a new list starts over and is read at once: one that fills the window is off, one that does not is following")
unittest
{
    EndFollow follow;
    follow.step(true, true, false);
    assert(follow.step(false, false, true) == EndStep.changed && !follow.following, "a long list, at its top");
    assert(follow.step(false, true, true) == EndStep.changed && follow.following, "a short one: its end is in view");
    assert(follow.step(false, true, true) == EndStep.none && follow.following, "a new list that is as it was: told of nothing");
}
