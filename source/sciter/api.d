module sciter.api;

import std.string;
import std.exception;
import std.conv;
import std.stdio;

public import sciter.types;
public import sciter.value;
public import sciter.behavior;
public import sciter.def;
public import sciter.dom;
public import sciter.request;
public import sciter.om;

struct SciterGraphicsAPI;
struct SCITER_X_MSG;
alias proc_ptr_t = void function();

struct SciterAPI_T
{
@nogc:

    uint version_; // 0
    extern (C) LPCWSTR function() SciterClassName; // 1
    extern (C) uint function(SBOOL) SciterVersion; // 2
    extern (C) SBOOL function(HWINDOW, LPCWSTR, const(ubyte)*, UINT) SciterDataReady; // 3
    extern (C) SBOOL function(HWINDOW, LPCWSTR, const(ubyte)*, UINT, void*) SciterDataReadyAsync; // 4

    version (Windows)
    {
        extern (C) void function(HWINDOW hwnd, UINT msg, WPARAM wParam, LPARAM lParam) SciterProc; // 5
        extern (C) void function(HWINDOW hwnd, UINT msg, WPARAM wParam, LPARAM lParam, SBOOL*) SciterProcND; // 6
    }
    else
    {
        void* SciterProc; // 5
        void* SciterProcND; // 6
    }

    extern (C) SBOOL function(HWINDOW, LPCWSTR path) SciterLoadFile; // 7
    extern (C) SBOOL function(HWINDOW, const(ubyte)* html, UINT htmlSize, LPCWSTR baseUrl) SciterLoadHtml; // 8
    extern (C) void function(HWINDOW, SciterHostCallback callback, void* param) SciterSetCallback; // 9
    extern (C) SBOOL function(const(ubyte)* css, UINT numBytes) SciterSetMasterCSS; // 10
    extern (C) SBOOL function(const(ubyte)* css, UINT numBytes) SciterAppendMasterCSS; // 11
    extern (C) SBOOL function(HWINDOW, const(ubyte)* css, UINT numBytes, LPCWSTR baseUrl, LPCWSTR mediaType) SciterSetCSS; // 12
    extern (C) SBOOL function(HWINDOW, LPCWSTR mediaType) SciterSetMediaType; // 13
    extern (C) SBOOL function(HWINDOW, const(SCITER_VALUE)* mediaVars) SciterSetMediaVars; // 14
    extern (C) UINT function(HWINDOW) SciterGetMinWidth; // 15
    extern (C) UINT function(HWINDOW, UINT width) SciterGetMinHeight; // 16
    extern (C) SBOOL function(HWINDOW, LPCSTR functionName, UINT argc, const(SCITER_VALUE)* argv, SCITER_VALUE* retval) SciterCall; // 17
    extern (C) SBOOL function(HWINDOW, LPCWSTR script, UINT scriptLength, SCITER_VALUE* pretval) SciterEval; // 18
    extern (C) void function(HWINDOW) SciterUpdateWindow; // 19

    version (Windows)
    {
        extern (C) void function(HWINDOW, void*) SciterTranslateMessage; // 20
    }
    else
    {
        void* SciterTranslateMessage; // 20
    }

    extern (C) SBOOL function(HWINDOW, UINT option, UINT_PTR value) SciterSetOption; // 21
    extern (C) void function(HWINDOW, UINT* px, UINT* py) SciterGetPPI; // 22
    extern (C) SBOOL function(HWINDOW, SCITER_VALUE* pval) SciterGetViewExpando; // 23

    void* SciterRenderD2D; // 24
    void* SciterD2DFactory; // 25
    void* SciterDWFactory; // 26
    void* SciterGraphicsCaps; // 27
    void* SciterSetHomeURL; // 28

    version (OSX)
    {
        //! returns NSView*
        extern (C) HWINDOW function(RECT*) SciterCreateNSView; // 29
    }
    else
    {
        void* SciterCreateNSView; // 29
    }

    version (linux)
    {
        //! returns GtkWidget*
        extern (C) HWINDOW function(RECT*) SciterCreateWidget; // 30
    }
    else
    {
        void* SciterCreateWidget; // 30
    }

    //extern (C) HWINDOW function(uint, const(RECT)* rect, SciterWindowDelegate callback, void* param, HWINDOW parent) SciterCreateWindow; // 31
    extern (C) HWINDOW function(uint, const(RECT)* rect, void*, void*, HWINDOW parent) SciterCreateWindow; // 31

    extern (C) void function(HWINDOW, void* param, DEBUG_OUTPUT_PROC pfOutput) SciterSetupDebugOutput; // 32

    extern (C) SCDOM_RESULT function(HELEMENT he) Sciter_UseElement; // 33
    extern (C) SCDOM_RESULT function(HELEMENT he) Sciter_UnuseElement; // 34
    extern (C) SCDOM_RESULT function(HWINDOW, HELEMENT*) SciterGetRootElement; // 35
    extern (C) SCDOM_RESULT function(HWINDOW hwnd, HELEMENT* phe) SciterGetFocusElement; // 36

    extern (C) SCDOM_RESULT function(HWINDOW hwnd, POINT pt, HELEMENT* phe) SciterFindElement; // 37
    extern (C) SCDOM_RESULT function(HELEMENT he, UINT* count) SciterGetChildrenCount; // 38
    extern (C) SCDOM_RESULT function(HELEMENT he, UINT n, HELEMENT* phe) SciterGetNthChild; // 39
    extern (C) SCDOM_RESULT function(HELEMENT he, HELEMENT* p_parent_he) SciterGetParentElement; // 40
    extern (C) SCDOM_RESULT function(HELEMENT he, SBOOL outer, LPCBYTE_RECEIVER* rcv, void* rcv_param) SciterGetElementHtmlCB; // 41
    extern (C) SCDOM_RESULT function(HELEMENT he, LPCWSTR_RECEIVER* rcv, void* rcv_param) SciterGetElementTextCB; // 42
    extern (C) SCDOM_RESULT function(HELEMENT he, LPCWSTR utf16, UINT length) SciterSetElementText; // 43
    extern (C) SCDOM_RESULT function(HELEMENT he, UINT* p_count) SciterGetAttributeCount; // 44
    extern (C) SCDOM_RESULT function(HELEMENT he, UINT n, LPCSTR_RECEIVER* rcv, void* rcv_param) SciterGetNthAttributeNameCB; // 45
    extern (C) SCDOM_RESULT function(HELEMENT he, UINT n, LPCWSTR_RECEIVER* rcv, void* rcv_param) SciterGetNthAttributeValueCB; // 46
    extern (C) SCDOM_RESULT function(HELEMENT he, LPCSTR name, LPCWSTR_RECEIVER* rcv, void* rcv_param) SciterGetAttributeByNameCB; // 47
    extern (C) SCDOM_RESULT function(HELEMENT he, LPCSTR name, LPCWSTR value) SciterSetAttributeByName; // 48
    extern (C) SCDOM_RESULT function(HELEMENT he) SciterClearAttributes; // 49
    extern (C) SCDOM_RESULT function(HELEMENT he, UINT* p_index) SciterGetElementIndex; // 50
    extern (C) SCDOM_RESULT function(HELEMENT he, LPCSTR* p_type) SciterGetElementType; // 51
    extern (C) SCDOM_RESULT function(HELEMENT he, LPCSTR_RECEIVER* rcv, void* rcv_param) SciterGetElementTypeCB; // 52
    extern (C) SCDOM_RESULT function(HELEMENT he, LPCSTR name, LPCWSTR_RECEIVER* rcv, void* rcv_param) SciterGetStyleAttributeCB; // 53
    extern (C) SCDOM_RESULT function(HELEMENT he, LPCSTR name, LPCWSTR value) SciterSetStyleAttribute; // 54
    extern (C) SCDOM_RESULT function(HELEMENT he, RECT* p_location, UINT areas /*ELEMENT_AREAS*/ ) SciterGetElementLocation; // 55
    extern (C) SCDOM_RESULT function(HELEMENT he, UINT SciterScrollFlags) SciterScrollToView; // 56
    extern (C) SCDOM_RESULT function(HELEMENT he, SBOOL andForceRender) SciterUpdateElement; // 57
    extern (C) SCDOM_RESULT function(HELEMENT he, RECT rc) SciterRefreshElementArea; // 58
    extern (C) SCDOM_RESULT function(HELEMENT he) SciterSetCapture; // 59
    extern (C) SCDOM_RESULT function(HELEMENT he) SciterReleaseCapture; // 60
    extern (C) SCDOM_RESULT function(HELEMENT he, HWINDOW* p_hwnd, SBOOL rootWindow) SciterGetElementHwnd; // 61
    extern (C) SCDOM_RESULT function(HELEMENT he, LPWSTR szUrlBuffer, UINT UrlBufferSize) SciterCombineURL; // 62
    extern (C) SCDOM_RESULT function(HELEMENT he, LPCSTR CSS_selectors, SciterElementCallback* callback, void* param) SciterSelectElements; // 63
    extern (C) SCDOM_RESULT function(HELEMENT he, LPCWSTR CSS_selectors, SciterElementCallback* callback, void* param) SciterSelectElementsW; // 64
    extern (C) SCDOM_RESULT function(HELEMENT he, LPCSTR selector, UINT depth, HELEMENT* heFound) SciterSelectParent; // 65
    extern (C) SCDOM_RESULT function(HELEMENT he, LPCWSTR selector, UINT depth, HELEMENT* heFound) SciterSelectParentW; // 66
    extern (C) SCDOM_RESULT function(HELEMENT he, const(ubyte)* html, UINT htmlLength, UINT where) SciterSetElementHtml; // 67
    extern (C) SCDOM_RESULT function(HELEMENT he, UINT* puid) SciterGetElementUID; // 68
    extern (C) SCDOM_RESULT function(HWINDOW hwnd, UINT uid, HELEMENT* phe) SciterGetElementByUID; // 69
    extern (C) SCDOM_RESULT function(HELEMENT hePopup, HELEMENT heAnchor, UINT placement) SciterShowPopup; // 70
    extern (C) SCDOM_RESULT function(HELEMENT hePopup, POINT pos, UINT placement) SciterShowPopupAt; // 71
    extern (C) SCDOM_RESULT function(HELEMENT he) SciterHidePopup; // 72
    extern (C) SCDOM_RESULT function(HELEMENT he, UINT* pstateBits) SciterGetElementState; // 73
    extern (C) SCDOM_RESULT function(HELEMENT he, UINT stateBitsToSet, UINT stateBitsToClear, SBOOL updateView) SciterSetElementState; // 74
    extern (C) SCDOM_RESULT function(LPCSTR tagname, LPCWSTR textOrNull, /*out*/ HELEMENT* phe) SciterCreateElement; // 75
    extern (C) SCDOM_RESULT function(HELEMENT he, /*out*/ HELEMENT* phe) SciterCloneElement; // 76
    extern (C) SCDOM_RESULT function(HELEMENT he, HELEMENT hparent, UINT index) SciterInsertElement; // 77
    extern (C) SCDOM_RESULT function(HELEMENT he) SciterDetachElement; // 78
    extern (C) SCDOM_RESULT function(HELEMENT he) SciterDeleteElement; // 79
    extern (C) SCDOM_RESULT function(HELEMENT he, UINT milliseconds, UINT_PTR timer_id) SciterSetTimer; // 80
    extern (C) SCDOM_RESULT function(HELEMENT he, ElementEventProc pep, void* tag) SciterDetachEventHandler; // 81
    extern (C) SCDOM_RESULT function(HELEMENT, ElementEventProc, void*) SciterAttachEventHandler; // 82
    extern (C) SCDOM_RESULT function(HWINDOW, ElementEventProc, void* tag, uint subscription) SciterWindowAttachEventHandler; // 83

    extern (C) SCDOM_RESULT function(HWINDOW hwndLayout, ElementEventProc pep, void* tag) SciterWindowDetachEventHandler; // 84
    extern (C) SCDOM_RESULT function(HELEMENT he, UINT appEventCode, HELEMENT heSource, UINT_PTR reason, /*out*/ SBOOL* handled) SciterSendEvent; // 85
    extern (C) SCDOM_RESULT function(HELEMENT he, UINT appEventCode, HELEMENT heSource, UINT_PTR reason) SciterPostEvent; // 86
    extern (C) SCDOM_RESULT function(HELEMENT he, METHOD_PARAMS* params) SciterCallBehaviorMethod; // 87
    extern (C) SCDOM_RESULT function(HELEMENT he, LPCWSTR url, UINT dataType, HELEMENT initiator) SciterRequestElementData; // 88
    extern (C) SCDOM_RESULT function(HELEMENT he, // element to deliver data
        LPCWSTR url, // url
        UINT dataType, // data type, see SciterResourceType.
        UINT requestType, // one of REQUEST_TYPE values
        REQUEST_PARAM* requestParams, // parameters
        UINT nParams // number of parameters

        

    ) SciterHttpRequest; // 89

    extern (C) SCDOM_RESULT function(HELEMENT he, POINT scrollPos, RECT viewRect, SIZE contentSize) SciterGetScrollInfo; // 90
    extern (C) SCDOM_RESULT function(HELEMENT he, POINT scrollPos, SBOOL smooth) SciterSetScrollPos; // 91
    extern (C) SCDOM_RESULT function(HELEMENT he, INT* pMinWidth, INT* pMaxWidth) SciterGetElementIntrinsicWidths; // 92
    extern (C) SCDOM_RESULT function(HELEMENT he, INT forWidth, INT* pHeight) SciterGetElementIntrinsicHeight; // 93
    extern (C) SCDOM_RESULT function(HELEMENT he, SBOOL* pVisible) SciterIsElementVisible; // 94
    extern (C) SCDOM_RESULT function(HELEMENT he, SBOOL* pEnabled) SciterIsElementEnabled; // 95
    extern (C) SCDOM_RESULT function(HELEMENT he, UINT firstIndex, UINT lastIndex, ELEMENT_COMPARATOR* cmpFunc, void* cmpFuncParam) SciterSortElements; // 96
    extern (C) SCDOM_RESULT function(HELEMENT he1, HELEMENT he2) SciterSwapElements; // 97
    extern (C) SCDOM_RESULT function(UINT evt, void* eventCtlStruct, SBOOL* bOutProcessed) SciterTraverseUIEvent; // 98
    extern (C) SCDOM_RESULT function(HELEMENT he, LPCSTR name, const(SCITER_VALUE)* argv, UINT argc, SCITER_VALUE* retval) SciterCallScriptingMethod; // 99
    extern (C) SCDOM_RESULT function(HELEMENT he, LPCSTR name, const(SCITER_VALUE)* argv, UINT argc, SCITER_VALUE* retval) SciterCallScriptingFunction; // 100
    extern (C) SCDOM_RESULT function(HELEMENT he, LPCWSTR script, UINT scriptLength, SCITER_VALUE* retval) SciterEvalElementScript; // 101
    extern (C) SCDOM_RESULT function(HELEMENT he, HWINDOW hwnd) SciterAttachHwndToElement; // 102
    extern (C) SCDOM_RESULT function(HELEMENT he, UINT* pType) SciterControlGetType; // 103
    extern (C) SCDOM_RESULT function(HELEMENT he, SCITER_VALUE* pval) SciterGetValue; // 104
    extern (C) SCDOM_RESULT function(HELEMENT he, const(SCITER_VALUE)* pval) SciterSetValue; // 105
    extern (C) SCDOM_RESULT function(HELEMENT he, SCITER_VALUE* pval, SBOOL forceCreation) SciterGetExpando; // 106
    extern (C) SCDOM_RESULT function(HELEMENT he, void* pval, SBOOL forceCreation) SciterGetObject; // 107
    extern (C) SCDOM_RESULT function(HELEMENT he, void* pval) SciterGetElementNamespace; // 108
    extern (C) SCDOM_RESULT function(HWINDOW hwnd, HELEMENT* phe) SciterGetHighlightedElement; // 109
    extern (C) SCDOM_RESULT function(HWINDOW hwnd, HELEMENT he) SciterSetHighlightedElement; // 110
    //|
    //| DOM Node API
    //|
    extern (C) SCDOM_RESULT function(HNODE hn) SciterNodeAddRef; // 111
    extern (C) SCDOM_RESULT function(HNODE hn) SciterNodeRelease; // 112
    extern (C) SCDOM_RESULT function(HELEMENT he, HNODE* phn) SciterNodeCastFromElement; // 113
    extern (C) SCDOM_RESULT function(HNODE hn, HELEMENT* he) SciterNodeCastToElement; // 114
    extern (C) SCDOM_RESULT function(HNODE hn, HNODE* phn) SciterNodeFirstChild; // 115
    extern (C) SCDOM_RESULT function(HNODE hn, HNODE* phn) SciterNodeLastChild; // 116
    extern (C) SCDOM_RESULT function(HNODE hn, HNODE* phn) SciterNodeNextSibling; // 117
    extern (C) SCDOM_RESULT function(HNODE hn, HNODE* phn) SciterNodePrevSibling; // 118
    extern (C) SCDOM_RESULT function(HNODE hnode, HELEMENT* pheParent) SciterNodeParent; // 119
    extern (C) SCDOM_RESULT function(HNODE hnode, UINT n, HNODE* phn) SciterNodeNthChild; // 120
    extern (C) SCDOM_RESULT function(HNODE hnode, UINT* pn) SciterNodeChildrenCount; // 121
    extern (C) SCDOM_RESULT function(HNODE hnode, UINT* pNodeType /*NODE_TYPE*/ ) SciterNodeType; // 122
    extern (C) SCDOM_RESULT function(HNODE hnode, LPCWSTR_RECEIVER* rcv, void* rcv_param) SciterNodeGetText; // 123
    extern (C) SCDOM_RESULT function(HNODE hnode, LPCWSTR text, UINT textLength) SciterNodeSetText; // 124
    extern (C) SCDOM_RESULT function(HNODE hnode, UINT where /*NODE_INS_TARGET*/ , HNODE what) SciterNodeInsert; // 125
    extern (C) SCDOM_RESULT function(HNODE hnode, SBOOL finalize) SciterNodeRemove; // 126
    extern (C) SCDOM_RESULT function(LPCWSTR text, UINT textLength, HNODE* phnode) SciterCreateTextNode; // 127
    extern (C) SCDOM_RESULT function(LPCWSTR text, UINT textLength, HNODE* phnode) SciterCreateCommentNode; // 128
    //|
    //| Value API
    //|
    extern (C) SCDOM_RESULT function(SCITER_VALUE* pretval) ValueInit; // 129
    extern (C) SCDOM_RESULT function(SCITER_VALUE* pretval) ValueClear; // 130
    extern (C) SCDOM_RESULT function(const(SCITER_VALUE)* pval1, const(SCITER_VALUE)* pval2) nothrow ValueCompare; // 131
    extern (C) SCDOM_RESULT function(SCITER_VALUE* dst, const(SCITER_VALUE)* src) ValueCopy; // 132
    extern (C) SCDOM_RESULT function(SCITER_VALUE* pval) ValueIsolate; // 133
    extern (C) SCDOM_RESULT function(const(SCITER_VALUE)* pval, UINT* pType, UINT* pUnits) ValueType; // 134

    extern (C) UINT function(const(SCITER_VALUE)* pval, LPCWSTR* pChars, UINT* pNumChars) nothrow ValueStringData; // 135
    extern (C) UINT function(SCITER_VALUE* pval, const(wchar)* chars, UINT numChars, UINT units) ValueStringDataSet; // 136
    extern (C) UINT function(const(SCITER_VALUE)* pval, INT* pData) nothrow ValueIntData; // 137
    extern (C) UINT function(SCITER_VALUE* pval, INT data, UINT type, UINT units) ValueIntDataSet; // 138
    extern (C) UINT function(const(SCITER_VALUE)* pval, INT64* pData) nothrow ValueInt64Data; // 139
    extern (C) UINT function(SCITER_VALUE* pval, INT64 data, UINT type, UINT units) ValueInt64DataSet; // 140
    extern (C) UINT function(const(SCITER_VALUE)* pval, FLOAT_VALUE* pData) nothrow ValueFloatData; // 141
    extern (C) UINT function(SCITER_VALUE* pval, FLOAT_VALUE data, UINT type, UINT units) ValueFloatDataSet; // 142
    extern (C) UINT function(const(SCITER_VALUE)* pval, const(ubyte)** pBytes, UINT* pnBytes) nothrow ValueBinaryData; // 143
    extern (C) UINT function(SCITER_VALUE* pval, const(ubyte)* pBytes, UINT nBytes, UINT type, UINT units) ValueBinaryDataSet; // 144
    extern (C) UINT function(const(SCITER_VALUE)* pval, INT* pn) nothrow ValueElementsCount; // 145
    extern (C) UINT function(const(SCITER_VALUE)* pval, INT n, SCITER_VALUE* pretval) nothrow ValueNthElementValue; // 146
    extern (C) UINT function(SCITER_VALUE* pval, INT n, const(SCITER_VALUE)* pval_to_set) ValueNthElementValueSet; // 147
    extern (C) UINT function(const(SCITER_VALUE)* pval, INT n, SCITER_VALUE* pretval) nothrow ValueNthElementKey; // 148
    extern (C) UINT function(const(SCITER_VALUE)* pval, KeyValueCallback penum, void* param) nothrow ValueEnumElements; // 149
    extern (C) UINT function(SCITER_VALUE* pval, const(SCITER_VALUE)* pkey, const(SCITER_VALUE)* pval_to_set) ValueSetValueToKey; // 150
    extern (C) UINT function(const(SCITER_VALUE)* pval, const SCITER_VALUE* pkey, SCITER_VALUE* pretval) nothrow ValueGetValueOfKey; // 151
    extern (C) UINT function(SCITER_VALUE* pval, /*VALUE_STRING_CVT_TYPE*/ UINT how) ValueToString; // 152
    extern (C) UINT function(SCITER_VALUE* pval, LPCWSTR str, UINT strLength, /*VALUE_STRING_CVT_TYPE*/ UINT how) ValueFromString; // 153
    extern (C) UINT function(const(SCITER_VALUE)* pval, SCITER_VALUE* pthis, UINT argc, const(
            SCITER_VALUE)* argv, SCITER_VALUE* pretval, LPCWSTR url) ValueInvoke; // 154
    extern (C) UINT function(SCITER_VALUE* pval, NATIVE_FUNCTOR_INVOKE pinvoke, NATIVE_FUNCTOR_RELEASE prelease, void* tag) ValueNativeFunctorSet; // 155
    extern (C) SBOOL function(const(SCITER_VALUE)* pval) nothrow ValueIsNativeFunctor; // 156

    // used to be script VM API
    void* reserved1; // 157
    void* reserved2; // 158
    void* reserved3; // 159
    void* reserved4; // 160

    extern (C) HSARCHIVE function(const(ubyte)* archiveData, UINT archiveDataLength) SciterOpenArchive; // 161
    extern (C) SBOOL function(HSARCHIVE harc, LPCWSTR path, const(ubyte)** pdata, UINT* pdataLength) SciterGetArchiveItem; // 162
    extern (C) SBOOL function(HSARCHIVE harc) SciterCloseArchive; // 163

    extern (C) SCDOM_RESULT function(const BEHAVIOR_EVENT_PARAMS* evt, SBOOL post, SBOOL* handled) SciterFireEvent; // 164

    extern (C) void* function(HWINDOW hwnd) SciterGetCallbackParam; // 165
    extern (C) UINT_PTR function(HWINDOW hwnd, UINT_PTR wparam, UINT_PTR lparam, UINT timeoutms) SciterPostCallback; // 166

    extern (C) void* function() GetSciterGraphicsAPI; // 167
    extern (C) void* function() GetSciterRequestAPI; // 168

    version (WINDOWS)
    {
        extern (C) SBOOL function(HWINDOW hwnd, IUnknown* pSwapChain) SciterCreateOnDirectXWindow; // IDXGISwapChain
        extern (C) SBOOL function(HWINDOW hwnd, HELEMENT elementToRenderOrNull, SBOOL frontLayer) SciterRenderOnDirectXWindow;
        extern (C) SBOOL function(HWINDOW hwnd, HELEMENT elementToRenderOrNull, IUnknown* surface) SciterRenderOnDirectXTexture; // IDXGISurface
    }
    else
    {
        void* SciterCreateOnDirectXWindow; // 169
        void* SciterRenderOnDirectXWindow; // 170
        void* SciterRenderOnDirectXTexture; // 171
    }

    extern (C) SBOOL function(HWINDOW hwnd, SCITER_X_MSG* pMsg) SciterProcX; // returns TRUE if handled // 172

    extern (C) UINT64 function(const(char)* name) SciterAtomValue; // 173
    extern (C) SBOOL function(UINT64 atomv, LPCSTR_RECEIVER* rcv, void* rcv_param) SciterAtomNameCB; // 174
    extern (C) SBOOL function(som_asset_t* pass) SciterSetGlobalAsset; // 175

    extern (C) SCDOM_RESULT function(HELEMENT el, UINT64 nameAtom, som_asset_t** ppass) SciterGetElementAsset; // 176

    extern (C) UINT function(HWINDOW hwndOrNull, LPCSTR name, const SCITER_VALUE* pvalToSet) SciterSetVariable; // 177
    extern (C) UINT function(HWINDOW hwndOrNull, LPCSTR name, SCITER_VALUE* pvalToGet) SciterGetVariable; // 178

    extern (C) UINT function(const(SCITER_VALUE)* pval, HELEMENT* ppElement) SciterElementUnwrap; // 179
    extern (C) UINT function(SCITER_VALUE* pval, HELEMENT pElement) SciterElementWrap; // 180

    extern (C) UINT function(const(SCITER_VALUE)* pval, HNODE* ppNode) SciterNodeUnwrap; // 181
    extern (C) UINT function(SCITER_VALUE* pval, HNODE pNode) SciterNodeWrap; // 182

    extern (C) SBOOL function(som_asset_t* pass) SciterReleaseGlobalAsset; // 183

    extern (C) INT_PTR function(UINT appCmd /**/ , UINT_PTR p1, UINT_PTR p2) nothrow SciterExec; // 184
    extern (C) INT_PTR function(HWINDOW hwnd, UINT windowCmd /**/ , UINT_PTR p1, UINT_PTR p2) nothrow SciterWindowExec; // 185

    extern (C) proc_ptr_t function(const(char)* procName) SciterEGLGetProcAddress; // 186
    extern (C) SCDOM_RESULT function(HELEMENT he, UINT eventCode, UINT_PTR reason) SciterEGLSendEvent; // 187
    extern (C) SCDOM_RESULT function(HELEMENT he, UINT eventCode, UINT_PTR reason) SciterRequestAnimationFrameEvent; // 188
}
