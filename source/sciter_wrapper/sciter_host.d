module sciter_wrapper.sciter_host;

import sciter.def;
import sciter.types;
import sciter.behavior;

import sciter_wrapper.sciter_archive;
import sciter_wrapper.sciter_value;

// load data from resource section of the PE
//bool load_resource_data(HINSTANCE hinst, LPCWSTR uri, LPCBYTE & pb, UINT & cb);
//bool load_html_resource(HINSTANCE hinst, UINT resId, LPCBYTE & pb, UINT & cb);

// standard implementation of SCN_ATTACH_BEHAVIOR notification
/*bool create_behavior(SCN_ATTACH_BEHAVIOR* lpab)
{
    event_handler * pb = behavior_factory::create(lpab->behaviorName, lpab->element);
    if (pb)
    {
        lpab->elementTag = pb;
        lpab->elementProc = event_handler::element_proc;
        return true;
    }
    return false;
}*/

mixin template SciterHost(BASE)
{
    /*void setupCallback()
    {
        SciterSetCallback(static_cast< BASE* >(this)->hwnd(), &callback, static_cast< BASE* >( this ) );
    }*/

    final void setupCallback(HWINDOW hwnd)
    {
        SciterSetCallback(hwnd, &callback, this);
    }

    // Sciter runtime callback
    final private static uint callback(SCITER_CALLBACK_NOTIFICATION* pnm, void* param)
    {
        assert(param);
        typeof(this)* self = cast(typeof(this)*)(param);
        return cast(uint) self.handleNotification(pnm);
    }

    // notifiaction cracker
    final private LRESULT handleNotification(SCITER_CALLBACK_NOTIFICATION* pnm)
    {
        // Crack and call appropriate method

        // here are all notifiactions
        switch (pnm.code)
        {
        case SC_LOAD_DATA:
            return onLoadData(cast(SCN_LOAD_DATA*) pnm);
        case SC_DATA_LOADED:
            return onDataLoaded(cast(SCN_DATA_LOADED*) pnm);
            //case SC_DOCUMENT_COMPLETE: return on_document_complete();
        case SC_ATTACH_BEHAVIOR:
            return onAttachBehavior(cast(SCN_ATTACH_BEHAVIOR*) pnm);
        case SC_ENGINE_DESTROYED:
            return onEngineDestroyed();
        case SC_POSTED_NOTIFICATION:
            return onPostedNotification(cast(SCN_POSTED_NOTIFICATION*) pnm);
        case SC_GRAPHICS_CRITICAL_FAILURE:
            onGraphicsCriticalFailure();
            return 0;
        }
        return 0;
    }

    // Overridables

    LRESULT onLoadData(SCN_LOAD_DATA* pnmld)
    {
        import core.stdc.wchar_ : wcslen;
        import std.algorithm.searching : startsWith;

        const(ubyte)* pb = 0;
        uint cb = 0;
        wchar[] uri = cast(wchar[]) pnmld.uri[0 .. wcslen(pnmld.uri)];

        if (uri.startsWith("res:"w))
        {
            // then by calling possibly overloaded load_resource_data method
            if (loadResourceData(uri.start + 4, pb, cb))
                SciterDataReady(pnmld.hwnd, pnmld.uri, pb, cb);
            else
            {
                debug writeln("LOAD FAILURE: ", uri);
                return SC_LOAD_DATA_RETURN_CODES.LOAD_DISCARD;
            }
        }
        else if (uri.startsWith("this://app/"w))
        {
            // try to get them from archive first
            const(ubyte)[] data = sciterArchive().get(uri.start + 11);
            if (data.length)
                SciterDataReady(pnmld.hwnd, pnmld.uri, data.ptr, data.length);
            else
            {
                debug writeln("LOAD FAILURE: ", uri);
                return SC_LOAD_DATA_RETURN_CODES.LOAD_DISCARD;
            }
        }

        return SC_LOAD_DATA_RETURN_CODES.LOAD_OK;
    }

    LRESULT onDataLoaded(SCN_DATA_LOADED* pnmld)
    {
        return 0;
    }

    LRESULT onAttachBehavior(SCN_ATTACH_BEHAVIOR* lpab)
    {
        return create_behavior(lpab);
    }

    LRESULT onEngineDestroyed()
    {
        return 0;
    }

    LRESULT onPostedNotification(SCN_POSTED_NOTIFICATION* lpab)
    {
        return 0;
    }

    void onGraphicsCriticalFailure()
    {
        version (Windows)
        {
            debug writeln("Direct2D graphics critical error");
        }
    }

    final bool loadResourceData(LPCWSTR uri, ref const(ubyte)* pb, ref UINT cb)
    {
        return systemLoadResourceData(getResourceInstance(), uri, pb, cb);
    }

    final bool loadFile(const(wchar)[] uri)
    {
        return SciterLoadFile(hwnd(), uri.ptr) != 0;
    }

    final bool loadHtml(LPCBYTE pb, UINT cb, LPCWSTR uri = 0)
    {
        return SciterLoadHtml(hwnd(), pb, cb, uri) != 0;
    }

    final HELEMENT root()
    {
        HELEMENT re = 0;
        SCDOM_RESULT r = SciterGetRootElement(hwnd(), &re);
        debug assert(r == SCDOM_OK);
        return re;
    }

    // todo: call functions, eval()

    // will post or send custom event to all windows in this GUI thread
    // To subscribe on such events use this in JS:
    //   Window.this.on("event-name",function(evt) {
    //     ...
    //   });
    static bool broadcastEvent(BEHAVIOR_EVENT_PARAMS evt, bool post = true)
    {
        debug assert(evt.name);
        evt.cmd = CUSTOM; // only custom, named events here 
        evt.heTarget = NULL; // heTarget must be null to dispatch it to all windows
        SBOOL handled = false;
        SCDOM_RESULT r = SciterFireEvent(&evt, post, &handled);
        debug assert(r == SCDOM_OK);
        return handled != 0;
    }

    // this script will be excuted in context of each document loaded into the engine,
    // The purpose of such init script is to initialize global context. 
    static void setInitScript(const(char)[] ut8z_js)
    {
        SBOOL r = SciterSetOption(NULL, SCITER_SET_INIT_SCRIPT, UINT_PTR(ut8z_js.ptr));
        debug assert(r);
    }

    // STATIC method: sets variable that will be available in each document 
    //                loaded after this call 
    static void setSharedVariable(const(char)[] name, SciterValueView val)
    {
        SciterSetVariable(NULL, name.ptr, val.raw);
    }

    // sets variable that will be available in root document of this window,
    // call it in or after DOCUMENT_CREATED event
    final void setRootDocumentVariable(const(char)[] name, SciterValueView val)
    {
        SciterSetVariable(hwnd(), name.ptr, val.raw);
    }
}

version (Windows)
{
    const(ubyte)[] systemLoadHtmlResource(HINSTANCE hinst, UINT resId)
    {
        HRSRC hrsrc = FindResource(hinst, MAKEINTRESOURCE(resId), MAKEINTRESOURCE(23));
        if (!hrsrc)
            return null; // resource not found here - proceed with default loader
        // Load specified resource and check if ok
        HGLOBAL hgres = LoadResource(hinst, hrsrc);
        if (!hgres)
            return null;
        // Retrieve resource data and check if ok
        const(ubyte)* pb = cast(const(ubyte)*) LockResource(hgres);
        if (!pb)
            return null;
        const uint cb = SizeofResource(hinst, hrsrc);
        if (!cb)
            return null;
        return pb[0 .. cb];
    }

    // loads data from resource section of hinst library.
    // accepts "name.ext" and "res:name.ext" uri's
    const(ubyte)[] systemLoadResourceData(HINSTANCE hinst, const(wchar)[] uri)
    {
        import core.stdc.wchar_ : wcsncmp, wcsncpy, wcsrchr;
        import std.algorithm.searching : startsWith;

        // const(ubyte) *  & pb, uint & cb)

        //const(ubyte)[] result;

        if (uri.length == 0)
            return null;
        // Retrieve url specification into a local storage since FindResource() expects
        // to find its parameters on stack rather then on the heap under Win9x/Me

        if (uri.startsWith("res:"w))
            uri = uri[4 .. $];

        if (uri.startsWith("//"w))
            uri = uri[2 .. $];

        wchar[MAX_PATH + 1] achURL = {0};
        wcsncpy(achURL.ptr, uri.ptr, MAX_PATH);

        wchar* pszName = achURL.ptr;

        // Separate extension if any
        wchar* pszExt = wcsrchr(pszName, '.');
        if (pszExt)
        {
            *pszExt++ = '\0';
        }

        // Find specified resource and leave if failed. Note that we use extension
        // as the custom resource type specification or assume standard HTML resource
        // if no extension is specified

        HRSRC hrsrc = 0;
        bool isHtml = false;
        if (pszExt == 0 || _wcsicmp(pszExt, "HTML"w) == 0 || _wcsicmp(pszExt, "HTM"w) == 0)
        {
            hrsrc = FindResourceW(hinst, pszName, MAKEINTRESOURCEW(23) /*RT_HTML*/ );
            isHtml = true;
        }
        else
            hrsrc = FindResourceW(hinst, pszName, pszExt);

        if (!hrsrc)
            return null; // resource not found here - proceed with the default loader

        // Load specified resource and check if ok

        HGLOBAL hgres = LoadResource(hinst, hrsrc);
        if (!hgres)
            return null;

        // Retrieve resource data and check if ok

        const(ubyte)* pb = cast(PBYTE)LockResource(hgres);
        if (!pb)
            return null;
        const uint cb = SizeofResource(hinst, hrsrc);
        if (!cb)
            return null;

        // Report data ready

        return pb[0 .. cb];
    }
}
else // not Windows
{
    const(ubyte)[] systemLoadHtmlResource(HINSTANCE hinst, UINT resId)
    {
        return null;
    }

    const(ubyte)[] systemLoadResourceData(HINSTANCE hinst, const(wchar)[] uri)
    {
        return null;
    }
}
