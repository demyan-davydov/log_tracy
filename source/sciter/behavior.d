module sciter.behavior;

import sciter.types;
import sciter.value;
import sciter.graphics;
import sciter.om;

align(8):

enum EVENT_GROUPS
{
    HANDLE_INITIALIZATION = 0x0000,
    HANDLE_MOUSE = 0x0001,
    HANDLE_KEY = 0x0002,
    HANDLE_FOCUS = 0x0004,
    HANDLE_SCROLL = 0x0008,
    HANDLE_TIMER = 0x0010,
    HANDLE_SIZE = 0x0020,
    HANDLE_DRAW = 0x0040,
    HANDLE_DATA_ARRIVED = 0x080,
    HANDLE_BEHAVIOR_EVENT = 0x0100,
    HANDLE_METHOD_CALL = 0x0200,
    HANDLE_SCRIPTING_METHOD_CALL = 0x0400,
    HANDLE_TISCRIPT_METHOD_CALL = 0x0800,
    HANDLE_EXCHANGE = 0x1000,
    HANDLE_GESTURE = 0x2000,
    HANDLE_ATTRIBUTE_CHANGE = 0x4000,
    HANDLE_SOM = 0x8000,
    HANDLE_ALL = 0xFFFF,
    SUBSCRIPTIONS_REQUEST = 0xFFFFFFFF
}

enum
{
    T_UNDEFINED = 0,
    T_NULL = 1,
    T_BOOL = 2,
    T_INT = 3,
    T_FLOAT = 4,
    T_STRING = 5,
    T_DATE = 6,
    T_CURRENCY = 7,
    T_LENGTH = 8,
    T_ARRAY = 9,
    T_MAP = 10
}

alias ElementEventProc = extern (C) SBOOL function(void* tag, HELEMENT he, UINT evtg, void* prms);

// signature of the function exported from external behavior/dll.
alias SciterBehaviorFactory = extern (C) SBOOL function(const(char)* name, HELEMENT he, ElementEventProc** proc, void** tag);

enum PHASE_MASK
{
    BUBBLING = 0, // bubbling (emersion) phase
    SINKING = 0x8000, // capture (immersion) phase, this flag is or'ed with EVENTS codes below
    HANDLED = 0x10000 // see: http://www.w3.org/TR/xml-events/Overview.html#s_intro
}

enum MOUSE_BUTTONS
{
    MAIN_MOUSE_BUTTON = 1, //aka left button
    PROP_MOUSE_BUTTON = 2, //aka right button
    MIDDLE_MOUSE_BUTTON = 4,
}

enum KEYBOARD_STATES
{
    KEYBOARD_STATE_LSHIFT = 0x0001,
    KEYBOARD_STATE_RSHIFT = 0x0002,
    KEYBOARD_STATE_LCONTROL = 0x0040,
    KEYBOARD_STATE_RCONTROL = 0x0080,
    KEYBOARD_STATE_LALT = 0x0100,
    KEYBOARD_STATE_RALT = 0x0200,
    KEYBOARD_STATE_LCOMMAND = 0x0400,
    KEYBOARD_STATE_RCOMMAND = 0x0800,
    KEYBOARD_STATE_NUM = 0x1000,
    KEYBOARD_STATE_CAPS = 0x2000,
    KEYBOARD_STATE_MODE = 0x4000,

    KEYBOARD_STATE_CONTROL = (KEYBOARD_STATE_LCONTROL | KEYBOARD_STATE_RCONTROL),
    KEYBOARD_STATE_SHIFT = (KEYBOARD_STATE_LSHIFT | KEYBOARD_STATE_RSHIFT),
    KEYBOARD_STATE_ALT = (KEYBOARD_STATE_LALT | KEYBOARD_STATE_RALT),
    KEYBOARD_STATE_COMMAND = (KEYBOARD_STATE_LCOMMAND | KEYBOARD_STATE_RCOMMAND), // "command key" on OSX, "win" on Windows
}

// parameters of evtg == HANDLE_INITIALIZATION

enum INITIALIZATION_EVENTS
{
    BEHAVIOR_DETACH = 0,
    BEHAVIOR_ATTACH = 1
}

struct INITIALIZATION_PARAMS
{
    UINT cmd; // INITIALIZATION_EVENTS
}

enum SOM_EVENTS
{
    SOM_GET_PASSPORT = 0,
    SOM_GET_ASSET = 1
}

struct SOM_PARAMS
{
    UINT cmd = 0; // SOM_EVENTS

    union Data
    {
        som_passport_t* passport;
        som_asset_t* asset;
    }

    Data data;
}

enum DRAGGING_TYPE
{
    NO_DRAGGING,
    DRAGGING_MOVE,
    DRAGGING_COPY,
}

// parameters of evtg == HANDLE_MOUSE

enum MOUSE_EVENTS
{
    MOUSE_ENTER = 0,
    MOUSE_LEAVE,
    MOUSE_MOVE,
    MOUSE_UP,
    MOUSE_DOWN,
    MOUSE_DCLICK, /// double click
    MOUSE_WHEEL,
    MOUSE_TICK, /// generated periodically while mouse is pressed
    MOUSE_IDLE, /// generated when mouse stays idle for some time

    //OBSOLETE
    DROP = 9, // item dropped, target is that dropped item
    //OBSOLETE
    DRAG_ENTER = 0xA, // drag arrived to the target element that is one of current drop targets.
    //OBSOLETE
    DRAG_LEAVE = 0xB, // drag left one of current drop targets. target is the drop target element.
    //OBSOLETE
    DRAG_REQUEST = 0xC, // drag src notification before drag start. To cancel - return true from handler.

    MOUSE_TCLICK = 0xF, // tripple click

    //MOUSE_TOUCH_START = 0xFC, // touch device pressed somehow
    //MOUSE_TOUCH_END = 0xFD,   // touch device depressed - clear, nothing on it

    MOUSE_DRAG_REQUEST = 0xFE, // mouse drag start detected event

    MOUSE_CLICK = 0xFF, // mouse click event

    //OBSOLETE
    DRAGGING = 0x100, // ORed with MOUSE_ENTER...MOUSE_DOWN codes above

    MOUSE_HIT_TEST = 0xFFE, // sent to element, allows to handle elements with non-trivial shapes.
}

struct MOUSE_PARAMS
{
    UINT cmd; // MOUSE_EVENTS
    HELEMENT target; // target element
    POINT pos; // position of cursor, element relative
    POINT pos_view; // position of cursor, view relative
    UINT button_state; // MOUSE_BUTTONS
    UINT alt_state; // KEYBOARD_STATES
    UINT cursor_type; // CURSOR_TYPE to set, see CURSOR_TYPE
    SBOOL is_on_icon; // mouse is over icon (foreground-image, foreground-repeat:no-repeat)

    HELEMENT dragging; // element that is being dragged over, this field is not NULL if (cmd & DRAGGING) != 0
    UINT dragging_mode; // see DRAGGING_TYPE.
}

enum CURSOR_TYPE
{
    CURSOR_ARROW, //0
    CURSOR_IBEAM, //1
    CURSOR_WAIT, //2
    CURSOR_CROSS, //3
    CURSOR_UPARROW, //4
    CURSOR_SIZENWSE, //5
    CURSOR_SIZENESW, //6
    CURSOR_SIZEWE, //7
    CURSOR_SIZENS, //8
    CURSOR_SIZEALL, //9
    CURSOR_NO, //10
    CURSOR_APPSTARTING, //11
    CURSOR_HELP, //12
    CURSOR_HAND, //13
    CURSOR_DRAG_MOVE, //14
    CURSOR_DRAG_COPY, //15
}

// parameters of evtg == HANDLE_KEY

enum KEY_EVENTS
{
    KEY_DOWN = 0,
    KEY_UP,
    KEY_CHAR
}

struct KEY_PARAMS
{
    UINT cmd; // KEY_EVENTS
    HELEMENT target; // target element
    UINT key_code; // key scan code, or character unicode for KEY_CHAR
    UINT alt_state; // KEYBOARD_STATES
}

/** #HANDLE_FOCUS commands */
enum FOCUS_EVENTS
{
    FOCUS_OUT = 0, /**< container lost focus from any element inside it, target is an element that lost focus */
    FOCUS_IN = 1, /**< container got focus on element inside it, target is an element that got focus */
    FOCUS_GOT = 2, /**< target element got focus */
    FOCUS_LOST = 3, /**< target element lost focus */
    FOCUS_REQUEST = 4, /**< bubbling event/request, gets sent on child-parent chain to accept/reject focus to be set on the child (target) */
    FOCUS_ADVANCE_REQUEST = 5, /**< bubbling event/request, gets sent on child-parent chain to advance focus */



}

enum FOCUS_CMD_TYPE
{
    FOCUS_RQ_NEXT,
    FOCUS_RQ_PREV,
    FOCUS_RQ_HOME,
    FOCUS_RQ_END,
    FOCUS_RQ_LEFT,
    FOCUS_RQ_RIGHT,
    FOCUS_RQ_UP,
    FOCUS_RQ_DOWN, // all these - by key
    FOCUS_RQ_FIRST, // these two - by_code
    FOCUS_RQ_LAST, //
    FOCUS_RQ_END_REACHED = 0x8000
}

/** #HANDLE_FOCUS params */
struct FOCUS_PARAMS
{
    UINT cmd; /**< #FOCUS_EVENTS */
    HELEMENT target; /**< target element, for #FOCUS_LOST it is a handle of new focus element
                                     and for #FOCUS_GOT it is a handle of old focus element, can be NULL */
    UINT cause; /**< focus cause params or FOCUS_CMD_TYPE for FOCUS_ADVANCE_REQUEST */
    SBOOL cancel; /**< in #FOCUS_REQUEST and #FOCUS_LOST phase setting this field to true will cancel transfer focus from old element to the new one. */
}

// parameters of evtg == HANDLE_SCROLL

enum SCROLL_EVENTS
{
    SCROLL_HOME = 0,
    SCROLL_END,
    SCROLL_STEP_PLUS,
    SCROLL_STEP_MINUS,
    SCROLL_PAGE_PLUS,
    SCROLL_PAGE_MINUS,
    SCROLL_POS,
    SCROLL_SLIDER_RELEASED,
    SCROLL_CORNER_PRESSED,
    SCROLL_CORNER_RELEASED,
    SCROLL_SLIDER_PRESSED,

    SCROLL_ANIMATION_START,
    SCROLL_ANIMATION_END,
}

enum SCROLL_SOURCE
{
    SCROLL_SOURCE_UNKNOWN,
    SCROLL_SOURCE_KEYBOARD, // SCROLL_PARAMS::reason <- keyCode
    SCROLL_SOURCE_SCROLLBAR, // SCROLL_PARAMS::reason <- SCROLLBAR_PART
    SCROLL_SOURCE_ANIMATOR,
    SCROLL_SOURCE_WHEEL,
}

enum SCROLLBAR_PART
{
    SCROLLBAR_BASE,
    SCROLLBAR_PLUS,
    SCROLLBAR_MINUS,
    SCROLLBAR_SLIDER,
    SCROLLBAR_PAGE_MINUS,
    SCROLLBAR_PAGE_PLUS,
    SCROLLBAR_CORNER,
}

struct SCROLL_PARAMS
{
    UINT cmd; // SCROLL_EVENTS
    HELEMENT target; // target element
    INT pos; // scroll position if SCROLL_POS
    SBOOL vertical; // true if from vertical scrollbar
    UINT source; // SCROLL_SOURCE
    UINT reason; // key or scrollbar part
}

/*enum GESTURE_CMD
  {
    GESTURE_START = 0,
    GESTURE_MOVE = 1,
    GESTURE_END = 2,

    // logical events
    GESTURE_PAN,    // The pan gesture.
    GESTURE_ZOOM,        // The zoom gesture.
    GESTURE_ROTATE,      // The rotation gesture.
    GESTURE_TAP1,   // The tap gesture, a.k.a. click
    GESTURE_TAP2,   // The two-finger tap gesture, a.k.a. right-click
    GESTURE_DOUBLE_TAP
  }

  enum GESTURE_STATE
  {
    GESTURE_STATE_BEGIN   = 1, // starts
    GESTURE_STATE_INERTIA = 2, // events generated by inertia processor
    GESTURE_STATE_END     = 4, // end, last event of the gesture sequence
  }

  enum GESTURE_TYPE_FLAGS // requested
  {
    GESTURE_FLAG_ZOOM               = 0x0001,
    GESTURE_FLAG_ROTATE             = 0x0002,
    GESTURE_FLAG_PAN_VERTICAL       = 0x0004,
    GESTURE_FLAG_PAN_HORIZONTAL     = 0x0008,
    GESTURE_FLAG_TAP1               = 0x0010, // press & tap
    GESTURE_FLAG_TAP2               = 0x0020, // two fingers tap

    GESTURE_FLAG_PAN_WITH_GUTTER    = 0x4000, // PAN_VERTICAL and PAN_HORIZONTAL modifiers
    GESTURE_FLAG_PAN_WITH_INERTIA   = 0x8000, //
    GESTURE_FLAGS_ALL               = 0xFFFF, //
  }
  */

struct GESTURE_PARAMS
{
    UINT cmd; // GESTURE_EVENTS
    HELEMENT target; // target element
    POINT pos; // position of cursor, element relative
    POINT pos_view; // position of cursor, view relative
}

enum EXCHANGE_CMD
{
    X_DRAG_ENTER = 0, // drag enters the element
    X_DRAG_LEAVE = 1, // drag leaves the element
    X_DRAG = 2, // drag over the element
    X_DROP = 3, // data dropped on the element
    X_PASTE = 4, // N/A
    X_DRAG_REQUEST = 5, // N/A
    X_DRAG_CANCEL = 6, // drag cancelled (e.g. by pressing VK_ESCAPE)
    X_WILL_ACCEPT_DROP = 7, // drop target element shall consume this event in order to receive X_DROP
}

enum DD_MODES
{
    DD_MODE_NONE = 0, // DROPEFFECT_NONE	( 0 )
    DD_MODE_COPY = 1, // DROPEFFECT_COPY	( 1 )
    DD_MODE_MOVE = 2, // DROPEFFECT_MOVE	( 2 )
    DD_MODE_COPY_OR_MOVE = 3, // DROPEFFECT_COPY	( 1 ) | DROPEFFECT_MOVE	( 2 )
    DD_MODE_LINK = 4, // DROPEFFECT_LINK	( 4 )
}

struct EXCHANGE_PARAMS
{
    UINT cmd; // EXCHANGE_EVENTS
    HELEMENT target; // target element
    HELEMENT source; // source element (can be null if D&D from external window)
    POINT pos; // position of cursor, element relative
    POINT pos_view; // position of cursor, view relative
    UINT mode; // DD_MODE
    SCITER_VALUE data; // packaged drag data
}

enum DRAW_EVENTS
{
    DRAW_BACKGROUND = 0,
    DRAW_CONTENT = 1,
    DRAW_FOREGROUND = 2,
    DRAW_OUTLINE = 3,
}

struct SCITER_GRAPHICS;

struct DRAW_PARAMS
{
    UINT cmd; // DRAW_EVENTS
    HGFX gfx; // hdc to paint on
    RECT area; // element area, to get invalid area to paint use GetClipBox,
    UINT reserved; // for DRAW_BACKGROUND/DRAW_FOREGROUND - it is a border box
    // for DRAW_CONTENT - it is a content box
}

enum CONTENT_CHANGE_BITS
{ // for CONTENT_CHANGED reason
    CONTENT_ADDED = 0x01,
    CONTENT_REMOVED = 0x02,
}

enum BEHAVIOR_EVENTS
{
    BUTTON_CLICK = 0, // click on button
    BUTTON_PRESS = 1, // mouse down or key down in button

    VALUE_CHANGED = 2, // value 
    VALUE_CHANGING = 3, // before text change

    SELECTION_CHANGED = 5, // selection changed in <select>, <textarea>, etc
    SELECTION_CHANGING = 0xC, // selection is changeing in <select>, <textarea>, etc

    POPUP_REQUEST = 7, // request to show popup just received,
    //     here DOM of popup element can be modifed.
    POPUP_READY = 8, // popup element has been measured and ready to be shown on screen,
    //     here you can use functions like ScrollToView.
    POPUP_DISMISSED = 9, // popup element is closed,
    //     here DOM of popup element can be modifed again - e.g. some items can be removed
    //     to free memory.

    MENU_ITEM_ACTIVE = 0xA, // menu item activated by mouse hover or by keyboard,
    MENU_ITEM_CLICK = 0xB, // menu item click,
    //   BEHAVIOR_EVENT_PARAMS structure layout
    //   BEHAVIOR_EVENT_PARAMS.cmd - MENU_ITEM_CLICK/MENU_ITEM_ACTIVE
    //   BEHAVIOR_EVENT_PARAMS.heTarget - owner(anchor) of the menu
    //   BEHAVIOR_EVENT_PARAMS.he - the menu item, presumably <li> element
    //   BEHAVIOR_EVENT_PARAMS.reason - BY_MOUSE_CLICK | BY_KEY_CLICK

    CONTEXT_MENU_REQUEST = 0x10, // "right-click", BEHAVIOR_EVENT_PARAMS::he is current popup menu HELEMENT being processed or NULL.
    // application can provide its own HELEMENT here (if it is NULL) or modify current menu element.

    VISUAL_STATUS_CHANGED = 0x11, // sent to the element being shown or hidden
    DISABLED_STATUS_CHANGED = 0x12, // broadcast notification, sent to all elements of some container that got new value of :disabled state

    POPUP_DISMISSING = 0x13, // popup is about to be closed

    CONTENT_CHANGED = 0x15, // content has been changed, is posted to the element that gets content changed,  reason is combination of CONTENT_CHANGE_BITS.
    // target == NULL means the window got new document and this event is dispatched only to the window.

    // "grey" event codes  - notfications from behaviors from this SDK
    HYPERLINK_CLICK = 0x80, // hyperlink click

    ELEMENT_COLLAPSED = 0x90, // element was collapsed, so far only behavior:tabs is sending these two to the panels
    ELEMENT_EXPANDED = 0x91, // element was expanded,

    ACTIVATE_CHILD = 0x92, // activate (select) child,
    // used for example by accesskeys behaviors to send activation request, e.g. tab on behavior:tabs.

    FORM_SUBMIT = 0x96, // behavior:form detected submission event. BEHAVIOR_EVENT_PARAMS::data field contains data to be posted.
    // BEHAVIOR_EVENT_PARAMS::data is of type T_MAP in this case key/value pairs of data that is about
    // to be submitted. You can modify the data or discard submission by returning true from the handler.
    FORM_RESET = 0x97, // behavior:form detected reset event (from button type=reset). BEHAVIOR_EVENT_PARAMS::data field contains data to be reset.
    // BEHAVIOR_EVENT_PARAMS::data is of type T_MAP in this case key/value pairs of data that is about
    // to be rest. You can modify the data or discard reset by returning true from the handler.

    DOCUMENT_COMPLETE = 0x98, // document in behavior:frame or root document is complete.

    HISTORY_PUSH = 0x99, // requests to behavior:history (commands)
    HISTORY_DROP = 0x9A,
    HISTORY_PRIOR = 0x9B,
    HISTORY_NEXT = 0x9C,
    HISTORY_STATE_CHANGED = 0x9D, // behavior:history notification - history stack has changed

    CLOSE_POPUP = 0x9E, // close popup request,
    REQUEST_TOOLTIP = 0x9F, // request tooltip, evt.source <- is the tooltip element.

    ANIMATION = 0xA0, // animation started (reason=1) or ended(reason=0) on the element.
    TRANSITION = 0xA1, // transition started (reason=1) or ended(reason=0) on the element.
    SWIPE = 0xB0, // swipe gesture detected, reason=4,8,2,6 - swipe direction, only from behavior:swipe-touch

    DOCUMENT_CREATED = 0xC0, // document created, script namespace initialized. target -> the document
    DOCUMENT_CLOSE_REQUEST = 0xC1, // document is about to be closed, to cancel closing do: evt.data = sciter::value("cancel");
    DOCUMENT_CLOSE = 0xC2, // last notification before document removal from the DOM
    DOCUMENT_READY = 0xC3, // document has got DOM structure, styles and behaviors of DOM elements. Script loading run is complete at this moment.
    DOCUMENT_PARSED = 0xC4, // document just finished parsing - has got DOM structure. This event is generated before DOCUMENT_READY
    //DOCUMENT_RELOAD        = 0xC5, // request to reload the document
    DOCUMENT_CLOSING = 0xC6, // view::notify_close
    CONTAINER_CLOSE_REQUEST = 0xC7, // window of host document is processing DOCUMENT_CLOSE_REQUEST
    CONTAINER_CLOSING = 0xC8, // window of host document is processing DOCUMENT_CLOSING

    VIDEO_INITIALIZED = 0xD1, // <video> "ready" notification
    VIDEO_STARTED = 0xD2, // <video> playback started notification
    VIDEO_STOPPED = 0xD3, // <video> playback stoped/paused notification
    VIDEO_BIND_RQ = 0xD4, // <video> request for frame source binding,
    //   If you want to provide your own video frames source for the given target <video> element do the following:
    //   1. Handle and consume this VIDEO_BIND_RQ request
    //   2. You will receive second VIDEO_BIND_RQ request/event for the same <video> element
    //      but this time with the 'reason' field set to an instance of sciter::video_destination interface.
    //   3. add_ref() it and store it for example in worker thread producing video frames.
    //   4. call sciter::video_destination::start_streaming(...) providing needed parameters
    //      call sciter::video_destination::render_frame(...) as soon as they are available
    //      call sciter::video_destination::stop_streaming() to stop the rendering (a.k.a. end of movie reached)

    VIDEO_SOURCE_CREATED = 0xD5,

    VIDEO_FRAME_REQUEST = 0xD8, // animation step, a.k.a. animation frame

    PAGINATION_STARTS = 0xE0, // behavior:pager starts pagination
    PAGINATION_PAGE = 0xE1, // behavior:pager paginated page no, reason -> page no
    PAGINATION_ENDS = 0xE2, // behavior:pager end pagination, reason -> total pages

    CUSTOM = 0xF0, // event with custom name

    EGL_RENDER = 0x20, //  

    FIRST_APPLICATION_EVENT_CODE = 0x100 // all custom event codes shall be greater
    // than this number. All codes below this will be used
    // solely by application - Sciter will not intrepret it
    // and will do just dispatching.
    // To send event notifications with  these codes use
    // SciterSend/PostEvent API.
}

enum CLICK_REASON
{
    BY_MOUSE_CLICK,
    BY_KEY_CLICK,
    SYNTHESIZED, // synthesized, programmatically generated.
    BY_MOUSE_ON_ICON,
}

enum EDIT_CHANGED_REASON
{
    BY_INS_CHAR, // single char insertion
    BY_INS_CHARS, // character range insertion, clipboard
    BY_DEL_CHAR, // single char deletion
    BY_DEL_CHARS, // character range deletion (selection)
    BY_UNDO_REDO, // undo/redo
}

struct BEHAVIOR_EVENT_PARAMS
{
    UINT cmd; // BEHAVIOR_EVENTS
    HELEMENT heTarget; // target element handler, in MENU_ITEM_CLICK this is owner element that caused this menu - e.g. context menu owner
    // In scripting this field named as Event.owner
    HELEMENT he; // source element e.g. in SELECTION_CHANGED it is new selected <option>, in MENU_ITEM_CLICK it is menu item (LI) element
    UINT_PTR reason; // CLICK_REASON or EDIT_CHANGED_REASON - UI action causing change.
    // In case of custom event notifications this may be any
    // application specific value.
    SCITER_VALUE data; // auxiliary data accompanied with the event. E.g. FORM_SUBMIT event is using this field to pass collection of values.

    LPCWSTR name; // name of custom event (when cmd == CUSTOM)
}

struct TIMER_PARAMS
{
    UINT* timerId; // timerId that was used to create timer by using SciterSetTimer
}

// identifiers of methods currently supported by intrinsic behaviors,
// see function SciterCallBehaviorMethod

enum BEHAVIOR_METHOD_IDENTIFIERS
{
    DO_CLICK = 0,

    SET_CURRENT_GL_CONTEXT = 0x10,
    RELEASE_CURRENT_GL_CONTEXT = 0x11,

    IS_EMPTY = 0xFC, // p - IS_EMPTY_PARAMS // set VALUE_PARAMS::is_empty (false/true) reflects :empty state of the element.
    GET_VALUE = 0xFD, // p - VALUE_PARAMS
    SET_VALUE = 0xFE, // p - VALUE_PARAMS

    FIRST_APPLICATION_METHOD_ID = 0x100
}

struct SCRIPTING_METHOD_PARAMS
{
    LPCSTR name; ///< method name
    const(SCITER_VALUE)* argv; ///< vector of arguments
    UINT argc; ///< argument count
    SCITER_VALUE result; ///< return value
}

// GET_VALUE/SET_VALUE methods params
struct VALUE_PARAMS
{
    UINT methodID;
    SCITER_VALUE val;
}

// IS_EMPTY method params
struct IS_EMPTY_PARAMS
{
    UINT methodID;
    UINT is_empty; // !0 - is empty
}

// see SciterRequestElementData

struct DATA_ARRIVED_PARAMS
{
    HELEMENT initiator; // element intiator of SciterRequestElementData request,
    LPCBYTE data; // data buffer
    UINT dataSize; // size of data
    UINT dataType; // data type passed "as is" from SciterRequestElementData
    UINT status; // status = 0 (dataSize == 0) - unknown error.
    // status = 100..505 - http response status, Note: 200 - OK!
    // status > 12000 - wininet error code, see ERROR_INTERNET_*** in wininet.h
    LPCWSTR uri; // requested url
}

struct ATTRIBUTE_CHANGE_PARAMS
{
    HELEMENT he; // this element
    LPCSTR name; // attribute name
    LPCWSTR value; // new attribute value, NULL if attribute was deleted
}
