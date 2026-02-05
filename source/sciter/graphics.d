module sciter.graphics;

import sciter.types;

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
