//! The C API of Sciter: the DOM handles and their types, as in sciter-x-dom.h.
module sciter.capi.dom;

import sciter.capi.types;
import sciter.capi.behavior : ElementEventProc;

/** DOM element handle. */
alias HELEMENT = void*;
alias HNODE = void*;
alias HRANGE = void*;

struct HPOSITION
{
    HNODE hn;
    INT pos;
}

alias HSARCHIVE = void*;

alias SCDOM_RESULT = INT;

enum SCDOM_OK = 0;
enum SCDOM_INVALID_HWND = 1;
enum SCDOM_INVALID_HANDLE = 2;
enum SCDOM_PASSIVE_HANDLE = 3;
enum SCDOM_INVALID_PARAMETER = 4;
enum SCDOM_OPERATION_FAILED = 5;
enum SCDOM_OK_NOT_HANDLED = -1;

struct METHOD_PARAMS
{
    UINT methodID;
}

struct REQUEST_PARAM
{
    LPCWSTR name;
    LPCWSTR value;
}

alias ELEMENT_COMPARATOR = extern (C) INT function(HELEMENT he1, HELEMENT he2, void* param);

enum ELEMENT_AREAS
{
    ROOT_RELATIVE = 0x01, // - or this flag if you want to get Sciter window relative coordinates,
    //   otherwise it will use nearest windowed container e.g. popup window.
    SELF_RELATIVE = 0x02, // - "or" this flag if you want to get coordinates relative to the origin
    //   of element iself.
    CONTAINER_RELATIVE = 0x03, // - position inside immediate container.
    VIEW_RELATIVE = 0x04, // - position relative to view - Sciter window

    CONTENT_BOX = 0x00, // content (inner)  box
    PADDING_BOX = 0x10, // content + paddings
    BORDER_BOX = 0x20, // content + paddings + border
    MARGIN_BOX = 0x30, // content + paddings + border + margins

    BACK_IMAGE_AREA = 0x40, // relative to content origin - location of background image (if it set no-repeat)
    FORE_IMAGE_AREA = 0x50, // relative to content origin - location of foreground image (if it set no-repeat)

    SCROLLABLE_AREA = 0x60, // scroll_area - scrollable area in content box

    AS_PPX = 0x8000,

}

alias SciterGetElementLocation = extern (C) SCDOM_RESULT function(HELEMENT he, RECT* p_location, UINT areas /*ELEMENT_AREAS*/ );

enum SCITER_SCROLL_FLAGS
{
    SCROLL_TO_TOP = 0x01,
    SCROLL_SMOOTH = 0x10,
}

/**Callback function used with #SciterVisitElement().*/
alias SciterElementCallback = extern (C) SBOOL function(HELEMENT he, void* param);

enum SET_ELEMENT_HTML
{
    SIH_REPLACE_CONTENT = 0,
    SIH_INSERT_AT_START = 1,
    SIH_APPEND_AFTER_LAST = 2,
    SOH_REPLACE = 3,
    SOH_INSERT_BEFORE = 4,
    SOH_INSERT_AFTER = 5
}

//alias ElementEventProc = extern (C) SBOOL function(void* tag, HELEMENT he, UINT evtg, void* prms);

enum ELEMENT_STATE_BITS
{
    STATE_LINK = 0x00000001, // :link pseudo-class in CSS
    STATE_HOVER = 0x00000002, // :hover pseudo-class in CSS
    STATE_ACTIVE = 0x00000004, // :active pseudo-class in CSS
    STATE_FOCUS = 0x00000008, // :focus pseudo-class in CSS
    STATE_VISITED = 0x00000010, // :visited pseudo-class in CSS
    STATE_CURRENT = 0x00000020, // :current, current (hot) item
    STATE_CHECKED = 0x00000040, // :checked, element is checked (or selected)
    STATE_DISABLED = 0x00000080, // :disabled, element is disabled
    STATE_READONLY = 0x00000100, // :read-only, readonly input element
    STATE_EXPANDED = 0x00000200, // :expanded, expanded state - nodes in tree view
    STATE_COLLAPSED = 0x00000400, // :collapsed, collapsed state - nodes in tree view - mutually exclusive with
    STATE_INCOMPLETE = 0x00000800, // :incomplete, fore (content) image was requested but not delivered
    STATE_ANIMATING = 0x00001000, // :animating, is animating currently
    STATE_FOCUSABLE = 0x00002000, // :focusable, will accept focus
    STATE_ANCHOR = 0x00004000, // :anchor, anchor in selection (used with current in selects)
    STATE_SYNTHETIC = 0x00008000, // :synthetic, this is a synthetic element - don't emit it's head/tail
    STATE_OWNS_POPUP = 0x00010000, // :owns-popup, has visible popup element (tooltip, menu, etc.) 
    STATE_TABFOCUS = 0x00020000, // :tab-focus, focus gained by tab traversal
    STATE_EMPTY = 0x00040000, // :empty, empty - element is empty (text.size() == 0 && subs.size() == 0)
    //  if element has behavior attached then the behavior is responsible for the value of this flag.
    STATE_BUSY = 0x00080000, // :busy, busy doing something (e.g. loading data)

    STATE_DRAG_OVER = 0x00100000, // drag over the block that can accept it (so is current drop target). Flag is set for the drop target block
    STATE_DROP_TARGET = 0x00200000, // active drop target.
    STATE_MOVING = 0x00400000, // dragging/moving - the flag is set for the moving block.
    STATE_COPYING = 0x00800000, // dragging/copying - the flag is set for the copying block.
    STATE_DRAG_SOURCE = 0x01000000, // element that is a drag source.
    STATE_DROP_MARKER = 0x02000000, // element is drop marker

    STATE_PRESSED = 0x04000000, // pressed - close to active but has wider life span - e.g. in MOUSE_UP it
    //   is still on; so behavior can check it in MOUSE_UP to discover MOUSE_CLICK condition.
    STATE_POPUP = 0x08000000, // :popup, this element is out of flow - shown as popup

    STATE_IS_LTR = 0x10000000, // the element or one of its containers has dir=ltr declared
    STATE_IS_RTL = 0x20000000, // the element or one of its containers has dir=rtl declared
}

enum REQUEST_TYPE
{
    GET_ASYNC, // async GET
    POST_ASYNC, // async POST
    GET_SYNC, // synchronous GET
    POST_SYNC // synchronous POST
}

enum CTL_TYPE
{
    CTL_NO = 0, ///< This dom element has no behavior at all.
    CTL_UNKNOWN = 1, ///< This dom element has behavior but its type is unknown.

    CTL_EDIT = 2, ///< Single line edit box.
    CTL_NUMERIC = 3, ///< Numeric input with optional spin buttons.
    CTL_CLICKABLE = 4, ///< toolbar button, behavior:clickable.
    CTL_BUTTON = 5, ///< Command button.
    CTL_CHECKBOX = 6, ///< CheckBox (button).
    CTL_RADIO = 7, ///< OptionBox (button).
    CTL_SELECT_SINGLE = 8, ///< Single select, ListBox or TreeView.
    CTL_SELECT_MULTIPLE = 9, ///< Multiselectable select, ListBox or TreeView.
    CTL_DD_SELECT = 10, ///< Dropdown single select.
    CTL_TEXTAREA = 11, ///< Multiline TextBox.
    CTL_HTML_SELECTION = 12, ///< HTML selection behavior.
    CTL_PASSWORD = 13, ///< Password input element.
    CTL_PROGRESS = 14, ///< Progress element.
    CTL_SLIDER = 15, ///< Slider input element.  
    CTL_DECIMAL = 16, ///< Decimal number input element.
    CTL_CURRENCY = 17, ///< Currency input element.
    CTL_SCROLLBAR = 18,
    CTL_LIST = 19,
    CTL_HTMLAREA = 20,
    CTL_CALENDAR = 21,
    CTL_DATE = 22,
    CTL_TIME = 23,
    CTL_FILE = 24, ///< file input element.
    CTL_PATH = 25, ///< path input element.

    CTL_HYPERLINK = 26,
    CTL_FORM = 27,

    CTL_MENUBAR = 28,
    CTL_MENU = 29,
    CTL_MENUBUTTON = 30,

    CTL_FRAME = 31,
    CTL_FRAMESET = 32,

    CTL_TOOLTIP = 33,

    CTL_HIDDEN = 34,
    CTL_URL = 35, ///< URL input element.
    CTL_TOOLBAR = 36,

    CTL_WINDOW = 37, ///< has HWND attached to it

    CTL_LABEL = 38,
    CTL_IMAGE = 39, ///< image/video object.  
    CTL_PLAINTEXT = 40, ///< Multiline TextBox + colorizer.

    CTL_SELECT_TREE = 41, ///< TreeView.
}

enum NODE_TYPE
{
    NT_ELEMENT,
    NT_TEXT,
    NT_COMMENT
}

enum NODE_INS_TARGET
{
    NIT_BEFORE,
    NIT_AFTER,
    NIT_APPEND,
    NIT_PREPEND,
}
