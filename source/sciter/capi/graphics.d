//! The C API of Sciter: the graphics handles and types, and the table of its graphics functions
//! (SciterGraphicsAPI), as in sciter-x-graphics.h.
module sciter.capi.graphics;

import sciter.capi.types;
import sciter.capi.value : SCITER_VALUE;

alias HGFX = void*;
alias HIMG = void*;
alias HPATH = void*;
alias HTEXT = void*;

alias SC_REAL = float;

alias SC_POS = SC_REAL; // position
alias SC_DIM = SC_REAL; // dimension
alias SC_ANGLE = SC_REAL; // angle (radians)
alias SC_COLOR = uint; // color

struct SC_COLOR_STOP
{
    SC_COLOR color;
    float offset; // 0.0 ... 1.0
}

enum GRAPHIN_RESULT
{
    GRAPHIN_PANIC = -1, // e.g. not enough memory
    GRAPHIN_OK = 0,
    GRAPHIN_BAD_PARAM = 1, // bad parameter
    GRAPHIN_FAILURE = 2, // operation failed, e.g. restore() without save()
    GRAPHIN_NOTSUPPORTED = 3 // the platform does not support requested feature
}

enum DRAW_PATH_MODE
{
    DRAW_FILL_ONLY = 1,
    DRAW_STROKE_ONLY = 2,
    DRAW_FILL_AND_STROKE = 3,
}

enum SCITER_LINE_JOIN_TYPE
{
    SCITER_JOIN_MITER = 0,
    SCITER_JOIN_ROUND = 1,
    SCITER_JOIN_BEVEL = 2,
    SCITER_JOIN_MITER_OR_BEVEL = 3,
}

enum SCITER_LINE_CAP_TYPE
{
    SCITER_LINE_CAP_BUTT = 0,
    SCITER_LINE_CAP_SQUARE = 1,
    SCITER_LINE_CAP_ROUND = 2,
}

alias ImageWriteFunction = extern (C) SBOOL function(void* prm, const(ubyte)* data, UINT dataLength) nothrow;
alias ImagePaintFunction = extern (C) void function(void* prm, HGFX hgfx, UINT width, UINT height) nothrow;

/// The numpad positions of gDrawText: the point (px, py) is that point of the text's box
enum TEXT_POSITION : UINT
{
    bottomLeft = 1,
    bottom = 2,
    bottomRight = 3,
    left = 4,
    center = 5,
    right = 6,
    topLeft = 7,
    top = 8,
    topRight = 9,
}

/// The table GetSciterGraphicsAPI() gives: 72 functions in the order of the header (one
/// pointer each; a function out of place calls another one, so the order is checked by a test
/// and by `checkGraphicsApi` at the start). The prefix of the names tells the group:
/// image*, g* drawing, path*, text*, v* values.
struct SciterGraphicsAPI
{
@nogc:
    extern (C) GRAPHIN_RESULT function(HIMG* poutImg, UINT width, UINT height, SBOOL withAlpha) nothrow imageCreate; // 0
    extern (C) GRAPHIN_RESULT function(HIMG* poutImg, UINT pixmapWidth, UINT pixmapHeight, UINT pixmap_format, const(ubyte)* pixmap) nothrow imageCreateFromPixmap; // 1
    extern (C) GRAPHIN_RESULT function(HIMG himg) nothrow imageAddRef; // 2
    extern (C) GRAPHIN_RESULT function(HIMG himg) nothrow imageRelease; // 3
    extern (C) GRAPHIN_RESULT function(HIMG himg, UINT* width, UINT* height, SBOOL* usesAlpha) nothrow imageGetInfo; // 4
    extern (C) GRAPHIN_RESULT function(HIMG himg, SC_COLOR byColor) nothrow imageClear; // 5
    extern (C) GRAPHIN_RESULT function(const(ubyte)* bytes, UINT num_bytes, HIMG* pout_img) nothrow imageLoad; // 6
    extern (C) GRAPHIN_RESULT function(HIMG himg, ImageWriteFunction pfn, void* prm, UINT encoding, UINT quality) nothrow imageSave; // 7
    extern (C) SC_COLOR function(UINT red, UINT green, UINT blue, UINT alpha) nothrow RGBA; // 8
    extern (C) GRAPHIN_RESULT function(HIMG img, HGFX* pout_gfx) nothrow gCreate; // 9
    extern (C) GRAPHIN_RESULT function(HGFX gfx) nothrow gAddRef; // 10
    extern (C) GRAPHIN_RESULT function(HGFX gfx) nothrow gRelease; // 11
    extern (C) GRAPHIN_RESULT function(HGFX hgfx, SC_POS x1, SC_POS y1, SC_POS x2, SC_POS y2) nothrow gLine; // 12
    extern (C) GRAPHIN_RESULT function(HGFX hgfx, SC_POS x1, SC_POS y1, SC_POS x2, SC_POS y2) nothrow gRectangle; // 13
    extern (C) GRAPHIN_RESULT function(HGFX hgfx, SC_POS x1, SC_POS y1, SC_POS x2, SC_POS y2, const(SC_DIM)* radii8) nothrow gRoundedRectangle; // 14
    extern (C) GRAPHIN_RESULT function(HGFX hgfx, SC_POS x, SC_POS y, SC_DIM rx, SC_DIM ry) nothrow gEllipse; // 15
    extern (C) GRAPHIN_RESULT function(HGFX hgfx, SC_POS x, SC_POS y, SC_POS rx, SC_POS ry, SC_ANGLE start, SC_ANGLE sweep) nothrow gArc; // 16
    extern (C) GRAPHIN_RESULT function(HGFX hgfx, SC_POS x, SC_POS y, SC_DIM r1, SC_DIM r2, SC_ANGLE start, UINT rays) nothrow gStar; // 17
    extern (C) GRAPHIN_RESULT function(HGFX hgfx, const(SC_POS)* xy, UINT num_points) nothrow gPolygon; // 18
    extern (C) GRAPHIN_RESULT function(HGFX hgfx, const(SC_POS)* xy, UINT num_points) nothrow gPolyline; // 19
    extern (C) GRAPHIN_RESULT function(HPATH* path_) nothrow pathCreate; // 20
    extern (C) GRAPHIN_RESULT function(HPATH path_) nothrow pathAddRef; // 21
    extern (C) GRAPHIN_RESULT function(HPATH path_) nothrow pathRelease; // 22
    extern (C) GRAPHIN_RESULT function(HPATH path_, SC_POS x, SC_POS y, SBOOL relative) nothrow pathMoveTo; // 23
    extern (C) GRAPHIN_RESULT function(HPATH path_, SC_POS x, SC_POS y, SBOOL relative) nothrow pathLineTo; // 24
    extern (C) GRAPHIN_RESULT function(HPATH path_, SC_POS x, SC_POS y, SC_ANGLE angle, SC_DIM rx, SC_DIM ry, SBOOL is_large_arc, SBOOL clockwise, SBOOL relative) nothrow pathArcTo; // 25
    extern (C) GRAPHIN_RESULT function(HPATH path_, SC_POS xc, SC_POS yc, SC_POS x, SC_POS y, SBOOL relative) nothrow pathQuadraticCurveTo; // 26
    extern (C) GRAPHIN_RESULT function(HPATH path_, SC_POS xc1, SC_POS yc1, SC_POS xc2, SC_POS yc2, SC_POS x, SC_POS y, SBOOL relative) nothrow pathBezierCurveTo; // 27
    extern (C) GRAPHIN_RESULT function(HPATH path_) nothrow pathClosePath; // 28
    extern (C) GRAPHIN_RESULT function(HGFX hgfx, HPATH path_, DRAW_PATH_MODE dpm) nothrow gDrawPath; // 29
    extern (C) GRAPHIN_RESULT function(HGFX hgfx, SC_ANGLE radians, const(SC_POS)* cx, const(SC_POS)* cy) nothrow gRotate; // 30
    extern (C) GRAPHIN_RESULT function(HGFX hgfx, SC_POS cx, SC_POS cy) nothrow gTranslate; // 31
    extern (C) GRAPHIN_RESULT function(HGFX hgfx, SC_DIM x, SC_DIM y) nothrow gScale; // 32
    extern (C) GRAPHIN_RESULT function(HGFX hgfx, SC_DIM dx, SC_DIM dy) nothrow gSkew; // 33
    extern (C) GRAPHIN_RESULT function(HGFX hgfx, SC_POS m11, SC_POS m12, SC_POS m21, SC_POS m22, SC_POS dx, SC_POS dy) nothrow gTransform; // 34
    extern (C) GRAPHIN_RESULT function(HGFX hgfx) nothrow gStateSave; // 35
    extern (C) GRAPHIN_RESULT function(HGFX hgfx) nothrow gStateRestore; // 36
    extern (C) GRAPHIN_RESULT function(HGFX hgfx, SC_DIM width) nothrow gLineWidth; // 37
    extern (C) GRAPHIN_RESULT function(HGFX hgfx, SCITER_LINE_JOIN_TYPE type_) nothrow gLineJoin; // 38
    extern (C) GRAPHIN_RESULT function(HGFX hgfx, SCITER_LINE_CAP_TYPE type_) nothrow gLineCap; // 39
    extern (C) GRAPHIN_RESULT function(HGFX hgfx, SC_COLOR c) nothrow gLineColor; // 40
    extern (C) GRAPHIN_RESULT function(HGFX hgfx, SC_COLOR color) nothrow gFillColor; // 41
    extern (C) GRAPHIN_RESULT function(HGFX hgfx, SC_POS x1, SC_POS y1, SC_POS x2, SC_POS y2, const(SC_COLOR_STOP)* stops, UINT nstops) nothrow gLineGradientLinear; // 42
    extern (C) GRAPHIN_RESULT function(HGFX hgfx, SC_POS x1, SC_POS y1, SC_POS x2, SC_POS y2, const(SC_COLOR_STOP)* stops, UINT nstops) nothrow gFillGradientLinear; // 43
    extern (C) GRAPHIN_RESULT function(HGFX hgfx, SC_POS x, SC_POS y, SC_DIM rx, SC_DIM ry, const(SC_COLOR_STOP)* stops, UINT nstops) nothrow gLineGradientRadial; // 44
    extern (C) GRAPHIN_RESULT function(HGFX hgfx, SC_POS x, SC_POS y, SC_DIM rx, SC_DIM ry, const(SC_COLOR_STOP)* stops, UINT nstops) nothrow gFillGradientRadial; // 45
    extern (C) GRAPHIN_RESULT function(HGFX hgfx, SBOOL even_odd) nothrow gFillMode; // 46
    extern (C) GRAPHIN_RESULT function(HTEXT* ptext, LPCWSTR text, UINT textLength, HELEMENT he, LPCWSTR classNameOrNull) nothrow textCreateForElement; // 47
    extern (C) GRAPHIN_RESULT function(HTEXT* ptext, LPCWSTR text, UINT textLength, HELEMENT he, LPCWSTR style, UINT styleLength) nothrow textCreateForElementAndStyle; // 48
    extern (C) GRAPHIN_RESULT function(HTEXT path_) nothrow textAddRef; // 49
    extern (C) GRAPHIN_RESULT function(HTEXT path_) nothrow textRelease; // 50
    extern (C) GRAPHIN_RESULT function(HTEXT text, SC_DIM* minWidth, SC_DIM* maxWidth, SC_DIM* height, SC_DIM* ascent, SC_DIM* descent, UINT* nLines) nothrow textGetMetrics; // 51
    extern (C) GRAPHIN_RESULT function(HTEXT text, SC_DIM width, SC_DIM height) nothrow textSetBox; // 52
    extern (C) GRAPHIN_RESULT function(HGFX hgfx, HTEXT text, SC_POS px, SC_POS py, UINT position) nothrow gDrawText; // 53
    extern (C) GRAPHIN_RESULT function(HGFX hgfx, HIMG himg, SC_POS x, SC_POS y, const(SC_DIM)* w, const(SC_DIM)* h, const(UINT)* ix, const(UINT)* iy, const(UINT)* iw, const(UINT)* ih, const(float)* opacity) nothrow gDrawImage; // 54
    extern (C) GRAPHIN_RESULT function(HGFX hgfx, SC_POS* inout_x, SC_POS* inout_y) nothrow gWorldToScreen; // 55
    extern (C) GRAPHIN_RESULT function(HGFX hgfx, SC_POS* inout_x, SC_POS* inout_y) nothrow gScreenToWorld; // 56
    extern (C) GRAPHIN_RESULT function(HGFX hgfx, SC_POS x1, SC_POS y1, SC_POS x2, SC_POS y2, float opacity) nothrow gPushClipBox; // 57
    extern (C) GRAPHIN_RESULT function(HGFX hgfx, HPATH hpath, float opacity) nothrow gPushClipPath; // 58
    extern (C) GRAPHIN_RESULT function(HGFX hgfx) nothrow gPopClip; // 59
    extern (C) GRAPHIN_RESULT function(HIMG himg, ImagePaintFunction pPainter, void* prm) nothrow imagePaint; // 60
    extern (C) GRAPHIN_RESULT function(HGFX hgfx, SCITER_VALUE* toValue) nothrow vWrapGfx; // 61
    extern (C) GRAPHIN_RESULT function(HIMG himg, SCITER_VALUE* toValue) nothrow vWrapImage; // 62
    extern (C) GRAPHIN_RESULT function(HPATH hpath, SCITER_VALUE* toValue) nothrow vWrapPath; // 63
    extern (C) GRAPHIN_RESULT function(HTEXT htext, SCITER_VALUE* toValue) nothrow vWrapText; // 64
    extern (C) GRAPHIN_RESULT function(const(SCITER_VALUE)* fromValue, HGFX* phgfx) nothrow vUnWrapGfx; // 65
    extern (C) GRAPHIN_RESULT function(const(SCITER_VALUE)* fromValue, HIMG* phimg) nothrow vUnWrapImage; // 66
    extern (C) GRAPHIN_RESULT function(const(SCITER_VALUE)* fromValue, HPATH* phpath) nothrow vUnWrapPath; // 67
    extern (C) GRAPHIN_RESULT function(const(SCITER_VALUE)* fromValue, HTEXT* phtext) nothrow vUnWrapText; // 68
    extern (C) GRAPHIN_RESULT function(HGFX hgfx) nothrow gFlush; // 69
    extern (C) GRAPHIN_RESULT function(HIMG* poutImg, HELEMENT domElement) nothrow imageCreateFromElement; // 70
    extern (C) GRAPHIN_RESULT function(HGFX hgfx, UINT nativeDcType, void** pDC) nothrow gGetNativeDC; // 71
}

/// The functions of SciterGraphicsAPI in the order of sciter-x-graphics.h (copied from it by a
/// script, 2026-11-19)
enum string[] graphicsApiOrder = [
    "imageCreate",
    "imageCreateFromPixmap",
    "imageAddRef",
    "imageRelease",
    "imageGetInfo",
    "imageClear",
    "imageLoad",
    "imageSave",
    "RGBA",
    "gCreate",
    "gAddRef",
    "gRelease",
    "gLine",
    "gRectangle",
    "gRoundedRectangle",
    "gEllipse",
    "gArc",
    "gStar",
    "gPolygon",
    "gPolyline",
    "pathCreate",
    "pathAddRef",
    "pathRelease",
    "pathMoveTo",
    "pathLineTo",
    "pathArcTo",
    "pathQuadraticCurveTo",
    "pathBezierCurveTo",
    "pathClosePath",
    "gDrawPath",
    "gRotate",
    "gTranslate",
    "gScale",
    "gSkew",
    "gTransform",
    "gStateSave",
    "gStateRestore",
    "gLineWidth",
    "gLineJoin",
    "gLineCap",
    "gLineColor",
    "gFillColor",
    "gLineGradientLinear",
    "gFillGradientLinear",
    "gLineGradientRadial",
    "gFillGradientRadial",
    "gFillMode",
    "textCreateForElement",
    "textCreateForElementAndStyle",
    "textAddRef",
    "textRelease",
    "textGetMetrics",
    "textSetBox",
    "gDrawText",
    "gDrawImage",
    "gWorldToScreen",
    "gScreenToWorld",
    "gPushClipBox",
    "gPushClipPath",
    "gPopClip",
    "imagePaint",
    "vWrapGfx",
    "vWrapImage",
    "vWrapPath",
    "vWrapText",
    "vUnWrapGfx",
    "vUnWrapImage",
    "vUnWrapPath",
    "vUnWrapText",
    "gFlush",
    "imageCreateFromElement",
    "gGetNativeDC",
];

@("SciterGraphicsAPI: one pointer per function, in the order of the header")
unittest
{
    static assert(SciterGraphicsAPI.sizeof == graphicsApiOrder.length * (void*).sizeof);
    static assert(graphicsApiOrder.length == 72);
    static assert([__traits(allMembers, SciterGraphicsAPI)] == graphicsApiOrder);
    static foreach (i, name; graphicsApiOrder)
        static assert(__traits(getMember, SciterGraphicsAPI, name).offsetof == i * (void*).sizeof, name ~ " is out of place");
}
