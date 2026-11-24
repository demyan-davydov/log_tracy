//! What the events of Sciter mean for the log table: how far a wheel step goes, which key is which key of the
//! table, which mouse button starts a press, which key combination is a copy. The numbers and the flags come from
//! Sciter's own types; the decisions are plain functions, checked by tests with plain numbers.
module ui.sciter_table.input;

import ptable.navigation : Key;
import ptable.rowpicks : Pick;
import ptable.tablehit : PointerKind;
import sciter.capi.behavior : CURSOR_TYPE, KEYBOARD_STATES, MOUSE_BUTTONS, PHASE_MASK;
import sciter.capi.key_codes : SC_KB_CODES;

/// A wheel step in pixels: the delta is a signed 16-bit number in the low half of `buttonState` (65524 is -12), forward
/// (the content moves down) is positive, as on Windows; `scale` pixels to a unit of the delta
double wheelPixels(uint buttonState, double scale)
{
    return -cast(int) cast(short) buttonState * scale;
}

/// Whether a press is of the main button: another one starts nothing (a menu, the middle button are not the table's yet)
bool startsPress(uint buttonState)
{
    return (buttonState & MOUSE_BUTTONS.MAIN_MOUSE_BUTTON) != 0;
}

/// Whether a release may end the table's press: one that names another button and not the main one does not (a right click while the
/// main button is held). One that names none passes: what Sciter gives on a release is not checked (6.0.5.5)
bool endsPress(uint buttonState)
{
    return buttonState == 0 || (buttonState & MOUSE_BUTTONS.MAIN_MOUSE_BUTTON) != 0;
}

/// The key of the table a key of Sciter is; false for one the table has no use for
bool tableKey(uint keyCode, out Key key)
{
    switch (keyCode)
    {
    case SC_KB_CODES.KB_DOWN: key = Key.down; return true;
    case SC_KB_CODES.KB_UP: key = Key.up; return true;
    case SC_KB_CODES.KB_PAGE_DOWN: key = Key.pageDown; return true;
    case SC_KB_CODES.KB_PAGE_UP: key = Key.pageUp; return true;
    case SC_KB_CODES.KB_HOME: key = Key.home; return true;
    case SC_KB_CODES.KB_END: key = Key.end; return true;
    case SC_KB_CODES.KB_ESCAPE: key = Key.escape; return true;
    default: return false;
    }
}

/// Control or Command with C
bool isCopy(uint altState, uint keyCode)
{
    return (altState & (KEYBOARD_STATES.KEYBOARD_STATE_CONTROL | KEYBOARD_STATES.KEYBOARD_STATE_COMMAND)) != 0
        && keyCode == SC_KB_CODES.KB_C;
}

/// Select all: A with Command on macOS, with Control elsewhere (Control+A on macOS is the start of a line, not ours)
bool isSelectAll(uint altState, uint keyCode, bool mac = onMac)
{
    const key = mac ? KEYBOARD_STATES.KEYBOARD_STATE_COMMAND : KEYBOARD_STATES.KEYBOARD_STATE_CONTROL;
    return (altState & key) != 0 && keyCode == SC_KB_CODES.KB_A;
}

/// A wheel with Shift held moves the columns, not the rows
bool wheelIsAcross(uint altState)
{
    return (altState & KEYBOARD_STATES.KEYBOARD_STATE_SHIFT) != 0;
}

/// Whether the system we are on is macOS: Command is the key that adds to a selection there, Control elsewhere
version (OSX)
    enum bool onMac = true;
else
    enum bool onMac = false;

/// What a press of the mouse does to the rows by the keys held: Shift extends the rows from the last pick, Command (macOS) or
/// Control (elsewhere) adds or takes away a row, both together add the range
Pick pickMode(uint altState, bool mac = onMac)
{
    const shift = (altState & KEYBOARD_STATES.KEYBOARD_STATE_SHIFT) != 0;
    const toggleKey = mac ? KEYBOARD_STATES.KEYBOARD_STATE_COMMAND : KEYBOARD_STATES.KEYBOARD_STATE_CONTROL;
    const toggle = (altState & toggleKey) != 0;
    return shift ? (toggle ? Pick.extendAdd : Pick.extend) : (toggle ? Pick.toggle : Pick.replace);
}

/// A press of the main button with Control on macOS is a click for a context menu, not a pick
bool isContextPress(uint altState, bool mac = onMac)
{
    return mac && (altState & KEYBOARD_STATES.KEYBOARD_STATE_CONTROL) != 0;
}

/// A press of the main button that begins a pick: not another button, not a click for a context menu
bool startsPickPress(uint buttonState, uint altState, bool mac = onMac)
{
    return startsPress(buttonState) && !isContextPress(altState, mac);
}

/// Whether an event of Sciter is the table's own to treat: of the bubbling phase and not handled by another element (a click on an item
/// of a menu over the table comes to the table too, handled by the menu, and is no press of the table)
bool isOurEvent(uint cmd)
{
    return (cmd & (PHASE_MASK.SINKING | PHASE_MASK.HANDLED)) == 0;
}

/// The cursor of Sciter for the pointer of the table
uint cursorOf(PointerKind pointer)
{
    return pointer == PointerKind.hand ? CURSOR_TYPE.CURSOR_HAND : CURSOR_TYPE.CURSOR_ARROW;
}

/// What a key of movement does to the rows: with Shift it extends them from the last pick
Pick keyPickMode(uint altState)
{
    return (altState & KEYBOARD_STATES.KEYBOARD_STATE_SHIFT) != 0 ? Pick.extend : Pick.replace;
}

@("wheelPixels: the signed half of the button state, forward is positive, scaled")
unittest
{
    assert(wheelPixels(65_524, 1) == 12, "65524 is -12 in 16 bits: the content goes down by 12");
    assert(wheelPixels(12, 1) == -12);
    assert(wheelPixels(65_524, 2.5) == 30);
    assert(wheelPixels(0xABCD_0000 | 65_524, 1) == 12, "the high half belongs to the buttons");
}

@("startsPress: the main button only")
unittest
{
    assert(startsPress(MOUSE_BUTTONS.MAIN_MOUSE_BUTTON));
    assert(!startsPress(MOUSE_BUTTONS.PROP_MOUSE_BUTTON) && !startsPress(0));
}

@("tableKey: the keys of the table by their codes, others are nothing")
unittest
{
    Key key;
    assert(tableKey(SC_KB_CODES.KB_PAGE_DOWN, key) && key == Key.pageDown);
    assert(tableKey(SC_KB_CODES.KB_ESCAPE, key) && key == Key.escape);
    assert(!tableKey(SC_KB_CODES.KB_A, key));
}

@("isCopy: C with Control or Command, not alone")
unittest
{
    assert(isCopy(KEYBOARD_STATES.KEYBOARD_STATE_CONTROL, SC_KB_CODES.KB_C));
    assert(isCopy(KEYBOARD_STATES.KEYBOARD_STATE_COMMAND, SC_KB_CODES.KB_C));
    assert(!isCopy(0, SC_KB_CODES.KB_C) && !isCopy(KEYBOARD_STATES.KEYBOARD_STATE_CONTROL, SC_KB_CODES.KB_A));
}

@("isSelectAll: A with the key of the system (Command on macOS, Control elsewhere), nothing else")
unittest
{
    enum control = KEYBOARD_STATES.KEYBOARD_STATE_LCONTROL, command = KEYBOARD_STATES.KEYBOARD_STATE_RCOMMAND;
    assert(isSelectAll(command, SC_KB_CODES.KB_A, true) && isSelectAll(control, SC_KB_CODES.KB_A, false));
    assert(!isSelectAll(control, SC_KB_CODES.KB_A, true) && !isSelectAll(command, SC_KB_CODES.KB_A, false));
    assert(!isSelectAll(0, SC_KB_CODES.KB_A, true) && !isSelectAll(command, SC_KB_CODES.KB_C, true));
}

@("pickMode: Shift extends, Command on macOS or Control elsewhere toggles, both add a range, the other key of the pair is nothing")
unittest
{
    enum shift = KEYBOARD_STATES.KEYBOARD_STATE_LSHIFT, control = KEYBOARD_STATES.KEYBOARD_STATE_RCONTROL,
        command = KEYBOARD_STATES.KEYBOARD_STATE_LCOMMAND;
    assert(pickMode(0, true) == Pick.replace && pickMode(0, false) == Pick.replace);
    assert(pickMode(shift, true) == Pick.extend && pickMode(command, true) == Pick.toggle);
    assert(pickMode(shift | command, true) == Pick.extendAdd);
    assert(pickMode(control, false) == Pick.toggle && pickMode(shift | control, false) == Pick.extendAdd);
    assert(pickMode(control, true) == Pick.replace && pickMode(command, false) == Pick.replace, "not the key of this system");
}

@("isContextPress: Control with the main button is a context click on macOS only; keyPickMode: Shift extends")
unittest
{
    assert(isContextPress(KEYBOARD_STATES.KEYBOARD_STATE_LCONTROL, true) && !isContextPress(KEYBOARD_STATES.KEYBOARD_STATE_LCONTROL, false));
    assert(!isContextPress(0, true));
    assert(keyPickMode(KEYBOARD_STATES.KEYBOARD_STATE_RSHIFT) == Pick.extend && keyPickMode(0) == Pick.replace);
}

@("wheelIsAcross: Shift turns the wheel to the columns")
unittest
{
    assert(wheelIsAcross(KEYBOARD_STATES.KEYBOARD_STATE_LSHIFT) && wheelIsAcross(KEYBOARD_STATES.KEYBOARD_STATE_RSHIFT));
    assert(!wheelIsAcross(0) && !wheelIsAcross(KEYBOARD_STATES.KEYBOARD_STATE_LCONTROL));
}

@("endsPress: the release of another button alone ends no press of the main one; one of the main button or of none does")
unittest
{
    assert(endsPress(MOUSE_BUTTONS.MAIN_MOUSE_BUTTON) && endsPress(0));
    assert(!endsPress(MOUSE_BUTTONS.PROP_MOUSE_BUTTON) && !endsPress(MOUSE_BUTTONS.MIDDLE_MOUSE_BUTTON));
    assert(endsPress(MOUSE_BUTTONS.MAIN_MOUSE_BUTTON | MOUSE_BUTTONS.PROP_MOUSE_BUTTON));
}

@("startsPickPress: the main button, not with Control on macOS; isOurEvent: not a sinking or a handled event")
unittest
{
    assert(startsPickPress(MOUSE_BUTTONS.MAIN_MOUSE_BUTTON, 0, true) && !startsPickPress(MOUSE_BUTTONS.PROP_MOUSE_BUTTON, 0, true));
    assert(!startsPickPress(MOUSE_BUTTONS.MAIN_MOUSE_BUTTON, KEYBOARD_STATES.KEYBOARD_STATE_LCONTROL, true));
    assert(startsPickPress(MOUSE_BUTTONS.MAIN_MOUSE_BUTTON, KEYBOARD_STATES.KEYBOARD_STATE_LCONTROL, false));
    assert(isOurEvent(4) && !isOurEvent(4 | PHASE_MASK.HANDLED) && !isOurEvent(4 | PHASE_MASK.SINKING));
}

@("cursorOf: the hand for the hand, the arrow for the rest")
unittest
{
    assert(cursorOf(PointerKind.hand) == CURSOR_TYPE.CURSOR_HAND && cursorOf(PointerKind.arrow) == CURSOR_TYPE.CURSOR_ARROW);
}
