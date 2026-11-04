module sciter.types;

// Sciter Types
alias HSARCH = void*;
//alias HWINDOW = void*;
alias HELEMENT = void*;
alias HNODE = void*;

alias SBOOL = int; // Sciter uses int for BOOL

alias VOID = void;
alias BOOL = char;
alias SCDOM_RESULT = int;
alias UINT = uint;
alias INT = int;
alias UINT_PTR = size_t;
alias INT_PTR = ptrdiff_t;
alias INT64 = long;
alias UINT64 = ulong;
alias FLOAT_VALUE = double;
alias LPWSTR = wchar*;
alias LPCWSTR = const(wchar)*;
alias LPSTR = char*;
alias LPCSTR = const(char)*;
alias LPBYTE = ubyte*;
alias LPCBYTE = const(ubyte)*;

struct RECT
{
    int left, top, right, bottom;
}

struct POINT
{
    INT x;
    INT y;
}

struct SIZE
{
    INT cx;
    INT cy;
}

alias SciterWindowDelegate = extern (C) long function(HWINDOW hwnd, uint msg, size_t wParam, ptrdiff_t lParam, void* pParam, int* handled);
//alias SciterElementEventProc = extern (C) int function(void* tag, HELEMENT he, uint evtg, void* prms);

alias LPCWSTR_RECEIVER = extern (C) void function(LPCWSTR str, UINT str_length, void* param);
alias LPCSTR_RECEIVER = extern (C) void function(LPCSTR str, UINT str_length, void* param);
alias LPCBYTE_RECEIVER = extern (C) void function(const(ubyte)* str, UINT num_bytes, void* param);

// x-types.h

enum GFX_LAYER
{
    GFX_LAYER_GDI = 1,
    GFX_LAYER_CG = 1, // Mac OS 
    GFX_LAYER_CAIRO = 1, // GTK

    // Windows specific layers
    GFX_LAYER_WARP = 2,
    GFX_LAYER_D2D_WARP = GFX_LAYER_WARP,
    GFX_LAYER_D2D = 3,

    // Generic layers
    GFX_LAYER_SKIA = 4,
    GFX_LAYER_SKIA_RASTER = GFX_LAYER_SKIA,
    GFX_LAYER_SKIA_OPENGL = 5,
    GFX_LAYER_SKIA_VULKAN = 6,

    // OSX specific layers
    GFX_LAYER_SKIA_METAL = 7,

    // Linux specific layers
    GFX_LAYER_SKIA_DX12 = 8,

    // best GPU layer for the platform:
    // Windows: DX12 -> VULKAN -> OPENGL -> RASTER
    // OSX: METAL -> [VULKAN] -> OPENGL -> RASTER
    // Linux: VULKAN -> OPENGL -> RASTER

    // Windows GPU layer
    GFX_LAYER_SKIA_GPU_WINDOWS = 9,

    // OSX GPU layer
    GFX_LAYER_SKIA_GPU_OSX = 10,

    // Linux GPU layer
    GFX_LAYER_SKIA_GPU_LINUX = 11,

    GFX_LAYER_SKIA_ANGLE_DX11 = 0x11,
    GFX_LAYER_SKIA_ANGLE_VULKAN = 0x12,
    GFX_LAYER_SKIA_ANGLE_METAL = 0x13,
    GFX_LAYER_SKIA_ANGLE_OPENGL = 0x14,

    GFX_LAYER_SKIA_ANGLE = 0x1f, // best ANGLE/GPU layer for the platform.

    GFX_LAYER_AUTO = 0xFFFF,
}

version (Windows)
{
    enum GFX_LAYER_SKIA_GPU = GFX_LAYER.GFX_LAYER_SKIA_GPU_WINDOWS;
}
else version (OSX)
{
    enum GFX_LAYER_SKIA_GPU = GFX_LAYER.GFX_LAYER_SKIA_GPU_OSX;
}
else version (linux)
{
    enum GFX_LAYER_SKIA_GPU = GFX_LAYER.GFX_LAYER_SKIA_GPU_LINUX;
}

version (Windows)
{
    // Only what the Sciter API uses: this module has its own BOOL, UINT...
    public import core.sys.windows.windef : HWND, HINSTANCE, HDC, WPARAM, LPARAM, LRESULT;

    version (WINDOWLESS)
    {
        alias HWINDOW = void*;
    }
    else
    {
        alias HWINDOW = HWND; // void* on windows
    }

    enum SCITER_DLL_NAME = "sciter.dll";
}

version (OSX)
{
    alias HWINDOW = void*; // NSWindow*
    alias HINSTANCE = void*; // NSApplication*
    alias HDC = void*; // CGContextRef
    alias LRESULT = long;

    enum SCITER_DLL_NAME = "libsciter.dylib";
}

version (linux)
{
    alias HWINDOW = void*;
    alias HINSTANCE = void*; //
    alias LRESULT = long;
    alias HDC = void*; // cairo_t

    enum SCITER_DLL_NAME = "libsciter.so";
}

version (Android)
{
    // #define WINDOWLESS

    alias HWINDOW = void*;

    alias HINSTANCE = void*; //
    alias LRESULT = long;
    alias HDC = void*; // not used anyway, draws on OpenGLESv2

    enum SCITER_DLL_NAME = "libsciter.so";
}
