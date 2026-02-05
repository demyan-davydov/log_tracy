module sciter.request;

alias HREQUEST = void*;

enum REQUEST_RESULT
{
    REQUEST_PANIC = -1, // e.g. not enough memory
    REQUEST_OK = 0,
    REQUEST_BAD_PARAM = 1, // bad parameter
    REQUEST_FAILURE = 2, // operation failed, e.g. index out of bounds
    REQUEST_NOTSUPPORTED = 3 // the platform does not support requested feature
}

enum SciterResourceType
{
    RT_DATA_HTML = 0,
    RT_DATA_IMAGE = 1,
    RT_DATA_STYLE = 2,
    RT_DATA_CURSOR = 3,
    RT_DATA_SCRIPT = 4,
    RT_DATA_RAW = 5,
    RT_DATA_FONT,
    RT_DATA_MEDIA, // video, audio, lottie, etc.
    RT_DATA_FORCE_DWORD = 0xffffffff
}

enum REQUEST_STATE
{
    RS_PENDING = 0,
    RS_SUCCESS = 1, // completed successfully
    RS_FAILURE = 2, // completed with failure

    RS_FORCE_DWORD = 0xffffffff
}
