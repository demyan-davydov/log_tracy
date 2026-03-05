module domain.document;

import dlt_core.dlt_source;
import dlt_core.decoded_message;
import dlt_core.fibex;
import dlt_core.indexer;
import dlt_core.log_filter : LogFilter;
import dlt_core.dlt_protocol : LogLevel, MessageType;

import domain.document_id;
import domain.document_item;
import domain.index.anchors;

interface DocumentView
{
    enum State
    {
        NotReady,
        Ready,
        BuildingIndex,
        Error,
    }

    size_t itemsCount() nothrow @nogc;

    bool fetchItem(size_t index, scope ref DocumentItem item);

    State state();

    double progress(); // return 1.0 if ready

    void enableFilter(bool enable);

    bool isFilterEnabled() const;

    void applyFilter(LogFilter!wchar filter);

    void resetFilter();
}

interface Document
{
    /*enum Operation
    {
        None,
        BuildingIndex,
        BuildingFilterIndex,
        BuildingSearchIndex,
    }*/

    DocumentView mainView();

    DocumentView searchView();

    DocumentId id() const nothrow @nogc;

    string sourcePath() const nothrow @nogc;

    string fibexPath() const nothrow @nogc;

    string filterPath() const nothrow @nogc;

    void openFibex(string path);

    void applyViewFilter(LogFilter!wchar filter);

    void applySearchFilter(LogFilter!wchar filter);

    bool setAnchor(size_t index, bool value);

    size_t[] exportAnchors() const pure;

    void importAnchors(const(size_t[]) anchors);
}
