//! DocumentItem: a row of a view of a document, its decoded record and what the
//! document knows of it (its index in the log, its anchor, whether the search found it).
module domain.document_item;

import log_core.log_message : LogMessage;

//! @brief represents a single item in the document
//! contains decoded message and metadata
struct DocumentItem
{
    alias Char = wchar;

    @disable this(this); // disable copy constructor

    // index in the original log file, can differ from the index in the document if filters are applied
    size_t realIndex;
    bool anchored;
    //! The current search found it: it matches the search, not only listed by
    //! its anchor (an anchored message is always in the search view)
    bool found;

    package LogMessage!Char _message;

    //! The decoded record; valid until the item is fetched again
    ref const(LogMessage!Char) message() const pure nothrow @nogc return
    {
        return _message;
    }
}
