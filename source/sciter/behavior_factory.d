//! A port of Sciter's C++ behavior factory, commented out whole: nothing here is
//! compiled or used.
module sciter.behavior_factory;

/*
import sciter.event_handler;

// behavior is just named event_handler

class SciterBehaviorFactory
{
    // behavior list support
    SciterBehaviorFactory* next;
    string name; // name must be a pointer to a static string

    this(string external_name)
    {
        // add this implementation to the list (singleton)
        next = root();
        root(this);
    }

    // needs to be overriden
    virtual event_handler* create(HELEMENT he) = 0;


    // returns behavior implementation by name.
    static event_handler* create(const char* name, HELEMENT he)
      {
        for(behavior_factory* t = root(); t; t = t->next)
          if(strcmp(t->name,name)==0)
          {
            return t->create(he);
          }
        return 0; // not found
      }
      // implementation of static list of behaviors
      static behavior_factory* root(behavior_factory* to_set = 0)
      {
        static behavior_factory* _root = 0;
        if(to_set) _root = to_set;
        return _root;
      }

    };

    inline void attach_dom_event_handler(HWINDOW hwnd, event_handler_raw* ph)
    {
      int r = SciterWindowAttachEventHandler( hwnd, &event_handler_raw::element_proc, static_cast<event_handler_raw*>(ph), HANDLE_ALL );
      assert(r == SCDOM_OK); (void)r;
    }

    inline void detach_dom_event_handler(HWINDOW hwnd, event_handler_raw* ph)
    {
      int r = SciterWindowDetachEventHandler( hwnd, &event_handler_raw::element_proc, static_cast<event_handler_raw*>(ph));
      assert(r == SCDOM_OK); (void)r;
    }


}
*/
