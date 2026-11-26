//! The C API of Sciter: the definitions of sciter-x-def.h (callbacks, notifications,
//! options), for 64-bit systems only.
module sciter.capi.def;

import core.stdc.stdint;
import sciter.capi.types;
import sciter.capi.request;
import sciter.capi.behavior;

// The functions and callbacks of the binding are extern (C): right on 64-bit systems only.
// On 32-bit Windows Sciter's are __stdcall, and a callback would corrupt the stack.
static assert(size_t.sizeof == 8, "the Sciter binding is for 64-bit systems only");

/** #SC_LOAD_DATA notification return codes */
enum SC_LOAD_DATA_RETURN_CODES
{
    LOAD_OK = 0, /**< do default loading if data not set */
    LOAD_DISCARD = 1, /**< discard request completely */
    LOAD_DELAYED = 2, /**< data will be delivered later by the host application.
                         Host application must call SciterDataReadyAsync(,,, requestId) on each LOAD_DELAYED request to avoid memory leaks. */
    LOAD_MYSELF = 3, /**< you return LOAD_MYSELF result to indicate that your (the host) application took or will take care about HREQUEST in your code completely.
                         Use sciter-x-request.h[pp] API functions with SCN_LOAD_DATA::requestId handle . */



}

/**Notifies that Sciter is about to download a referred resource.
 *
 * \param lParam #LPSCN_LOAD_DATA.
 * \return #SC_LOAD_DATA_RETURN_CODES
 *
 * This notification gives application a chance to override built-in loader and
 * implement loading of resources in its own way (for example images can be loaded from
 * database or other resource). To do this set #SCN_LOAD_DATA::outData and
 * #SCN_LOAD_DATA::outDataSize members of SCN_LOAD_DATA. Sciter does not
 * store pointer to this data. You can call #SciterDataReady() function instead
 * of filling these fields. This allows you to free your outData buffer
 * immediately.
**/
enum SC_LOAD_DATA = 0x01;

/**This notification indicates that external data (for example image) download process
 * completed.
 *
 * \param lParam #LPSCN_DATA_LOADED
 *
 * This notifiaction is sent for each external resource used by document when
 * this resource has been completely downloaded. Sciter will send this
 * notification asynchronously.
 **/
enum SC_DATA_LOADED = 0x02;

/**This notification is sent when all external data (for example image) has been downloaded.
 *
 * This notification is sent when all external resources required by document
 * have been completely downloaded. Sciter will send this notification
 * asynchronously.
 **/
/* obsolete #define SC_DOCUMENT_COMPLETE 0x03
   use DOCUMENT_COMPLETE DOM event.
  */

/**This notification is sent on parsing the document and while processing
 * elements having non empty style.behavior attribute value.
 *
 * \param lParam #LPSCN_ATTACH_BEHAVIOR
 *
 * Application has to provide implementation of #sciter::behavior interface.
 * Set #SCN_ATTACH_BEHAVIOR::impl to address of this implementation.
 **/
enum SC_ATTACH_BEHAVIOR = 0x04;

/**This notification is sent when instance of the engine is destroyed.
 * It is always final notification.
 *
 * \param lParam #LPSCN_ENGINE_DESTROYED
 *
 **/
enum SC_ENGINE_DESTROYED = 0x05;

/**Posted notification.
 
 * \param lParam #LPSCN_POSTED_NOTIFICATION
 *
 **/
enum SC_POSTED_NOTIFICATION = 0x06;

/**This notification is sent when the engine encounters critical rendering error: e.g. DirectX gfx driver error.
   Most probably bad gfx drivers.
 
 * \param lParam #LPSCN_GRAPHICS_CRITICAL_FAILURE
 *
 **/
enum SC_GRAPHICS_CRITICAL_FAILURE = 0x07;

/**This notification is sent when the engine needs keyboard to be present on screen
   E.g. when <input|text> gets focus

 * \param lParam #LPSCN_KEYBOARD_REQUEST
 *
 **/
enum SC_KEYBOARD_REQUEST = 0x08;

/**This notification is sent when the engine needs some area to be redrawn
 
 * \param lParam #LPSCN_INVLIDATE_RECT
 *
 **/
enum SC_INVALIDATE_RECT = 0x09;

/**This notification is sent when the engine needs some area to be redrawn

  * \param lParam #LPSCN_SET_CURSOR
  *
  **/
enum SC_SET_CURSOR = 0x0A;

/**Notification callback structure.
 **/
struct SCITER_CALLBACK_NOTIFICATION
{
    UINT code; /**< [in] one of the codes above.*/
    HWINDOW hwnd; /**< [in] HWINDOW of the window this callback was attached to.*/
}

alias SciterHostCallback = extern (C) UINT function(SCITER_CALLBACK_NOTIFICATION* pns, void* callbackParam);

/**This structure is used by #SC_LOAD_DATA notification.
 *\copydoc SC_LOAD_DATA
 **/

struct SCN_LOAD_DATA
{
    UINT code; /**< [in] one of the codes above.*/
    HWINDOW hwnd; /**< [in] HWINDOW of the window this callback was attached to.*/

    LPCWSTR uri; /**< [in] Zero terminated string, fully qualified uri, for example "http://server/folder/file.ext".*/

    LPCBYTE outData; /**< [in,out] pointer to loaded data to return. if data exists in the cache then this field contain pointer to it*/
    UINT outDataSize; /**< [in,out] loaded data size to return.*/
    UINT dataType; /**< [in] SciterResourceType */

    HREQUEST requestId; /**< [in] request handle that can be used with sciter-x-request API */

    HELEMENT principal;
    HELEMENT initiator;
}

/**This structure is used by #SC_DATA_LOADED notification.
 *\copydoc SC_DATA_LOADED
 **/
struct SCN_DATA_LOADED
{
    UINT code; /**< [in] one of the codes above.*/
    HWINDOW hwnd; /**< [in] HWINDOW of the window this callback was attached to.*/

    LPCWSTR uri; /**< [in] zero terminated string, fully qualified uri, for example "http://server/folder/file.ext".*/
    LPCBYTE data; /**< [in] pointer to loaded data.*/
    UINT dataSize; /**< [in] loaded data size (in bytes).*/
    UINT dataType; /**< [in] SciterResourceType */
    UINT status; /**< [in]
                                         status = 0 (dataSize == 0) - unknown error.
                                         status = 100..505 - http response status, Note: 200 - OK!
                                         status > 12000 - wininet error code, see ERROR_INTERNET_*** in wininet.h
                                 */
    HREQUEST requestId; /**< [in] request handle that can be used with sciter-x-request API */
}

/**This structure is used by #SC_ATTACH_BEHAVIOR notification.
 *\copydoc SC_ATTACH_BEHAVIOR **/
struct SCN_ATTACH_BEHAVIOR
{
    UINT code; /**< [in] one of the codes above.*/
    HWINDOW hwnd; /**< [in] HWINDOW of the window this callback was attached to.*/

    HELEMENT element; /**< [in] target DOM element handle*/
    LPCSTR behaviorName; /**< [in] zero terminated string, string appears as value of CSS behavior:"???" attribute.*/

    // not `ElementEventProc*`: the C type is a function, the D alias is already a pointer to one
    ElementEventProc elementProc; /**< [out] pointer to ElementEventProc function.*/
    void* elementTag; /**< [out] tag value, passed as is into pointer ElementEventProc function.*/

}

/**This structure is used by #SC_ENGINE_DESTROYED notification.
 *\copydoc SC_ENGINE_DESTROYED **/
struct SCN_ENGINE_DESTROYED
{
    UINT code; /**< [in] one of the codes above.*/
    HWINDOW hwnd; /**< [in] HWINDOW of the window this callback was attached to.*/
}

/**This structure is used by #SC_ENGINE_DESTROYED notification.
 *\copydoc SC_ENGINE_DESTROYED **/
struct SCN_POSTED_NOTIFICATION
{
    UINT code; /**< [in] one of the codes above.*/
    HWINDOW hwnd; /**< [in] HWINDOW of the window this callback was attached to.*/
    UINT_PTR wparam;
    UINT_PTR lparam;
    UINT_PTR lreturn;
}

/**This structure is used by #SC_GRAPHICS_CRITICAL_FAILURE notification.
 *\copydoc SC_GRAPHICS_CRITICAL_FAILURE **/
struct SCN_GRAPHICS_CRITICAL_FAILURE
{
    UINT code; /**< [in] = SC_GRAPHICS_CRITICAL_FAILURE */
    HWINDOW hwnd; /**< [in] HWINDOW of the window this callback was attached to.*/
}

/**This structure is used by #SC_KEYBOARD_REQUEST notification.
 *\copydoc SC_KEYBOARD_REQUEST **/
struct SCN_KEYBOARD_REQUEST
{
    UINT code; /**< [in] = SC_KEYBOARD_REQUEST */
    HWINDOW hwnd; /**< [in] HWINDOW of the window this callback was attached to.*/
    LPCSTR keyboardType; /**< [in] see: https://developer.android.com/reference/android/widget/TextView#attr_android:inputType */
}

/**This structure is used by #SC_INVALIDATE_RECT notification.
 *\copydoc SC_INVALIDATE_RECT **/
struct SCN_INVALIDATE_RECT
{
    UINT code; /**< [in] = SC_INVALIDATE_RECT */
    HWINDOW hwnd; /**< [in] HWINDOW of the window this callback was attached to.*/
    RECT invalidRect; /**< [in] cumulative invalid rect.*/
}

/**This structure is used by #SC_SET_CURSOR notification.
 *\copydoc SC_SET_CURSOR **/
struct SCN_SET_CURSOR
{
    UINT code; /**< [in] = SC_SET_CURSOR */
    HWINDOW hwnd; /**< [in] HWINDOW of the window this callback was attached to.*/
    UINT cursorId; /**< [in] #CURSOR_TYPE, if cursorUrl == NULL */
    LPCSTR cursorUrl; /**< [in] cursor URL */
}

// Methods ...

enum SCRIPT_RUNTIME_FEATURES
{
    ALLOW_FILE_IO = 0x00000001,
    ALLOW_SOCKET_IO = 0x00000002,
    ALLOW_EVAL = 0x00000004,
    ALLOW_SYSINFO = 0x00000008,
    ALLOW_CMODULES = 0x00000010
}

enum SCITER_RT_OPTIONS
{
    SCITER_SMOOTH_SCROLL = 1, // value:TRUE - enable, value:FALSE - disable, enabled by default
    SCITER_CONNECTION_TIMEOUT = 2, // value: milliseconds, connection timeout of http client
    SCITER_HTTPS_ERROR = 3, // value: 0 - drop connection, 1 - use builtin dialog, 2 - accept connection silently
    SCITER_FONT_SMOOTHING = 4, // value: 0 - system default, 1 - no smoothing, 2 - std smoothing, 3 - clear type

    SCITER_TRANSPARENT_WINDOW = 6, // Windows Aero support, value:
    // 0 - normal drawing,
    // 1 - window has transparent background after calls DwmExtendFrameIntoClientArea() or DwmEnableBlurBehindWindow().
    SCITER_SET_GPU_BLACKLIST = 7, // hWnd = NULL,
    // value = LPCBYTE, json - GPU black list, see: gpu-blacklist.json resource.
    SCITER_SET_SCRIPT_RUNTIME_FEATURES = 8, // value - combination of SCRIPT_RUNTIME_FEATURES flags.
    SCITER_SET_GFX_LAYER = 9, // hWnd = NULL, value - GFX_LAYER
    SCITER_SET_DEBUG_MODE = 10, // hWnd, value - TRUE/FALSE
    SCITER_SET_UX_THEMING = 11, // hWnd = NULL, value - SBOOL, TRUE - the engine will use "unisex" theme that is common for all platforms. 
    // That UX theme is not using OS primitives for rendering input elements. Use it if you want exactly
    // the same (modulo fonts) look-n-feel on all platforms.

    SCITER_ALPHA_WINDOW = 12, //  hWnd, value - TRUE/FALSE - window uses per pixel alpha (e.g. WS_EX_LAYERED/UpdateLayeredWindow() window)

    SCITER_SET_INIT_SCRIPT = 13, // hWnd - N/A , value LPCSTR - UTF-8 encoded script source to be loaded into each view before any other script execution.
    //                             The engine copies this string inside the call.

    SCITER_SET_MAIN_WINDOW = 14, //  hWnd, value - TRUE/FALSE - window is main, will destroy all other dependent windows on close

    SCITER_SET_MAX_HTTP_DATA_LENGTH = 15, // hWnd - N/A , value - max request length in megabytes (1024*1024 bytes)

    SCITER_SET_PX_AS_DIP = 16, // value 1 - 1px in CSS is treated as 1dip, value 0 - default behavior - 1px is a physical pixel 

    SCITER_ENABLE_UIAUTOMATION = 17, // hWnd - N/A , TRUE/FALSE, enables UIAutomation support. 

    SCITER_USE_INTERNAL_HTTP_CLIENT = 18, // hWnd - N/A , TRUE - use internal HTTP client
    //              FALSE - use system HTTP client (on platforms that has it: Win,Mac,Lin)
    SCITER_EXTENDED_TOUCHPAD_SUPPORT = 19, // hWnd - N/A , TRUE/FALSE, enables/disables extended touchpad support, TRUE by default   

    SCITER_ENABLE_DIRECT_COMPOSITION = 20, // hWnd - N/A , TRUE/FALSE, enables DirectComposition on Windows 11. 
    //        TRUE by default on Windows 11. Set it to FALSE if window will host child windows.
    SCITER_SET_ROOT_CA = 21, // hWnd - N/A , const char* certificates, in format acceptable by mbedtls_x509_crt_parse()

    SCITER_ALLOW_DISPLAY_SLEEP_FULLSCREEN = 22, // hWnd - N/A , TRUE/FALSE, full screen windows prevent screen saver and display power-off.
    //        FALSE by default. Set it to TRUE before a window enters full screen mode to enable sleep mode.

}

/**Set various options.
 *
 * \param[in] hWnd \b HWINDOW, Sciter window handle.
 * \param[in] option \b UINT, id of the option, one of SCITER_RT_OPTIONS
 * \param[in] option \b UINT, value of the option.
 *
 **/
//SBOOL SCAPI SciterSetOption(HWINDOW hWnd, UINT option, UINT_PTR value );

/** Application related operations */

enum SCITER_APP_CMD
{
    SCITER_APP_STOP = 0, /// reuest to quit message pump loop
    SCITER_APP_LOOP = 1, /// run message pump loop until SCITER_APP_STOP or main window closure
    SCITER_APP_INIT = 2, /// pass argc/argv to application: p1 - argc, p2 - CHAR** argv 
    SCITER_APP_SHUTDOWN = 3, /// free resources of the application 
    SCITER_APP_RUN = 4, /// scapp mode: load JS and run message pump loop until SCITER_APP_STOP or main window closure, p1 - JS url, p2 - 0 or SciterPrimordialLoader; 
    SCITER_APP_LOOP_ITERATION = 6, /// does single message pump loop iteration, SCITER_APP_LOOP is essentially this:
    /// while( SciterExec(SCITER_APP_LOOP_ITERATION,0,0) );
    SCITER_APP_LOOP_HEARTBIT = 7, /// checks outstanding tasks and timers,
    /// like SCITER_APP_LOOP_ITERATION but without message processing 
}

/**
  * Sciter "Primordial" Loader used by SCITER_APP_RUN
  */
//SBOOL SciterPrimordialLoader(const WCHAR* url, LPCBYTE* out_pb, UINT* out_cb);

/** Perform application related operation
 *
 * \param[in] appCmd \b SCITER_APP_CMD, application wide command
 * \param[in] p1 \b UINT_PTR, first parameter 
 * \param[in] p2 \b UINT_PTR, second parameter
 *
 * Note: SciterExec(SCITER_APP_LOOP,0,0) will not return until main window is present or SCITER_APP_STOP received
 * 
 **/

//INT_PTR SCAPI SciterExec(UINT appCmd /*SCITER_APP_CMD*/, UINT_PTR p1, UINT_PTR p2);

enum SCITER_WINDOW_CMD
{
    SCITER_WINDOW_SET_STATE = 1, // p1 - SCITER_WINDOW_STATE, p2 - N/A
    SCITER_WINDOW_GET_STATE = 2, // p1 - N/A , p2 - N/A, returns SCITER_WINDOW_STATE
    SCITER_WINDOW_ACTIVATE = 3, // p1 - BOOL, true - bring_to_front , p2 - N/A
    SCITER_WINDOW_SET_PLACEMENT = 4, // p1 - const POINT*, position, p2 const SIZE* - dimension, in ppx, either one can be null
    SCITER_WINDOW_GET_PLACEMENT = 5, // p1 - POINT*, position, p2 SIZE* - dimension, in ppx, either one can be null

    SCITER_WINDOW_GET_VULKAN_ENVIRONMENT = 20, // p1 - &SciterVulkanEnvironment, p2 - sizeof(SciterVulkanEnvironment)
    SCITER_WINDOW_GET_VULKAN_CONTEXT = 21, // p1 - &SciterVulkanContext, p2 - sizeof(SciterVulkanContext)
    SCITER_WINDOW_SET_VULKAN_BRIDGE = 22, // p1 - SciterWindowVulkanBridge*, p2 - N/A
}

enum SCITER_WINDOW_STATE
{
    SCITER_WINDOW_STATE_CLOSED = 0, // not a window (SET_STATE: close it)
    SCITER_WINDOW_STATE_HIDDEN = 1,
    SCITER_WINDOW_STATE_SHOWN = 2,
    SCITER_WINDOW_STATE_MINIMIZED = 3,
    SCITER_WINDOW_STATE_MAXIMIZED = 4,
    SCITER_WINDOW_STATE_FULL_SCREEN = 5,
}

/** Perform window related operation
 *
 * \param[in] windowCmd \b SCITER_WINDOW_CMD, window related command
 * \param[in] p1 \b UINT_PTR, first parameter
 * \param[in] p2 \b UINT_PTR, second parameter
 *
 **/

//INT_PTR SCAPI SciterWindowExec(HWINDOW hwnd, UINT windowCmd /*SCITER_WINDOW_CMD*/, UINT_PTR p1, UINT_PTR p2);

/**Get current pixels-per-inch metrics of the Sciter window
 *
 * \param[in] hWndSciter \b HWINDOW, Sciter window handle.
 * \param[out] px \b PUINT, get ppi in horizontal direction.
 * \param[out] py \b PUINT, get ppi in vertical direction.
 *
 **/

//VOID SCAPI SciterGetPPI(HWINDOW hWndSciter, UINT* px, UINT* py);

/**Get "expando" of the view object
 *
 * \param[in] hWndSciter \b HWINDOW, Sciter window handle.
 * \param[out] pval \b VALUE*, expando as sciter::value.
 *
 **/

//SBOOL SCAPI SciterGetViewExpando( HWINDOW hwnd, VALUE* pval );

struct URL_DATA
{
    LPCSTR requestedUrl; // requested URL
    LPCSTR realUrl; // real URL data arrived from (after possible redirections)
    SciterResourceType requestedType; // requested data category: html, script, image, etc.
    LPCSTR httpHeaders; // if any
    LPCSTR mimeType; // mime type reported by server (if any)
    LPCSTR encoding; // data encoding (if any)
    LPCBYTE data;
    UINT dataLength;
}

alias URL_DATA_RECEIVER = extern (C) void function(const URL_DATA* pUrlData, void* param);

/** Get url resource data received by the engine
 *  Note: this function really works only if the engine is set to debug mode.
 *
 * \param[in] hWndSciter \b HWINDOW, Sciter window handle.
 * \param[in] receiver \b URL_DATA_RECEIVER, address of reciver callback.
 * \param[in] param \b LPVOID, param passed to callback as it is.
 * \param[in] url \b LPCSTR, optional, url of the data. If not provided the engine will list all loaded resources
 * \return \b SBOOL, \c TRUE if receiver is called at least once, FALSE otherwise.
 *
 **/

//SBOOL SCAPI SciterEnumUrlData(HWINDOW hWndSciter, URL_DATA_RECEIVER* receiver, void* param, LPCSTR url);

version (windows)
{

    /**Creates instance of Sciter Engine on window controlled by DirectX
*
* \param[in] hwnd \b HWINDOW, window handle to create Sciter on.
* \param[in] IDXGISwapChain \b pSwapChain,  reference of IDXGISwapChain created on the window.
* \return \b SBOOL, \c TRUE if engine instance is created, FALSE otherwise.
*
**/

    //SBOOL SCAPI SciterCreateOnDirectXWindow(HWINDOW hwnd, IUnknown* pSwapChain); // IDXGISwapChain

    /**Renders content of the document loaded into the window
* Optionally allows to render parts of document (separate DOM elements) as layers
*
* \param[in] hwnd \b HWINDOW, window handle to create Sciter on.
* \param[in] HELEMENT \b elementToRenderOrNull,  html element to render. If NULL then the engine renders whole document.
* \param[in] SBOOL \b frontLayer,  TRUE if elementToRenderOrNull is not NULL and this is the topmost layer.
* \return \b SBOOL, \c TRUE if layer was rendered successfully.
*
**/
    //SBOOL SCAPI SciterRenderOnDirectXWindow(HWINDOW hwnd, HELEMENT elementToRenderOrNull /* = NULL*/, SBOOL frontLayer /* = FALSE*/);

    /**Renders content of the document loaded to DXGI texture
* Optionally allows to render parts of document (separate DOM elements) as layers
*
* \param[in] HWINDOW \b hwnd, window handle to create Sciter on.
* \param[in] HELEMENT \b elementToRenderOrNull,  html element to render. If NULL then the engine renders whole document.
* \param[in] IDXGISurface \b surface, DirectX 2D texture to render in.
* \return \b SBOOL, \c TRUE if layer was rendered successfully.
*
**/
    //SBOOL SCAPI SciterRenderOnDirectXTexture(HWINDOW hwnd, HELEMENT elementToRenderOrNull, IUnknown* surface); // IDXGISurface

    /**Render document to ID2D1RenderTarget
 *
 * \param[in] hWndSciter \b HWINDOW, Sciter window handle.
 * \param[in] ID2D1RenderTarget \b prt, Direct2D render target.
 * \return \b SBOOL, \c TRUE if hBmp is 24bpp or 32bpp, FALSE otherwise.
 *
 **/

    //SBOOL SCAPI SciterRenderD2D(HWINDOW hWndSciter, IUnknown* /*ID2D1RenderTarget**/ prt);

    /** Obtain pointer to ID2D1Factory instance used by the engine:
 *
 * \param[in] ID2D1Factory \b **ppf, address of variable receiving pointer of ID2D1Factory.
 * \return \b SBOOL, \c TRUE if parameters are valid and *ppf was set by valid pointer.
 *
 * NOTE 1: ID2D1Factory returned by the function is "add-refed" - it is your responsibility to call Release() on it.
 * NOTE 2: *ppf variable shall be initialized to NULL before calling the function.
 *
 **/

    //SBOOL SCAPI     SciterD2DFactory(IUnknown** /*ID2D1Factory ***/ ppf);

    /** Obtain pointer to IDWriteFactory instance used by the engine:
 *
 * \param[in] IDWriteFactory \b **ppf, address of variable receiving pointer of IDWriteFactory.
 * \return \b SBOOL, \c TRUE if parameters are valid and *ppf was set by valid pointer.
 *
 * NOTE 1: IDWriteFactory returned by the function is "add-refed" - it is your responsibility to call Release() on it.
 * NOTE 2: *ppf variable shall be initialized to NULL before calling the function.
 *
 **/

    //SBOOL SCAPI     SciterDWFactory(IUnknown** /*IDWriteFactory ***/ ppf);
}

/** Get graphics capabilities of the system
 *
 * \pcaps[in] UINT* \b pcaps, address of variable receiving:
 *                             0 - no compatible graphics found;
 *                             1 - compatible graphics found but Direct2D will use WARP driver (software emulation);
 *                             2 - Direct2D will use hardware backend (best performance);
 * \return \b SBOOL, \c TRUE if pcaps is valid pointer.
 *
 **/

//SBOOL SCAPI     SciterGraphicsCaps(UINT* pcaps);

/** Set sciter home url.
 *  home url is used for resolving sciter: urls
 *  If you will set it like SciterSetHomeURL(hwnd,"http://sciter.com/modules/")
 *  then <script src="sciter:lib/root-extender.tis"> will load
 *  root-extender.tis from http://sciter.com/modules/lib/root-extender.tis
 *
 * \param[in] hWndSciter \b HWINDOW, Sciter window handle.
 * \param[in] baseUrl \b LPCWSTR, URL of sciter home.
 *
 **/

//SBOOL SCAPI     SciterSetHomeURL(HWINDOW hWndSciter, LPCWSTR baseUrl);

version (OSX)
{
    //HWINDOW SCAPI  SciterCreateNSView( LPRECT frame ); // returns NSView*
}

enum SCITER_CREATE_WINDOW_FLAGS
{
    SW_CHILD = (1 << 0), // child window only, if this flag is set all other flags ignored
    SW_TITLEBAR   = (1 << 1), // toplevel window, has titlebar
    SW_RESIZEABLE = (1 << 2), // has resizeable frame
    SW_TOOL       = (1 << 3), // is tool window
    SW_CONTROLS   = (1 << 4), // has minimize / maximize buttons
    //SW_GLASSY     = (1 << 5), // glassy window - supports "Acrylic" on Windows and "Vibrant" on MacOS. 
    SW_ALPHA = (1 << 6), // transparent window ( e.g. WS_EX_LAYERED on Windows )
    SW_MAIN = (1 << 7), // main window of the app, will terminate the app on close
    SW_POPUP = (1 << 8), // the window is created as topmost window.
    SW_ENABLE_DEBUG = (1 << 9), // make this window inspector ready
    //SW_OWNS_VM      = (1 << 10), // it has its own script VM
}

//#if !defined(WINDOWLESS)
/** Create sciter window.
 *  On Windows returns HWND of either top-level or child window created.
 *  On OS X returns NSView* of either top-level window or child view .
 *
 * \param[in] creationFlags \b SCITER_CREATE_WINDOW_FLAGS, creation flags.
 * \param[in] frame \b LPRECT, window frame position and size.
 * \param[in] reserved1 \b void*, not used, set to NULL
 * \param[in] reserved2 \b void*, not used, set to NULL
 * \param[in] parent \b HWINDOW, optional parent window.
 *
 **/
//HWINDOW SCAPI  SciterCreateWindow( UINT creationFlags,
//                                            LPRECT frame,
//                                            void* reserved1, /// set to NULL
//                                            void* reserved2, /// set to NULL
//                                            HWINDOW parent);

// #endif

/** SciterSetupDebugOutput - setup debug output function.
 *
 *  This output function will be used for reprting problems
 *  found while loading html and css documents.
 *
 **/

enum OUTPUT_SUBSYTEMS
{
    OT_DOM = 0, // html parser & runtime
    OT_CSSS, // csss! parser & runtime
    OT_CSS, // css parser
    OT_TIS, // TIS parser & runtime
}

enum OUTPUT_SEVERITY
{
    OS_INFO,
    OS_WARNING,
    OS_ERROR,
}

alias DEBUG_OUTPUT_PROC = extern (C) void function(void* param, uint subsystem /*OUTPUT_SUBSYTEMS*/ , uint severity, LPCWSTR text, uint text_length);

//void SCAPI SciterSetupDebugOutput(
//                HWINDOW                  hwndOrNull,// HWINDOW or null if this is global output handler
//                void*                param,     // param to be passed "as is" to the pfOutput
//                DEBUG_OUTPUT_PROC     pfOutput   // output function, output stream alike thing.
//                );

@("SCITER_WINDOW_STATE: the values of sciter-x-def.h (6.0.5.5)")
unittest
{
    // Not of the window commands' order: HIDDEN is 1, SHOWN 2. A wrong value hid the window
    // that expand() meant to show (Windows showed none)
    with (SCITER_WINDOW_STATE)
    {
        assert(SCITER_WINDOW_STATE_CLOSED == 0);
        assert(SCITER_WINDOW_STATE_HIDDEN == 1);
        assert(SCITER_WINDOW_STATE_SHOWN == 2);
        assert(SCITER_WINDOW_STATE_MINIMIZED == 3);
        assert(SCITER_WINDOW_STATE_MAXIMIZED == 4);
        assert(SCITER_WINDOW_STATE_FULL_SCREEN == 5);
    }
}

@("SCITER_RT_OPTIONS: the sleep option of sciter-x-def.h (6.0.5.6)")
unittest
{
    assert(SCITER_RT_OPTIONS.SCITER_ALLOW_DISPLAY_SLEEP_FULLSCREEN == 22);
}
